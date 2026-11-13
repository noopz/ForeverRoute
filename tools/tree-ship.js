// The tree's plans as the built-in plans (docs/research/shared-trunk.md): every race x class the tree assembled
// (tools/tree-assemble.js, <tree dir>/assembled/<race>_<class>/Route.lua) written into its load-on-demand addon,
// addon/ForeverRoute_Starter_<race>_<class>/Plan.lua, in the shape tools/starter.js writes (the .toc stays as it is),
// with the plans stamp (CLAUDE.md, Versioning) naming the tree. Only a race x class that already has a built-in plan
// folder is written: the addon's list of plans doesn't change. Run tools/tree-gate.js --sim first - ship only a tree
// whose plans all played 1-60 with no broken check.
// usage: node tools/tree-ship.js <tree dir> [<tree dir> ...] [--addon <addon dir>] [--dry]
const fs = require('fs'), path = require('path');
const { execFileSync } = require('child_process');
const ROOT = path.join(__dirname, '..');
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf('--' + k); return i >= 0 ? args[i + 1] : d; };
const trees = args.filter((a, i) => !a.startsWith('--') && !(i > 0 && args[i - 1] === '--addon'));
const ADDON = path.resolve(opt('addon', path.join(ROOT, 'addon')));
const DRY = args.includes('--dry');
if (!trees.length) { console.log('usage: node tools/tree-ship.js <tree dir> [...] [--addon dir] [--dry]'); process.exit(2); }
const qdbVer = (() => { try { return JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'questiedb-version.json'), 'utf8')).version; } catch (e) { return '?'; } })();
const commit = (() => { try { return execFileSync('git', ['rev-parse', '--short', 'HEAD'], { cwd: ROOT, encoding: 'utf8' }).trim(); } catch (e) { return '?'; } })();
const built = new Date().toISOString().slice(0, 10);
let n = 0, skipped = [];
for (const t of trees) {
  const dir = path.resolve(t), tree = path.basename(dir);
  const gate = (() => { try { return JSON.parse(fs.readFileSync(path.join(dir, 'gate.json'), 'utf8')); } catch (e) { return null; } })();
  for (const rc of fs.readdirSync(path.join(dir, 'assembled'))) {
    const [race, cls] = rc.split('_');
    const folder = path.join(ADDON, `ForeverRoute_Starter_${race}_${cls}`);
    const route = path.join(dir, 'assembled', rc, 'Route.lua');
    if (!fs.existsSync(folder) || !fs.existsSync(route)) { skipped.push(rc + ' (no built-in plan folder)'); continue; }
    // the simulated player's verdict for this plan, when the gate ran with --sim: a broken check stops it shipping
    const g = gate && gate.find((r) => r.race === race && r.cls === cls);
    if (g && g.sim && !(g.sim.exit === 0 && g.sim.broke === 0)) { skipped.push(`${rc} (simulated player: exit ${g.sim.exit}, broke ${g.sim.broke})`); continue; }
    const key = `${race}-${cls}`;
    const stamp = `plans ${built} · QuestieDB ${qdbVer} · planner ${commit} · tree ${tree}`;
    const block = `-- Built-in plan for a ${race} ${cls}, from the ${tree} tree (tools/tree-ship.js): the ${race} start, the faction trunk, ${cls} side trips.\n-- ${stamp}\nForeverRouteStarter = ForeverRouteStarter or {}\nForeverRouteStarterStamp = ForeverRouteStarterStamp or {}\nForeverRouteStarterStamp[${JSON.stringify(key)}] = ${JSON.stringify(stamp)}\nForeverRouteStarter[${JSON.stringify(key)}] = function()\n${fs.readFileSync(route, 'utf8')}\nend\n`;
    if (!DRY) fs.writeFileSync(path.join(folder, 'Plan.lua'), block);
    n++;
  }
}
console.log(`${DRY ? 'would write' : 'wrote'} ${n} built-in plan(s)` + (skipped.length ? `; skipped: ${skipped.join(', ')}` : ''));
