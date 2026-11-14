// The tree's gate (docs/research/shared-trunk.md): every race x class of the faction put together from the tree
// (tools/tree-assemble.js) and scored against its own built-in plan the same way (tools/score-plan.js: quest work plus
// grinding priced as people play). With --sim, the simulated player also plays each assembled plan 1-60 (clean
// persona): it must break no check. Writes <tree dir>/gate.json and a table.
// usage: node tools/tree-gate.js <tree dir> [--sim] [--only race_class,...] [--out gate-file]   (--out: shards run side by side)
const fs = require('fs'), path = require('path');
const { execFileSync, spawnSync } = require('child_process');
const W = require('./world');
const ROOT = path.join(__dirname, '..');
const args = process.argv.slice(2);
const treeDir = path.resolve(args.find((a) => !a.startsWith('--')) || '');
const opt = (k, d) => { const i = args.indexOf('--' + k); return i >= 0 ? args[i + 1] : d; };
const summary = JSON.parse(fs.readFileSync(path.join(treeDir, 'summary.json'), 'utf8'));
const races = Object.keys(summary.starts);
const only = opt('only', '') ? new Set(opt('only', '').split(',')) : null;
const combos = fs.readdirSync(path.join(ROOT, 'addon')).map((d) => d.match(/^ForeverRoute_Starter_([a-z]+)_([a-z]+)$/)).filter(Boolean)
  .map((m) => ({ race: m[1], cls: m[2] })).filter((c) => races.includes(c.race) && (!only || only.has(c.race + '_' + c.cls)));
const score = (file) => JSON.parse(execFileSync(process.execPath, [path.join(__dirname, 'score-plan.js'), file], { cwd: ROOT, encoding: 'utf8' }).trim().split('\n').pop());
function sim(race, cls, plan) {
  const r = spawnSync(process.execPath, [path.join(__dirname, 'simplay.js'), `starter:${race}-${cls}`, 'clean'], { cwd: ROOT, env: { ...process.env, FR_SIM_PLAN: plan, FR_SIM_CKPT: '0' }, encoding: 'utf8', maxBuffer: 1 << 28 });
  const out = (r.stdout || '') + (r.stderr || '');
  const t = out.match(/travel: riding ([\d.]+) h, flying ([\d.]+) h/);
  const travel = t ? +(+t[1] + +t[2]).toFixed(1) : NaN;
  const broke = +((out.match(/(\d+) broke a check/) || [])[1] ?? NaN);
  return { exit: r.status, travel, broke, tail: out.split('\n').slice(-4).join(' | ') };
}
const rows = [];
for (const { race, cls } of combos) {
  const own = path.join(ROOT, 'addon', `ForeverRoute_Starter_${race}_${cls}`, 'Plan.lua');
  let line;
  try { line = execFileSync(process.execPath, [path.join(__dirname, 'tree-assemble.js'), treeDir, race, cls], { cwd: ROOT, encoding: 'utf8' }).trim(); }
  catch (e) { rows.push({ race, cls, error: String(e.stdout || e.message).slice(-300) }); console.log(`${race} ${cls}: assemble failed`); continue; }
  const plan = path.join(treeDir, 'assembled', `${race}_${cls}`, 'Plan.lua');
  // a race x class with no built-in plan yet (the Horde's Skyborne) has nothing to compare against
  const a = score(plan), o = fs.existsSync(own) ? score(own) : { hours: NaN, workH: NaN, grindH: NaN, quests: NaN };
  const row = { race, cls, tree: { hours: a.hours, workH: a.workH, grindH: a.grindH, quests: a.quests }, own: { hours: o.hours, workH: o.workH, grindH: o.grindH, quests: o.quests }, assembled: line };
  if (args.includes('--sim')) row.sim = sim(race, cls, plan);
  rows.push(row);
  const d = o.hours > 0 ? ((a.hours - o.hours) / o.hours) * 100 : NaN;
  console.log(`${(race + ' ' + cls).padEnd(18)} tree ${a.hours} h (work ${a.workH}, grind ${a.grindH}, ${a.quests} quests)  own ${o.hours} h (grind ${o.grindH})  ${d >= 0 ? '+' : ''}${d.toFixed(1)}%${row.sim ? `  sim: exit ${row.sim.exit}, travel ${row.sim.travel} h, broke ${row.sim.broke}` : ''}`);
}
fs.writeFileSync(opt('out', '') ? path.resolve(opt('out', '')) : path.join(treeDir, 'gate.json'), JSON.stringify(rows, null, 1));
const ok = rows.filter((r) => r.tree);
const avg = (f) => { const v = ok.map(f).filter(Number.isFinite); return (v.reduce((s, x) => s + x, 0) / Math.max(1, v.length)).toFixed(1); }; // (a plan with nothing to compare against counts only for the tree)
console.log(`\n${ok.length} of ${rows.length} assembled; mean tree ${avg((r) => r.tree.hours)} h (grind ${avg((r) => r.tree.grindH)}) vs own ${avg((r) => r.own.hours)} h (grind ${avg((r) => r.own.grindH)})`);
