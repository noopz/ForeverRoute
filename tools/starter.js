// The built-in plan: what the addon follows when no planner runs on the player's PC (an addon-only install, e.g. from
// an addon site). A brand-new character of one race and class is planned from level 1 in its start zone, with no save
// and none of your own learned rates (yours come from grouped play; a starter is for anyone), and written into the addon
// as Starter.lua: ForeverRouteStarter["<race>-<class>"] = function() ... end, the same plan shape the companion writes
// per character. The addon uses it only when there is no plan of your own (Core.lua LoadMyPlan).
// usage: node tools/starter.js [race=gnome] [class=warlock] [targetLevel=30] [paths=2]
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const ROOT = path.join(__dirname, '..');
const [race = 'gnome', cls = 'warlock', target = '30', N = '1'] = process.argv.slice(2);
// start zones (QuestieDB area ids): where a new character of the race appears
const START = { gnome: 1, dwarf: 1, human: 12, nightelf: 141, skyborne: 16593, // skyborne: Zephras Isle (Forever)
  orc: 14, troll: 14, tauren: 215, undead: 85, skybornehorde: 16593 }; // Windshaper Skyborne: Zephras Isle too // Durotar (Valley of Trials), Mulgore (Camp Narache), Tirisfal (Deathknell)
const zone = START[race];
if (!zone) { console.log('no start zone known for ' + race + ' (add it to START)'); process.exit(2); }
const key = `${race}-${cls}`;
// FR_EXPERIMENT=<name> FR_EXTRA='{"lonelyYards":400}': a trial plan with extra planner settings, in
// paths-starter/<key>-<name>, and no addon written (the built-in plans stay as they are)
const EXP = process.env.FR_EXPERIMENT || '';
const work = path.join(ROOT, 'paths-starter', key + (EXP ? '-' + EXP : ''));
fs.mkdirSync(work, { recursive: true });
const cfgFile = path.join(work, 'campaign.json');
execFileSync(process.execPath, [path.join(__dirname, 'make-character.js'), '--name', 'Starter', '--race', race, '--class', cls, '--level', '1', '--zone', String(zone), '--target', String(target), '--out', cfgFile], { cwd: ROOT, stdio: 'inherit' });
const cfg = JSON.parse(fs.readFileSync(cfgFile, 'utf8'));
Object.assign(cfg, { homeZone: zone, targetLevel: +target, maxLegs: 200, routesOut: path.join(work, 'Route.lua'), learnedFile: false,
  // a built-in plan is made with nothing else running (no game to keep smooth): every core but one
  parallel: Math.max(1, require('os').cpus().length - 1),
  // walking paths depend only on the terrain: one cache for every built-in plan (the work folder is new each time)
  waypointsCache: 'leg-cache-waypoints/waypoints-cache.json' }, JSON.parse(process.env.FR_EXTRA || '{}'));
fs.writeFileSync(cfgFile, JSON.stringify(cfg, null, 2));
const t0 = Date.now();
// the planner, watched: once it says it wrote the plan it gets 15 s to exit, then it's stopped (a worker thread once kept
// a finished planner alive for good, after process.exit, and the batch of built-in plans waited on it)
const planner = require('child_process').spawn(process.execPath, ['--max-old-space-size=8000', path.join(__dirname, 'paths.js'), cfgFile, N, '0', '--work', work], { cwd: ROOT, stdio: ['ignore', 'pipe', 'inherit'] });
let wrote = false;
planner.stdout.on('data', (d) => { process.stdout.write(d); if (/wrote \d+ paths/.test(String(d)) && !wrote) { wrote = true; setTimeout(() => { try { planner.kill(); } catch (e) {} }, 15000).unref(); } });
planner.on('close', (code) => { if (!wrote) { console.log('the planner stopped without a plan (exit ' + code + ')'); process.exit(1); } finish(); });
function finish() {
const inner = fs.readFileSync(path.join(work, 'Route.lua'), 'utf8');
if (!/id = "path:/.test(inner)) { console.log('the planner made no path: Starter.lua not written'); process.exit(1); }
// the chain-loss report beside the plan (tools/chain-report.js: the chain parts it reaches and leaves out, and why),
// and its one line in the output for reports/starters.md. Read from the planner's own path-0.json: the plan file
// leaves out a pick-up that is never handed in, and with it the "picked up, never handed in" class
try {
  const CR = require('./chain-report');
  const rep = CR.reportFor(path.join(work, 'path-0.json'), { race, cls });
  fs.writeFileSync(path.join(work, 'chain-report.txt'), CR.formatReport(rep, key + (EXP ? '-' + EXP : '')));
  fs.writeFileSync(path.join(work, 'chain-report.json'), JSON.stringify(rep, null, 1));
  console.log(CR.summaryLine(rep));
} catch (e) { console.log('chain report not written: ' + e.message); }
if (EXP) { console.log(`wrote ${path.relative(ROOT, path.join(work, 'Route.lua'))} (experiment ${EXP}: no addon written)`); return; }
// one load-on-demand addon per race-class (addon/ForeverRoute_Starter_<race>_<class>): 20 built-in plans are ~30 MB of
// Lua, so each loads only for a character of its race and class with no plan of its own (Core.lua LoadMyPlan)
const folder = 'ForeverRoute_Starter_' + key.replace(/-/g, '_');
const dir = path.join(ROOT, 'addon', folder);
fs.mkdirSync(dir, { recursive: true });
const mainToc = fs.readFileSync(path.join(ROOT, 'addon', 'ForeverRoute', 'ForeverRoute.toc'), 'utf8');
// the plans stamp (CLAUDE.md, Versioning): when it was built, from which quest data and planner - shown in the addon, so
// a report says which plan someone had, apart from the addon's version
const qdbVer = (() => { try { return JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'questiedb-version.json'), 'utf8')).version; } catch (e) { return '?'; } })();
const commit = (() => { try { return execFileSync('git', ['rev-parse', '--short', 'HEAD'], { cwd: ROOT, encoding: 'utf8' }).trim(); } catch (e) { return '?'; } })();
const built = new Date().toISOString().slice(0, 10);
const stamp = `plans ${built} · QuestieDB ${qdbVer} · planner ${commit}`;
const iface = (/## Interface: (\S+)/.exec(mainToc) || [, '16001'])[1];
fs.writeFileSync(path.join(dir, folder + '.toc'), [
  '## Interface: ' + iface,
  '## Title: Forever Route - built-in plan: ' + race + ' ' + cls,
  '## Notes: Loaded by Forever Route only for a ' + race + ' ' + cls + ' with no plan of its own.',
  '## Dependencies: ForeverRoute',
  // nested under Forever Route in the game's addon list (51 plans listed one by one filled it)
  '## Group: ForeverRoute',
  '## LoadOnDemand: 1',
  '## Version: plans ' + built,
  '## X-Plans: ' + stamp,
  '', 'Plan.lua', ''].join('\n'));
const block = `-- Built-in plan for a ${race} ${cls} (tools/starter.js): followed when there is no plan of your own for this character.
-- ${stamp}
ForeverRouteStarter = ForeverRouteStarter or {}
ForeverRouteStarterStamp = ForeverRouteStarterStamp or {}
ForeverRouteStarterStamp[${JSON.stringify(key)}] = ${JSON.stringify(stamp)}
ForeverRouteStarter[${JSON.stringify(key)}] = function()
${inner}
end
`;
fs.writeFileSync(path.join(dir, 'Plan.lua'), block);
console.log(`wrote addon/${folder}: ${key}, 1 -> ${target}, ${(block.length / 1e6).toFixed(1)} MB, planned in ${Math.round((Date.now() - t0) / 60000)} min`);
}
