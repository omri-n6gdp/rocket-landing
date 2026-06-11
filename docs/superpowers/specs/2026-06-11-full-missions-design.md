# Booster: Full Missions — Design

**Date:** 2026-06-11 · **Status:** Approved by Omri (chat) · **Supersedes:** landing-only campaign

## 1. Summary & decisions

Extend Booster from a landing game into a full-mission spaceflight game: takeoff, orbit,
transfers, docking, re-entry, landing, multistage rockets.

Decisions made with Omri:

1. **Physics: hybrid.** Real 2D orbital mechanics for orbit/transfer/docking. Ascent is
   semi-scripted (guided gravity turn, not free-form aerodynamics).
2. **The 18-mission landing campaign is replaced** by a ~14-mission full-mission campaign.
   Landing survives as the final phase of missions (and as Free Flight practice, §10).
3. **Architecture: mission = chain of phases.** Each phase is a self-contained mini-sim with
   its own view/controls/physics, stitched with camera transitions. Shared mission state
   (rocket stages, fuel, score, damage) threads through.

## 2. Hard constraints (unchanged from current game)

- One `index.html`. No build step, no dependencies, no network beyond Google Fonts.
- Runs by double-click (file://) on Mac and via `phone.sh` (http) on iPhone Safari.
- 60 fps on an iPhone; canvas 2D only.
- All persistence in `localStorage`.
- Keyboard + the existing touch-button scheme.
- Owner is not an engineer: the game must remain a thing he can run, never administer.

## 3. Architecture

### 3.1 Phase state machine

```
MISSION = { rocket, world(s), phases: [PhaseSpec, ...] }
RUN     = { phaseIdx, craft (stages[], fuel per stage, rcs fuel), score per phase,
            carry-over modifiers (entry offset, orbit error...), elapsed }
```

- One global `update(dt)` and `render()` dispatch to the active phase object:
  `PHASES[spec.type].update(dt)` / `.render()`. Mirrors today's single-loop structure.
- Phase ends by calling `phaseDone(result)` → scripted transition (camera move, 1–2 s,
  non-interactive) → next phase `init(carryOver)`.
- Failure inside a phase ends the mission with the existing report card (verdict per phase
  listed; CRASH/LOST semantics preserved).
- The existing landing sim becomes `PHASES.land` with its current update/render/eval moved
  behind that interface, behaviour unchanged.

### 3.2 Game scale

Two scale domains, never mixed in one frame:
- **Surface domain** (ascent low altitude, landing): metres, current `ppm` camera.
- **Orbital domain** (orbit map, docking-relative): kilometres with planet-radius units,
  own camera. Bodies use game-scaled radii/μ (Earth R≈600 km style compression, like KSP)
  so orbits are minutes, not hours. Exact constants tuned during implementation;
  requirement: LEO period ≈ 2–4 min at ×1, every mission ≤ ~10 min with warp.

## 4. Phase specs

### 4.1 ASCENT (side view, guided)

- Starts on the pad of the mission's world (reuses surface renderer + new pad gantry).
- Controls: throttle (W/↑/THRUST), lean (←/→), **Space = stage**, H autopilot.
- A pitch ladder ghost (reuses autopilot lean-ghost rendering) shows the ideal gravity-turn
  attitude as a function of altitude. Following it ⇒ efficiency score.
- Physics: 2D (x = downrange, y = altitude). Thrust from current stage, mass falls as fuel
  burns, g eases with altitude, exponential atmosphere density for drag + Max-Q.
- **Max-Q rule:** dynamic-pressure proxy q = ρ(alt)·v². If lean exceeds a q-dependent
  envelope → structural failure (BREAKUP verdict). Arcade widens the envelope.
- Staging: stage burnout → "STAGE" prompt; Space separates (spent stage tumbles away as a
  particle-prop). Auto-stage on Arcade. Early/late staging just wastes Δv — no instant fail.
- Camera: starts at landing-game scale; zooms out continuously with altitude; sky gradient
  → black; horizon curvature illusion ramps in above ~30% of atmoTop; stars fade in.
- Exit: speed+altitude reach the mission's MECO window → engine cut → pull-back transition
  into ORBIT with state converted to orbital elements. Under-performance → suborbital arc:
  mission continues directly to ENTRY (emergency), scored accordingly.

### 4.2 ORBIT (map view, real physics)

- View: central body disc + atmosphere ring, your craft marker, **live orbit ellipse**,
  Ap/Pe markers with altitudes, target overlay (dashed orbit or station marker with its
  ellipse), Moon on rails where relevant.
- Propagation: on coast, closed-form Kepler (solve E from M by Newton iteration) — exact
  under warp, zero numerical drift. During burns, warp locks to ×1 and state integrates
  numerically (semi-implicit Euler, dt ≤ 1/120), then elements re-derived.
- Controls: rotate craft (←/→), throttle (W), warp (,/. keys; touch ± buttons) ×1 ×10 ×100
  ×1000. Warp auto-drops to ×1 at guidance-burn windows, SOI crossings, atmosphere contact.
- Guidance (the "helpers"): per objective the game computes a burn solution (Hohmann or
  bi-impulse): draws burn point on the orbit, desired pointing reticle, Δv bar, countdown.
  Difficulty gates: Arcade = full (timer, auto-point option); Realistic = marker + reticle,
  manual timing; Hardcore = target orbit drawn only, no markers.
- Objectives (parameterised per mission): `circularize(alt±tol)`, `raise(Ap,Pe±tol)`,
  `rendezvous(station, range, relV)`, `transfer(moon)` (Ap touches Moon ring → SOI handoff:
  patched two-body, Moon-centric frame, Moon circular on rails), `capture(body, Ap,Pe)`,
  `deorbit(Pe < atmo threshold over target longitude band)` → ENTRY.
- Failure modes: atmosphere dip without deorbit intent (drag warning → forced ENTRY off
  target), escape trajectory without objective (LOST), stage/fuel exhaustion with unmet
  objective (STRANDED verdict + report).
- Scoring: orbit accuracy = f(|Ap−target|, |Pe−target|), fuel margin, time bonus.

### 4.3 DOCK (close view, relative drift)

- Trigger: rendezvous objective met (range < 2 km, |relV| < limit) → cut to metres-scale
  side view: station structure (per-world station sprite: core + panels + port with
  approach-corridor rings), craft with RCS.
- Physics: 2D relative inertia (station frame, no gravity gradient). Nothing decays —
  drift continues until countered. RCS: arrows = translate (4-way), Q/E = rotate,
  consumes RCS budget.
- Success: enter corridor cone, |offset| ≤ port tolerance, |tilt| ≤ tol, contact speed ≤
  limit → verdict via the existing landing evaluator (PERFECT/GOOD/HARD mapped to dock).
- Failure: hit station outside port or above speed limit (bounce + damage; 2 strikes =
  mission fail), RCS exhausted while > stop distance (STRANDED).
- Undock (when mission continues): scripted 3 s separation, no input.

### 4.4 ENTRY (corridor mini-phase, ~20 s)

- Trigger: deorbit objective met (or emergency suborbital). Side view, high-speed streak,
  plasma particles, heat bar, G readout.
- Control: ←/→ holds attitude inside a drifting safe cone (cone width by difficulty;
  crewed missions also impose a G ceiling shown on the HUD).
- Outside cone → heat/G accumulate → BURNUP fail. Inside → speed bleeds to landing-handoff.
- Exit quality sets LANDING initial conditions: position offset from pad (up to ±120 m),
  extra |vx|, start altitude (good entry ⇒ today's standard start state).

### 4.5 LAND (existing game, verbatim)

- Current surface sim, terrain kinds, hazards, evaluation, scoring — moved behind the
  phase interface, logic untouched. Mission-defined world/terrain/rocket-stage.
- The tower-catch and drone-ship variants remain; "Booster Catch" mission runs LAND as a
  **mid-mission** phase for stage 1, then returns to ORBIT for stage 2 (see §7 M8).

## 5. Multistage rocket model

```
ROCKETS.falcon9 = { name, style, stages: [
  { name:'Booster',  thrust, dry, fuel, gimbal:true,  canLand:true  },
  { name:'Stage 2',  thrust, dry, fuel, gimbal:true,  rcs:true      },
], rcsBudget, h, w, ... }
```

- Stages define `thrust`, `dry` mass and `fuel` mass (arbitrary consistent units);
  effective accel = thrust / (dry + fuel remaining of this stage + mass of stages above).
  Staging drops dead mass → felt TWR jump (the fun of staging).
- Roster: Falcon 9 (2-stage), Starship (Super Heavy + Ship), Grasshopper (1-stage, hops
  only), Falcon Heavy (boost stage + core + S2 simplified to 2 logical stages), Lunar
  Lander (descent+ascent stages — ascent stage flies Moon-takeoff missions).
- Existing single-value rockets become the relevant single stage for LAND-only contexts
  (Free Flight practice).

## 6. Worlds & stations

- WORLDS gain orbital params: `{R, mu, atmoTop, soi, orbitColor}`; Earth and Mars get
  atmosphere entry bands; Moon: none (no ENTRY phase — direct descent to LAND).
- Moon orbits Earth on rails (circle, period game-scaled); Mars missions start in
  Mars-approach (no interplanetary cruise — see cuts §12).
- STATIONS: `alpha` (Earth LEO), `gateway` (lunar orbit), `aresOrbiter` (Mars orbit).
  On-rails circular orbits; sprite assembled from parts; one port each.

## 7. Campaign (replaces old 18; ~14 missions)

| # | Name | Recipe (phases) | Teaches |
|---|------|-----------------|---------|
| 1 | First Flight | ascent(hop) → land(downrange pad) | throttle, lean, staging |
| 2 | Kármán Line | ascent(100 km) → entry → land | entry cone |
| 3 | Orbit! | ascent → orbit(circularize) → orbit(deorbit) → entry → land | the orbit map |
| 4 | Rendezvous | ascent → orbit(circ) → orbit(rendezvous) → deorbit → entry → land | phasing/chase |
| 5 | First Docking | … → dock → undock → deorbit → entry → land | docking |
| 6 | Resupply Run | heavy cargo variant of 5, tighter fuel | mass management |
| 7 | Crew Rotation | 5 with G-ceiling entry + night dock | precision under limits |
| 8 | Booster + Catch | ascent(stage1) → **land(tower-catch, stage 1)** → orbit(stage 2 circ) → deorbit → entry → land(ship) — sequential: you catch the booster, then a "MEANWHILE" card cuts to stage 2 already coasting | multistage showpiece |
| 9 | To the Moon | ascent → orbit(circ) → transfer(Moon) → capture → land(Moon, lander) | TLI, SOI, capture |
| 10 | Homeward | ascent(Moon) → orbit(Moon circ) → transfer(Earth) → entry → land(ship at sea) | return legs |
| 11 | Lunar Gateway | Moon mission ending in dock at gateway | combo |
| 12 | Mars Arrival | capture(Mars) → orbit(adjust) → entry(dust) → land(mountains) | arrival ops |
| 13 | Mars Ascent | ascent(Mars) → orbit(circ) → rendezvous → dock(aresOrbiter) | ascent-to-dock |
| 14 | Grand Tour | ascent → dock(refuel) → transfer(Moon) → capture → land(Moon) → ascent(Moon) → transfer(Earth) → entry → land(catch) | everything |

Unlock model unchanged (finish N unlocks N+1, per difficulty). Mission definitions are a
data table like today's CAMPAIGN — phases are parameterised specs, no per-mission code.

## 8. Difficulty & helpers

| | Arcade | Realistic | Hardcore |
|---|---|---|---|
| Burn guidance | marker + countdown + auto-point | marker + reticle | target orbit only |
| Staging | auto option | manual | manual |
| Tolerances (orbit/dock/land) | wide (current ×1.3-ish) | current | tight |
| Fuel | ×1.3 | ×1.0 | ×0.88 |
| Entry cone / Max-Q envelope | wide | normal | narrow |
| Score mult | ×1.0 | ×1.5 | ×2.0 |

This **activates the existing dead `DIFFS[*].fuelMul` config** (until now defined but
never applied) — part of this redesign, not a silent balance change to the old game.

## 9. Scoring, report, persistence

- Per-phase score (each phase defines its 0–1 quality factors × weight) summed → mission
  score × difficulty mult × mission index bonus (same shape as today).
- Report card lists each phase with its verdict + the headline verdict = worst critical
  phase (a PERFECT landing can't rescue a HARD dock).
- Save: `boosterLanding.v3` = `{ perDiff: {unlocked, best[missionIdx]}, mute }`.
  v2 keys ignored (campaign replaced; autopilot runs were never saved anyway).

## 10. Menu & Free Flight

- Tabs: **Campaign** (the 14) · **Free Flight** (sandbox: pick a single phase recipe —
  "Just orbit", "Docking practice", "Landing practice (old game)", "Full custom mission" —
  plus world/rocket/terrain pickers). Landing practice preserves the old quick-play loop
  with the old terrain kinds.
- Mission cards show phase-chain icons (🚀🌍🔗🔥🛬) instead of the old tags.

## 11. Controls (per phase) & HUD

- Desktop: W/↑ throttle · ←/→ steer/translate · Space stage · Z/X RCS lateral (dock:
  arrows 4-way + Q/E rotate) · ,/. warp · H autopilot · P pause · R retry · Esc menu.
- Touch: existing buttons re-skinned per phase; new STAGE button (appears only when
  relevant), warp − / + pair on orbit map, 4-way RCS pad in dock.
- HUD swaps card sets per phase (ascent: ALT/SPEED/PITCH/Q + stage fuel bars · orbit:
  AP/PE/PERIOD/Δv + warp + target deltas · dock: RANGE/CLOSING/ALIGN + RCS bar · entry:
  HEAT/G/SPEED · land: current HUD). Same visual language (tcards/bars).
- Autopilot H cycles OFF/AUTO/ASSIST in every phase: ascent flies the ladder; orbit
  executes the computed burns; dock = PD approach; entry holds cone centre; land = current.

## 12. Cuts (explicit non-goals)

No interplanetary cruise (Mars starts at arrival). No 3D, no n-body, no orbital decay,
no life support, no EVA, no multiple ports/stations per body, no aero lift modelling,
no inclination (everything coplanar 2D).

## 13. Audio

Reuse thrust noise/blips/boom. Add (all synthesised, same WebAudio style): staging thunk,
RCS tick-hiss, warp riser, docking clunk + latch, entry rumble (filtered noise scaled by
heat), guidance beeps (burn window open/close).

## 14. Testing & verification plan

- Hash harness extends: `#sim:diff:idx` = autopilot flies the **whole mission**
  synchronously, result → `document.title` (existing pattern); `#phase:diff:idx:phaseIdx`
  = jump to a phase with canned nominal entry state (manual/visual testing);
  `#shot:...` unchanged.
- Regression matrix: autopilot must complete all 14 missions × 3 difficulties (42 runs)
  before any milestone is called done.
- **Menu-path test is mandatory** (open page with no hash, click Launch via browser
  automation): the 2026-06-11 frame-1 crash hid exactly in the gap the hash harness
  bypasses. Frame-1 render with no run state must stay safe (`env`-guard pattern).
- Per-phase unit sims: each phase must be startable standalone from a canned state
  (this is what `#phase:` exists for) so bugs localise.
- Performance: orbit map must hold 60 fps with ellipse + markers + particles on phone
  (ellipses drawn from cached sampled points, re-sampled only when elements change).

## 15. Build order (for the implementation plan)

1. Phase-machine skeleton + existing landing game moved behind the phase interface
   (game must remain fully playable as landing-only at this checkpoint).
2. Ascent phase (+staging, Max-Q, transition out) → missions 1–2 playable.
3. Orbit map (Kepler propagation, warp, circularize/deorbit guidance) → mission 3.
4. Rendezvous + dock → missions 4–7.
5. Entry phase polish + crew G-limits.
6. Moon SOI/transfer/capture + Moon missions; multistage showpiece (M8).
7. Mars missions, stations roster, Free Flight sandbox modes.
8. Campaign table finalisation, scoring balance pass, audio additions, touch polish,
   full matrix + menu-path verification.
