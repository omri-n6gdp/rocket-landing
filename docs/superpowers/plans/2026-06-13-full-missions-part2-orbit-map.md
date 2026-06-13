# Full Missions Part 2: Orbit Map + Mission 3 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an ORBIT phase — a map-view mini-sim with real 2D two-body orbital mechanics, time-warp, and circularize/deorbit guidance — and wire it into a new Mission 3 "Orbit!" (`ascent → orbit:circularize → orbit:deorbit → entry → land`).

**Architecture:** A new `PHASES.orbit` object joins the existing registry (`ascent`/`entry`/`land`). It runs in its own scale domain (planet-centric, kilometres) with its own camera and renderer, never mixed with the surface domain. Orbits are propagated closed-form (solve Kepler's equation) while coasting — exact under any warp factor, zero numerical drift — and integrated numerically only during thrust. Objectives (circularize, deorbit) are parameterised specs; a guidance solver computes the burn and the difficulty-gated HUD overlay. The ascent MECO window inserts onto a fixed, deterministic ellipse; the deorbit objective lowers periapsis into the atmosphere and hands off to the existing ENTRY phase.

**Tech Stack:** Vanilla JS + canvas 2D, in one `index.html`. No deps, no build. Testing: in-page `#test` assertion runner + the agent-browser harness (see project `CLAUDE.md`).

**Scope (per spec §15 build-order item 3):** ORBIT map + Mission 3 ONLY. Rendezvous, docking, transfers, SOI, and missions 4–14 are Parts 3+ and get their own plan documents. This plan must leave the game fully playable with M1, M2, and the new M3 all completable under autopilot on all three difficulties.

---

## Context for the engineer (read first)

- **Read the project `CLAUDE.md` first** for architecture and the verification harness. The whole game is one `index.html` (~1328 lines, one `<script>` at the bottom). Read it before Task 4.
- **Spec:** `docs/superpowers/specs/2026-06-11-full-missions-design.md` — this plan covers §3.2 (two scale domains), §4.2 (ORBIT), §7 mission 3, §8 (difficulty guidance gating), §9 (scoring/report), §11 (HUD/controls per phase), §14 (testing).
- **Part 1 is done and merged** (tag `part1-complete`). Existing anchors (current line numbers; re-grep before editing, the file grows):
  - `WORLDS` table: line ~288 · `ROCKETS`/`CRAFT`: ~294–322 · `DIFFS`: ~324 · `CAMPAIGN`: ~345
  - state vars (`RUN/PH/TRANS`, `M/MS/T/WLD`, `R/env`, `ap`): ~384–392 · input/`readKeys`: ~394–412
  - phase engine (`startMission/nextPhase/phaseDone/skipTransition/stepTransition`): ~471–501
  - `PHASES.land`: ~527 · `PHASES.ascent`: ~540 (ascent exit/carry ~595–598; `ap()` ~608) · `PHASES.entry`: ~673
  - `endMission`: ~932 · `render()` dispatch: ~959 (`if(RUN&&PH&&PH!==PHASES.land){ PH.render(); }`) · `updateHUD`/`setCardLabels`: ~1133/1138
  - `loop()`: ~1232 · TESTS block: ~1240–1306 · hash IIFE (`#test/#sim/#simland/#play/#shot`): ~1307
- **House style:** terse, single-letter-ish locals, section banners `/* ═══ name ═══ */`, comments only for non-obvious constraints. Match it.
- **Verification harness (proven this session — `timeout` is NOT installed on this Mac, never wrap commands in it):**

```bash
export PATH="/opt/homebrew/bin:$PATH"
G="file:///Users/omrishahar/code/rocket-landing/index.html"
# b <hash>: bounce through about:blank (forces reload — hash-only changes don't) then print <title>
b(){ agent-browser open about:blank >/dev/null 2>&1; agent-browser open "$G#$1" >/dev/null 2>&1; agent-browser get title; }
# usage: b test ; b sim:realistic:2 ; b phase:realistic:2:1
```

Define `b` once per shell. Every "Run:" step below assumes it. A full live mission runs in real time; `#sim` runs it synchronously to a `RESULT …` title.

- **Frame-1 rule (hard):** hash modes bypass the menu. After any change ALSO load with no hash and confirm the menu loop is alive (`tPrev` advances) and clicking `#playBtn` enters the mission. `render()`/`updateHUD` must never assume a run exists.
- **Commit after every task.** Footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## Scale & units (lock these in — Task 1 encodes them)

Orbit domain works in **kilometres and seconds**; velocity km/s; `mu` in km³/s². Surface domain (ascent/entry/land) stays in metres and is NEVER drawn in the same frame (spec §3.2). The two domains connect only through `RUN.carry` at phase transitions — this is a designed remap, not physical continuity.

Earth constants (added to `WORLDS.port`/`WORLDS.sea`): `R=600` (body radius km), `mu=400000` (km³/s²), `atmoH=70` (atmosphere shell thickness km — drawn as a ring), `atmoEntry=40` (altitude km below which a descending craft hits the entry interface), `soi=null` (Parts 3+). Sanity: circular LEO at 120 km altitude → r=720, v=√(mu/720)≈23.6 km/s, period 2π·720/23.6≈192 s ≈ 3.2 min — inside the spec's 2–4 min target.

## File structure

Everything stays in `index.html`. New `<script>` sections, in this order:
- **ORBITAL MECHANICS** (pure math) — after the `CRAFT` section (~line 322).
- **ORBIT PHASE** (`ORB` state, `PHASES.orbit`, guidance, `orbRender`, warp) — after the `PHASES.entry` block (~line 730).
- Tests appended to the TESTS block; `#phase` added to the hash IIFE.

Within-file module boundary: the orbit phase touches only its own `ORB` state + shared services (`RUN`, craft fns, `phaseDone`, audio, input, canvas). It does NOT read `R/env/T/M` (those are surface-domain). Cross-phase data passes ONLY via `RUN.carry`.

---

### Task 1: Orbital math core + body constants

**Files:** Modify `index.html` — new ORBITAL MECHANICS section after the CRAFT block (~line 322); add fields to `WORLDS`; tests appended to TESTS block.

All game orbits are **counterclockwise (prograde, h>0)** and **elliptic (0≤e<1)** by construction; the math assumes this (documented, not defended).

- [ ] **Step 1: Write failing tests** (append to the TESTS block, before the hash IIFE)

```js
T_('orbit: circular orbit has e~0 and the spec period', ()=>{
  const mu=400000, r0=720, v=Math.sqrt(mu/r0);
  const el=orbElements(r0,0, 0,v, mu);
  near(el.e,0,1e-6,'circular'); near(el.a,r0,1e-6,'a=r');
  ok(el.period>120&&el.period<240,'LEO period 2-4 min, got '+el.period);
});
T_('orbit: ellipse apoapsis/periapsis from a,e', ()=>{
  const mu=400000, a=700, e=0.2;                 // start at periapsis
  const rp=a*(1-e), vp=Math.sqrt(mu*(2/rp-1/a));
  const el=orbElements(rp,0, 0,vp, mu);
  near(el.pe,rp,1e-4,'pe'); near(el.ap,a*(1+e),1e-4,'ap'); near(el.e,e,1e-4,'e');
});
T_('orbit: Kepler solver inverts mean anomaly', ()=>{
  for(const e of [0,0.1,0.5,0.85]) for(const M of [0.3,1.7,3.0,5.5]){
    const E=solveKepler(M,e); near(E-e*Math.sin(E),M,1e-9,'e='+e+' M='+M); }
});
T_('orbit: coast advances ccw and round-trips over a full period', ()=>{
  const mu=400000, r0=720, v=Math.sqrt(mu/r0);
  const el=orbElements(r0,0, 0,v, mu);
  const q=orbAdvance(el, el.period/4, mu);       // quarter turn ccw: (r,0)->(0,r)
  near(q.x,0,1e-2,'x~0'); near(q.y,r0,1e-2,'y~r');
  const full=orbAdvance(el, el.period, mu);
  near(full.x,r0,1e-2,'back to x'); near(full.y,0,1e-2,'back to y');
});
T_('orbit: vCirc and escape classification', ()=>{
  const mu=400000; near(vCirc(720,mu), Math.sqrt(mu/720), 1e-9);
  const el=orbElements(720,0, 0,Math.sqrt(2*mu/720)+0.5, mu);  // above escape speed
  ok(el.energy>0 || el.a<0, 'hyperbolic/escape detected');
});
```

- [ ] **Step 2: Run, verify FAIL** — Run: `b test` → `TESTS FAIL 5/15 :: orbit: … orbElements is not defined` (count: 10 existing + 5 new; first failure name may vary).

- [ ] **Step 3: Implement the math** — insert after the CRAFT section:

```js
/* ═════════════════ ORBITAL MECHANICS (2D planet-centric, km & s) ═════════════════
   r=(x,y) km from body centre, v=(vx,vy) km/s, mu in km^3/s^2.
   Assumes prograde counterclockwise (h>0), elliptic (0<=e<1) — the only orbits the game makes. */
function vCirc(r,mu){ return Math.sqrt(mu/r); }
function orbElements(rx,ry,vx,vy,mu){
  const r=Math.hypot(rx,ry), v2=vx*vx+vy*vy, rv=rx*vx+ry*vy;
  const energy=v2/2 - mu/r, a=-mu/(2*energy);
  const ex=(v2/mu - 1/r)*rx - rv/mu*vx, ey=(v2/mu - 1/r)*ry - rv/mu*vy;
  const e=Math.hypot(ex,ey), omega=Math.atan2(ey,ex);
  let nu=Math.atan2(ry,rx)-omega; nu=Math.atan2(Math.sin(nu),Math.cos(nu));
  const okElliptic=energy<0;
  return { a,e,omega,nu,energy, h:rx*vy-ry*vx,
           ap: okElliptic? a*(1+e):Infinity, pe: a*(1-e),
           period: okElliptic? 2*Math.PI*Math.sqrt(a*a*a/mu):Infinity,
           n: okElliptic? Math.sqrt(mu/(a*a*a)):0 };
}
function solveKepler(M,e){ M=Math.atan2(Math.sin(M),Math.cos(M)); let E=e<0.8?M:Math.PI;
  for(let i=0;i<8;i++){ const d=(E-e*Math.sin(E)-M)/(1-e*Math.cos(E)); E-=d; if(Math.abs(d)<1e-12)break; } return E; }
function eccFromTrue(nu,e){ return Math.atan2(Math.sqrt(1-e*e)*Math.sin(nu), e+Math.cos(nu)); }
function trueFromEcc(E,e){ return Math.atan2(Math.sqrt(1-e*e)*Math.sin(E), Math.cos(E)-e); }
function orbStateAt(a,e,omega,nu,mu){                      // perifocal -> world (ccw)
  const p=a*(1-e*e), r=p/(1+e*Math.cos(nu)), vp=Math.sqrt(mu/p);
  const cx=r*Math.cos(nu), cy=r*Math.sin(nu), vcx=-vp*Math.sin(nu), vcy=vp*(e+Math.cos(nu));
  const c=Math.cos(omega), s=Math.sin(omega);
  return { x:cx*c-cy*s, y:cx*s+cy*c, vx:vcx*c-vcy*s, vy:vcx*s+vcy*c, r };
}
function orbAdvance(el, dt, mu){                            // closed-form coast step
  const E0=eccFromTrue(el.nu,el.e), M0=E0-el.e*Math.sin(E0);
  const E=solveKepler(M0+el.n*dt, el.e), nu=trueFromEcc(E,el.e);
  return orbStateAt(el.a, el.e, el.omega, nu, mu);
}
```

- [ ] **Step 4: Add orbital constants to WORLDS** (same edit; keep existing fields):

```js
// append to each (Parts 3+ fill moon/mars properly):
sea:  {... atmoTop:10000, R:600, mu:400000, atmoH:70, atmoEntry:40, orbitColor:'#5cc8ff'},
port: {... atmoTop:10000, R:600, mu:400000, atmoH:70, atmoEntry:40, orbitColor:'#5cc8ff'},
moon: {... atmoTop:0,     R:300, mu:90000,  atmoH:0,  atmoEntry:0,  orbitColor:'#aab3c6'},
mars: {... atmoTop:7000,  R:480, mu:260000, atmoH:50, atmoEntry:30, orbitColor:'#ff9b6b'},
```

- [ ] **Step 5: Run, verify PASS** — Run: `b test` → `TESTS PASS 15/15`. Run: `b ''` → `Booster — Rocket Landing` (clean frame-1, no orbit code touches startup).

- [ ] **Step 6: Commit**

```bash
git add index.html && git commit -m "feat: 2D orbital-mechanics core (Kepler propagation) + body constants

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Orbit state + propagation + time-warp

**Files:** Modify `index.html` — new ORBIT PHASE section after `PHASES.entry` (~line 730); tests appended.

`ORB` holds the live orbit as a **state vector** (`x,y,vx,vy`) plus cached elements. Coasting advances closed-form (warp-safe). Thrust integrates numerically at ×1 only.

- [ ] **Step 1: Write failing tests** (append)

```js
T_('orbit: coast is warp-invariant (closed-form, no drift)', ()=>{
  const mu=400000; ORB=mkOrbit(720,0, 0,vCirc(720,mu), mu);
  const big=()=>{ const o=mkOrbit(720,0,0,vCirc(720,mu),mu); for(let i=0;i<1;i++) orbCoast(o, 50, mu); return o; };
  const small=()=>{ const o=mkOrbit(720,0,0,vCirc(720,mu),mu); for(let i=0;i<5000;i++) orbCoast(o, 50/5000, mu); return o; };
  const A=big(), B=small();
  near(A.x,B.x,1e-3,'x warp-invariant'); near(A.y,B.y,1e-3,'y warp-invariant');
});
T_('orbit: a prograde burn raises apoapsis', ()=>{
  const mu=400000; const o=mkOrbit(720,0, 0,vCirc(720,mu), mu);
  const ap0=orbElements(o.x,o.y,o.vx,o.vy,mu).ap;
  orbBurn(o, 1.0, 0.5, mu);                 // +1 km/s prograde over 0.5 s of dt
  ok(orbElements(o.x,o.y,o.vx,o.vy,mu).ap > ap0+1, 'apoapsis rose');
});
T_('warp: clamps to the ladder and never goes below 1', ()=>{
  eq(warpStep(1,+1),10); eq(warpStep(10,+1),100); eq(warpStep(1000,+1),1000,'caps');
  eq(warpStep(1,-1),1,'floor'); eq(warpStep(100,-1),10);
});
```

- [ ] **Step 2: Run, verify FAIL** — `b test` → `TESTS FAIL 3/18 :: … mkOrbit is not defined`.

- [ ] **Step 3: Implement** — insert at the top of the ORBIT PHASE section:

```js
/* ═════════════════ ORBIT PHASE ═════════════════
   Own scale domain (km, planet-centric). Coast = closed-form Kepler (warp-safe);
   thrust = numerical integrate at warp 1. Talks to the rest only via RUN.carry. */
let ORB=null;
const WARPS=[1,10,100,1000];
function warpStep(w,dir){ let i=WARPS.indexOf(w); if(i<0)i=0; i=clamp(i+dir,0,WARPS.length-1); return WARPS[i]; }
function mkOrbit(x,y,vx,vy,mu){ const o={x,y,vx,vy,mu}; o.el=orbElements(x,y,vx,vy,mu); return o; }
function orbCoast(o, dt, mu){                       // advance along the conic, exact
  o.el=orbElements(o.x,o.y,o.vx,o.vy,mu);
  if(o.el.energy>=0) return;                        // escape: caller handles (LOST)
  const s=orbAdvance(o.el, dt, mu); o.x=s.x; o.y=s.y; o.vx=s.vx; o.vy=s.vy;
}
function orbBurn(o, dvMag, dt, mu){                 // numerical integrate thrust at warp 1
  const steps=Math.max(1,Math.ceil(dt/(1/120)));    // dt<=1/120 per substep
  const h=dt/steps, aThr=dvMag/dt;                  // accel along current velocity dir
  for(let i=0;i<steps;i++){
    const r=Math.hypot(o.x,o.y), gr=-o.mu/(r*r), sp=Math.hypot(o.vx,o.vy)||1;
    const ax=gr*o.x/r + aThr*o.vx/sp, ay=gr*o.y/r + aThr*o.vy/sp;
    o.vx+=ax*h; o.vy+=ay*h; o.x+=o.vx*h; o.y+=o.vy*h;   // semi-implicit Euler
  }
  o.el=orbElements(o.x,o.y,o.vx,o.vy,mu);
}
```

(Note: `orbBurn`'s 4th test arg `mu` matches `o.mu`; the signature keeps `mu` explicit for symmetry with the other fns. The test passes `mu`; `orbBurn` uses `o.mu` internally — keep both equal.)

- [ ] **Step 4: Run, verify PASS** — `b test` → `TESTS PASS 18/18`.

- [ ] **Step 5: Commit**

```bash
git add index.html && git commit -m "feat: orbit state, closed-form coast, burn integration, warp ladder

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Guidance solver (circularize / deorbit)

**Files:** Modify `index.html` — ORBIT PHASE section (after Task 2 code); tests appended.

A guidance solution names the **burn point** (true anomaly), the **Δv** (signed: + prograde, − retrograde), the pointing, and whether the objective is **met**. Tolerances scale with difficulty.

- [ ] **Step 1: Write failing tests** (append)

```js
T_('guidance: circularize wants a prograde burn at apoapsis and detects completion', ()=>{
  const mu=400000, ra=720, rp=660, a=(ra+rp)/2;          // ellipse, apoapsis 720
  const vAp=Math.sqrt(mu*(2/ra-1/a)); const o=mkOrbit(0,ra, vAp,0, mu);  // at apoapsis, moving +x (ccw)
  const g=orbGuide({type:'circularize',alt:120}, o, 600, 'realistic'); // R=600 -> alt 120 = r 720
  ok(g.dv>0,'prograde'); ok(Math.abs(g.dv-(vCirc(ra,mu)-vAp))<1e-3,'dv to circular');
  ok(!g.met,'eccentric not yet circular');
  const c=mkOrbit(0,720, vCirc(720,mu),0, mu);
  ok(orbGuide({type:'circularize',alt:120}, c, 600, 'realistic').met,'circular meets it');
});
T_('guidance: deorbit wants retrograde and completes when periapsis enters atmosphere', ()=>{
  const mu=400000; const c=mkOrbit(0,720, vCirc(720,mu),0, mu);
  const g=orbGuide({type:'deorbit',entryAlt:40}, c, 600, 'realistic');
  ok(g.dv<0,'retrograde to drop periapsis');
  const decaying=mkOrbit(0,720, vCirc(720,mu)*0.82,0, mu);    // periapsis now deep
  ok(orbGuide({type:'deorbit',entryAlt:40}, decaying, 600, 'realistic').met,'pe in atmosphere');
});
```

- [ ] **Step 2: Run, verify FAIL** — `b test` → `TESTS FAIL 2/20 :: … orbGuide is not defined`.

- [ ] **Step 3: Implement** — insert after the Task-2 functions:

```js
/* objective specs: {type:'circularize',alt} | {type:'deorbit',entryAlt}
   returns {dv (signed km/s), burnNu (rad), met (bool), kind ('prograde'|'retrograde'), label} */
function orbGuide(obj, o, R, diff){
  const mu=o.mu, el=orbElements(o.x,o.y,o.vx,o.vy,mu);
  const tolE = diff==='arcade'?0.04 : diff==='hardcore'?0.012 : 0.022;     // eccentricity tolerance
  if(obj.type==='circularize'){
    const rTgt=R+obj.alt, ra=el.ap, burnNu=Math.PI;                        // circularize at apoapsis
    const vAp=Math.sqrt(mu*(2/ra-1/el.a)), dv=vCirc(ra,mu)-vAp;
    const altTol = diff==='arcade'?40 : diff==='hardcore'?12 : 22;
    const met = el.e<tolE && Math.abs(el.a-rTgt)<altTol;
    return {dv, burnNu, met, kind:'prograde', label:'CIRCULARIZE'};
  } else { // deorbit
    const rEntry=R+obj.entryAlt, ra=el.ap;
    const aT=(ra+rEntry)/2, vAt=Math.sqrt(mu*(2/ra-1/aT)), vNow=Math.sqrt(mu*(2/ra-1/el.a));
    const met = el.pe <= rEntry;
    return {dv: vAt-vNow, burnNu:Math.PI, met, kind:'retrograde', label:'DEORBIT'};
  }
}
```

- [ ] **Step 4: Run, verify PASS** — `b test` → `TESTS PASS 20/20`.

- [ ] **Step 5: Commit**

```bash
git add index.html && git commit -m "feat: orbit guidance solver (circularize + deorbit, difficulty tolerances)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: PHASES.orbit (logic) + ascent→orbit + orbit→entry handoffs

**Files:** Modify `index.html` — ORBIT PHASE section (add `PHASES.orbit`); ascent exit (~line 595); `#sim`/`#phase` hash; tests appended.

The orbit phase: insert from carry, coast/warp, let the player (or AP) rotate + burn toward the objective, complete → `phaseDone(carry)`. Deorbit completion hands an entry carry to the existing ENTRY phase.

- [ ] **Step 1: Write failing tests** (append) — drive the phase headlessly with the AP

```js
T_('orbit phase: AP circularizes then reports OK', ()=>{
  diff='realistic'; ap=1;
  RUN={ idx:99, m:{name:'t',phases:[{type:'orbit',label:'CIRC',world:'port',obj:{type:'circularize',alt:120}}]},
        pi:-1, results:[], carry:{}, score:0, craft:mkCraft('falcon9') };
  _missionReportHook=r=>{ RUN.done=r; };
  nextPhase();                                   // enters orbit, inserts
  let n=0; while(!RUN.done && PH===PHASES.orbit && n<200000){ PH.update(1/60); n++; }
  ok(RUN.results[0],'phase ended'); eq(RUN.results[0].fail,undefined,'no fail');
  ok(orbElements(ORB.x,ORB.y,ORB.vx,ORB.vy,WLD.mu).e<0.05,'left ~circular');
  _missionReportHook=null; RUN=null; PH=null; ORB=null;
});
T_('orbit phase: insertion orbit is elliptic with apoapsis near target', ()=>{
  diff='realistic';
  RUN={ idx:99, m:{name:'t',phases:[{type:'orbit',label:'CIRC',world:'port',obj:{type:'circularize',alt:120}}]},
        pi:-1, results:[], carry:{}, score:0, craft:mkCraft('falcon9') };
  nextPhase();
  const el=orbElements(ORB.x,ORB.y,ORB.vx,ORB.vy,WLD.mu);
  ok(el.e>0.02,'starts eccentric (something to circularize)');
  ok(el.ap>WLD.R+90,'apoapsis near LEO target');
  RUN=null; PH=null; ORB=null;
});
```

- [ ] **Step 2: Run, verify FAIL** — `b test` → `TESTS FAIL 2/22 :: … Cannot read properties of undefined (PHASES.orbit)`.

- [ ] **Step 3: Implement `PHASES.orbit`** — insert after the guidance solver:

```js
let orbWarp=1, orbBurning=false;
PHASES.orbit={
  init(spec,carry){
    WLD=WORLDS[spec.world]; const mu=WLD.mu, R=WLD.R, D=DIFFS[diff];
    M={ rw:ROCKETS[RUN.craft.rk].w, rh:ROCKETS[RUN.craft.rk].h, style:ROCKETS[RUN.craft.rk].style, mult:D.mult, mc:D.dc };
    T=null; env=null; document.body.classList.remove('asc');
    orbWarp=1; orbBurning=false;
    // insertion: fixed deterministic ellipse — apoapsis at LEO target, periapsis just above the atmosphere.
    // carry.emergency (ascent under-performed) => periapsis BELOW entry => decays straight to ENTRY.
    const ra=R+(spec.obj&&spec.obj.alt||120), rp = carry.emergency ? R+WLD.atmoEntry-20 : R+WLD.atmoEntry+25;
    const a=(ra+rp)/2, vAp=Math.sqrt(mu*(2/ra-1/a));
    ORB=mkOrbit(0, ra, vAp, 0, mu);              // start AT apoapsis moving +x (ccw)
    O={ spec, obj:spec.obj, ang:Math.atan2(ORB.vy,ORB.vx), score:0, t:0, burnT:0, dvSpent:0 };
    $('#missionTag').innerHTML='<b>'+WLD.name+'</b> · '+ROCKETS[RUN.craft.rk].name+' · '+RUN.m.name;
  },
  update(dt){
    O.t+=dt; readKeys();
    const c=RUN.craft, s=c.stages[c.si], mu=WLD.mu, R=WLD.R;
    const g=orbGuide(O.obj, ORB, R, diff);
    const inp = ap!==0 ? this.ap(dt,g) : { thr:input.thr, left:input.left, right:input.right,
      warpUp:keys['.']||input._tWarpUp, warpDn:keys[',']||input._tWarpDn };
    // warp (edge-triggered; never while thrusting / near a burn / near atmosphere)
    if(inp.warpUp&&!O._wu){ orbWarp=warpStep(orbWarp,+1); } O._wu=inp.warpUp;
    if(inp.warpDn&&!O._wd){ orbWarp=warpStep(orbWarp,-1); } O._wd=inp.warpDn;
    if(ORB.el && (ORB.el.pe < R+WLD.atmoH+30)) orbWarp=Math.min(orbWarp,10);     // calm down near atmosphere
    // rotate craft (free in vacuum)
    O.ang += ((inp.right?1:0)-(inp.left?1:0))*2.2*dt;
    // thrust: locks warp to 1, burns stage fuel, applies dv along facing
    orbBurning = !!inp.thr && s.fuel>0;
    if(orbBurning){ orbWarp=1;
      const acc=craftAccel(c,1)/1000;                 // m/s^2 -> km/s^2 (game thrust is "surface" scale; /1000 to km)
      const dv=acc*dt; ORB.vx+=Math.cos(O.ang)*dv*0; // see note: we steer by O.ang but burn prograde/retro via sign
      orbBurnAlong(ORB, O.ang, dv, mu); burnStage(c,1,dt); O.dvSpent+=dv;
      setThrustSound(1);
    } else setThrustSound(0);
    // propagate
    const eff=orbBurning?dt:dt*orbWarp;
    if(!orbBurning) orbCoast(ORB, eff, mu);
    ORB.el=orbElements(ORB.x,ORB.y,ORB.vx,ORB.vy,mu);
    // outcomes
    if(ORB.el.energy>=0){ phaseDone({fail:'LOST',reason:'Escaped to a hyperbolic trajectory',score:0}); return; }
    if(O.obj.type==='deorbit' && ORB.el.pe <= R+WLD.atmoEntry){
      const vAtmo=Math.sqrt(mu*(2/(R+WLD.atmoEntry)-1/ORB.el.a));
      phaseDone({verdict:'OK', score:this.scoreIt(g),
        carry:{ v: clamp(vAtmo*7, 90, 240), emergency:false }}); return;   // hand to ENTRY (km/s -> entry units)
    }
    if(O.obj.type==='deorbit' && (ORB.el.pe <= R+WLD.atmoH+5)) {/* drag zone — keep going, will hit entryAlt */}
    if(ORB.el.pe <= R){ phaseDone({fail:'LOST',reason:'Periapsis hit the surface',score:0}); return; }   // crashed orbit (no deorbit intent path for M3 circ phase)
    if(g.met && !orbBurning && O.obj.type!=='deorbit'){
      phaseDone({verdict:'OK', score:this.scoreIt(g)}); return;            // objective complete (e.g. circularize)
    }
  },
  ap(dt,g){
    const out={thr:0,left:0,right:0,warpUp:0,warpDn:0};
    // point along the burn direction: prograde = +velocity, retrograde = -velocity
    const velAng=Math.atan2(ORB.vy,ORB.vx);
    const want = g.kind==='retrograde' ? velAng+Math.PI : velAng;
    let dA=Math.atan2(Math.sin(want-O.ang),Math.cos(want-O.ang));
    if(dA>0.05) out.right=1; else if(dA<-0.05) out.left=1;
    // are we at the burn point (apoapsis)? nu near burnNu within a window
    const atBurn = Math.abs(Math.atan2(Math.sin(ORB.el.nu-g.burnNu),Math.cos(ORB.el.nu-g.burnNu))) < 0.18;
    const aligned = Math.abs(dA)<0.08;
    if(!g.met && atBurn && aligned){ out.thr=1; }                          // burn
    else if(!g.met && !atBurn && Math.abs(dA)<0.4){ out.warpUp=1; }        // coast to the burn point under warp
    return out;
  },
  scoreIt(g){ const acc=clamp(1-Math.abs(orbElements(ORB.x,ORB.y,ORB.vx,ORB.vy,WLD.mu).e),0,1);
    const fuel=RUN.craft.stages[RUN.craft.si].fuel/RUN.craft.stages[RUN.craft.si].fuel0;
    return Math.round((600 + acc*900 + fuel*500)*M.mult); },
  render(){ orbRender(); },
  hud(){ orbHud(); },
};
let O=null;
function orbBurnAlong(o, ang, dv, mu){    // apply an impulse dv (km/s) along heading `ang`
  o.vx+=Math.cos(ang)*dv; o.vy+=Math.sin(ang)*dv; o.el=orbElements(o.x,o.y,o.vx,o.vy,mu);
}
```

(Implementation note for the engineer: delete the stray `ORB.vx+=…*dv*0` scratch line — it is a no-op left as a reminder that steering is via `orbBurnAlong(ORB,O.ang,…)`, not direct prograde addition. The craft thrusts along where it points (`O.ang`); the AP points it prograde/retrograde. Keep `orbBurnAlong` as the single place velocity changes during thrust.)

- [ ] **Step 4: Ascent → orbit handoff.** Orbital missions reach a MECO window and insert; the ascent doesn't need to know the next phase (the chain decides). The existing non-hop exit already fires at `cutAlt` with `carry:{v}`; the orbit init ignores `v` and uses the deterministic insertion, so **no ascent code change is required for the nominal path.** Only the emergency flag matters and it is already set by the ascent SHORT exit. Verify by reading lines ~595–598 — confirm the SHORT branch sets `carry:{…,emergency:true}` (it does). Add one comment there:

```js
// (ascent line ~596) NOTE: orbital missions consume only carry.emergency; nominal insertion is deterministic in PHASES.orbit.init
```

- [ ] **Step 5: Add `#sim` reach + `#phase` jump harness.** In the hash IIFE, add `#phase:diff:idx:phaseIdx` to jump straight into a phase with canned nominal entry (manual/visual testing). Insert before the `if(p[0]==='sim')` block:

```js
  if(p[0]==='phase'){ diff=DIFFS[p[1]]?p[1]:'realistic'; ap=1;
    const idx=clamp(+p[2]||0,0,CAMPAIGN.length-1), pj=+p[3]||0;
    RUN={ idx, m:CAMPAIGN[idx], pi:pj-1, results:[], carry:{}, score:0, craft:mkCraft(CAMPAIGN[idx].r) };
    WLD=WORLDS[CAMPAIGN[idx].w]; gameState='play'; paused=false; TRANS=null;
    $('#menu').classList.remove('show'); $('#hud').classList.add('on'); updateAPBtn();
    nextPhase(); requestAnimationFrame(loop); return; }
```

- [ ] **Step 6: Run, verify PASS** — `b test` → `TESTS PASS 22/22`. (`#sim`/`#phase` visual checks come after the renderer exists in Task 5.)

- [ ] **Step 7: Commit**

```bash
git add index.html && git commit -m "feat: PHASES.orbit logic — insertion, warp, burns, objective completion + #phase harness

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Orbit map renderer + HUD + warp touch buttons + wiring

**Files:** Modify `index.html` — ORBIT PHASE section (`orbRender`, `orbHud`); `#touch` HTML + CSS + `bindTouch` list; `setCardLabels` is reused. No change needed to `render()`/`updateHUD` dispatch (they already route `PH.render()`/`PH.hud()` for non-land phases).

Visual task — verified by screenshot + the full-mission sims in Task 6, plus a 60 fps perf check. The renderer must draw from cached sampled ellipse points (re-sampled only when elements change) per spec §14.

- [ ] **Step 1: Implement `orbRender`** — insert in the ORBIT PHASE section:

```js
let orbView={scale:1, cx:0, cy:0};                 // px-per-km + screen centre of body
let orbEllipseCache={key:'', pts:[]};
function orbFit(){ const mu=WLD.mu; const far=Math.max(ORB.el.ap, WLD.R+WLD.atmoH)*1.25;
  orbView.scale=Math.min(W,H)*0.5/far; orbView.cx=W/2; orbView.cy=H/2; }
function oX(x){ return orbView.cx + x*orbView.scale; }
function oY(y){ return orbView.cy - y*orbView.scale; }
function orbSampleEllipse(el){
  const key=el.a.toFixed(2)+'|'+el.e.toFixed(4)+'|'+el.omega.toFixed(4);
  if(key===orbEllipseCache.key) return orbEllipseCache.pts;
  const pts=[]; for(let i=0;i<=96;i++){ const nu=i/96*TAU; const s=orbStateAt(el.a,el.e,el.omega,nu,WLD.mu); pts.push([s.x,s.y]); }
  orbEllipseCache={key,pts}; return pts;
}
function orbRender(){
  orbFit();
  ctx.fillStyle='#02030a'; ctx.fillRect(-40,-40,W+80,H+80); ctx.globalAlpha=0.8; drawStars(); ctx.globalAlpha=1;
  // body + atmosphere ring
  const Rp=WLD.R*orbView.scale, atmo=(WLD.R+WLD.atmoH)*orbView.scale;
  const ar=ctx.createRadialGradient(oX(0),oY(0),Rp,oX(0),oY(0),atmo);
  ar.addColorStop(0,'rgba(90,150,255,0.22)'); ar.addColorStop(1,'rgba(90,150,255,0)');
  ctx.fillStyle=ar; ctx.beginPath(); ctx.arc(oX(0),oY(0),atmo,0,TAU); ctx.fill();
  const bg=ctx.createRadialGradient(oX(0)-Rp*0.3,oY(0)-Rp*0.3,Rp*0.2,oX(0),oY(0),Rp);
  bg.addColorStop(0,'#3a7fd0'); bg.addColorStop(1,'#0f2a52');
  ctx.fillStyle=bg; ctx.beginPath(); ctx.arc(oX(0),oY(0),Rp,0,TAU); ctx.fill();
  // orbit ellipse (cached samples)
  const pts=orbSampleEllipse(ORB.el);
  ctx.strokeStyle=WLD.orbitColor; ctx.lineWidth=1.6; ctx.globalAlpha=0.9; ctx.beginPath();
  pts.forEach((p,i)=>{ const X=oX(p[0]),Y=oY(p[1]); i?ctx.lineTo(X,Y):ctx.moveTo(X,Y); }); ctx.closePath(); ctx.stroke(); ctx.globalAlpha=1;
  // Ap / Pe markers
  const apS=orbStateAt(ORB.el.a,ORB.el.e,ORB.el.omega,Math.PI,WLD.mu), peS=orbStateAt(ORB.el.a,ORB.el.e,ORB.el.omega,0,WLD.mu);
  orbTag(oX(apS.x),oY(apS.y),'Ap '+Math.round(ORB.el.ap-WLD.R)+'km','var(--cyan)');
  orbTag(oX(peS.x),oY(peS.y),'Pe '+Math.round(ORB.el.pe-WLD.R)+'km', ORB.el.pe<WLD.R+WLD.atmoEntry?'var(--red)':'var(--gold)');
  // target circle for circularize
  if(O.obj.type==='circularize'){ const rt=(WLD.R+O.obj.alt)*orbView.scale;
    ctx.setLineDash([3,6]); ctx.strokeStyle='rgba(120,170,255,.4)'; ctx.beginPath(); ctx.arc(oX(0),oY(0),rt,0,TAU); ctx.stroke(); ctx.setLineDash([]); }
  // craft marker + heading
  const mx=oX(ORB.x), my=oY(ORB.y);
  ctx.save(); ctx.translate(mx,my); ctx.rotate(-O.ang);
  ctx.fillStyle=orbBurning?'#ff9b3c':'#eaf0ff'; ctx.beginPath(); ctx.moveTo(7,0); ctx.lineTo(-4,-4); ctx.lineTo(-4,4); ctx.closePath(); ctx.fill();
  ctx.restore();
  // guidance reticle (difficulty-gated) — Task 6 fills the difficulty rules; default draw burn node
  if(diff!=='hardcore'){ const g=orbGuide(O.obj,ORB,WLD.R,diff);
    const bs=orbStateAt(ORB.el.a,ORB.el.e,ORB.el.omega,g.burnNu,WLD.mu);
    ctx.fillStyle=g.kind==='retrograde'?'var(--red)':'var(--green)';
    ctx.beginPath(); ctx.arc(oX(bs.x),oY(bs.y),4,0,TAU); ctx.fill(); }
}
function orbTag(x,y,txt,col){ ctx.fillStyle=col; ctx.beginPath(); ctx.arc(x,y,3,0,TAU); ctx.fill();
  ctx.fillStyle=col; ctx.font='600 10px IBM Plex Mono'; ctx.textAlign='center'; ctx.fillText(txt,x,y-8); ctx.textAlign='left'; }
```

- [ ] **Step 2: Implement `orbHud`** (cards AP/PE/PERIOD/Δv + warp readout):

```js
function orbHud(){
  const el=ORB.el, s=RUN.craft.stages[RUN.craft.si];
  setCardLabels(['Apoapsis','Periapsis','Period','Warp']);
  const vs=$$('.tele .tcard .v');
  vs[0].innerHTML=Math.round(el.ap-WLD.R)+'<small> km</small>'; vs[0].style.color='var(--cyan)';
  vs[1].innerHTML=Math.round(el.pe-WLD.R)+'<small> km</small>'; vs[1].style.color=el.pe<WLD.R+WLD.atmoEntry?'var(--red)':'var(--green)';
  vs[2].innerHTML=Math.round(el.period)+'<small> s</small>'; vs[2].style.color='var(--ink)';
  vs[3].innerHTML=orbWarp+'<small>×</small>'; vs[3].style.color=orbWarp>1?'var(--gold)':'var(--ink)';
  $('#fuelFill').style.width=(100*s.fuel/s.fuel0)+'%'; $('#fuelTxt').textContent=Math.round(100*s.fuel/s.fuel0)+'%';
  $('#thrFill').style.width=(orbBurning?100:0)+'%'; $('#thrTxt').textContent=orbBurning?'BURN':'—';
  const apP=$('#apPanel'), g=orbGuide(O.obj,ORB,WLD.R,diff);
  if(ap!==0){ apP.classList.add('on'); $('#apState').textContent=AP_NAMES[ap]; $('#apState').className='apState '+(ap===1?'auto':'assist');
    $('#apPhaseEl').textContent=g.label; $('#apTgtEl').innerHTML='Δv '+Math.abs(g.dv).toFixed(2)+'<small> km/s</small>'; }
  else apP.classList.remove('on');
}
```

- [ ] **Step 3: Warp touch buttons.** In `#touch` add (after `#tStage`):

```html
<div class="tbtn" id="tWarpDn">WARP−</div>
<div class="tbtn" id="tWarpUp">WARP+</div>
```

CSS (next to `#tStage`):

```css
#tWarpDn,#tWarpUp{left:auto;width:52px;height:52px;display:none}
#tWarpDn{right:calc(84px + env(safe-area-inset-right,0px));bottom:calc(132px + env(safe-area-inset-bottom,0px))}
#tWarpUp{right:calc(18px + env(safe-area-inset-right,0px));bottom:calc(132px + env(safe-area-inset-bottom,0px))}
body.orbit #tWarpDn,body.orbit #tWarpUp{display:grid}
```

Add to the `bindTouch` list (~line where the `['#tThr:_tThr',…]` array is): `'#tWarpUp:_tWarpUp','#tWarpDn:_tWarpDn'`. In `PHASES.orbit.init` add `document.body.classList.add('orbit')`; in `PHASES.land.init`/`PHASES.entry.init`/`openMenu`/`endMission` add `document.body.classList.remove('orbit')` (mirror how `asc` is handled).

- [ ] **Step 4: Render dispatch already works** — `render()` line ~963 calls `PH.render()` for any non-land phase, so `orbRender` runs. Confirm `updateHUD` (~1133) calls `PH.hud()` when present (it does). No edit beyond the class toggles in Step 3.

- [ ] **Step 5: Visual smoke** — `b ''` → clean menu (frame-1). Then screenshot the orbit map via `#phase` (jump to M3's orbit phase — index set in Task 6; until then use the test mission through a temporary `#phase:realistic:2:1`). Launch headless Chrome directly (no `timeout`):

```bash
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"; G="file:///Users/omrishahar/code/rocket-landing/index.html"
"$CHROME" --headless=new --disable-gpu --no-first-run --window-size=900,600 --virtual-time-budget=3000 \
  --user-data-dir="$(mktemp -d)" --screenshot=/tmp/orbit.png "$G#phase:realistic:2:1" >/dev/null 2>&1 &
sleep 7; kill -9 %1 2>/dev/null
```

Eyeball `/tmp/orbit.png`: body disc + atmosphere ring centred, the orbit ellipse, Ap/Pe tags, dashed target circle, craft marker. Nothing should reference surface-domain `R/env`.

- [ ] **Step 6: Commit**

```bash
git add index.html && git commit -m "feat: orbit map renderer (cached ellipse, Ap/Pe, target, reticle) + HUD + warp buttons

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Mission 3 data, difficulty guidance gating, full verification, tag

**Files:** Modify `index.html` — `CAMPAIGN` (add M3); guidance-gating in `orbRender`; CLAUDE.md; tests as needed.

- [ ] **Step 1: Add Mission 3 to CAMPAIGN** (after M2):

```js
 {w:'port',r:'falcon9',name:'Orbit!',d:'Reach space, circularize a low orbit, then deorbit, re-enter and land.',
  phases:[
   {type:'ascent',label:'ASCENT',   world:'port',rocket:'falcon9',cutAlt:10500},
   {type:'orbit', label:'CIRCULARIZE',world:'port',obj:{type:'circularize',alt:120}},
   {type:'orbit', label:'DEORBIT',   world:'port',obj:{type:'deorbit',entryAlt:40}},
   {type:'entry', label:'RE-ENTRY',  world:'port',gMax:0},
   {type:'land',  label:'LAND',      world:'port',terrain:'pad',rocket:'falcon9',a:300,hazards:{wind:.4}}]},
```

The `ICONS` map in `buildCampaign` already maps `orbit:'🌍'` (added Part 1, Task 5) — confirm the card renders the 🚀🌍🌍🔥🛬 chain.

- [ ] **Step 2: Difficulty guidance gating in `orbRender`** — replace the Step-1 reticle block with the spec §8 rules:

```js
  // guidance gating: arcade = burn node + target + Δv vector; realistic = node + target; hardcore = target only
  if(diff!=='hardcore'){ const g=orbGuide(O.obj,ORB,WLD.R,diff);
    const bs=orbStateAt(ORB.el.a,ORB.el.e,ORB.el.omega,g.burnNu,WLD.mu);
    ctx.fillStyle=g.kind==='retrograde'?'var(--red)':'var(--green)';
    ctx.beginPath(); ctx.arc(oX(bs.x),oY(bs.y),4,0,TAU); ctx.fill();
    if(diff==='arcade'){ const vA=Math.atan2(ORB.vy,ORB.vx), dir=g.kind==='retrograde'?vA+Math.PI:vA;
      ctx.strokeStyle=ctx.fillStyle; ctx.lineWidth=2; ctx.beginPath(); ctx.moveTo(oX(ORB.x),oY(ORB.y));
      ctx.lineTo(oX(ORB.x)+Math.cos(-dir)*26,oY(ORB.y)+Math.sin(-dir)*26); ctx.stroke(); } }
```

- [ ] **Step 3: Autopilot matrix — the Part-2 gate.** Define `b` (see Context). Run:

```bash
for d in arcade realistic hardcore; do for i in 0 1 2; do echo "$d M$((i+1)): $(b sim:$d:$i)"; done; done
b test
```

Expected: all `RESULT COMPLETE…` (M1/M2/M3 × 3 diffs = 9 lines, no CRASH/BREAKUP/BURNUP/LOST/TIMEOUT); `TESTS PASS 22/22`. **If M3 times out or fails:** the orbit AP is the usual culprit — tuning knobs: AP burn-point window (`0.18`), alignment deadband (`0.08`), warp-during-coast cap, insertion `rp`/`ra`, guidance tolerances (`tolE`, `altTol`). Use systematic-debugging; re-run the whole step. Do NOT weaken a tolerance so far that the orbit is visibly non-circular — verify `e<0.05` after the circularize phase via `#phase` + eval.

- [ ] **Step 4: The human path (mandatory frame-1 rule).**

```bash
agent-browser open about:blank; agent-browser open "$G"
a=$(agent-browser eval tPrev); sleep 1; b2=$(agent-browser eval tPrev); echo "menu loop $a -> $b2 (must differ)"
agent-browser eval "campIdx=2; buildMenu(); 'M3 selected'"          # select Orbit!
agent-browser click '#playBtn'; sleep 1
agent-browser eval "({state:gameState, phase:RUN&&RUN.m.phases[RUN.pi].type})"   # expect play / ascent
agent-browser press h
agent-browser wait --fn "document.title.indexOf('RESULT')===0" --timeout 120000
agent-browser eval "document.title"                                  # expect RESULT COMPLETE … M3
agent-browser close --all
```

Also: during the orbit phase, eval `gameState==='play'` and screenshot to confirm the map renders live.

- [ ] **Step 5: Performance check (spec §14: 60 fps on the map).** With the orbit phase live (`#play:realistic:2`), sample frame timing:

```bash
agent-browser open "$G#play:realistic:2"; sleep 14   # ascent ~ then orbit
agent-browser eval "(async()=>{let t=[],l=performance.now();for(let i=0;i<120;i++){await new Promise(r=>requestAnimationFrame(r));const n=performance.now();t.push(n-l);l=n;}t.sort((a,b)=>a-b);return {median:+t[60].toFixed(1),p95:+t[114].toFixed(1)};})()"
```

Expected median ≤ ~17 ms (≈60 fps), p95 ≤ ~22 ms. If worse, the ellipse cache (`orbSampleEllipse` key) is the first thing to check — it must NOT resample every frame while coasting.

- [ ] **Step 6: Update CLAUDE.md** — under the phases line add `orbit` (map view, Kepler, warp); note the `#phase:diff:idx:phaseIdx` jump harness; add the orbit tuning knobs (insertion `ra/rp`, guidance tolerances, AP burn window). Note the two scale domains are never mixed in one frame.

- [ ] **Step 7: Tag + commit**

```bash
git add index.html CLAUDE.md docs/ && git commit -m "feat: Mission 3 'Orbit!' (ascent->circularize->deorbit->entry->land) + difficulty guidance gating + docs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git tag part2-orbit-map && git log --oneline | head -8
```

---

## Plan self-review (done at writing time)

- **Spec coverage (Part-2 slice):** §3.2 two domains → orbit owns km scale, never mixed (Task 4 `T=null;env=null`, Task 5 renderer); §4.2 view (body+atmo ring+ellipse+Ap/Pe+target+marker) → Task 5; propagation closed-form coast + numerical burn → Tasks 1–2; warp ladder + auto-drop near atmosphere/burn → Tasks 2,4; guidance circularize/deorbit + difficulty gating → Tasks 3,5,6; objectives circularize+deorbit (rendezvous/transfer/capture explicitly deferred to Parts 3+) → Task 3; failure modes escape→LOST, periapsis→surface, atmosphere→ENTRY → Task 4; scoring (accuracy+fuel) → Task 4 `scoreIt`; §7 M3 chain → Task 6; §8 guidance gating + tolerances → Tasks 3,6; §9 per-phase report (reuses Part-1 `endMission`); §11 HUD card swap + warp touch → Task 5; §14 `#sim` whole-mission, `#phase` jump, perf, human path → Tasks 4,6.
- **Deferred (NOT in this plan, by scope):** rendezvous, dock, transfer/SOI, capture, moon/mars orbital tuning, missions 4–14, audio additions (§13). Listed so the next plan picks them up.
- **Placeholder scan:** none — every step has code or an exact command + expected title. The one scratch line in Task 4 Step 3 is explicitly called out for deletion.
- **Type consistency:** `orbElements/solveKepler/eccFromTrue/trueFromEcc/orbStateAt/orbAdvance/vCirc` (Task 1); `mkOrbit/orbCoast/orbBurn/orbBurnAlong/warpStep/WARPS/ORB` (Tasks 2,4); `orbGuide` signature `(obj,o,R,diff)→{dv,burnNu,met,kind,label}` used identically in Tasks 3,4,5,6; `PHASES.orbit`/`O`/`orbWarp`/`orbBurning` (Task 4); `orbRender/orbHud/orbView/oX/oY/orbSampleEllipse/orbTag/orbFit/orbEllipseCache` (Task 5); `setCardLabels` reused from Part 1; `body.orbit` class toggled in init + cleared in land/entry/openMenu/endMission (Task 5 Step 3). WORLDS fields `R/mu/atmoH/atmoEntry/orbitColor` defined Task 1, consumed Tasks 3–6.
- **Open risk flagged for the engineer:** the surface↔orbit unit remap (ascent m/s ↔ orbit km/s, and the `craftAccel/1000` thrust scaling, and the `vAtmo*7` entry handoff) are tuned constants, not physical — Task 6 Step 3 tuning is expected to land them. Keep the circularize result visibly circular (`e<0.05`).
```
