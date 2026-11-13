// Checks for alternatives (a quest's exclusive list: one quest from givers in several towns, doing one closes the
// others): the rule that marks same-name alternatives when the data is built (exclusive-alternatives.js), on the real
// quest data, and that the safety net (ensure-steps.js) and the audit (lint-route.js) hold a route to them.
// A warlock who had taken In Search of Menara Voidrender from Demisette Cloyce was sent to Briarthorn for it (tester).
// usage: node tools/test-exclusive.js   (from the repo, needs qdb/; FR_TEST_DB: another db.json)
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const ALT = require('./exclusive-alternatives');

const ROOT = path.resolve(__dirname, '..');
const dbFile = process.env.FR_TEST_DB || path.join(ROOT, 'qdb', 'db.json');
if (!fs.existsSync(dbFile)) { console.log('skipped: needs ' + dbFile); process.exit(0); }
const raw = fs.readFileSync(dbFile, 'utf8');
// (overrides on top, as a build has them: Remote Contact from Andron Gant gets its hand-in there)
const fresh = () => { const db = JSON.parse(raw); require('./apply-overrides').apply(db); return db; };
let fails = 0;
const check = (name, ok, info) => { console.log((ok ? 'ok   ' : 'FAIL ') + name + (ok ? '' : '  ' + JSON.stringify(info))); if (!ok) fails++; };
const byName = (db, name) => Object.values(db.quests).filter((q) => q.name === name).map((q) => q.id);
// the data as if it had none of these links (to test the rule, not QuestieDB's own marks)
const unmark = (db, ids) => { const s = new Set(ids); for (const id of ids) if (db.quests[id]) db.quests[id].exclusive = (db.quests[id].exclusive || []).filter((e) => !s.has(e)); };
const groupOf = (groups, id) => groups.find((g) => g.ids.includes(id));

// alternatives the rule must find, with QuestieDB's marks taken away (Goblin Engineering's are in the data; were they
// not, this is what would mark them)
{
  const db = fresh();
  const cases = [
    ['Goblin Engineering (Alliance: Springspindle Fizzlegear, Lilliam Sparkspindle)', [3629, 4181]],
    ['Remote Contact (Andron Gant, Jes\'rimon, Magatha Grimtotem)', [91734, 91735, 91737]],
  ];
  for (const [, ids] of cases) unmark(db, ids);
  const groups = ALT.find(db);
  for (const [name, ids] of cases) {
    const g = groupOf(groups, ids[0]);
    check('alternatives: ' + name, g && ids.every((id) => g.ids.includes(id)) && g.ids.length === ids.length, g);
  }
}
// breadcrumbs for one quest are not marked: the breadcrumb rule closes them once that quest is yours (route2.js,
// Engine.Breadcrumbed), and the data says nothing about both before it. QuestieDB's own marks on such a set stay
{
  const db = fresh();
  const cases = [
    ['Seeking Strahad (Gan\'rul Bloodeye, Carendin Halgar: breadcrumbs for Strahad\'s quest)', [2996, 3001]],
    ['Report to Kadrak (Thork, Darn Talongrip: breadcrumbs for The Warsong Reports)', [6541, 6542]],
    ['In Search of Menara Voidrender (Briarthorn, Demisette Cloyce: breadcrumbs, with QuestieDB\'s marks taken away)', [4736, 4738]],
  ];
  for (const [, ids] of cases) unmark(db, ids);
  const groups = ALT.find(db);
  for (const [name, ids] of cases) check('not marked: ' + name, !ids.some((id) => groupOf(groups, id)), groups.filter((g) => ids.some((id) => g.ids.includes(id))));
  const db2 = fresh(); ALT.mark(db2);
  check('...Menara\'s QuestieDB marks stay (Demisette Cloyce\'s closes Briarthorn\'s)', ALT.closers(db2.quests, db2.quests[4736]).includes(4738));
}
// what closes a quest: its exclusive list, less the quests that lead to it
{
  const db = fresh(), Q = db.quests;
  check('closers: Returning Home (a prerequisite of Stars of Elune) does not close it', !ALT.closers(Q, Q[5627]).includes(5629), ALT.closers(Q, Q[5627]));
  check('...Stars of Elune closes Returning Home', ALT.closers(Q, Q[5629]).includes(5627), ALT.closers(Q, Q[5629]));
  check('closers: The Tome of Nobility from Duthorian Rall is not closed by its own breadcrumb (4486), but is by the other giver\'s (4485)', !ALT.closers(Q, Q[1661]).includes(4486) && ALT.closers(Q, Q[1661]).includes(4485), ALT.closers(Q, Q[1661]));
  check('closers: Desperate Prayer from Laurena and from High Priest Rohan close each other', ALT.closers(Q, Q[5639]).includes(5634) && ALT.closers(Q, Q[5634]).includes(5639));
}
// look-alikes the rule must leave alone, also with any marks taken away
{
  const db = fresh();
  const cases = [
    ['Return to Chillwind Camp: two parts of the Scourge Cauldron chain', [5220, 5223]],
    ['Hidden Enemies: Thrall\'s first part and Neeru\'s later part', [5728, 5730]],
    ['Beached Sea Turtle: separate turtles (objects), all doable', [4725, 4727]],
    ['A Donation of Runecloth: each quartermaster\'s own errand', [99194, 99199]],
    ['Call of Earth: the Durotar and Mulgore totem chains', [1517, 1520]],
    ['Khan Hratha: the Magram and Gelkis sides, each to its own', [1380, 1381]],
    ['Corrupted Windblossom: repeatable', byName(db, 'Corrupted Windblossom')],
    ['Minion\'s Scourgestones: repeatable', byName(db, "Minion's Scourgestones")],
    ['Stolen Winter Veil Treats: the same giver twice', byName(db, 'Stolen Winter Veil Treats')],
    ['The Legend of Stalvan: one chain', byName(db, 'The Legend of Stalvan')],
    ['Tome of the Cabal: one chain', byName(db, 'Tome of the Cabal')],
    ['Membership Card Renewal: repeatable', byName(db, 'Membership Card Renewal')],
  ];
  for (const [, ids] of cases) unmark(db, ids);
  const groups = ALT.find(db);
  for (const [name, ids] of cases) {
    const hit = groups.filter((g) => ids.some((id) => g.ids.includes(id)));
    check('not alternatives: ' + name + ' (' + ids.join(', ') + ')', ids.length >= 2 && !hit.length, hit);
  }
  // notAlternative (tools/forever-overrides.json) rules a quest out
  const db2 = fresh(); unmark(db2, [3629, 4181]); db2.quests[4181].notAlternative = true;
  check('notAlternative keeps a quest out of a group', !groupOf(ALT.find(db2), 3629));
}
// what a build marks: the whole list, both ways, and a rerun gives the same data (from scratch, not on top)
{
  const db = fresh();
  const groups = ALT.mark(db);
  console.log('     marked on this data: ' + (groups.length ? groups.map((g) => g.name + ' ' + g.ids.join('/')).join('; ') : 'nothing'));
  check('marked both ways', groups.every((g) => g.ids.every((a) => g.ids.every((b) => a === b || db.quests[a].exclusive.includes(b)))));
  check('a second pass finds nothing left to mark', ALT.find(db).length === 0, ALT.find(db).map((g) => g.name));
  const once = JSON.stringify(db.quests);
  const again = ALT.mark(db);
  check('a rerun gives the same data, and lists the same groups', JSON.stringify(db.quests) === once && again.length === groups.length, again.map((g) => g.name));
  // the list stays short: a broad rule that caught the cloth donations or the Cenarion plants would be in the dozens
  check('a handful of groups, not dozens (' + groups.length + ')', groups.length <= 10, groups.map((g) => g.name));
  // a quest given notAlternative after it was marked (the quick path: apply-overrides.js on an existing db.json)
  // loses its marks on the next run, and the others theirs to it
  const rc = groupOf(groups, 91735);
  if (rc) {
    db.quests[91737].notAlternative = true;
    ALT.mark(db);
    check('notAlternative after a mark: the marks to and from it come off', !(db.quests[91737].exclusive || []).includes(91735) && !(db.quests[91735].exclusive || []).includes(91737) && (db.quests[91735].exclusive || []).includes(91734), [db.quests[91735].exclusive, db.quests[91737].exclusive]);
  } else check('Remote Contact is marked (for the notAlternative case)', false, groups.map((g) => g.name));
  // QuestieDB's own links are never taken off
  check('...QuestieDB\'s own links stay', (db.quests[4736].exclusive || []).includes(4738));
}

// the safety net: a pick-up whose alternative is done, in your log or taken earlier on the route goes, all its steps
{
  const db = fresh();
  const conv = JSON.parse(fs.readFileSync(path.join(path.dirname(dbFile), 'conversion.json'), 'utf8')).geometry.transforms;
  const ensure = require('./ensure-steps').makeEnsure(db, conv);
  const sw = { m: 1453, x: 0.39, y: 0.85, zone: 'Stormwind City' }, ifg = { m: 1455, x: 0.51, y: 0.08, zone: 'Ironforge' }, bar = { m: 1413, x: 0.49, y: 0.57, zone: 'The Barrens' };
  const menara = (q, at) => [{ k: 'accept', q, name: 'In Search of Menara Voidrender', level: 31, ...at, sec: 'a' }, { k: 'turnin', q, name: 'In Search of Menara Voidrender', level: 31, ...bar, sec: 'a' }];
  const both = [...menara(4738, sw), { k: 'fly', to: 1455, dest: 'Ironforge', sec: 'a' }, ...menara(4736, ifg)];
  const out1 = ensure(both.map((s) => ({ ...s })), { done: [], active: [] });
  check('ensure: the second alternative on a route goes (Briarthorn after Demisette Cloyce)', out1.some((s) => s.q === 4738) && !out1.some((s) => s.q === 4736), out1.filter((s) => s.q).map((s) => s.k + s.q));
  const out2 = ensure(menara(4736, ifg), { done: [4738], active: [] });
  check('ensure: done before the route, Briarthorn\'s goes', !out2.some((s) => s.q === 4736), out2.filter((s) => s.q).map((s) => s.k + s.q));
  const out3 = ensure(menara(4736, ifg), { done: [], active: [4738] });
  check('ensure: in your log from Stormwind, Briarthorn\'s goes', !out3.some((s) => s.q === 4736), out3.filter((s) => s.q).map((s) => s.k + s.q));
  const out4 = ensure(menara(4736, ifg), { done: [], active: [] });
  check('ensure: neither, Briarthorn\'s stays', out4.some((s) => s.k === 'accept' && s.q === 4736) && out4.some((s) => s.k === 'turnin' && s.q === 4736));
  // a quest's own prerequisite in its exclusive list: Returning Home, then Stars of Elune - both stay
  const dar = { m: 1457, x: 0.39, y: 0.81, zone: 'Darnassus' };
  const elune = [{ k: 'accept', q: 5629, name: 'Returning Home', level: 10, ...dar, sec: 'a' }, { k: 'turnin', q: 5629, name: 'Returning Home', level: 10, ...dar, sec: 'a' },
    { k: 'accept', q: 5627, name: 'Stars of Elune', level: 10, ...dar, sec: 'a' }, { k: 'turnin', q: 5627, name: 'Stars of Elune', level: 10, ...dar, sec: 'a' }];
  const out5 = ensure(elune.map((s) => ({ ...s })), { done: [], active: [] });
  check('ensure: Stars of Elune after Returning Home stays', out5.some((s) => s.k === 'accept' && s.q === 5627) && out5.some((s) => s.k === 'accept' && s.q === 5629), out5.filter((s) => s.q).map((s) => s.k + s.q));
}
// both alternatives on a route: the one the route's follow-ups need is kept, not simply the first (made-up quests)
{
  const conv = JSON.parse(fs.readFileSync(path.join(path.dirname(dbFile), 'conversion.json'), 'utf8')).geometry.transforms;
  const q = (id, xp, extra) => ({ id, name: 'Q' + id, level: 20, reqLevel: 20, xp, races: 0, classes: 0, preGroup: [], preSingle: [], exclusive: [], objectives: [], starters: [], finishers: [], ...extra });
  const mk = (quests) => require('./ensure-steps').makeEnsure({ quests, npcs: {}, objects: {} }, conv);
  const at = { m: 1453, x: 0.5, y: 0.5, zone: 'Stormwind City', sec: 'a' };
  const pair = (id) => [{ k: 'accept', q: id, name: 'Q' + id, level: 20, ...at }, { k: 'turnin', q: id, name: 'Q' + id, level: 20, ...at }];
  const accepted = (out) => out.filter((s) => s.k === 'accept').map((s) => s.q);
  // A (more XP, first) and B close each other; C needs B
  const withC = { 1: q(1, 500, { exclusive: [2] }), 2: q(2, 300, { exclusive: [1] }), 3: q(3, 400, { preGroup: [2] }) };
  const o1 = mk(withC)([...pair(1), ...pair(2), ...pair(3)], { done: [], active: [] });
  check('ensure: of two alternatives, the one a later quest needs is kept (B, for C)', JSON.stringify(accepted(o1)) === '[2,3]', accepted(o1));
  // without C: the one worth more (A)
  const noC = { 1: q(1, 300, { exclusive: [2] }), 2: q(2, 500, { exclusive: [1] }) };
  const o2 = mk(noC)([...pair(1), ...pair(2)], { done: [], active: [] });
  check('ensure: ...with no follow-up, the one worth more XP (the later B here)', JSON.stringify(accepted(o2)) === '[2]', accepted(o2));
  // a later quest that takes either one (preSingle naming both) needs neither in particular: the first, at equal XP
  const either = { 1: q(1, 300, { exclusive: [2] }), 2: q(2, 300, { exclusive: [1] }), 3: q(3, 400, { preSingle: [1, 2] }) };
  const o3 = mk(either)([...pair(1), ...pair(2), ...pair(3)], { done: [], active: [] });
  check('ensure: ...one either will do for, at equal XP: the first', JSON.stringify(accepted(o3)) === '[1,3]', accepted(o3));
}

// carried deliveries (carry-deliveries.js): the first city the route passes where one of a set of alternatives can be
// carried takes it - "can be carried" by the same test as the quest itself, not just a giver standing there
{
  const conv = JSON.parse(fs.readFileSync(path.join(path.dirname(dbFile), 'conversion.json'), 'utf8')).geometry.transforms;
  const { carry } = require('./carry-deliveries');
  const npc = (id, name, zone, x, y) => ({ id, name, friendly: 'A', spawns: [{ zone, x, y }] });
  const N = { 1: npc(1, 'Stormwind giver', 1519, 50, 50), 2: npc(2, 'Ironforge giver', 1537, 50, 50), 3: npc(3, 'Barrens hand-in', 17, 55, 55) };
  const del = (id, giver, ex, extra) => ({ id, name: 'Delivery', level: 31, reqLevel: 31, xp: 600, races: 0, classes: 0, preGroup: [], preSingle: [], exclusive: ex, objectives: [], special: 0,
    starters: [{ type: 'npc', ...N[giver] }], finishers: [{ type: 'npc', ...N[3] }], ...extra });
  const run = (quests) => {
    const steps = [{ k: 'goto', m: 1453, x: 0.5, y: 0.5, sec: 0 }, { k: 'goto', m: 1455, x: 0.5, y: 0.5, sec: 1 }, { k: 'goto', m: 1413, x: 0.5, y: 0.5, sec: 2 }, { k: 'goto', m: 1413, x: 0.6, y: 0.6, sec: 2 }];
    const legs = [{ from: 0, zone: 1519, levelBefore: 31 }, { from: 1, zone: 1537, levelBefore: 31 }, { from: 2, zone: 17, levelBefore: 31 }];
    carry(steps, legs, { db: { quests, npcs: N, objects: {} }, conv, completed: [], log: {}, level: 31, race: 'human', klass: 'warlock', faction: 'alliance' });
    return steps.filter((s) => s.k === 'accept').map((s) => s.q + '@' + s.m);
  };
  const r1 = run({ 10: del(10, 1, [11]), 11: del(11, 2, [10]) });
  check('carry: both can be carried - Stormwind\'s (the first city) only', JSON.stringify(r1) === '["10@1453"]', r1);
  const r2 = run({ 10: del(10, 1, [11], { classes: 1 }), 11: del(11, 2, [10]) });
  check('carry: Stormwind\'s is another class\'s - Ironforge\'s is carried', JSON.stringify(r2) === '["11@1455"]', r2);
  const r3 = run({ 10: del(10, 1, [11], { reqLevel: 40 }), 11: del(11, 2, [10]) });
  check('carry: Stormwind\'s needs a higher level - Ironforge\'s is carried', JSON.stringify(r3) === '["11@1455"]', r3);
  const r4 = run({ 10: del(10, 1, [11], { preGroup: [99] }), 11: del(11, 2, [10]), 99: del(99, 3, [], { objectives: [{}] }) });
  check('carry: Stormwind\'s needs an earlier quest not done - Ironforge\'s is carried', JSON.stringify(r4) === '["11@1455"]', r4);
}

// the audit flags a pick-up whose alternative is had
{
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fr-excl-'));
  const q = (id, ex) => ({ id, name: 'In Search of Menara Voidrender', level: 31, reqLevel: 31, races: 0, classes: 0, preGroup: [], preSingle: [], exclusive: ex, objectives: [], starters: [], finishers: [] });
  const ldb = path.join(dir, 'db.json');
  // (and Stars of Elune as QuestieDB has it: one of its breadcrumbs needed first, and the same ones in its exclusive list)
  const elune = { 5627: { ...q(5627, [5629]), name: 'Stars of Elune', level: 10, reqLevel: 10, preSingle: [5629] }, 5629: { ...q(5629, [5627]), name: 'Returning Home', level: 10, reqLevel: 10 } };
  fs.writeFileSync(ldb, JSON.stringify({ quests: { 4736: q(4736, [4738]), 4738: q(4738, [4736]), ...elune }, npcs: {}, objects: {} }));
  const ser = (o) => '{ ' + Object.entries(o).map(([k, v]) => k + ' = ' + (typeof v === 'string' ? JSON.stringify(v) : v)).join(', ') + ' }';
  const audit = (steps, done) => {
    const f = path.join(dir, 'Route.lua');
    fs.writeFileSync(f, ['ForeverRouteData = {', '  paths = {', '  {', '    id = "path:test",', '    steps = {', ...steps.map((s) => '      ' + ser(s) + ','), '    },', '  },', '  },', '}'].join('\n'));
    const doneFile = path.join(dir, 'done.json'); fs.writeFileSync(doneFile, JSON.stringify(done || []));
    return execFileSync(process.execPath, [path.join(__dirname, 'lint-route.js'), f, ldb, 'path:test', '', doneFile], { encoding: 'utf8' });
  };
  const at = { m: 1455, x: 0.51, y: 0.08, zone: 'Ironforge', lvl: 31 }, sw = { m: 1453, x: 0.39, y: 0.85, zone: 'Stormwind City', lvl: 31 };
  const acc = (id, w) => ({ k: 'accept', q: id, name: 'In Search of Menara Voidrender', ...w });
  check('lint: Briarthorn\'s with Demisette Cloyce\'s done is flagged', /alternative \(4738\) is done/.test(audit([acc(4736, at)], [4738])));
  check('lint: both picked up on one route is flagged', /alternative \(4738\) is picked up at #1/.test(audit([acc(4738, sw), { k: 'fly', to: 1455, dest: 'Ironforge', text: 'Ironforge' }, acc(4736, at)])));
  check('lint: one of them alone is fine', !/alternative/.test(audit([acc(4736, at)])));
  const dar = { m: 1457, x: 0.39, y: 0.81, zone: 'Darnassus', lvl: 10 };
  check('lint: Stars of Elune after Returning Home (its prerequisite) is fine', !/alternative/.test(audit([{ k: 'accept', q: 5629, name: 'Returning Home', ...dar }, { k: 'turnin', q: 5629, name: 'Returning Home', ...dar }, { k: 'accept', q: 5627, name: 'Stars of Elune', ...dar }], [])));
  check('lint: ...Returning Home after Stars of Elune is flagged', /accept Returning Home: its alternative Stars of Elune \(5627\) is picked up at #1/.test(audit([{ k: 'accept', q: 5627, name: 'Stars of Elune', ...dar }, { k: 'accept', q: 5629, name: 'Returning Home', ...dar }], [])));
  fs.rmSync(dir, { recursive: true, force: true });
}

console.log(fails ? `${fails} failed` : 'all passed');
process.exit(fails ? 1 : 0);
