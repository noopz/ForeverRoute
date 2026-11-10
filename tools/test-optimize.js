// Checks that the optimizer (optimize.js) agrees with the quest simulation (route2.js): the simulation's own order of
// pick-ups, objectives and hand-ins follows every rule, so the optimizer's cost model must find no broken rule in it.
// When the two disagree (kill XP counted at another level, a log cap that is not Forever's 40...), every order looks
// broken to the optimizer and a whole leg ships unoptimized.
// usage: node tools/test-optimize.js [leg-config.json ...]   (from the repo, needs qdb/ and terrain/)
//   with no arguments it plans a few fresh zone legs; given campaign leg configs (work-*/leg-*.json) it checks those
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const { makeEval } = require('./optimize');

const ROOT = path.resolve(__dirname, '..');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fr-opt-'));
const camp = (() => { const d = path.join(ROOT, 'routes'); const f = fs.existsSync(d) && fs.readdirSync(d).find((x) => /^campaign-.*\.json$/.test(x)); if (!f) { console.log('skipped: needs your settings in routes/campaign-<name>.json (tools/make-character.js)'); process.exit(0); } return JSON.parse(fs.readFileSync(path.join(d, f), 'utf8')); })();
const rel = (f) => (f && !path.isAbsolute(f) ? path.join(ROOT, f) : f);
function fresh(zone, level) {
  return { race: 'gnome', class: 'warlock', faction: 'alliance', level, xp: 0, zones: [zone, 1519], minQuestLevel: level - 6, maxQuestLevel: level + 5, targetLevel: 30, finishOpen: true, arrivalTour: true,
    flightSec: 120, completed: [], active: {}, terrainDir: rel(camp.terrainDir), conversion: rel(camp.conversion), trainLevels: camp.trainLevels, trainer: camp.trainer, itemsJson: rel(camp.itemsJson),
    dungeonFile: fs.existsSync(camp.dungeonFile || '') ? camp.dungeonFile : undefined, dungeons: camp.dungeons, dungeonRunMin: camp.dungeonRunMin, groupWaitMin: camp.groupWaitMin, title: 'test' };
}
const legs = process.argv.slice(2).length
  ? process.argv.slice(2).map((f) => ({ name: path.basename(f), cfg: JSON.parse(fs.readFileSync(f, 'utf8')) }))
  : [['Redridge at 20', 44, 20], ['Wetlands at 23', 11, 23], ['Duskwood at 27', 10, 27]].map(([name, z, l]) => ({ name, cfg: fresh(z, l) }));
let fails = 0;
for (const { name, cfg } of legs) {
  const evOut = path.join(dir, 'events.json'), cfgFile = path.join(dir, 'cfg.json');
  // never write over the campaign's own files: only the optimizer input comes out
  const c = { ...cfg, optimize: true, eventsOut: evOut, eventsOnly: true, stateOut: path.join(dir, 'state.json'), routeOut: undefined, legOut: undefined };
  fs.writeFileSync(cfgFile, JSON.stringify(c));
  execFileSync(process.execPath, ['--max-old-space-size=8000', path.join(__dirname, 'route2.js'), rel(camp.db), cfgFile], { cwd: ROOT, stdio: ['ignore', 'ignore', 'ignore'] });
  const { events, D, nL, opts } = JSON.parse(fs.readFileSync(evOut, 'utf8'));
  const cost = makeEval(events, Float32Array.from(D), nL, opts);
  const v = isFinite(cost(Int32Array.from(opts.initial))) ? cost.violations : Infinity;
  const ok = v === 0;
  console.log((ok ? 'ok   ' : 'FAIL ') + name + ': the simulation\'s own order (' + events.length + ' events) breaks ' + v + ' optimizer rule(s)');
  if (!ok) fails++;
}
fs.rmSync(dir, { recursive: true, force: true });
console.log(fails ? fails + ' failed' : 'all passed');
process.exit(fails ? 1 : 0);
