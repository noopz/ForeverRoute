// One plan per faction, built as a tree (docs/research/shared-trunk.md, "The tree, built as a tree"):
//   1. race starts: each of the faction's races planned from level 1 to the join level (--join, default 20)
//   2. the trunk state: level J, the quests *every* start handed in (a quest only some did stays in the trunk: those who
//      did it skip it as done, the rest get it), the quests every start still holds, and the most common place they end
//   3. the trunk: planned from that state to 60 as race "<faction>" and class "none" - only what every race of the
//      faction may take, no class quests and no training (those are the class branches, spliced on afterwards)
// Writes tree/<faction>[-<exp>]/: starts/<race>/, trunk-state.json, trunk/ (Route.lua, path-0.json, path-0.log), and
// summary.json (hours and grind minutes per piece).
// usage: node tools/tree.js <alliance|horde> [--join 20] [--exp name] [--reuse-starts] [--start-class warrior]
//        [--extra '{"hopMin":20}']  (planner settings for the trunk only: experiments)
const fs = require('fs'), path = require('path');
const { spawnSync, spawn } = require('child_process');
const W = require('./world');
const ROOT = path.join(__dirname, '..');
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf('--' + k); return i >= 0 ? args[i + 1] : d; };
const faction = (args[0] || '').toLowerCase();
if (!W.FACTION_RACES[faction]) { console.log('usage: node tools/tree.js <alliance|horde> [--join 20] [--exp name]'); process.exit(2); }
const J = +opt('join', 20), EXP = opt('exp', ''), START_CLASS = opt('start-class', 'warrior');
const out = path.join(ROOT, 'tree', faction + (EXP ? '-' + EXP : ''));
fs.mkdirSync(path.join(out, 'starts'), { recursive: true });
const readJson = (f) => JSON.parse(fs.readFileSync(f, 'utf8'));

// grind minutes and hours of one planned piece (its path-0.log / path-0.json)
function measure(dir) {
  const log = fs.existsSync(path.join(dir, 'path-0.log')) ? fs.readFileSync(path.join(dir, 'path-0.log'), 'utf8') : '';
  let grindMin = 0, grindLegs = 0;
  for (const m of log.matchAll(/-> grind in [^:]+: level \d+ -> \d+, ~(\d+) min/g)) { grindMin += +m[1]; grindLegs++; }
  const p = fs.existsSync(path.join(dir, 'path-0.json')) ? readJson(path.join(dir, 'path-0.json')) : null;
  return { hours: p ? +(p.minutes / 60).toFixed(1) : null, endLevel: p && p.endLevel, grindMin, grindLegs, legs: p && p.legs };
}

// a start is the same for every class of its race: planned class-neutral (no training, no class quests - the class
// branch brings those, below the join level too). starter.js needs a real class to make the character; this overrides it.
const NEUTRAL = { class: 'none', trainers: [], trainer: null, trainLevels: [] };

// 1. race starts (the planner's own starter, one per race, to level J)
const starts = {};
// Skyborne (Forever's race, its start on Zephras Isle) join the trunk too, but their start is not one the trunk state
// is the meeting point of: planned and joined, left out of the intersection
const EXTRA_RACES = { alliance: ['skyborne'], horde: ['skybornehorde'] }; // the Horde's are the Windshaper Skyborne
const ALL_RACES = W.FACTION_RACES[faction].concat(args.includes('--no-extra') ? [] : EXTRA_RACES[faction]);
for (const race of ALL_RACES) {
  const key = `${race}-${START_CLASS}`, exp = (EXP ? EXP + '-' : '') + 'start' + J;
  const dir = path.join(ROOT, 'paths-starter', key + '-' + exp);
  if (!(args.includes('--reuse-starts') && fs.existsSync(path.join(dir, 'path-0.json')))) {
    console.log(`start: ${race} to ${J} ...`);
    const r = spawnSync(process.execPath, [path.join(__dirname, 'starter.js'), race, START_CLASS, String(J), '1'], { cwd: ROOT, env: { ...process.env, FR_EXPERIMENT: exp, FR_EXTRA: JSON.stringify(NEUTRAL) }, encoding: 'utf8', maxBuffer: 1 << 28 });
    fs.writeFileSync(path.join(out, 'starts', race + '.out'), (r.stdout || '') + (r.stderr || ''));
    if (r.status) { console.log(`start ${race} failed (exit ${r.status}): see ${path.join(out, 'starts', race + '.out')}`); process.exit(1); }
  }
  const p = readJson(path.join(dir, 'path-0.json'));
  if (!p.endState) { console.log(`start ${race}: no endState in path-0.json (planner older than tree.js)`); process.exit(1); }
  starts[race] = { dir, end: p.endState, ...measure(dir) };
  console.log(`start ${race}: level ${starts[race].endLevel}, ${starts[race].hours} h, grind ${starts[race].grindMin} min, ends in ${p.endState.state.pos && p.endState.state.pos.zone}`);
}

// a start that stops short of the join (it ran out of quests: grinding is off) would drag every race down to its
// level - Horde v9: the tauren start ended at 16 in Redridge and the trunk found nothing at 16 in Hillsbrad
const short = Object.entries(starts).filter(([r, s]) => W.FACTION_RACES[faction].includes(r) && (s.end.state.level || 0) < J);
if (short.length) { for (const [r, s] of short) console.log(`start ${r} stopped at level ${s.end.state.level}, short of the join (${J}), in zone ${s.end.state.pos && s.end.state.pos.zone}: see ${path.join(s.dir, "path-0.log")}`); process.exit(1); }

// 2. the trunk state
const ends = W.FACTION_RACES[faction].map((r) => starts[r].end.state);
const all = (sets) => sets.reduce((a, b) => new Set([...a].filter((x) => b.has(x))));
const completed = [...all(ends.map((e) => new Set(e.completed || [])))].sort((a, b) => a - b);
const activeIds = all(ends.map((e) => new Set(Object.keys(e.active || {}))));
const active = Object.fromEntries([...activeIds].map((id) => [id, ends[0].active[id]]));
const zoneVotes = {};
for (const e of ends) if (e.pos) zoneVotes[e.pos.zone] = (zoneVotes[e.pos.zone] || 0) + 1;
const zone = +Object.entries(zoneVotes).sort((a, b) => b[1] - a[1])[0][0];
const at = ends.find((e) => e.pos && e.pos.zone === zone);
const visits = {};
for (const s of Object.values(starts)) for (const [z, n] of Object.entries(s.end.visits || {})) visits[z] = Math.min(visits[z] ?? n, n); // visited by all
const level = Math.min(...ends.map((e) => e.level));
const trunkState = { state: { level, xp: 0, completed, active, pos: at.pos, zone, hearthCd: 0 }, visits };
fs.writeFileSync(path.join(out, 'trunk-state.json'), JSON.stringify(trunkState));
const union = new Set(ends.flatMap((e) => e.completed || []));
console.log(`trunk state: level ${level} in zone ${zone}; ${completed.length} quests done by every start (${union.size - completed.length} by some only: in the trunk for the rest), ${activeIds.size} held by all`);

// 3. the trunk
const base = readJson(path.join(starts[W.FACTION_RACES[faction][0]].dir, 'campaign.json'));
const trunkDir = path.join(out, 'trunk');
fs.mkdirSync(trunkDir, { recursive: true });
const cfg = { ...base, character: 'Trunk', race: faction, class: 'none', faction, level, startZone: zone, homeZone: null,
  startStateFile: path.join(out, 'trunk-state.json'), targetLevel: 60,
  // the class branches: training and class quests are spliced on per class afterwards
  trainers: [], trainer: null, trainerNote: undefined, trainLevels: [],
  mustDo: (base.mustDo || []).filter((q) => W.canTake(require(path.join(ROOT, base.db)).quests[q], faction, 'none')),
  special: (base.special || []).filter((s) => (s.quests || []).every((q) => W.canTake(require(path.join(ROOT, base.db)).quests[q], faction, 'none'))),
  routesOut: path.join(trunkDir, 'Route.lua'), ...JSON.parse(opt('extra', '{}')) };
const cfgFile = path.join(trunkDir, 'campaign.json');
fs.writeFileSync(cfgFile, JSON.stringify(cfg, null, 2));
console.log(`trunk: ${faction} ${level} -> 60 ...`);
const t0 = Date.now();
const planner = spawn(process.execPath, ['--max-old-space-size=8000', path.join(__dirname, 'paths.js'), cfgFile, '1', '0', '--work', trunkDir], { cwd: ROOT, stdio: ['ignore', 'pipe', 'inherit'] });
const logOut = fs.createWriteStream(path.join(out, 'trunk.out'));
let wrote = false;
planner.stdout.on('data', (d) => { logOut.write(d); if (/wrote \d+ paths/.test(String(d)) && !wrote) { wrote = true; setTimeout(() => { try { planner.kill(); } catch (e) {} }, 15000).unref(); } });
planner.on('close', (code) => {
  if (!wrote) { console.log('the trunk planner stopped without a plan (exit ' + code + '): see ' + path.join(out, 'trunk.out')); process.exit(1); }
  if (!fs.existsSync(path.join(trunkDir, 'path-0.json'))) { console.log('the trunk planner wrote no path (0 paths): see ' + path.join(out, 'trunk.out')); process.exit(1); }
  const trunk = measure(trunkDir);
  const summary = { faction, join: J, startClass: START_CLASS, starts: Object.fromEntries(Object.entries(starts).map(([r, s]) => [r, { dir: path.relative(ROOT, s.dir), hours: s.hours, endLevel: s.endLevel, grindMin: s.grindMin, legs: s.legs }])),
    trunkState: { level, zone, completed: completed.length, someOnly: union.size - completed.length, active: activeIds.size },
    trunk: { ...trunk, plannerSec: Math.round((Date.now() - t0) / 1000) } };
  fs.writeFileSync(path.join(out, 'summary.json'), JSON.stringify(summary, null, 1));
  console.log(`trunk: level ${trunk.endLevel}, ${trunk.hours} h, grind ${trunk.grindMin} min in ${trunk.grindLegs} legs, planned in ${summary.trunk.plannerSec} s`);
  console.log('  ' + (trunk.legs || []).join(' > '));
  (args.includes('--no-zone-routes') ? Promise.resolve([]) : require('./zone-routes').build(out, { share: +opt('zone-route-share', 0.6) })).then((zr) => {
    summary.zoneRoutes = zr.length;
    fs.writeFileSync(path.join(out, 'summary.json'), JSON.stringify(summary, null, 1));
    process.exit(0);
  });
});

