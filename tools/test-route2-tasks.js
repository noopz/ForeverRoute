// Checks how route2.js reads quest objectives (counts, kills, mob levels), on the real quest data, without planning a
// route (route2 with tasksOnly stops after building its task list).
// usage: node tools/test-route2-tasks.js   (from the repo, needs qdb/ and terrain/)
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fr-tasks-'));
function tasksFor(zones, level) {
  const cfgFile = path.join(dir, 'cfg.json'), out = path.join(dir, 'tasks.json');
  fs.writeFileSync(cfgFile, JSON.stringify({ zones, level, race: 'gnome', class: 'warlock', faction: 'alliance', minQuestLevel: 1, maxQuestLevel: 60, maxKills: 1e9,
    conversion: path.join(ROOT, 'qdb', 'conversion.json'), terrainDir: path.join(ROOT, 'terrain'), tasksOut: out, tasksOnly: true }));
  execFileSync(process.execPath, ['--max-old-space-size=8000', path.join(__dirname, 'route2.js'), path.join(ROOT, 'qdb', 'db.json'), cfgFile], { cwd: ROOT, stdio: ['ignore', 'ignore', 'inherit'] });
  return JSON.parse(fs.readFileSync(out, 'utf8'));
}
let fails = 0;
const check = (name, ok, info) => { console.log((ok ? 'ok   ' : 'FAIL ') + name + (ok ? '' : '  ' + JSON.stringify(info))); if (!ok) fails++; };
const obj = (T, id, re) => T[id] && T[id].objs.find((o) => re.test(o.label));

// Redridge at 21: the mobs where the plan sends you, not the hardest dropper anywhere
const R = tasksFor([44, 1519], 21);
check('Redridge Goulash: all three collects at mobs of level 23 or less', R[92] && R[92].objs.length === 3 && R[92].objs.every((o) => o.mobLevel <= 23), R[92]);
check('Murloc Poachers: Redridge murlocs (22), not level-29 ones elsewhere', R[150] && R[150].objs.every((o) => o.mobLevel <= 23), R[150]);
check('Blackrock Menace: Redridge orcs', R[20] && R[20].objs.every((o) => o.mobLevel <= 24), R[20]);
check('Redridge Goulash wants five of each ("five pieces of", not a digit)', R[92] && R[92].objs.every((o) => /^Collect 5 /.test(o.label)), R[92]);

// counts read from the quest text (they are shown to you on the step card)
const W = tasksFor([11, 10, 33, 406, 1519], 30);
const count = (T, id, re) => { const o = obj(T, id, re); return o && +/^\w+ (\d+) /.exec(o.label)[1]; };
check('The Cursed Crew: 13 sailors, 5 marines, one Snuffbox', count(W, 289, /Sailor/) === 13 && count(W, 289, /Marine/) === 5 && count(W, 289, /Snuffbox/) === 1, W[289]);
check('Snellig\'s Snuffbox is a sure drop from one mob: about one kill, not 26', obj(W, 289, /Snuffbox/) && obj(W, 289, /Snuffbox/).kills <= 2, W[289]);
check('Wolves at Our Heels: 12 Starving and 8 Rabid Dire Wolves (Wolves = Wolf)', count(W, 226, /Starving/) === 12 && count(W, 226, /Rabid/) === 8, W[226]);
check('Uncovering the Past: one of each fragment', W[299] && W[299].objs.length === 4 && W[299].objs.every((o) => / 1 /.test(o.label)), W[299]);
check('Colonel Kurzen: 6 Elite, 4 Subchiefs, one head', count(W, 202, /Elite/) === 6 && count(W, 202, /Subchief/) === 4 && count(W, 202, /Head/) === 1, W[202]);
check('Kurzen\'s Mystery: one of each legend', W[207] && W[207].objs.length && W[207].objs.every((o) => / 1 /.test(o.label)), W[207]);
check('A Gnome\'s Respite: 10 Venture Co. Loggers (an abbreviation does not end the clause)', count(W, 1071, /Logger/) === 10 && count(W, 1071, /Deforester/) === 10, W[1071]);
const H = tasksFor([47, 15, 1519], 40);
check('Skulk Rock Clean-up: 10 Jade Oozes ("Oozes" is Ooze)', count(H, 2877, /Jade Ooze/) === 10 && count(H, 2877, /Green Sludge/) === 10, H[2877]);
check('Jarl Needs Eyes: 40 eyes, as the text says', count(H, 1206, /Darkmist Eye/) === 40, H[1206]);
check('Super Reaper 6000: one set of blueprints (the 6000 is part of the name)', count(W, 1093, /Blueprints/) === 1, W[1093]);
check('Chapter I: one of each page', W[339] && W[339].objs.length && W[339].objs.every((o) => / 1 /.test(o.label)), W[339]);

// Wetlands at 27: War Banners from the classic Dragonmaw camp (normal, 26-29), not the 300 elite Dragonmaw Forever added
// further east (29-30), which drop them too: the player was sent among the elites
const WB = tasksFor([11], 27);
check('War Banners: the normal Dragonmaw camp, not the elites', obj(WB, 464, /War Banner/) && obj(WB, 464, /War Banner/).mobLevel <= 28, WB[464]);
fs.rmSync(dir, { recursive: true, force: true });
console.log(fails ? fails + ' failed' : 'all passed');
process.exit(fails ? 1 : 0);
