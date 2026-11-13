// Checks the optimizer (optimize.js):
// 1. it agrees with the quest simulation (route2.js): the simulation's own order of pick-ups, objectives and hand-ins
//    follows every rule, so the optimizer's cost model must find no broken rule in it. When the two disagree (kill XP
//    counted at another level, a log cap that is not Forever's 40...), every order looks broken to the optimizer and a
//    whole leg ships unoptimized.
// 2. it is deterministic: the same leg gives the same order on 1 thread and on 3 (its work is a number of moves in a
//    number of runs, not seconds and not one run per core, so a busy or a bigger PC plans the same route).
// usage: node tools/test-optimize.js [leg-config.json | leg.events.json ...]   (from the repo, needs qdb/ and terrain/)
//   with no arguments it plans a few fresh zone legs; given campaign leg configs (work-*/leg-*.json) it checks those;
//   a .events.json file (route2.js cfg.eventsOut) is the optimizer's input itself, no simulation needed
// node tools/test-optimize.js --budget [efforts=0.25,0.5,1,2] [legs...]: quality against work - each leg searched at
//   each effort (optimize.js workFor x effort, RUNS runs), how far each is above the best order any of them found
//   (seconds of the cost: travel + work + backtracking - finishing-XP bonus), and the time it took. What the default
//   effort was chosen with. --runs 3,5,7 (after the efforts): each effort at each number of runs too (default RUNS),
//   what the number of runs was weighed with.
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const { makeEval, optimize, workFor, RUNS } = require('./optimize');

const ROOT = path.resolve(__dirname, '..');
let args = process.argv.slice(2);
const BUDGET = args[0] === '--budget';
let efforts = [0.25, 0.5, 1, 2];
let runsList = [RUNS];
if (BUDGET) {
  args = args.slice(1);
  if (args[0] && /^[\d.,]+$/.test(args[0])) efforts = args.shift().split(',').map(Number);
  if (args[0] === '--runs') { args.shift(); runsList = args.shift().split(',').map(Number); }
}
const settings = efforts.flatMap((effort) => runsList.map((runs) => ({ effort, runs })));
const label = (x) => `effort ${String(x.effort).padEnd(5)}` + (runsList.length > 1 ? ` runs ${x.runs}` : '');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fr-opt-'));
const needCamp = !args.length || args.some((f) => !/[.]events[.]json$/.test(f));
const camp = !needCamp ? {} : (() => { const d = path.join(ROOT, 'routes'); const f = fs.existsSync(d) && fs.readdirSync(d).find((x) => /^campaign-.*\.json$/.test(x)); if (!f) { console.log('skipped: needs your settings in routes/campaign-<name>.json (tools/make-character.js)'); process.exit(0); } return JSON.parse(fs.readFileSync(path.join(d, f), 'utf8')); })();
const rel = (f) => (f && !path.isAbsolute(f) ? path.join(ROOT, f) : f);
function fresh(zone, level) {
  return { race: 'gnome', class: 'warlock', faction: 'alliance', level, xp: 0, zones: [zone, 1519], minQuestLevel: level - 6, maxQuestLevel: level + 5, targetLevel: 30, finishOpen: true, arrivalTour: true,
    flightSec: 120, completed: [], active: {}, terrainDir: rel(camp.terrainDir), conversion: rel(camp.conversion), trainLevels: camp.trainLevels, trainer: camp.trainer, itemsJson: rel(camp.itemsJson),
    dungeonFile: fs.existsSync(camp.dungeonFile || '') ? camp.dungeonFile : undefined, dungeons: camp.dungeons, dungeonRunMin: camp.dungeonRunMin, groupWaitMin: camp.groupWaitMin, title: 'test' };
}
const legs = args.length
  ? args.map((f) => ({ name: path.basename(f), file: f }))
  : [['Redridge at 20', 44, 20], ['Wetlands at 23', 11, 23], ['Duskwood at 27', 10, 27]].map(([name, z, l]) => ({ name, cfg: fresh(z, l) }));
// the optimizer's input for a leg: from route2.js (never writing over the campaign's own files), or given as it is
function input(leg) {
  if (leg.file && /[.]events[.]json$/.test(leg.file)) return JSON.parse(fs.readFileSync(leg.file, 'utf8'));
  const cfg = leg.cfg || JSON.parse(fs.readFileSync(leg.file, 'utf8'));
  const evOut = path.join(dir, 'events.json'), cfgFile = path.join(dir, 'cfg.json');
  const c = { ...cfg, optimize: true, eventsOut: evOut, eventsOnly: true, stateOut: path.join(dir, 'state.json'), routeOut: undefined, legOut: undefined };
  fs.writeFileSync(cfgFile, JSON.stringify(c));
  execFileSync(process.execPath, ['--max-old-space-size=8000', path.join(__dirname, 'route2.js'), rel(camp.db), cfgFile], { cwd: ROOT, stdio: ['ignore', 'ignore', 'ignore'] });
  return JSON.parse(fs.readFileSync(evOut, 'utf8'));
}
(async () => {
  let fails = 0;
  const table = [];
  for (const leg of legs) {
    const { events, D, nL, opts } = input(leg);
    require('./world').setLearned(opts.learned);
    const Df = Float32Array.from(D);
    if (BUDGET) {
      const rows = [];
      for (const x of settings) {
        const t = Date.now();
        const r = await optimize(events, Df, nL, { ...opts, effort: x.effort, runs: x.runs, capMs: undefined });
        rows.push({ ...x, cost: r.cost, ms: Date.now() - t });
      }
      const best = Math.min(...rows.map((r) => r.cost));
      const base = makeEval(events, Df, nL, opts)(Int32Array.from(opts.initial));
      console.log(`${leg.name}: ${events.length} events, ${workFor(events.length).maxIt} moves a run at effort 1, ${runsList.join('/')} runs; the simulation's order is ${Math.round(base - best)} s above the best`);
      for (const r of rows) console.log(`  ${label(r)} ${String(Math.round(r.cost - best)).padStart(6)} s above the best   ${(r.ms / 1000).toFixed(1)} s`);
      table.push(rows.map((r) => r.cost - best));
      continue;
    }
    const cost = makeEval(events, Df, nL, opts);
    const v = isFinite(cost(Int32Array.from(opts.initial))) ? cost.violations : Infinity;
    const ok = v === 0;
    console.log((ok ? 'ok   ' : 'FAIL ') + leg.name + ': the simulation\'s own order (' + events.length + ' events) breaks ' + v + ' optimizer rule(s)');
    if (!ok) fails++;
    // a short search (a tenth of the moves, 3 runs) on 1 thread and on 3: the same order
    const o = { ...opts, effort: 0.1, runs: 3, capMs: undefined };
    const a = await optimize(events, Df, nL, { ...o, workers: 1 }), b = await optimize(events, Df, nL, { ...o, workers: 3 });
    const same = a.cost === b.cost && a.order.join() === b.order.join();
    console.log((same ? 'ok   ' : 'FAIL ') + leg.name + ': 3 runs on 1 thread and on 3 threads ' + (same ? 'give the same order' : `differ (${Math.round(a.cost)} vs ${Math.round(b.cost)})`));
    if (!same) fails++;
  }
  fs.rmSync(dir, { recursive: true, force: true });
  if (BUDGET) {
    console.log(`\nsum over ${table.length} legs, seconds above the best found:`);
    settings.forEach((x, i) => console.log(`  ${label(x)} ${Math.round(table.reduce((t, r) => t + r[i], 0))}`));
    process.exit(0);
  }
  console.log(fails ? fails + ' failed' : 'all passed');
  process.exit(fails ? 1 : 0);
})();
