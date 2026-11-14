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
  execFileSync(process.execPath, ['--max-old-space-size=8000', path.join(__dirname, 'route2.js'), extra.dbFile || rel(camp.db), cfgFile, out], { cwd: ROOT, stdio: ['ignore', 'ignore', 'ignore'] });
  return { steps: JSON.parse(fs.readFileSync(out, 'utf8')), state: JSON.parse(fs.readFileSync(state, 'utf8')) };
}
let fails = 0;
const check = (name, ok, info) => { console.log((ok ? 'ok   ' : 'FAIL ') + name + (ok ? '' : '  ' + JSON.stringify(info))); if (!ok) fails++; };
const doneFor = (steps, q) => steps.filter((s) => s.type === 'do' && s.items.some((i) => i.q === q));

// Bellygrub (one level-24 boar) next to 46 Great Goretusks: farming Goretusks for Redridge Goulash at 20 does not
// bring his tusk along, and nothing counts his tusk before you can fight him (the level gate, world.minLevelFor:
// 21 with mobs up to 3 above you from 20)
{
  const { steps } = sim({ zones: [44, 1519], level: 20, active: { 34: { complete: false, objectives: [{ done: false, text: "Bellygrub's Tusk: 0/1" }] } } });
  const tusk = doneFor(steps, 34);
  check('An Unwelcome Guest is not done by farming boars before Bellygrub is in reach', tusk.every((s) => s.lvl >= require('./world').minLevelFor(24)), tusk.map((s) => ({ lvl: s.lvl, items: s.items.filter((i) => i.q === 34) })));
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
// same-name alternatives the data leaves unmarked (tools/exclusive-alternatives.js, run when the data is built - and
// here on a copy, with the overrides, so the case holds before qdb/ is rebuilt): Remote Contact from Jes'rimon in
// Orgrimmar, Magatha Grimtotem in Thunder Bluff or Andron Gant in Undercity, all to Jediga in Azshara. Taken from
// Magatha, Orgrimmar does not plan Jes'rimon's
{
  const db = JSON.parse(fs.readFileSync(rel(camp.db), 'utf8'));
  require('./apply-overrides').apply(db);
  require('./exclusive-alternatives').mark(db);
  const dbFile = path.join(dir, 'db-alternatives.json'); fs.writeFileSync(dbFile, JSON.stringify(db));
  const horde = { zones: [1637, 16], level: 50, race: 'orc', class: 'warrior', faction: 'horde', trainer: undefined, trainLevels: [], dbFile };
  const remote = (steps) => steps.filter((s) => s.type === 'accept' && [91734, 91735, 91737].includes(s.q)).map((s) => s.q);
  const a = sim(horde).steps, b = sim({ ...horde, completed: [91737] }).steps;
  check('Remote Contact: Orgrimmar and Azshara plan Jes\'rimon\'s', remote(a).includes(91735), remote(a));
  check('...but not once Magatha Grimtotem\'s is done', !remote(b).length, remote(b));
}
// a hand-in and pick-up spot inside a town that is not one of its NPCs: the Waterlogged Chest off Menethil's shore
// (within the hub's reach, so no field loop went there, and the hub visit only walked its NPCs). Lightforge Iron was
// picked up and never handed in, and The Lost Ingots, which starts from the chest, was in no path
{
  const { steps } = sim({ zones: [11, 1519], level: 32, completed: [270] });
  const at = (k, q) => steps.findIndex((s) => s.type === k && s.q === q);
  check('Lightforge Iron is handed in at the Waterlogged Chest', at('accept', 321) >= 0 && at('turnin', 321) > at('accept', 321), [at('accept', 321), at('turnin', 321)]);
  check('...and The Lost Ingots starts there and is handed in to Glorin Steelbrow', at('accept', 324) > at('turnin', 321) && at('turnin', 324) > at('accept', 324), [at('accept', 324), at('turnin', 324)]);
}
// work the quest data lists none of (Brewer's Trade: Brewmeister Bilger in Southshore gives it and takes it back,
// "Deliver the bottles ... to Dun Garok"): alone it is left out (the addon offers it at the giver); as the first quest
// of a chain (a follow-up added here) it stays - pick-up, one "do the work" step with no known place, hand-in
{
  const plain = sim({ zones: [267, 1519], level: 27 });
  check('Brewer\'s Trade, in no chain, is not planned', !plain.steps.some((s) => s.q === 98071), plain.steps.filter((s) => s.q === 98071).map((s) => s.type));
  const db = JSON.parse(fs.readFileSync(rel(camp.db), 'utf8'));
  db.quests[99990] = { ...JSON.parse(JSON.stringify(db.quests[98071])), id: 99990, name: 'Brewer\'s Trade, part two', text: ['Speak with Brewmeister Bilger again.'], preSingle: [98071], preGroup: [], xp: 1000 };
  const dbFile = path.join(dir, 'db-chain.json'); fs.writeFileSync(dbFile, JSON.stringify(db));
  const legOut = path.join(dir, 'leg-brew.json');
  const { steps } = sim({ zones: [267, 1519], level: 27, dbFile, optimize: true, optimizeEffort: 0.25, optimizeRuns: 2, workers: 2, legOut, routeOut: path.join(dir, 'leg-brew.lua') });
  const its = steps.filter((s) => s.q === 98071 || (s.items || []).some((i) => i.q === 98071)).map((s) => s.type);
  check('...as the first of a chain it is planned: accept, its work, hand-in', JSON.stringify(its) === '["accept","do","turnin"]', its);
  const leg = JSON.parse(fs.readFileSync(legOut, 'utf8')).steps.filter((s) => s.q === 98071);
  const work = leg.find((s) => s.k === 'obj');
  check('...in the step file: accept, one unknown step, hand-in', JSON.stringify(leg.map((s) => s.k)) === '["accept","obj","turnin"]' && work && work.unknown === true, leg);
  check('...the step: the quest\'s first sentence, the note, no walking path', work && /^Deliver the bottles of Fallrook Varietal/.test(work.text) && work.text.length <= 71 && /isn't in the quest data/.test(work.note || '') && !work.wp && !work.walk && !work.target && !work.match, work);
  check('...and the follow-up comes after its hand-in', steps.findIndex((s) => s.type === 'accept' && s.q === 99990) > steps.findIndex((s) => s.type === 'turnin' && s.q === 98071), steps.filter((s) => s.q === 99990).map((s) => s.type));
}
// The Stockade, on two real legs of Testchar's path (Redridge at 24, then Duskwood at 25 - Stormwind rides along with both)
const fixture = (f) => JSON.parse(fs.readFileSync(path.join(__dirname, 'test-fixtures', f), 'utf8'));
{
  // the run step comes after every pick-up of a quest done in it, and the quests' objectives after the run
  const legOut = path.join(dir, 'leg.json');
  const { steps, state } = sim({ ...fixture('leg-redridge-stockade.json'), optimize: true, optimizeEffort: 0.25, optimizeRuns: 2, workers: 2, legOut, routeOut: path.join(dir, 'leg.lua'), addonsDir: camp.addonsDir });
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
// Riverglades' chains: Apple of My Eye, Foal Play and Rog'mar Supplies want items from objects QuestieDB has no record
// of (Fresh Apple, Pawprint Tracing, Rog'mar Supply Crate) - read as "objectives outside the planned zones", they and
// the chains behind them were lost. They lead on, so they stay, their item an unknown step; the leg says what of its
// value carries on chains begun earlier (carryValue: none here, the chains begin and go on in Riverglades - stragglers
// the revisit penalty is for), and why a chain's next part is not on it (chainSkip)
{
  const { steps, state } = sim({ zones: [16591], level: 39, completed: [94877, 94924, 94613] });
  const handed = new Set(steps.filter((s) => s.type === 'turnin').map((s) => s.q));
  check('Apple of My Eye, Foal Play and Rog\'mar Supplies are handed in', [95561, 94615, 95426].every((q) => handed.has(q)), [95561, 94615, 95426].filter((q) => !handed.has(q)));
  check('...and the next parts they open (Fit for a Princess, The Rog\'mar Situation)', handed.has(95913) && handed.has(95066), { 95913: handed.has(95913), 95066: handed.has(95066) });
  check('chains begun and going on in the same zone are not carried on (carryValue 0)', state.carryValue === 0, state.carryValue);
  // (its work is in other zones: carried for a leg there - an away objective - or, when not picked up here, said so)
  check('a next part left out says why (Wound Dressings: its cloth comes from other zones)', (state.active || {})[96081] || /outside|another zone/.test((state.chainSkip || {})[96081] || ''), state.chainSkip);
  // unknown steps have no mob level: their kill XP was NaN, and with it the leg's XP (the campaign then ground a level)
  check('the leg ends with a real XP figure (unknown steps pay no kill XP, not NaN)', Number.isFinite(state.xp), state.xp);
}
// a quest finished in your log is carried on wherever it is handed in (A Scroll from Mauren, from Stonetalon)
{
  const { state } = sim({ zones: [44, 1519], level: 21, completed: [1071], active: { 1075: { complete: true, objectives: [] } } });
  check('a hand-in of a quest you came in with counts as carried on', state.carryValue > 0, state.carryValue);
}
// a chain begun in another zone is: Return to Verner (Elwynn) opens Underbelly Scales and A Baying of Gnolls in Redridge
{
  const { steps, state } = sim({ zones: [44, 1519], level: 20, completed: [119] });
  const handed = new Set(steps.filter((s) => s.type === 'turnin').map((s) => s.q));
  check('next parts of a chain begun in Elwynn are handed in in Redridge', handed.has(122) && handed.has(124), [...handed]);
  check('...and count as carried on (carryValue)', state.carryValue > 0, state.carryValue);
}
// a gray quest finished in your log whose hand-in is in the leg's zones is handed in (its work is done; the campaign
// keeps it in the log for such a leg) - Underbelly Scales at 26, handed in in Redridge, opens nothing
{
  const { steps } = sim({ zones: [44, 1519], level: 26, completed: [119], active: { 122: { complete: true, objectives: [] } } });
  check('a finished gray quest is handed in where the leg passes its hand-in', steps.some((s) => s.type === 'turnin' && s.q === 122), steps.filter((s) => s.type === 'turnin').map((s) => s.q));
}
// an item with no source in the data at all (Something's in the Water's Filled Freshwater Phial, filled from another
// item) is planned like work the data lists none of when its quest leads on: an unknown step with the quest's other
// work (else at its giver), so the chain goes on (96085) instead of being lost - as Linken's container items now are
{
  const { steps } = sim({ zones: [16591], level: 40, completed: [96083] });
  check('a chain part whose item has no source is planned (an unknown step), not dropped', steps.some((s) => s.type === 'turnin' && s.q === 96084), steps.filter((s) => s.q === 96084).map((s) => s.type));
}
// a chain's next part handed to you in a side zone where the leg hands in its last part stays on the leg, to carry to
// another zone: Highway Robbery (Desolace) gives On the Lam, for Tokal in Stranglethorn (a leg planned with the
// optimizer: the side-zone pick-ups it would make for nothing are dropped there)
{
  const legOut = path.join(dir, 'leg.json');
  sim({ zones: [406, 405], level: 38, optimize: true, optimizeEffort: 0.1, workers: 1, legOut, routeOut: path.join(dir, 'route.lua') });
  const leg = JSON.parse(fs.readFileSync(legOut, 'utf8'));
  const at = (k, q) => leg.steps.findIndex((s) => s.k === k && s.q === q);
  check('On the Lam is picked up in Desolace after the hand-in of Highway Robbery, to carry on', at('turnin', 79229) >= 0 && at('accept', 79235) > at('turnin', 79229), [at('turnin', 79229), at('accept', 79235)]);
}
fs.rmSync(dir, { recursive: true, force: true });
console.log(fails ? fails + ' failed' : 'all passed');
process.exit(fails ? 1 : 0);
