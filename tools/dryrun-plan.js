// Before committing a planner or quest-data change: plan from your latest save into a scratch folder, exactly as the
// companion's fast pass would (tools/autoplan.js), then put the result through the same gates the companion uses -
// a leveling path in it, the audit (lint-route.js on each main path) and the live check (the addon on that plan at
// the spot you saved). The companion plans with the repo's tools the moment they're committed, so a commit is a
// deploy to your game: this is the check that comes first (a 2026-11-13 planner change installed a plan with no path).
// usage: node tools/dryrun-plan.js [routes/campaign-<name>.json] [--full]   exit 0 = all gates passed
const fs = require('fs'), os = require('os'), path = require('path');
const { spawnSync } = require('child_process');
const ROOT = path.join(__dirname, '..');
const args = process.argv.slice(2);
const cfgFile = args.find((a) => a.endsWith('.json')) || fs.readdirSync(path.join(ROOT, 'routes')).filter((f) => /^campaign-.*\.json$/.test(f)).map((f) => path.join(ROOT, 'routes', f))[0];
const full = args.includes('--full');
const base = JSON.parse(fs.readFileSync(cfgFile, 'utf8'));
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'fr-dryrun-'));
const cfg = { ...base, routesOut: path.join(work, 'Route.lua'), ...(full ? { beam: 4 } : { reuseDungeons: path.join(ROOT, 'paths-auto-full', 'dungeons.json'), optimizeEffort: 0.5, evalRetrySec: 0 }) };
fs.writeFileSync(path.join(work, 'campaign.json'), JSON.stringify(cfg));
const t0 = Date.now();
// FR_DRYRUN_MIN: minutes the planner may take (a comparison run on a busy PC; the gate itself keeps 20 / 90)
// (the planner can stay alive after writing its plan - a worker thread; tools/starter.js stops it 15 s after 'wrote')
const r = spawnSync(process.execPath, ['--max-old-space-size=8000', path.join(__dirname, 'paths.js'), path.join(work, 'campaign.json'), '3', full ? '2' : '0', '--work', work], { cwd: ROOT, encoding: 'utf8', maxBuffer: 1 << 26, timeout: (+process.env.FR_DRYRUN_MIN || (full ? 90 : 20)) * 60000 });
const out = (r.stdout || '') + (r.stderr || '');
fs.writeFileSync(path.join(work, 'paths.log'), out);
console.log(`planned in ${Math.round((Date.now() - t0) / 1000)} s -> ${work}`);
console.log((out.match(/^wrote .*$/m) || ['(no "wrote" line)'])[0]);
let bad = 0;
const file = cfg.routesOut;
const text = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
const ids = [...text.matchAll(/^ {4}id = "(path:[^"]+)",/gm)].map((m) => m[1]);
if (!ids.length) { console.log('FAIL: no leveling path in the plan'); bad++; }
// the audit, as the companion runs it (prerequisites against the quests done in your save)
let doneArg = [], st = null;
try {
  st = require('./snapshot').loadCharState(base.charDir, path.resolve(ROOT, base.conversion));
  if (st && Array.isArray(st.completed)) { const f = path.join(work, 'done.json'); fs.writeFileSync(f, JSON.stringify({ done: st.completed, log: Object.keys(st.log || {}).map(Number) })); doneArg = [f]; }
} catch (e) { console.log('(no snapshot: prerequisites unchecked)'); }
for (const id of ids.slice(0, 3)) {
  const a = spawnSync(process.execPath, [path.join(__dirname, 'lint-route.js'), file, path.join(ROOT, 'qdb', 'db.json'), id, (base.class || '') + ',' + (base.race || ''), ...doneArg], { encoding: 'utf8', maxBuffer: 1 << 24 });
  const lines = String(a.stdout || '').trim().split('\n');
  const clean = lines[1] === 'no issues found';
  console.log(`audit ${id.slice(0, 70)}: ${lines[0]}, ${clean ? 'no issues' : (lines.length - 1) + ' issue(s)'}`);
  if (!clean) { bad++; for (const l of lines.slice(1, 8)) console.log('   ' + l); }
}
// the chain-loss summary (tools/chain-report.js) for the first path: not a gate, a number to compare before and after
// a planner change - one that starts cutting chains shows here before a tester finds it. (From the plan file, which
// keeps no pick-up it never hands in: those count under the other classes.) With the save's quests done, its log and
// the quests you said no to: else a character at 30 shows every chain it finished at 10-20 as lost
if (ids.length) {
  try {
    const CR = require('./chain-report');
    console.log(CR.summaryLine(CR.reportFor(file, { pathId: ids[0], race: base.race, cls: base.class, completed: [...(base.completed || []), ...((st && st.completed) || [])], active: (st && st.log) || base.active, nope: (st && st.nope) || [] })) + ` (full: node tools/chain-report.js ${file})`);
  } catch (e) { console.log('(no chain report: ' + e.message + ')'); }
}
// the live check: the repo's addon on this plan at the spot you saved
if (base.charDir && ids.length) {
  // (wrapped as the companion installs it: your character's block in the plan file - tools/autoplan.js wrapAll)
  const ME = path.basename(path.dirname(base.charDir)).replace(/\s/g, '');
  const wrapped = path.join(work, 'Route.wrapped.lua');
  fs.writeFileSync(wrapped, `-- ForeverRoute plan for ${ME} begin\nForeverRouteByChar = ForeverRouteByChar or {}\nForeverRouteByChar[${JSON.stringify(ME)}] = function()\n${text}\nend\n-- ForeverRoute plan for ${ME} end\n`);
  const lc = spawnSync(process.execPath, [path.join(__dirname, 'live-check.js'), base.charDir, wrapped], { cwd: ROOT, encoding: 'utf8', maxBuffer: 1 << 24 });
  const lo = String(lc.stdout || '') + String(lc.stderr || '');
  console.log(lo.trim().split('\n').slice(-4).join('\n'));
  if (lc.status !== 0) bad++;
}
console.log(bad ? `NOT safe to commit: ${bad} gate(s) failed` : 'all gates passed');
process.exitCode = bad ? 1 : 0;
