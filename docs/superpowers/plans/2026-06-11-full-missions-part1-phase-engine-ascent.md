# Full Missions Part 1: Phase Engine + Ascent — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Booster's single landing sim into a phase-chained mission engine and ship the first two full missions (suborbital hop; Kármán-line flight with re-entry), with multistage rockets, the old landing game preserved as Practice mode, and an in-page test harness.

**Architecture:** Everything stays in one `index.html` (hard constraint — double-click + phone). A `PHASES` registry of self-contained phase objects (`init/update/render/hud`) is driven by a mission `RUN` state; the existing landing sim is moved behind that interface unchanged; new ASCENT and ENTRY phases chain into it. Dev-only hash modes (`#test`, `#sim`, `#simland`) provide TDD and regression gates, verified with headless Chrome.

**Tech Stack:** Vanilla JS + canvas 2D, WebAudio, localStorage. No dependencies, no build. Testing: in-page `#test` assertion runner + headless Chrome title-grep + agent-browser menu-path check.

**Scope split (per spec §15):** This is Part 1 of 3. Part 2 = orbit map/rendezvous/dock (spec §4.2–4.3, missions 3–7). Part 3 = Moon/Mars/SOI, M8 showpiece, stations, audio pass, balance (missions 8–14). Parts 2–3 get their own plan documents after Part 1 lands.

---

## Context for the engineer (read first)

- The whole game is `index.html` (~907 lines). One `<script>` at the bottom. Read it fully before Task 4 — it's short.
- **Spec:** `docs/superpowers/specs/2026-06-11-full-missions-design.md` (approved). Part 1 covers spec §3 (architecture), §4.1 (ascent), §4.4 (entry, basic), §4.5 (land), §5 (multistage), §9–§11 for what exists so far, §14 (testing).
- Existing code map (line numbers from the Part-1 starting commit `db34544`):
  - data tables `WORLDS/ROCKETS/DIFFS/TERRAINS/CAMPAIGN`: lines ~284–335
  - persistence (`SKEY`, `load/persist/prog`): ~337–343 · canvas/camera: ~345–358
  - state vars: ~360–368 · input/touch: ~370–398 · audio: ~400–420
  - `resolveMission/buildTerrain/startGame`: ~422–477 · autopilot: ~479–532
  - `update(dt)` (surface physics): ~534–598 · landing eval/report: ~608–641
  - `render()` + `draw*`: ~644–808 · `updateHUD`: ~810–826 · menu: ~849–890
  - `loop()` + hash dev modes (`#sim/#play/#shot`): ~892–903
- **House rules:** terse style, single-letter-ish locals, section banner comments `/* ═══ name ═══ */`. Match it. Comments only for non-obvious constraints.
- **Verification command used throughout** (proven to work on this machine):

```bash
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
G="file:///Users/omrishahar/code/rocket-landing/index.html"
run(){ "$CHROME" --headless=new --disable-gpu --no-first-run \
  --user-data-dir="$(mktemp -d)" --dump-dom "$G#$1" 2>/dev/null \
  | grep -o '<title>[^<]*</title>'; }
# usage: run test     |  run sim:realistic:0   |  run simland:realistic:pad:falcon9
```

Define `run` once per shell session; every "Run:" step below assumes it.

- **The frame-1 rule (regression from 2026-06-11):** `render()` must never assume a run exists. Hash modes start runs before the first frame and HIDE such bugs — that's why the menu-click test in Task 9 is mandatory and not optional.
- Commit after every task. Message footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File structure

| File | Responsibility |
|---|---|
| `index.html` (modify) | The game. New `<script>` sections added in this order: CRAFT (stage math) after ROCKETS; PHASE ENGINE after `buildTerrain`; ASCENT + ENTRY phases after the landing-phase wrap; TESTS block immediately before the hash IIFE. Grows to ~1800 lines — keep section banners. |
| `docs/superpowers/plans/…this file` | Task tracking (tick checkboxes as you go). |

Within-file boundaries (treat as modules): a phase object touches only its own state object (`A` for ascent, `E` for entry, `R/env/T` for land) + shared services (`RUN`, craft fns, particles, audio, input). Cross-phase data passes ONLY via `RUN.carry`.

---

### Task 1: In-page test harness (`#test`)

**Files:** Modify `index.html` (immediately before the hash-mode IIFE at the bottom, line ~897).

- [x] **Step 1: Add the harness + a self-test**

Insert before the `(function(){ const p=location.hash...` IIFE:

```js
/* ═════════════════ dev tests (#test) ═════════════════ */
const TESTS=[]; function T_(name,fn){ TESTS.push({name,fn}); }
function eq(a,b,m){ if(a!==b) throw new Error((m||'eq')+': got '+JSON.stringify(a)+' want '+JSON.stringify(b)); }
function near(a,b,tol,m){ if(!(Math.abs(a-b)<=tol)) throw new Error((m||'near')+': got '+a+' want '+b+'±'+tol); }
function ok(v,m){ if(!v) throw new Error(m||'expected truthy'); }
function runTests(){ let fails=[];
  for(const t of TESTS){ try{ t.fn(); }catch(e){ fails.push(t.name+' — '+e.message); } }
  document.title = fails.length ? 'TESTS FAIL '+fails.length+'/'+TESTS.length+' :: '+fails[0]
                                : 'TESTS PASS '+TESTS.length+'/'+TESTS.length;
}
T_('harness sanity', ()=>{ eq(1+1,2); near(0.1+0.2,0.3,1e-9); ok(clamp(5,0,3)===3); });
```

- [x] **Step 2: Wire `#test` into the hash IIFE**

In the IIFE, change the first line of the handler:

```js
(function(){ const p=location.hash.replace('#','').toLowerCase().split(':');
  if(p[0]==='test'){ runTests(); return; }
  if(p[0]==='sim'||p[0]==='play'||p[0]==='shot'){ ...
```

(only the `if(p[0]==='test')` line is new; the rest stays.)

- [x] **Step 3: Run and verify PASS**

Run: `run test`
Expected: `<title>TESTS PASS 1/1</title>`

Also verify the game still loads clean with no hash (frame-1 rule):
`run "" ` → expected `<title>Booster — Rocket Landing</title>` (no RESULT/TESTS text).

- [x] **Step 4: Commit**

```bash
git add index.html && git commit -m "test: in-page #test assertion harness

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Multistage craft model (pure logic)

**Files:** Modify `index.html` — new section after the `ROCKETS` table (~line 297); tests appended to the TESTS block.

- [x] **Step 1: Write failing tests** (append to TESTS block)

```js
T_('craft: mass stacks stages', ()=>{
  const c=mkCraft('falcon9');
  near(craftMass(c), 22+60+(4+12), 1e-9, 'wet mass incl upper stage');
});
T_('craft: accel rises as fuel burns', ()=>{
  const c=mkCraft('falcon9'); const a0=craftAccel(c,1);
  c.stages[0].fuel=10; const a1=craftAccel(c,1);
  ok(a1>a0,'lighter = faster'); near(a0, 900/98, 1e-6);
});
T_('craft: burn consumes, clamps at 0, cuts thrust', ()=>{
  const c=mkCraft('falcon9'); c.stages[0].fuel=1;
  burnStage(c,1,2);           // rate 4 → wants 8, clamps to 1
  eq(c.stages[0].fuel,0); eq(craftAccel(c,1),0,'no fuel no thrust');
});
T_('craft: staging drops mass, TWR jumps', ()=>{
  const c=mkCraft('falcon9'); c.stages[0].fuel=0;
  ok(canStage(c)); ok(doStage(c)); eq(c.si,1);
  near(craftMass(c), 4+12, 1e-9);
  ok(!canStage(c)); ok(!doStage(c),'cannot stage past last');
});
```

- [x] **Step 2: Run, verify FAIL**

Run: `run test`
Expected: `TESTS FAIL 4/5 :: craft: mass stacks stages — mkCraft is not defined` (message may vary; FAIL count 4).

- [x] **Step 3: Implement** — insert after the ROCKETS table:

```js
/* ═════════════════ CRAFT (multistage state) ═════════════════
   stages: thrust & masses in consistent arbitrary units; fuel in mass units,
   rate = mass/s at full throttle. Landing-phase fuel bar maps stage fuel %. */
function mkCraft(rk){ const r=ROCKETS[rk];
  return { rk, si:0, rcs:r.rcsBudget||0, stages:r.stages.map(s=>({...s})) }; }
function stagesAbove(c,i){ let m=0; for(let j=i+1;j<c.stages.length;j++){ const s=c.stages[j]; m+=s.dry+s.fuel; } return m; }
function craftMass(c){ const s=c.stages[c.si]; return s.dry+s.fuel+stagesAbove(c,c.si); }
function craftAccel(c,thr){ const s=c.stages[c.si]; return s.fuel>0 ? thr*s.thrust/craftMass(c) : 0; }
function burnStage(c,thr,dt){ const s=c.stages[c.si]; s.fuel=Math.max(0,s.fuel-thr*s.rate*dt); }
function canStage(c){ return c.si<c.stages.length-1; }
function doStage(c){ if(!canStage(c)) return false; c.si++; return true; }
```

- [x] **Step 4: Add stage data to ROCKETS** (same edit). Extend each rocket object with `stages` + `rcsBudget` (legacy fields stay — Practice mode still uses them):

```js
// inside ROCKETS, add per rocket (keep existing fields):
falcon9:  {... , rcsBudget:0, stages:[
  {name:'Booster', thrust:900, dry:22, fuel:60, rate:4,    gimbal:true, canLand:true},
  {name:'Stage 2', thrust:110, dry:4,  fuel:12, rate:0.55, gimbal:true, rcs:true}]},
starship: {... , rcsBudget:8, stages:[
  {name:'Super Heavy', thrust:1600, dry:40, fuel:110, rate:7,   gimbal:true, canLand:true},
  {name:'Ship',        thrust:260,  dry:12, fuel:34,  rate:1.4, gimbal:true, rcs:true, canLand:true}]},
hopper:   {... , rcsBudget:0, stages:[
  {name:'Hopper', thrust:140, dry:3.4, fuel:9, rate:1.0, gimbal:true, canLand:true}]},
heavy:    {... , rcsBudget:0, stages:[
  {name:'Boost cores', thrust:2100, dry:48, fuel:130, rate:9,   gimbal:true, canLand:true},
  {name:'Stage 2',     thrust:110,  dry:4,  fuel:13,  rate:0.55,gimbal:true, rcs:true}]},
lander:   {... , rcsBudget:10, stages:[
  {name:'Descent', thrust:46, dry:4,  fuel:11, rate:0.8, gimbal:true, canLand:true},
  {name:'Ascent',  thrust:16, dry:2.2,fuel:5,  rate:0.4, gimbal:true, rcs:true}]},
```

- [x] **Step 5: Run, verify PASS**

Run: `run test` → Expected: `TESTS PASS 5/5`. Also `run sim:realistic:0` → still `RESULT GOOD AUTO …` (legacy landing untouched).

- [x] **Step 6: Commit**

```bash
git add index.html && git commit -m "feat: multistage craft model + stage data (TDD)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Phase engine (RUN / PHASES / transitions)

**Files:** Modify `index.html` — new section after `buildTerrain` (~line 451); tests appended.

- [x] **Step 1: Write failing tests** (append to TESTS block)

```js
T_('phases: chain runs to completion', ()=>{
  let log=[];
  PHASES._a={init(s,c){log.push('a:'+(c.x||0));}, update(dt){ phaseDone({score:100, carry:{x:7}}); }, render(){}};
  PHASES._b={init(s,c){log.push('b:'+c.x);},      update(dt){ phaseDone({score:50}); },              render(){}};
  RUN={ m:{name:'t', phases:[{type:'_a'},{type:'_b'}] }, pi:-1, results:[], carry:{}, score:0, craft:mkCraft('falcon9'), reported:false };
  _missionReportHook=r=>{ RUN.reported=true; };
  nextPhase();                       // enters _a
  PH.update(1/60); skipTransition(); // _a done → transition → _b
  PH.update(1/60); skipTransition();
  eq(log.join('|'),'a:0|b:7','carry passed');
  eq(RUN.score,150); ok(RUN.reported,'mission report fired');
  _missionReportHook=null;
});
T_('phases: fail short-circuits', ()=>{
  let log=[];
  PHASES._f={init(){}, update(dt){ phaseDone({fail:'BREAKUP', score:0}); }, render(){}};
  PHASES._n={init(){log.push('never');}, update(){}, render(){}};
  RUN={ m:{name:'t', phases:[{type:'_f'},{type:'_n'}] }, pi:-1, results:[], carry:{}, score:0, craft:mkCraft('falcon9'), reported:false };
  _missionReportHook=r=>{ RUN.reported=true; RUN.failv=r.fail; };
  nextPhase(); PH.update(1/60);
  eq(log.length,0,'next phase never inits'); eq(RUN.failv,'BREAKUP');
  _missionReportHook=null;
});
```

- [x] **Step 2: Run, verify FAIL** — `run test` → `TESTS FAIL 2/7 :: phases: … PHASES is not defined`.

- [x] **Step 3: Implement the engine** — insert after `buildTerrain`:

```js
/* ═════════════════ PHASE ENGINE ═════════════════
   A mission = chain of phase specs. Cross-phase data passes ONLY via RUN.carry. */
let RUN=null, PH=null, TRANS=null, _missionReportHook=null;
const PHASES={};
function startMission(idx){
  const m=CAMPAIGN[idx];
  RUN={ idx, m, pi:-1, results:[], carry:{}, score:0, craft:mkCraft(m.r) };
  WLD=WORLDS[m.w];
  paused=false; particles.length=0; shake=0; apLatch=false; apIx=0; apPrevPadX=0;
  $('#menu').classList.remove('show'); $('#report').classList.remove('show'); $('#pause').classList.remove('show');
  $('#hud').classList.add('on'); gameState='play'; updateAPBtn(); audioResume();
  nextPhase();
}
function nextPhase(){
  RUN.pi++;
  if(RUN.pi>=RUN.m.phases.length){ missionReport(null); return; }
  const spec=RUN.m.phases[RUN.pi];
  PH=PHASES[spec.type]; PH.init(spec,RUN.carry); RUN.carry={};
}
function phaseDone(res){
  RUN.results.push(res); RUN.score+=res.score||0;
  if(res.carry) RUN.carry=res.carry;
  if(res.fail){ missionReport(res); return; }
  if(RUN.pi>=RUN.m.phases.length-1){ missionReport(null); return; }
  TRANS={t:0, dur:1.6, label:RUN.m.phases[RUN.pi+1].label||''};
}
function skipTransition(){ if(TRANS){ TRANS=null; nextPhase(); } }
function stepTransition(dt){ if(!TRANS) return false; TRANS.t+=dt; if(TRANS.t>=TRANS.dur){ TRANS=null; nextPhase(); } return true; }
function missionReport(failRes){
  if(_missionReportHook){ _missionReportHook(failRes||{}); return; }   // tests stub the UI
  endMission(failRes);   // real report UI — Task 5
}
```

- [x] **Step 4: Run, verify PASS** — `run test` → `TESTS PASS 7/7`. (`endMission` is not called by tests; it may not exist yet — JS only resolves it at call time.)

- [x] **Step 5: Commit**

```bash
git add index.html && git commit -m "feat: mission phase engine (RUN/PHASES/phaseDone/transitions)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Landing behind the phase interface + Practice mode + save v3

This is the load-bearing refactor. Behaviour of landing flying must not change — gated by recording verdicts before/after.

**Files:** Modify `index.html`: `startGame` (~452–477), `update` (~534), `render`/`drawGuides` path, `loop` (~893), report (~828), menu (~849–890), persistence (~337), hash IIFE.

- [x] **Step 1: Record the BEFORE regression baseline**

```bash
for t in pad ship platform mountains tower; do echo "== $t"; run sim:realistic:3; done > /tmp/before.txt 2>&1   # old campaign idx 3 = ship; plus:
run sim:realistic:0 >> /tmp/before.txt; run sim:hardcore:16 >> /tmp/before.txt
cat /tmp/before.txt
```

Save the verdict lines; Step 7 must reproduce equivalents via `#simland`.

- [x] **Step 2: Split `startGame` into `landInit(params)` + register `PHASES.land`**

Replace the whole `startGame` function with:

```js
/* land params: {world,terrain,rocket,hazards,a,craft|null,carry:{xOff,vx,vy}|null,nameTag} */
function landInit(o){
  WLD=WORLDS[o.world]; const RK=ROCKETS[o.rocket], D=DIFFS[diff];
  T=buildTerrain(o.terrain,RK,D);
  MS={...hz(o.hazards||{}), name:o.nameTag||'Landing', world:o.world, terrain:o.terrain, rocketName:RK.name};
  M={ g:WLD.g, wind:WLD.wind, accel:RK.accel, fuel:RK.fuel, rot:RK.rot, rotEase:RK.rotEase, rcs:RK.rcs,
      rh:RK.h, rw:RK.w, style:RK.style, vMax:D.vMax, hMax:D.hMax, tilt:D.tilt, autoLevel:D.autoLevel,
      mult:D.mult, pad:T.padW, mc:D.dc };
  if(o.craft){ const s=o.craft.stages[o.craft.si];               // mission flight: stage-driven engine
    M.accel=s.thrust/craftMass(o.craft); M.craft=o.craft;
    M.fuelCap=s.fuel0!==undefined?s.fuel0:ROCKETS[o.rocket].stages[o.craft.si].fuel; }
  const startAlt=(o.a||250)*MS.altMul + T.deck0;
  const dir=Math.random()<.5?-1:1, steady=dir*M.wind*MS.wind, amp=MS.moving*7;
  const c=o.carry||{};
  R={ x:(c.xOff!==undefined?c.xOff:rnd(-1,1)*M.pad*0.5), y:startAlt,
      vx:(c.vx!==undefined?c.vx:steady*0.7+rnd(-1,1)*0.6), vy:(c.vy!==undefined?c.vy:-7),
      angle:rnd(-1,1)*0.05, av:0, throttle:0, legs:0, exhaust:0,
      fuel: o.craft? 100*o.craft.stages[o.craft.si].fuel/M.fuelCap : 100 };
  env={ t:0, windCur:steady, windTarget:steady, steady, gustT:rnd(1,2.5),
        padX:0, deckY:T.deck0, amp, freq:0.28, dust:[] };
  particles.length=0; shake=0;
  cam.bottom=R.y-0.62*VIS; cam.x=0; apLatch=false; apIx=0; apPrevPadX=0;
  document.body.classList.toggle('rcs',M.rcs);
  $('#missionTag').innerHTML='<b>'+WLD.name+'</b> · '+RK.name+' · '+(o.nameTag||TERRAINS[o.terrain].name);
}
PHASES.land={
  init(spec,carry){ landInit({...spec, carry, craft:RUN?RUN.craft:null}); },
  update(dt){ landUpdate(dt); },
  render(){ /* world rendering stays in render(); nothing extra */ },
};
```

And rename the existing `update` function to `landUpdate` (one-word change at its definition).

Inside `landUpdate`, change the fuel burn + the two end-of-flight calls so missions thread through the craft:

```js
// fuel burn — replace the existing line inside the throttle block:
    if(M.craft){ burnStage(M.craft,R.throttle,dt); R.fuel=100*M.craft.stages[M.craft.si].fuel/M.fuelCap; }
    else R.fuel=Math.max(0,R.fuel-R.throttle*(100/(M.fuel*MS.fuelMul))*dt);
```

`evaluateLanding`/`endAttempt` stay as the legacy single-flight path; missions route around them — at the two call sites in `landUpdate` (`evaluateLanding()` and both `endAttempt(...)` calls) change to:

```js
    if(overPad && R.y<=env.deckY){ RUN?landEvalMission():evaluateLanding(); return; }
    ...
    R.y=T.ground(R.x); RUN?phaseDone({fail:'CRASH',reason,score:0}):endAttempt('CRASH',{reason}); return;
    ...
  if(Math.abs(R.x-env.padX)>200){ RUN?phaseDone({fail:'LOST',reason:'Drifted out of range',score:0}):endAttempt('LOST',{reason:'Drifted out of range'}); return; }
```

and add next to `evaluateLanding`:

```js
function landEvalMission(){
  const impactVy=R.vy, impactVx=R.vx; R.y=env.deckY; R.vy=0;
  const vdesc=Math.abs(impactVy), hsp=Math.abs(impactVx), tilt=Math.abs(R.angle*DEG);
  const okV=vdesc<=M.vMax, okH=hsp<=M.hMax, okT=tilt<=M.tilt;
  const soft=clamp(1-vdesc/M.vMax,0,1), up=clamp(1-tilt/M.tilt,0,1),
        acc=clamp(1-Math.abs(R.x-env.padX)/(M.pad/2),0,1);
  if(okV&&okH&&okT){
    const perfect=vdesc<=M.vMax*0.45&&hsp<=M.hMax*0.5&&tilt<=M.tilt*0.5&&Math.abs(R.x-env.padX)<=M.pad*0.22;
    sndSuccess(); sndThud(clamp(vdesc/M.vMax,0,1));
    phaseDone({verdict:perfect?'PERFECT':'GOOD', score:Math.round((1100+soft*1500+acc*1200+up*600)*M.mult)});
  } else if(vdesc<=M.vMax*1.7&&hsp<=M.hMax*1.8&&tilt<=M.tilt*1.8){
    sndThud(1); phaseDone({verdict:'HARD', score:Math.round(350*M.mult)});
  } else { sndBoom(); explode(); shake=1.4; phaseDone({fail:'CRASH', reason:'Came in too hot', score:0}); }
}
```

- [x] **Step 3: Dispatch update/render through PH + transitions; keep legacy flow working**

In `loop()` nothing changes. In the global flow:

```js
// replace:  if(gameState==='play'&&!paused) update(dt);   →
function update(dt){            // new top-level dispatcher, same name the loop calls
  if(stepTransition(dt)) return;
  if(RUN){ if(PH) PH.update(dt); } else landUpdate(dt);     // legacy Practice path
}
```

(The old `update` body is already renamed `landUpdate`; this new `update` replaces it at top level. `render()` needs one addition — transition veil, drawn last:)

```js
// at the end of render(), before ctx.restore():
  if(TRANS){ const k=Math.min(1,TRANS.t/0.4), k2=TRANS.t>TRANS.dur-0.4?(TRANS.dur-TRANS.t)/0.4:1;
    ctx.globalAlpha=Math.min(k,k2)*0.85; ctx.fillStyle='#04070f'; ctx.fillRect(0,0,W,H);
    ctx.globalAlpha=Math.min(k,k2); ctx.fillStyle='#8b97bb'; ctx.font='600 13px IBM Plex Mono';
    ctx.textAlign='center'; ctx.fillText(TRANS.label||'…',W/2,H/2); ctx.textAlign='left'; ctx.globalAlpha=1; }
```

- [x] **Step 4: Mission report UI (`endMission`) + save v3**

Replace `SKEY` block additions (keep old SKEY constant for mute migration):

```js
const SKEY3='boosterLanding.v3';
let save3=(function(){ try{return JSON.parse(localStorage.getItem(SKEY3))||{}}catch(e){return{}} })();
function persist3(){ try{localStorage.setItem(SKEY3,JSON.stringify(save3))}catch(e){} }
function prog3(d){ if(!save3[d]) save3[d]={unlocked:0,best:{}}; return save3[d]; }
```

Add `endMission` next to `endAttempt`:

```js
function endMission(failRes){
  gameState='result'; setThrustSound(0);
  const fail=failRes&&failRes.fail, byAuto=ap!==0;
  const verdict=fail||((RUN.results.every(r=>r.verdict==='PERFECT'))?'PERFECT':'COMPLETE');
  const score=fail?0:Math.round(RUN.score*(1+RUN.idx*0.07));
  let isBest=false;
  if(!fail&&!byAuto){ const p=prog3(diff);
    if(RUN.idx>=p.unlocked) p.unlocked=Math.min(CAMPAIGN.length-1,RUN.idx+1);
    if(!p.best[RUN.idx]||score>p.best[RUN.idx]){ p.best[RUN.idx]=score; isBest=true; } persist3(); }
  const colors={PERFECT:'var(--green)',COMPLETE:'var(--cyan)',CRASH:'var(--red)',LOST:'var(--red)',BREAKUP:'var(--red)',BURNUP:'var(--red)'};
  $('#rVerdict').innerHTML=verdict+(byAuto?' <span style="font-size:.4em;vertical-align:middle;color:var(--cyan);font-weight:700">🤖 AUTOPILOT</span>':'');
  $('#rVerdict').style.color=colors[verdict]||'var(--ink)';
  $('#rSub').textContent=fail?(failRes.reason||'Mission failed.'):'Mission complete — every phase flown.';
  $('#rStats').innerHTML=RUN.m.phases.map((p,i)=>{ const r=RUN.results[i];
    const v=r?(r.fail||r.verdict||'OK'):'—';
    return '<div class="rstat"><div class="k">'+(p.label||p.type)+'</div><div class="v" style="color:'+(r&&!r.fail?'var(--green)':(r?'var(--red)':'var(--faint)'))+'">'+v+'</div></div>'; }).join('');
  $('#rScore').textContent=score.toLocaleString();
  const best=prog3(diff).best[RUN.idx]||0;
  $('#rBest').innerHTML=byAuto?'flown by autopilot · not saved':(!fail?('best '+best.toLocaleString()+(isBest?'<span class="newbest">NEW BEST</span>':'')):'');
  $('#rNext').style.display=(!fail&&RUN.idx<CAMPAIGN.length-1)?'':'none';
  $('#report').classList.add('show');
  document.title='RESULT '+verdict+(byAuto?' AUTO':'')+' M'+(RUN.idx+1)+' score='+score
    +' phases='+RUN.results.map(r=>r.fail||r.verdict||'ok').join(',');
}
```

- [x] **Step 5: Menu — Campaign launches missions; Practice tab keeps the old game**

In the menu code: rename tab labels and wire `playBtn`:

```js
// tab ids stay; relabel in HTML: tabCampaign → '🗺 Missions', tabFree → '🛠 Practice'
$('#playBtn').onclick=()=>{ audioResume();
  if(tab==='campaign') startMission(campIdx);
  else { RUN=null; PH=null; landInit({world:freeWorld,terrain:freeTerrain,rocket:freeRocket,
         hazards:practiceHaz(), a:250, nameTag:'Practice'});
         gameState='play'; paused=false; updateAPBtn();
         $('#menu').classList.remove('show'); $('#report').classList.remove('show'); $('#hud').classList.add('on'); audioResume(); } };
function practiceHaz(){ const h={}; if(WORLDS[freeWorld].wind>0) h.wind=.5;
  if(freeWorld==='mars') h.dust=.6; if(freeTerrain==='ship') h.moving=.7; return h; }
```

`buildCampaign` switches to `prog3(diff)` and the new CAMPAIGN table (Task 5 supplies it; until then it renders the placeholder M1 row added in Step 6). Retry/`r` key: `if(k==='r'){ if(gameState==='play'||gameState==='result'){ RUN?startMission(RUN.idx):($('#menu').classList.contains('show')?0:landInit(lastPracticeArgs())) } }` — simplest correct form: store the last launch closure:

```js
let relaunch=null;            // set inside playBtn handler for both branches
// in startMission: relaunch=()=>startMission(idx);
// in practice branch: relaunch=()=>{...the same landInit call...};
// r-key/rRetry/rNext use: if(relaunch) relaunch();
```

(Wire `$('#rRetry').onclick=()=>relaunch&&relaunch();`, `$('#rNext').onclick=()=>{ if(RUN&&RUN.idx<CAMPAIGN.length-1) startMission(RUN.idx+1); };` and the `r` key to `relaunch`.)

- [x] **Step 6: Temporary campaign stub + `#simland` harness**

Replace the old 18-entry CAMPAIGN with a stub so the file stays runnable until Task 5:

```js
const CAMPAIGN=[
  {w:'port',r:'falcon9',name:'First Landing (temp)',d:'Placeholder until ascent ships.',
   phases:[{type:'land',label:'LAND',world:'port',terrain:'pad',rocket:'falcon9',a:240}]},
];
```

In the hash IIFE, add `#simland` (synchronous, like `#sim`) and point `#sim` at missions:

```js
if(p[0]==='simland'){ diff=DIFFS[p[1]]?p[1]:'realistic'; ap=1;
  RUN=null; PH=null;
  landInit({world:(p[3]==='lander'||p[3]==='hopper')?'moon':(p[2]==='ship'?'sea':'port'),
    terrain:TERRAINS[p[2]]?p[2]:'pad', rocket:ROCKETS[p[3]]?p[3]:'falcon9', a:250, nameTag:'simland'});
  gameState='play';
  let n=0; while(gameState==='play'&&n<14000){ landUpdate(1/60); n++; }
  if(gameState==='play') document.title='RESULT TIMEOUT';
  return; }
if(p[0]==='sim'){ diff=DIFFS[p[1]]?p[1]:'realistic'; ap=1;
  startMission(clamp(+p[2]||0,0,CAMPAIGN.length-1));
  let n=0; while(gameState==='play'&&n<60000){ update(1/60); n++; }
  if(gameState==='play') document.title='RESULT TIMEOUT';
  return; }
```

(`#play`/`#shot` keep working: change their `startGame()` calls to `startMission(campIdx)`.)
Note `#simland` drives `landUpdate` directly and `#sim` drives the dispatcher `update` — transitions advance because `stepTransition` runs inside it.

- [x] **Step 7: AFTER regression check vs Step 1 baseline**

```bash
run test                                  # expect TESTS PASS 7/7
for t in pad ship platform mountains tower; do for r in falcon9 starship hopper heavy lander; do
  echo "== $t/$r: $(run simland:realistic:$t:$r)"; done; done
run sim:realistic:0                       # temp mission → RESULT COMPLETE/PERFECT AUTO M1 ...
```

Expected: every `simland` line ends `RESULT GOOD AUTO…`/`PERFECT`/`HARD` (success verdicts — same class of outcomes as /tmp/before.txt; exact scores may differ where rng differs). `TIMEOUT`, `CRASH`, `LOST`, or a JS-error title = regression: stop and fix before proceeding.
Also run the frame-1 check: `run ""` → plain `Booster — Rocket Landing` title.

- [x] **Step 8: Commit**

```bash
git add index.html && git commit -m "refactor: landing behind phase interface; missions launch via RUN; Practice mode; save v3; #simland harness

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

**Consistency note for Task 2 (apply while doing Task 2):** `mkCraft` must snapshot each stage's starting fuel: `stages:R.stages.map(s=>({...s, fuel0:s.fuel}))` — the HUD fuel bars and `M.fuelCap` (Task 4) read `fuel0`.

---

### Task 5: New campaign data (M1 + M2) and world atmosphere constants

**Files:** Modify `index.html`: CAMPAIGN stub from Task 4, WORLDS table.

- [x] **Step 1: Add `atmoTop` to WORLDS** (entry/ascent need it; Moon=0 means no entry phase):

```js
// WORLDS additions (one field per world):
sea:  {... atmoTop:10000},  port: {... atmoTop:10000},
moon: {... atmoTop:0},      mars: {... atmoTop:7000},
```

The game's "space line" is 10 km of game-altitude (KSP-style compression per spec §3.2) — the ALTITUDE card just shows honest km.

- [x] **Step 2: Replace the Task-4 CAMPAIGN stub with the real Part-1 table**

```js
const CAMPAIGN=[
 {w:'port',r:'falcon9',name:'First Flight',d:'Up, over, and down on the pad. Learn throttle and lean.',
  phases:[
   {type:'ascent',label:'ASCENT',world:'port',rocket:'falcon9',hop:true,cutAlt:1400,hand:340},
   {type:'land',  label:'LAND',  world:'port',terrain:'pad',rocket:'falcon9',a:340,hazards:{}}]},
 {w:'port',r:'falcon9',name:'Kármán Line',d:'Ride the full stack to space, stage on the way, survive re-entry.',
  phases:[
   {type:'ascent',label:'ASCENT',  world:'port',rocket:'falcon9',cutAlt:10500},
   {type:'entry', label:'RE-ENTRY',world:'port',gMax:0},
   {type:'land',  label:'LAND',    world:'port',terrain:'pad',rocket:'falcon9',a:300,hazards:{wind:.4}}]},
];
```

- [x] **Step 3: Mission cards show phase-chain icons** — in `buildCampaign`, replace the old `tags` line with:

```js
const ICONS={ascent:'🚀',entry:'🔥',land:'🛬',orbit:'🌍',dock:'🔗'};
const tags=[WORLDS[m.w].ic+' '+WORLDS[m.w].name.split(' · ').pop(),
            m.phases.map(p=>ICONS[p.type]||'•').join(' ')];
```

(everything else in the card markup stays; `prog3(diff)` already wired in Task 4.)

- [x] **Step 4: Run sanity** — `run test` → `TESTS PASS 7/7`; `run ""` → clean title. `run sim:realistic:0` → will FAIL/TIMEOUT (ascent not implemented yet) — that's expected; do NOT debug it here.

- [x] **Step 5: Commit**

```bash
git add index.html && git commit -m "feat: Part-1 campaign table (M1 hop, M2 Kármán) + world atmoTop

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: ASCENT phase

**Files:** Modify `index.html`: new section after `PHASES.land` block; HTML `#touch` div; CSS; `updateHUD` dispatcher; `explode()` guard; `drawGuides` guard; TESTS block.

- [x] **Step 1: Failing logic tests** (append to TESTS):

```js
T_('ascent: pitch ladder is 0 on the pad, eastward and capped high up', ()=>{
  near(ascPitchTarget(0),0,1e-9); near(ascPitchTarget(200),0,1e-9,'vertical to 300m');
  ok(ascPitchTarget(3000)>0.2,'leans east'); ok(ascPitchTarget(99000)<=1.25+1e-9,'capped');
  ok(ascPitchTarget(6000)>ascPitchTarget(2000),'monotonic');
});
T_('ascent: Max-Q envelope narrows with q then relaxes', ()=>{
  ok(ascMaxLean(0)>1.0,'thin air = free');
  ok(ascMaxLean(2.0)<0.45,'thick+fast = tight');
  ok(ascMaxLean(0.2)>ascMaxLean(2.0));
});
```

- [x] **Step 2: Run, verify FAIL** — `run test` → `TESTS FAIL 2/9 :: … ascPitchTarget is not defined`.

- [x] **Step 3: Implement the phase.** Insert after the `PHASES.land` registration:

```js
/* ═════════════════ ASCENT PHASE ═════════════════
   Own physics (x=downrange east, y=altitude); reuses drawRocket via the R/M proxy.
   Sets global ppm each frame — PHASES.land.init calls resize() to restore it. */
let A=null;
function ascPitchTarget(y){ return clamp((y-300)/9000,0,1)*1.25; }            // rad east
function ascMaxLean(q){ return 0.09+0.9/(0.7+q*2.2); }                        // q in normalized units
PHASES.ascent={
  init(spec,carry){
    WLD=WORLDS[spec.world]; const RK=ROCKETS[spec.rocket], D=DIFFS[diff];
    M={ g:WLD.g, rw:RK.w, rh:RK.h, style:RK.style, rcs:false, pad:30, mult:D.mult, mc:D.dc };
    A={ spec, x:0,y:0,vx:0,vy:0, ang:0,av:0, thr:0, t:-3.2, q:0,qFrac:0, over:0,
        ladderErr:0, ladderN:0, sep:null, stagedLate:0, apStageT:0, done:false };
    T=null; env=null;                       // frame-1 rule: world drawing is ascent-owned
    R={ x:0,y:0, vx:0,vy:0, angle:0, av:0, throttle:0, legs:0, exhaust:0, fuel:100 };
    cam.bottom=-20; cam.x=0;
    document.body.classList.remove('rcs'); document.body.classList.add('asc');
    $('#missionTag').innerHTML='<b>'+WLD.name+'</b> · '+RK.name+' · '+RUN.m.name;
  },
  update(dt){
    A.t+=dt;
    const c=RUN.craft, s=c.stages[c.si];
    readKeys();
    const inp = ap!==0 ? this.ap(dt) : {thr:input.thr,left:input.left,right:input.right};
    if(A.t<0){ A.thr=lerp(A.thr, A.t>-0.6?1:0, clamp(dt*6,0,1)); R.exhaust=A.thr; this.sync(); return; }  // countdown: engines light, clamps hold
    A.thr=lerp(A.thr, inp.thr?1:0, clamp(dt*9,0,1)); if(s.fuel<=0) A.thr=0;
    const rotIn=(inp.right?1:0)-(inp.left?1:0);
    A.av=lerp(A.av, rotIn*55/DEG, clamp(dt*5,0,1)); A.ang=clamp(A.ang+A.av*dt,-1.45,1.45);
    if(DIFFS[diff].autoLevel&&rotIn===0) A.ang=lerp(A.ang,ascPitchTarget(A.y),clamp(dt*0.5,0,1));  // arcade nudge
    const acc=craftAccel(c,A.thr); burnStage(c,A.thr,dt);
    const rho=WLD.atmoTop?Math.exp(-A.y/(WLD.atmoTop*0.33)):0, sp=Math.hypot(A.vx,A.vy);
    A.q=rho*sp*sp/1000; A.qFrac=clamp(Math.abs(A.ang)/ascMaxLean(A.q),0,1.3);
    const drag=0.012*rho*sp;
    let ax=acc*Math.sin(A.ang)-drag*A.vx, ay=acc*Math.cos(A.ang)-M.g-drag*A.vy;
    if(A.t<0.4&&A.vy<0){ ay=Math.max(ay,0); }                                  // pad holds you
    A.vx+=ax*dt; A.vy+=ay*dt; A.x+=A.vx*dt; A.y=Math.max(0,A.y+A.vy*dt);
    // ladder adherence (scored)
    A.ladderErr+=Math.abs(A.ang-ascPitchTarget(A.y)); A.ladderN++;
    // Max-Q structural envelope
    if(A.y>40&&Math.abs(A.ang)>ascMaxLean(A.q)*(diff==='arcade'?1.5:diff==='hardcore'?0.85:1))
         A.over+=dt; else A.over=Math.max(0,A.over-dt*0.7);
    if(A.over>1.1){ this.sync(); explode(); shake=1.4; sndBoom();
      phaseDone({fail:'BREAKUP',reason:'Aerodynamic stress tore the rocket apart',score:0}); return; }
    // staging (Space / STAGE btn); spent stage becomes a prop
    if((keys[' ']||input._tStage)&&s.fuel<=0&&canStage(c)){ keys[' ']=false; input._tStage=0; ascDoStage(); }
    if(s.fuel<=0&&canStage(c)) A.stagedLate+=dt;
    if(A.sep){ const p=A.sep; p.t+=dt; p.vy-=M.g*0.6*dt; p.x+=p.vx*dt; p.y+=p.vy*dt; p.rot+=p.vr*dt; if(p.t>5) A.sep=null; }
    // engine particles (reuse landing flame look)
    if(A.thr>0.05&&s.fuel>0){ const dx=Math.sin(A.ang),dy=Math.cos(A.ang);
      for(let i=0;i<2;i++){ const v=rnd(8,16)*A.thr;
        particles.push({x:A.x-dx*2,y:A.y-dy*2,vx:-dx*v+rnd(-3,3),vy:-dy*v+rnd(-2,2),life:rnd(.3,.6),t:0,size:rnd(1.2,2.4),kind:'flame'}); } }
    setThrustSound(A.thr*(s.fuel>0?1:0)); stepParticles(dt); shake=Math.max(0,shake-dt*3);
    this.sync();
    // exits
    const cur=c.stages[c.si];
    if(A.spec.hop){
      if(A.y>=A.spec.cutAlt) A.thr=Math.min(A.thr,0);                          // MECO: coast over the top
      if(A.vy<0&&A.y<=A.spec.hand){
        phaseDone({verdict:'OK',score:this.scoreIt(),carry:{xOff:clamp(A.x*0.15,-60,60),vx:clamp(A.vx,-18,18),vy:clamp(A.vy,-46,-8)}}); return; }
      if(A.vy<0&&cur.fuel<=0&&!canStage(c)&&A.y>A.spec.hand+400){}             // gliding down dry is fine — land phase decides fate
    } else {
      if(A.y>=A.spec.cutAlt){
        phaseDone({verdict:'OK',score:this.scoreIt(),carry:{v:Math.hypot(A.vx,A.vy)}}); return; }
      if(cur.fuel<=0&&!canStage(c)&&A.vy<0){                                   // under-performance → emergency entry (spec §4.1)
        phaseDone({verdict:'SHORT',score:Math.round(this.scoreIt()*0.4),carry:{v:Math.hypot(A.vx,A.vy)*0.8,emergency:true}}); return; }
    }
  },
  sync(){ const s=RUN.craft.stages[RUN.craft.si];
    R.x=A.x; R.y=A.y; R.angle=A.ang; R.exhaust=A.thr*(s.fuel>0?1:0); R.legs=0; R.fuel=100*s.fuel/s.fuel0;
    ppm=H/(VIS*(1+A.y/260)); cam.bottom=lerp(cam.bottom,A.y-0.45*H/ppm,clamp(0.08,0,1)); cam.x=lerp(cam.x,A.x,0.08); },
  scoreIt(){ const c=RUN.craft, fuelFrac=c.stages[c.si].fuel/c.stages[c.si].fuel0;
    const ladder=clamp(1-(A.ladderErr/Math.max(1,A.ladderN))/0.5,0,1);
    const crisp=clamp(1-A.stagedLate/4,0,1);
    return Math.round((fuelFrac*500+ladder*550+crisp*150)*M.mult); },
  ap(dt){ const out={thr:1,left:0,right:0}, c=RUN.craft, s=c.stages[c.si];
    const tgt=ascPitchTarget(A.y), pred=A.ang+A.av/5;
    if(tgt-pred>0.015) out.right=1; else if(tgt-pred<-0.015) out.left=1;
    if(A.spec.hop&&A.y>=A.spec.cutAlt) out.thr=0;
    if(s.fuel<=0&&canStage(c)){ A.apStageT+=dt; if(A.apStageT>0.6){ ascDoStage(); A.apStageT=0; } }
    return out; },
  render(){ ascRender(); },
  hud(){ const s=RUN.craft.stages[RUN.craft.si];
    setCardLabels(['Altitude','Speed','Pitch','Max-Q']);
    const vs=$$('.tele .tcard .v');
    vs[0].innerHTML=A.y<1000?Math.round(A.y)+'<small> m</small>':(A.y/1000).toFixed(1)+'<small> km</small>'; vs[0].style.color='var(--ink)';
    vs[1].innerHTML=Math.round(Math.hypot(A.vx,A.vy))+'<small> m/s</small>'; vs[1].style.color='var(--ink)';
    vs[2].innerHTML=Math.round(A.ang*DEG)+'<small>°</small>';
    vs[2].style.color=Math.abs(A.ang-ascPitchTarget(A.y))>0.18?'var(--gold)':'var(--green)';
    vs[3].innerHTML=Math.round(A.qFrac*100)+'<small>%</small>';
    vs[3].style.color=A.qFrac>0.95?'var(--red)':A.qFrac>0.65?'var(--gold)':'var(--ink)';
    $('#fuelFill').style.width=(100*s.fuel/s.fuel0)+'%'; $('#fuelTxt').textContent=Math.round(100*s.fuel/s.fuel0)+'%';
    $('#fuelFill').style.background=s.fuel/s.fuel0<0.2?'linear-gradient(90deg,#7a2f2f,var(--red))':'linear-gradient(90deg,#2f6f4a,var(--green))';
    $('#thrFill').style.width=(A.thr*100)+'%'; $('#thrTxt').textContent=Math.round(A.thr*100)+'%';
    const apP=$('#apPanel');
    if(ap!==0){ apP.classList.add('on'); $('#apState').textContent=AP_NAMES[ap];
      $('#apState').className='apState '+(ap===1?'auto':'assist');
      $('#apPhaseEl').textContent=(RUN.craft.stages[RUN.craft.si].fuel<=0&&canStage(RUN.craft))?'STAGE!':'ASCENT GUIDANCE';
      $('#apTgtEl').innerHTML='pitch '+Math.round(ascPitchTarget(A.y)*DEG)+'° <small>vs</small> '+Math.round(A.ang*DEG)+'°'; }
    else apP.classList.remove('on'); },
};
function ascDoStage(){ const c=RUN.craft;
  A.sep={x:A.x-Math.sin(A.ang)*2,y:A.y-Math.cos(A.ang)*2,vx:A.vx*0.9-3,vy:A.vy*0.85-3,rot:A.ang,vr:rnd(-1.2,1.2),t:0,w:M.rw,h:M.rh*0.55};
  doStage(c); M.rh=ROCKETS[c.rk].h*0.55; M.rw=ROCKETS[c.rk].w*0.8;
  blip(110,0.3,'square',0.32); shake=Math.max(shake,0.55);
  for(let i=0;i<16;i++) particles.push({x:A.x,y:A.y-2,vx:rnd(-8,8),vy:rnd(-6,2),life:rnd(.3,.8),t:0,size:rnd(1.5,3),kind:'spark'});
}
function ascRender(){
  // darken sky with altitude; stars fade in above half-atmosphere
  const k=WLD.atmoTop?clamp(A.y/WLD.atmoTop,0,1):1;
  ctx.fillStyle='rgba(2,3,8,'+(k*0.92)+')'; ctx.fillRect(-40,-40,W+80,H+80);
  if(k>0.45){ ctx.globalAlpha=(k-0.45)/0.55; drawStars(); ctx.globalAlpha=1; }
  // ground + pad while still in view
  const gY=sy(0);
  if(gY<H+60){ ctx.fillStyle=WLD.ground; ctx.fillRect(-40,gY,W+80,H-gY+80);
    const px=sx(0); ctx.fillStyle='rgba(20,28,44,.9)'; ctx.fillRect(px-15*ppm,gY,30*ppm,Math.max(3,1.4*ppm));
    ctx.fillStyle='#e8c24a'; for(let x=px-15*ppm;x<px+15*ppm;x+=13) ctx.fillRect(x,gY,6,3);
    ctx.strokeStyle='#3a4866'; ctx.lineWidth=Math.max(2,ppm*1.2);                       // gantry tower
    ctx.beginPath(); ctx.moveTo(px-8*ppm,gY); ctx.lineTo(px-8*ppm,gY-26*ppm); ctx.stroke(); }
  // spent stage prop
  if(A.sep){ const p=A.sep; ctx.save(); ctx.translate(sx(p.x),sy(p.y)); ctx.rotate(p.rot);
    ctx.fillStyle='#aab3c6'; ctx.fillRect(-p.w*ppm/2,-p.h*ppm,p.w*ppm,p.h*ppm); ctx.restore();
    if(Math.random()<0.5) particles.push({x:p.x,y:p.y,vx:rnd(-2,2),vy:rnd(-2,2),life:rnd(.4,1),t:0,size:rnd(1,2.5),kind:'spray'}); }
  drawParticles(); drawRocket();
  // pitch ladder ghost (same visual language as the AP lean ghost)
  if(gameState==='play'){ ctx.save(); ctx.translate(sx(A.x),sy(A.y)); ctx.rotate(ascPitchTarget(A.y));
    ctx.setLineDash([3,5]); ctx.strokeStyle='rgba(92,200,255,.65)'; ctx.lineWidth=1.6;
    ctx.beginPath(); ctx.moveTo(0,0); ctx.lineTo(0,-M.rh*ppm*1.5); ctx.stroke(); ctx.restore(); }
  // countdown numerals
  if(A.t<0){ ctx.fillStyle='rgba(234,240,255,.92)'; ctx.font='800 64px Outfit';
    ctx.textAlign='center'; ctx.fillText(Math.ceil(-A.t),W/2,H*0.3); ctx.textAlign='left'; }
}
```

- [x] **Step 4: Wire the shared bits** (each is a small precise edit):

1. `render()` world section — ascent draws its own world: change
   `if(env) drawTerrain();` → stays, and change `if(gameState==='play') drawGuides();` → `if(gameState==='play'&&env) drawGuides();`
   then add after the world drawing, before particles: `if(RUN&&PH===PHASES.ascent){ /* ascent renders inside PH.render() */ }` — concretely, the render dispatch becomes:

```js
function render(){
  ctx.save();
  if(shake>0) ctx.translate(rnd(-1,1)*shake*7,rnd(-1,1)*shake*7);
  drawSkyWorld(); if(WLD.stars) drawStars(); drawCelestial();
  if(RUN&&PH&&PH!==PHASES.land){ PH.render(); }
  else {
    if(env) drawTerrain();
    if(gameState==='play'||gameState==='result'){ drawParticles(); if(R) drawRocket(); }
    if(gameState==='play'&&env) drawGuides();
  }
  if(WLD.haze||MS.dust||MS.fog) drawAtmosphere();
  if(TRANS){ /* veil from Task 4 stays here */ }
  ctx.restore();
}
```

2. `updateHUD` dispatcher:

```js
function updateHUD(){
  if(gameState!=='play') return;
  if(RUN&&PH&&PH.hud){ PH.hud(); return; }
  setCardLabels(['Altitude','Descent','Sideways','Tilt']); landHud();
}
function setCardLabels(l){ $$('.tele .tcard .k').forEach((k,i)=>k.textContent=l[i]); }
```

(rename the old `updateHUD` body to `landHud`, drop its own gameState guard, and register `hud(){ setCardLabels(['Altitude','Descent','Sideways','Tilt']); landHud(); }` on `PHASES.land`.)

3. `PHASES.land.init` first line: `resize();` (restores `ppm` after ascent's zoom).
4. `explode()` env guard: `y:Math.max(R.y,env?env.deckY:0)+rnd(0,6)`.
5. Touch STAGE button. HTML inside `#touch`: `<div class="tbtn" id="tStage">STAGE</div>`; CSS: `#tStage{right:calc(18px + env(safe-area-inset-right,0px));bottom:calc(132px + env(safe-area-inset-bottom,0px));width:58px;height:58px;display:none} body.asc #tStage{display:grid}` (+ phone block: `#tStage{bottom:calc(136px + env(safe-area-inset-bottom,0px))}`); JS: add `'#tStage:_tStage'` to the bindTouch list.
6. `openMenu()`/`endMission()` cleanup: add `document.body.classList.remove('asc')` to `openMenu`, and in `PHASES.land.init` too (entering landing from ascent).

- [x] **Step 5: Run tests + first full-mission sims**

`run test` → `TESTS PASS 9/9`.
`run sim:realistic:0` → expected `RESULT COMPLETE AUTO M1 score=… phases=OK,GOOD` (verdict letters may vary GOOD/PERFECT/HARD but no fail).
M2 will TIMEOUT (entry phase missing) — expected until Task 7.
Tuning knobs if M1 fails: booster `thrust` (900→up if it can't climb), `ascMaxLean` constants (0.9 numerator wider), hop `cutAlt`/`hand`, carry clamps. Re-run until COMPLETE on all three: `for d in arcade realistic hardcore; do run sim:$d:0; done`.

- [x] **Step 6: Commit**

```bash
git add index.html && git commit -m "feat: ascent phase — guided gravity turn, Max-Q, staging, hop missions

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: ENTRY phase (basic)

**Files:** Modify `index.html`: new section after the ascent block; TESTS block.

- [x] **Step 1: Failing test** (append):

```js
T_('entry: cone drifts inside ±0.75 and is finite', ()=>{
  for(let t=0;t<30;t+=0.37){ const c=entryCone(t,1.234); ok(isFinite(c)&&Math.abs(c)<=0.75,'t='+t); }
});
```

- [x] **Step 2: Run, verify FAIL** — `run test` → `TESTS FAIL 1/10 :: entry: … entryCone is not defined`.

- [x] **Step 3: Implement:**

```js
/* ═════════════════ ENTRY PHASE ═════════════════ */
let E=null;
function entryCone(t,ph){ return 0.42*Math.sin(t*0.55+ph)+0.22*Math.sin(t*1.45+ph*1.7); }
PHASES.entry={
  init(spec,carry){
    WLD=WORLDS[spec.world]; T=null; env=null;
    const D=DIFFS[diff];
    E={ spec, v:clamp(carry.v||160,90,240), ang:0, ph:rnd(0,TAU), t:0, heat:0, peak:0, g:0,
        emergency:!!carry.emergency, w:(diff==='arcade'?0.34:diff==='hardcore'?0.2:0.27), errAcc:0, errN:0 };
    M={...M, mult:D.mult};
    R={x:0,y:0,vx:0,vy:0,angle:0,av:0,throttle:0,legs:0,exhaust:0,fuel:R?R.fuel:100};
    cam.bottom=0; cam.x=0; document.body.classList.remove('asc');
  },
  update(dt){
    E.t+=dt; readKeys();
    const inp = ap!==0 ? this.ap(dt) : {left:input.left,right:input.right};
    E.ang=clamp(E.ang+((inp.right?1:0)-(inp.left?1:0))*1.1*dt,-0.9,0.9);
    const cone=entryCone(E.t,E.ph), err=Math.abs(E.ang-cone);
    E.errAcc+=err; E.errN++;
    const vPrev=E.v;
    E.v=Math.max(42,E.v-(14+E.v*0.09)*dt);
    E.g=(vPrev-E.v)/dt/9.8;
    if(err>E.w) E.heat+=dt*(0.32+E.v/240*0.5); else E.heat=Math.max(0,E.heat-dt*0.22);
    E.peak=Math.max(E.peak,E.heat);
    if(E.spec.gMax&&E.g>E.spec.gMax){ E.heat+=dt*0.5; }       // crewed: pulling too hard also cooks the envelope
    if(E.heat>=1){ explode(); shake=1.4; sndBoom();
      phaseDone({fail:'BURNUP',reason:'Lost the entry corridor — vehicle burned up',score:0}); return; }
    if(E.v<=45){
      const sl=clamp(E.errAcc/Math.max(1,E.errN)/E.w,0,1.6);
      phaseDone({verdict:E.peak<0.25?'CLEAN':'HOT', score:Math.round((1-clamp(E.peak,0,1))*600*M.mult),
        carry:{xOff:clamp(sl*(Math.random()<.5?-1:1)*110,-110,110)*(E.emergency?1.2:1),
               vx:clamp(sl*14,-16,16)*(Math.random()<.5?-1:1), vy:-34}}); return; }
    setThrustSound(0); shake=clamp(E.heat*0.7,0,0.8); stepParticles(dt);
    if(Math.random()<0.7) particles.push({x:rnd(-1,1)*2,y:rnd(-1,1)*2,vx:-Math.sin(E.ang)*30+rnd(-8,8),vy:18+rnd(-4,4),life:rnd(.2,.5),t:0,size:rnd(1.5,3.2),kind:'flame'});
  },
  ap(dt){ const out={left:0,right:0}; const cone=entryCone(E.t,E.ph), pred=E.ang;
    if(cone-pred>0.03) out.right=1; else if(cone-pred<-0.03) out.left=1; return out; },
  render(){
    ctx.fillStyle='rgba(2,3,8,0.9)'; ctx.fillRect(-40,-40,W+80,H+80);
    ctx.globalAlpha=0.8; drawStars(); ctx.globalAlpha=1;
    const limbY=H*0.86;                                       // planet limb glow at the bottom
    const g=ctx.createLinearGradient(0,limbY-80,0,H); g.addColorStop(0,'rgba(0,0,0,0)'); g.addColorStop(1,WLD.sky[1]);
    ctx.fillStyle=g; ctx.fillRect(0,limbY-80,W,H-limbY+80);
    ppm=H/240; cam.bottom=-120; cam.x=0;                      // fixed close frame
    ctx.save(); ctx.translate(W/2,H*0.42); ctx.rotate(E.ang);
    const hw=M.rw*ppm*0.5, hh=M.rh*ppm*0.55;                  // capsule/stage silhouette + plasma sheath
    ctx.fillStyle='#cfd6e4'; roundRect(-hw,-hh,hw*2,hh,hw*0.6); ctx.fill();
    const pl=ctx.createRadialGradient(0,hh*0.4,2,0,hh*0.4,hh*2.2);
    pl.addColorStop(0,'rgba(255,200,120,'+(0.25+E.heat*0.7)+')'); pl.addColorStop(1,'rgba(255,90,40,0)');
    ctx.fillStyle=pl; ctx.beginPath(); ctx.arc(0,hh*0.4,hh*2.2,0,TAU); ctx.fill();
    ctx.restore();
    drawParticles();
    // corridor cone indicator
    const cone=entryCone(E.t,E.ph);
    ctx.save(); ctx.translate(W/2,H*0.42);
    for(const s of[-1,1]){ ctx.save(); ctx.rotate(cone+s*E.w);
      ctx.strokeStyle='rgba(92,200,255,.5)'; ctx.setLineDash([4,7]); ctx.lineWidth=1.5;
      ctx.beginPath(); ctx.moveTo(0,-20); ctx.lineTo(0,-H*0.3); ctx.stroke(); ctx.restore(); }
    ctx.restore();
  },
  hud(){
    setCardLabels(['Speed','Heat','G-Force','Corridor']);
    const vs=$$('.tele .tcard .v');
    vs[0].innerHTML=Math.round(E.v*28)+'<small> km/h</small>'; vs[0].style.color='var(--ink)';
    vs[1].innerHTML=Math.round(E.heat*100)+'<small>%</small>';
    vs[1].style.color=E.heat>0.7?'var(--red)':E.heat>0.4?'var(--gold)':'var(--green)';
    vs[2].innerHTML=E.g.toFixed(1)+'<small> g</small>';
    vs[2].style.color=(E.spec.gMax&&E.g>E.spec.gMax)?'var(--red)':'var(--ink)';
    const err=Math.abs(E.ang-entryCone(E.t,E.ph));
    vs[3].innerHTML=(err<E.w?'IN':'OUT'); vs[3].style.color=err<E.w?'var(--green)':'var(--red)';
    $('#fuelFill').style.width=R.fuel+'%'; $('#fuelTxt').textContent=Math.round(R.fuel)+'%';
    $('#thrFill').style.width='0%'; $('#thrTxt').textContent='—';
    const apP=$('#apPanel');
    if(ap!==0){ apP.classList.add('on'); $('#apState').textContent=AP_NAMES[ap];
      $('#apState').className='apState '+(ap===1?'auto':'assist');
      $('#apPhaseEl').textContent='HOLDING CORRIDOR'; $('#apTgtEl').innerHTML='heat '+Math.round(E.heat*100)+'%'; }
    else apP.classList.remove('on'); },
};
```

- [x] **Step 4: Run tests + the M2 mission end-to-end**

`run test` → `TESTS PASS 10/10`.
`for d in arcade realistic hardcore; do run sim:$d:1; done` → each `RESULT COMPLETE AUTO M2 score=… phases=OK,CLEAN|HOT,…` (no TIMEOUT/fail).
Tuning knobs: `E.w` widths, heat rates (0.32/0.22), v-decay constants, AP deadband 0.03.

- [x] **Step 5: Commit**

```bash
git add index.html && git commit -m "feat: re-entry phase — corridor hold, heat, G readout, carry into landing

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Autopilot integration polish + landing AP under missions

**Files:** Modify `index.html`: `landUpdate` AP hook, `cycleAP`.

- [x] **Step 1: Confirm land phase AP works inside missions** — `landUpdate` already calls `autopilot(dt)` when `ap!==0`; missions reach it through `PHASES.land.update`. Verify: `run sim:realistic:0` shows phases all succeed (`phases=OK,…` with no `CRASH`). If the lander drifts: check that `landInit` reset `apPrevPadX=0` (it does — Task 4 code).

- [x] **Step 2: Make `R`/`r` retry work mid-mission** — already wired via `relaunch` (Task 4 Step 5). Manual check in a real browser later (Task 9); here just verify the binding exists: `grep -c "relaunch" index.html` ≥ 4.

- [x] **Step 3: Sweep stray references** —

```bash
grep -n "startGame" index.html   # expect ZERO hits (all call sites replaced in Task 4)
grep -n "save\b\|prog(" index.html | grep -v save3 | grep -v prog3   # only the mute lines may remain
run test && run "" && run sim:realistic:0 && run sim:realistic:1 && run simland:realistic:tower:starship
```

All green/expected titles before committing.

- [x] **Step 4: Commit**

```bash
git add index.html && git commit -m "chore: retry wiring + stray reference sweep for mission flow

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Full verification — matrix, human path, phone smoke, tag

**Files:** none (verification only) — fixes allowed, each with its own commit.

- [ ] **Step 1: Full autopilot matrix (the Part-1 gate)**

```bash
for d in arcade realistic hardcore; do for i in 0 1; do echo "$d M$((i+1)): $(run sim:$d:$i)"; done; done
for t in pad ship platform mountains tower; do echo "P-$t: $(run simland:realistic:$t:falcon9)"; done
run test
```

Expected: 6/6 missions `RESULT COMPLETE…` (or PERFECT), 5/5 practice `GOOD/PERFECT/HARD`, tests PASS. Any other outcome: STOP, fix (systematic-debugging skill), re-run whole step.

- [ ] **Step 2: The human path (mandatory — the 2026-06-11 rule)**

```bash
export PATH="/opt/homebrew/bin:$PATH"
agent-browser open "file:///Users/omrishahar/code/rocket-landing/index.html"; sleep 2
a=$(agent-browser eval "tPrev"); sleep 1; b=$(agent-browser eval "tPrev"); echo "menu loop: $a -> $b"   # MUST differ
agent-browser snapshot -i | grep -i launch                      # find the Launch ref (@eN)
agent-browser click @e7                                          # use the actual ref printed above
sleep 2; agent-browser eval "({state:gameState, phase:RUN&&RUN.m.phases[RUN.pi].type, t:A&&A.t})"
# expect: state 'play', phase 'ascent', t counting up from -3.2
agent-browser press h; sleep 45
agent-browser eval "document.title"                              # expect RESULT COMPLETE … M1
agent-browser screenshot /tmp/p1_mission_report.png
agent-browser close --all
```

Also click through: Esc → menu shows → Practice tab → pick tower/starship → Launch → flies (5 s eval `gameState==='play'`).

- [ ] **Step 3: Phone-layout smoke** — `run shot:realistic:0:5` then screenshot the file with the existing `#shot` flow in agent-browser at 390×844 (`agent-browser open --viewport 390x844 "$G#shot:realistic:0:5"`, screenshot, eyeball: STAGE button visible during ascent, cards readable, nothing overlapping).

- [ ] **Step 4: Update the project CLAUDE.md** — create `~/code/rocket-landing/CLAUDE.md`:

```markdown
# Booster — rocket game (single index.html)

- Run: double-click index.html. Phone: ./phone.sh → http://<mac>.local:8090.
- Dev harness (URL hash): #test (assertions→title) · #sim:diff:idx (autopilot full mission→title)
  · #simland:diff:terrain:rocket (landing practice) · #play / #shot as before.
- HARD RULE: hash modes bypass the menu — after any change, also verify the human path
  (load with no hash: menu render loop alive, click Launch). A frame-1 render crash hid
  there once (2026-06-11).
- Architecture: PHASES registry + RUN mission state; phases talk only via RUN.carry.
  Spec: docs/superpowers/specs/2026-06-11-full-missions-design.md (Parts 2–3 pending).
```

- [ ] **Step 5: Tag and final commit**

```bash
git add -A && git commit -m "docs: project CLAUDE.md (harness + human-path rule)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git tag part1-phase-engine && git log --oneline
```

---

## Plan self-review (done at writing time)

- **Spec coverage (Part-1 slice):** §3.1 engine→Task 3; §3.2 scale→ascent ppm zoom + atmoTop (Task 5/6); §4.1→Task 6 (camera pull-back to space ✓, breakup ✓, staging ✓, MECO ✓, under-performance→emergency entry ✓; curvature illusion deliberately deferred to Part 2 where the orbit map makes it meaningful); §4.4 basic→Task 7 (crewed gMax plumbed via spec, first used in Part 2's M7); §4.5→Task 4; §5→Task 2; §9 (per-phase report, v3 saves)→Task 4; §10 Practice→Task 4/5; §11 (HUD per phase, STAGE touch)→Tasks 6–7; §14 (#test/#sim/#simland/human-path)→Tasks 1,4,9. Deferred to Parts 2–3: §4.2–4.3, §6–§8 guidance gating (current diff effects: arcade auto-level nudge + envelope width only), §12–§13 audio pass, fuelMul activation (lands with the §8 difficulty table in Part 2).
- **Placeholders:** none — every step has code or an exact command + expected output.
- **Type consistency:** `mkCraft/craftMass/craftAccel/burnStage/canStage/doStage/stagesAbove` (Tasks 2,4,6); `RUN/PH/PHASES/phaseDone/nextPhase/skipTransition/stepTransition/missionReport/_missionReportHook` (Tasks 3,4); `landInit/landUpdate/landHud/landEvalMission` (Tasks 4,6); `A/E` phase states, `ascPitchTarget/ascMaxLean/ascDoStage/ascRender/entryCone` (Tasks 6,7); `SKEY3/save3/persist3/prog3` (Task 4); `setCardLabels` (Tasks 6,7); `relaunch` (Tasks 4,8); `fuel0` snapshot noted as Task-2 consistency note and used in Tasks 4,6.

