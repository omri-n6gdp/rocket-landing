# Booster — rocket game (single index.html)

SpaceX-style spaceflight game. One file, no build, no deps (only Google Fonts).
- **Run:** double-click `index.html`. Phone: `./phone.sh` → http://<mac>.local:8090.
- **Owner is not an engineer** — keep it a thing he can run, never administer.

## Architecture

A mission is a chain of **phases**. `PHASES` registry (`init/update/render/hud`)
driven by mission state `RUN`. Cross-phase data passes ONLY via `RUN.carry`.
- Phases: `land` (the original landing sim, behind the interface), `ascent`
  (guided gravity turn, Max-Q, staging), `entry` (re-entry corridor hold).
  Orbit/dock are Parts 2–3 (not built yet).
- Multistage craft model: `mkCraft/craftMass/craftAccel/burnStage/canStage/doStage`.
  A stage's `fuel0` is the snapshot for fuel-bar %.
- Practice mode (Free Flight) keeps the OLD single-flight landing via `landInit`
  with `RUN=null`; it persists to the v2 save (`prog/save`). Campaign uses v3
  (`prog3/save3`). Both are intentional.
- Spec: `docs/superpowers/specs/2026-06-11-full-missions-design.md`.
  Plan: `docs/superpowers/plans/2026-06-11-full-missions-part1-phase-engine-ascent.md`.

## Dev harness (URL hash) — all set `document.title` so a headless runner can grep it

- `#test` — runs the in-page assertion suite → `TESTS PASS n/n` / `TESTS FAIL ...`.
- `#sim:diff:idx` — autopilot flies the WHOLE mission synchronously → `RESULT ...`.
- `#simland:diff:terrain:rocket` — one legacy landing-practice flight (regression).
- `#play:diff:idx` — live autopilot mission (watch it). `#shot:diff:idx:secs` —
  steps `secs` then paints one frame + forces the touch UI (for screenshots).

## Verifying changes (what actually works on this Mac)

`timeout`/`gtimeout` are NOT installed here — don't wrap commands in them (they
fail with exit 127 and silently run nothing). Two working runners:

1. **agent-browser** (most reliable; CDP, not `--dump-dom`). Hash-only URL
   changes don't reload, so bounce through about:blank each time:
   ```bash
   export PATH="/opt/homebrew/bin:$PATH"
   G="file:///Users/omrishahar/code/rocket-landing/index.html"
   b(){ agent-browser open about:blank >/dev/null 2>&1; agent-browser open "$G#$1" >/dev/null 2>&1; agent-browser get title; }
   b test; b sim:realistic:0; b sim:hardcore:1
   ```
   A live mission runs in real time (~25 s+); poll with
   `agent-browser wait --fn "document.title.indexOf('RESULT')===0" --timeout 70000`.
   agent-browser's `viewport` command does NOT resize here; for a phone shot
   launch Chrome directly with `--window-size=390,844 --virtual-time-budget=N
   --screenshot=out.png "$G#play:realistic:0"` (it self-exits; run it backgrounded).
2. Raw `"$CHROME" --headless=new --dump-dom "$G#test" | grep -o '<title>...'`
   also works (no `timeout` wrapper).

## HARD RULES

- **Hash modes bypass the menu.** After any change ALSO verify the human path:
  load with NO hash → menu render loop must stay alive (`tPrev` advances) and
  clicking Launch (`#playBtn`) must enter the mission. A frame-1 render crash
  hid exactly in that gap once (2026-06-11). `render()`/`updateHUD` must never
  assume a run exists.
- Part-1 gate before calling work done: `#test` passes, and autopilot completes
  M1 + M2 on arcade/realistic/hardcore (`RESULT COMPLETE…`, no CRASH/BREAKUP/
  TIMEOUT), plus the 5 practice terrains land.

## Tuning knobs (ascent balance)

`ascDragK` (drag = ascDragK·ρ·speed·v) sets terminal velocity — too high and the
rocket can't reach space. Booster `thrust`/`fuel`/`rate` in `ROCKETS.falcon9`.
Hop vs orbital-shot exit via the ascent phase spec (`hop/cutAlt/hand`). The
ascent autopilot clamps commanded pitch to the difficulty-adjusted Max-Q
envelope (`ascMaxLean`) — keep that margin or it breaks up on hardcore.
