// Checks the quest simulation in route2.js (one zone leg, no optimizing) on the real quest data: what it hands in,
// what it counts as done along the way, and how it plans dungeon runs.
// usage: node tools/test-route2-sim.js   (from the repo, needs qdb/ and terrain/)
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const camp = (() => { const d = path.join(ROOT, 'routes'); const f = fs.existsSync(d) && fs.readdirSync(d).find((x) => /^campaign-.*\.json$/.test(x)); if (!f) { console.log('skipped: needs your settings in routes/campaign-<name>.json (tools/make-character.js)'); process.exit(0); } return JSON.parse(fs.readFileSync(path.join(d, f), 'utf8')); })();
const rel = (f) => (f && !path.isAbsolute(f) ? path.join(ROOT, f) : f);
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fr-sim-'));
function sim(extra) {
  const cfgFile = path.join(dir, 'cfg.json'), out = path.join(dir, 'out.json'), state = path.join(dir, 'state.json');
  const level = extra.level;
  fs.writeFileSync(cfgFile, JSON.stringify({ race: 'gnome', class: 'warlock', faction: 'alliance', xp: 0, minQuestLevel: level - 6, maxQuestLevel: level + 5, targetLevel: 30, finishOpen: true, arrivalTour: true,
    flightSec: 120, completed: [], active: {}, terrainDir: rel(camp.terrainDir), conversion: rel(camp.conversion), trainLevels: camp.trainLevels, trainer: camp.trainer, itemsJson: rel(camp.itemsJson),
    dungeonFile: fs.existsSync(camp.dungeonFile || '') ? camp.dungeonFile : undefined, dungeons: camp.dungeons, dungeonRunMin: camp.dungeonRunMin, groupWaitMin: camp.groupWaitMin, title: 'test', stateOut: state, ...extra }));
  execFileSync(process.execPath, ['--max-old-space-size=8000', path.join(__dirname, 'route2.js'), rel(camp.db), cfgFile, out], { cwd: ROOT, stdio: ['ignore', 'ignore', 'ignore'] });
  return { steps: JSON.parse(fs.readFileSync(out, 'utf8')), state: JSON.parse(fs.readFileSync(state, 'utf8')) };
}
let fails = 0;
const check = (name, ok, info) => { console.log((ok ? 'ok   ' : 'FAIL ') + name + (ok ? '' : '  ' + JSON.stringify(info))); if (!ok) fails++; };
const doneFor = (steps, q) => steps.filter((s) => s.type === 'do' && s.items.some((i) => i.q === q));

// Bellygrub (one level-24 boar) next to 46 Great Goretusks: farming Goretusks for Redridge Goulash at 20 does not
// bring his tusk along, and nothing counts his tusk before you can fight him (22 with mobs up to 3 above you)
{
  const { steps } = sim({ zones: [44, 1519], level: 20, active: { 34: { complete: false, objectives: [{ done: false, text: "Bellygrub's Tusk: 0/1" }] } } });
  const tusk = doneFor(steps, 34);
  check('An Unwelcome Guest is not done by farming boars at level 20-21', tusk.every((s) => s.lvl >= 22), tusk.map((s) => ({ lvl: s.lvl, items: s.items.filter((i) => i.q === 34) })));
  check('no shared drop credit for Bellygrub\'s Tusk', !tusk.some((s) => s.items.some((i) => i.q === 34 && i.shared)), tusk);
}
// a finished quest from another zone (A Scroll from Mauren, picked up in Stonetalon) is handed in when the leg passes
// its turn-in NPC (Collin Mauren in Stormwind rides along with every Eastern Kingdoms leg)
{
  const { steps, state } = sim({ zones: [44, 1519], level: 21, completed: [1071], active: { 1075: { complete: true, objectives: [] } } });
  check('A Scroll from Mauren (in the log, done) is handed in in Stormwind', steps.some((s) => s.type === 'turnin' && s.q === 1075), steps.filter((s) => s.type === 'turnin').map((s) => s.q));
  check('...and is no longer in the log at the end of the leg', !(state.active || {})[1075], Object.keys(state.active || {}));
}
// The Great Outdoors is offered in every start zone but one character does only one (the data marks them exclusive):
// done in Dun Morogh, the Elwynn one is not planned; planned, its doubled campfire objective is one step
{
  const s1 = sim({ zones: [12], level: 6, completed: [96608] });
  check('The Great Outdoors done in Dun Morogh: not planned again in Elwynn', !s1.steps.some((x) => x.type === 'accept' && x.q === 95998), s1.steps.filter((x) => x.q === 95998));
  const s2 = sim({ zones: [12], level: 6 });
  const fire = s2.steps.filter((x) => x.type === 'do').flatMap((x) => x.items).filter((i) => i.q === 95998);
  check('...without it, Elwynn plans it, with its campfire once', s2.steps.some((x) => x.type === 'accept' && x.q === 95998) && fire.length === 1, fire);
}
// The Stockade, on two real legs of Testchar's path (Redridge at 24, then Duskwood at 25 - Stormwind rides along with both)
const fixture = (f) => JSON.parse(fs.readFileSync(path.join(__dirname, 'test-fixtures', f), 'utf8'));
{
  // the run step comes after every pick-up of a quest done in it, and the quests' objectives after the run
  const legOut = path.join(dir, 'leg.json');
  const { steps, state } = sim({ ...fixture('leg-redridge-stockade.json'), optimize: true, optimizeSeconds: 2, workers: 2, legOut, routeOut: path.join(dir, 'leg.lua'), addonsDir: camp.addonsDir });
  const leg = JSON.parse(fs.readFileSync(legOut, 'utf8')).steps;
  const run = leg.findIndex((s) => s.k === 'goto' && /^Run The Stockade/.test(s.text || ''));
  const inside = leg.map((s, i) => [s, i]).filter(([s]) => s.k === 'obj' && /\(in The Stockade\)/.test(s.text || ''));
  const qs = new Set(inside.map(([s]) => s.q));
  const accepts = leg.map((s, i) => [s, i]).filter(([s]) => s.k === 'accept' && qs.has(s.q));
  check('Redridge leg runs The Stockade once', leg.filter((s) => s.k === 'goto' && /^Run The Stockade/.test(s.text || '')).length === 1, run);
  check('...after picking up every quest done in it', run >= 0 && accepts.every(([, i]) => i < run), { run: run + 1, accepts: accepts.map(([s, i]) => [i + 1, s.name]) });
  check('...and before the steps for what you do inside', run >= 0 && inside.every(([, i]) => i > run), { run: run + 1, inside: inside.map(([s, i]) => [i + 1, s.text]) });
  check('the leg says The Stockade has been run on this path', (state.dungeonsRun || []).includes(717), state.dungeonsRun);
  // the next leg holds one new Stockade quest (Crime and Punishment): not worth a second 55-minute run
  const next = sim({ ...fixture('leg-duskwood-after-stockade.json'), dungeonsRun: state.dungeonsRun, addonsDir: camp.addonsDir });
  const runs2 = next.steps.filter((s) => s.type === 'dungeon' && s.dungeon === 717);
  const quests2 = new Set(next.steps.filter((s) => s.type === 'do').flatMap((s) => s.items).filter((i) => /\(in The Stockade\)/.test(i.label)).map((i) => i.q));
  check('a dungeon already run on this path is run again only with 3 or more of its quests waiting', runs2.length === 0 || quests2.size >= 3, { runs: runs2.length, quests: [...quests2] });
}
fs.rmSync(dir, { recursive: true, force: true });
console.log(fails ? fails + ' failed' : 'all passed');
process.exit(fails ? 1 : 0);
