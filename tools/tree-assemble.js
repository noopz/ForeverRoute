// Puts one race x class plan together from a faction tree (tools/tree.js), the way the tree plays
// (docs/research/shared-trunk.md):
//   - the race's start, then the faction trunk minus what the start already did (hand-ins; pick-ups it made)
//   - class work is side quests, like the Cozy Sleeping Bag: self-contained routes that open at a level. The class's
//     reviewed side trips (tools/reviewed-<faction>.json, through make-character.js) go in the way every plan gets
//     them - paths.js splices an in-path one in at the first zone change once you can do it, and offers the rest as
//     trips of their own. Training is the same: when two ranks are waiting, or you are in a trainer's city anyway
//     (world.js trainNow, the rule route2 plans by).
// Nothing is replanned: paths.js --reuse gives the result the same safety net and walking paths as a built-in plan.
// usage: node tools/tree-assemble.js <tree dir> <race> <class> [--out dir]
const fs = require('fs'), path = require('path'), os = require('os');
const { execFileSync } = require('child_process');
const W = require('./world');
const ROOT = path.join(__dirname, '..');
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf('--' + k); return i >= 0 ? args[i + 1] : d; };
const [treeDir, race, cls] = args.filter((a, i) => !a.startsWith('--') && !(i > 0 && args[i - 1].startsWith('--')));
if (!treeDir || !race || !cls) { console.log('usage: node tools/tree-assemble.js <tree dir> <race> <class> [--out dir]'); process.exit(2); }
const readJson = (f) => JSON.parse(fs.readFileSync(f, 'utf8'));
const summary = readJson(path.join(treeDir, 'summary.json'));
if (!summary.starts[race]) { console.log(`no ${race} start in ${treeDir}`); process.exit(1); }
const startDir = path.join(ROOT, summary.starts[race].dir), trunkDir = path.join(treeDir, 'trunk');
const S = readJson(path.join(startDir, 'path-0.json')), K = readJson(path.join(trunkDir, 'path-0.json'));
const trunkCfg = readJson(path.join(trunkDir, 'campaign.json'));
const db = readJson(path.join(ROOT, trunkCfg.db));
const Q = db.quests;

// the race x class's own settings: trainers, training levels, side trips, must-do quests
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fr-tree-'));
const rcFile = path.join(tmp, 'campaign.json');
execFileSync(process.execPath, [path.join(__dirname, 'make-character.js'), '--name', 'Starter', '--race', race, '--class', cls, '--level', '1', '--zone', String(W.RACE_HOME[race]), '--target', '60', '--out', rcFile], { cwd: ROOT, stdio: 'ignore' });
const rc = readJson(rcFile);

// 1. start + trunk, without class work (the start and trunk are planned without it; this keeps it that way)
const classWork = (s) => s.k === 'train' || (s.q > 0 && Q[s.q] && !W.classFits(Q[s.q].classes, 'none'));
const start = S.steps.filter((s) => !classWork(s));
const handed = new Set(start.filter((s) => s.k === 'turnin').map((s) => s.q));
const accepted = new Set(start.filter((s) => s.k === 'accept').map((s) => s.q));
const trunk = K.steps.filter((s) => !classWork(s) && !(s.q && handed.has(s.q)) && !(s.k === 'accept' && accepted.has(s.q)));
const off = S.sections.length;
// the trunk's step clock (tm: minutes, on hearth steps - lint-route keeps the hour cooldown on it) starts after the
// start's: restarted at the seam, every plan read "hearth only -528 min after the one before"
const tmOff = Math.max(0, ...start.map((s) => +s.tm || 0));
let steps = start.concat(trunk.map((s) => ({ ...s, sec: (s.sec || 1) + off, ...(s.tm != null ? { tm: s.tm + tmOff } : {}) })));

// 2. training as a side quest: at a hand-in once two ranks wait, or as soon as one waits while you are in a trainer's town
const trainers = rc.trainers || (rc.trainer ? [rc.trainer] : []);
const zoneOf = (s) => s.zone;
const zoneName = (z) => { const t = trainers.find((x) => x.zone === z); return t && t.name ? (t.name.match(/\(([^)]+)\)/) || [, t.name])[1] : null; };
const trainerIn = (zn) => trainers.find((t) => zoneName(t.zone) === zn || (t.name || '').includes(zn));
const out = [];
let trained = 1, lvl = 1, trainSteps = 0;
for (const s of steps) {
  out.push(s);
  if (s.lvl) lvl = s.lvl;
  if (s.k !== 'turnin' && s.k !== 'fly') continue;
  const due = (rc.trainLevels || []).filter((l) => l > trained && l <= lvl);
  if (!due.length) continue;
  const here = trainerIn(zoneOf(s));
  if (!W.trainNow(due, !!here)) continue;
  const t = here || trainers.find((x) => /Stormwind|Ironforge|Darnassus|Orgrimmar|Thunder Bluff|Undercity/.test(x.name || '')) || trainers[0];
  if (!t) continue;
  out.push({ k: 'train', text: 'level ' + due.join('/') + ' spells', note: t.note || rc.trainerNote, sec: s.sec, m: undefined, zoneId: t.zone, x: t.x / 100, y: t.y / 100, zone: zoneName(t.zone) || t.name, r: 10, lvl });
  trained = due[due.length - 1]; trainSteps++;
}
// the uiMap of each trainer's zone: from any step of the plan in that zone (the planner's own steps carry it)
const mapOf = {};
for (const s of out) if (s.zone && s.m) mapOf[s.zone] = s.m;
steps = out.map((s, i) => ({ ...(s.k === 'train' ? { ...s, m: s.m || mapOf[s.zone], zoneId: undefined } : s), id: i + 1 }));

// 3. through paths.js (no replanning): the side trips go in, the walking paths and the safety net
const dir = opt('out', path.join(treeDir, 'assembled', `${race}_${cls}`));
fs.mkdirSync(dir, { recursive: true });
for (const f of fs.readdirSync(trunkDir)) { const p = path.join(trunkDir, f); if (fs.statSync(p).isFile() && !/^(Route\.lua|campaign\.json|path-0\.json)$/.test(f)) fs.copyFileSync(p, path.join(dir, f)); }
const plan = { ...K, legs: (S.legs || []).concat(K.legs || []), startLevel: 1, sections: S.sections.concat(K.sections), steps, choices: [], minutes: (S.minutes || 0) + (K.minutes || 0) };
fs.writeFileSync(path.join(dir, 'path-0.json'), JSON.stringify(plan));
const cfg = { ...trunkCfg, character: 'Starter', race, class: cls, level: 1, startZone: W.RACE_HOME[race], homeZone: W.RACE_HOME[race], startStateFile: undefined,
  trainers: rc.trainers, trainer: rc.trainer, trainerNote: rc.trainerNote, trainLevels: rc.trainLevels, special: rc.special, mustDo: rc.mustDo, bonusQuests: rc.bonusQuests, bonusNotes: rc.bonusNotes,
  routesOut: path.join(dir, 'Route.lua'), reuseDungeons: path.join(dir, 'dungeons.json'),
  // the tree's zone routes (tools/zone-routes.js): every plan offers them in the path picker, by level
  extraZoneRoutes: (() => { try { return readJson(path.join(treeDir, 'zone-routes', 'index.json')).map((d) => ({ name: d.name, z: d.z, level: d.level, xph: d.xph, pathOut: path.join(treeDir, d.file) })); } catch (e) { return []; } })() };
fs.writeFileSync(path.join(dir, 'campaign.json'), JSON.stringify(cfg, null, 2));
// (through run-planner.js: the planner can stay alive after writing its plan, and waiting for it hung for an hour)
execFileSync(process.execPath, [path.join(__dirname, 'run-planner.js'), path.join(dir, 'paths.log'), path.join(dir, 'campaign.json'), '1', '0', '--work', dir, '--reuse'], { cwd: ROOT, stdio: ['ignore', 'ignore', 'inherit'] });
const log = fs.readFileSync(path.join(dir, 'paths.log'), 'utf8');
const trips = [...log.matchAll(/in the path: (.+?) \((\d+) steps\)/g)].map((m) => m[1]);
const zr = (cfg.extraZoneRoutes || []).length;
console.log(`${race} ${cls}: ${zr} zone routes, start ${start.length} steps, trunk ${trunk.length} of ${K.steps.length}, training ${trainSteps} stops, side trips in the path: ${trips.join(', ') || 'none'} -> ${path.relative(ROOT, path.join(dir, 'Route.lua'))}`);
// wrapped as a built-in plan (Plan.lua), to play with FR_SIM_PLAN (tools/simplay.js starter:<race>-<class>) or ship
const key = `${race}-${cls}`;
const stamp = `tree ${path.basename(treeDir)} · ${new Date().toISOString().slice(0, 10)}`;
fs.writeFileSync(path.join(dir, 'Plan.lua'), [
  `-- Built-in plan for a ${race} ${cls}, from the ${summary.faction} tree (tools/tree-assemble.js): the ${race} start, the ${summary.faction} trunk, ${cls} side trips.`,
  `-- ${stamp}`,
  'ForeverRouteStarter = ForeverRouteStarter or {}',
  'ForeverRouteStarterStamp = ForeverRouteStarterStamp or {}',
  `ForeverRouteStarterStamp[${JSON.stringify(key)}] = ${JSON.stringify(stamp)}`,
  `ForeverRouteStarter[${JSON.stringify(key)}] = function()`,
  fs.readFileSync(path.join(dir, 'Route.lua'), 'utf8'),
  'end', ''].join('\n'));
