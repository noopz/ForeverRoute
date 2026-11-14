// Checks for the quests a campaign carries from leg to leg (tools/carry.js) on a small made-up quest table: errands for
// deliveries (The Orphan's pattern), the log kept from filling up (pruneLog, a save with a full log among them), the
// zones with open chains, the revisit rule's carve-out and the card's "the chain ends here".
// usage: node tools/test-carry.js
const { makeCarry, revisited } = require('./carry');

let fails = 0;
const check = (name, ok, info) => { console.log((ok ? 'ok   ' : 'FAIL ') + name + (ok ? '' : '  ' + JSON.stringify(info))); if (!ok) fails++; };

// zones: 1 where you are, 2 Alterac (a giver), 4 Blasted Lands (the leg), 5 a fresh zone, 6 a city, 7 over the sea
const zoneName = { 1: 'Home', 2: 'Alterac', 3: 'Far', 4: 'Blasted Lands', 5: 'Fresh', 6: 'City', 7: 'Over the sea' };
const uiMap = { 1: 101, 2: 102, 3: 103, 4: 104, 5: 105, 6: 106, 7: 107 };
const continent = { 1: 0, 2: 0, 3: 0, 4: 0, 5: 0, 6: 0, 7: 1 };
const npc = (id, zone, x = 50, y = 50) => ({ type: 'npc', id, name: 'npc' + id, spawns: [{ zone, x, y }] });
function Q(id, o) {
  return { id, name: o.name || 'q' + id, level: o.level ?? 50, reqLevel: o.reqLevel ?? 40, xp: o.xp ?? 1000, races: 0, classes: 0, special: 0,
    starters: o.starters || [npc(1000 + id, o.from ?? 1)], finishers: o.finishers || [npc(2000 + id, o.to ?? 1)], objectives: o.objectives || [],
    preSingle: o.pre || [], preGroup: [], exclusive: [], zone: o.from ?? 1 };
}
function build(quests, { st = {}, cfg = {}, plan = [1], hopMin = {} } = {}) {
  const db = { quests: Object.fromEntries(quests.map((q) => [q.id, q])), npcs: {}, objects: {} };
  const followersOf = {};
  for (const q of quests) for (const p of [...q.preSingle, ...q.preGroup]) (followersOf[p] = followersOf[p] || []).push(q.id);
  const mainZone = (spawns) => { const n = {}; for (const p of spawns || []) n[p.zone] = (n[p.zone] || 0) + 1; let b = null; for (const z in n) if (b === null || n[z] > n[b]) b = z; return b === null ? null : +b; };
  const starterZone = (q) => (q && q.starters && q.starters[0] ? mainZone(q.starters[0].spawns) : null);
  // minutes between zones: hopMin[zone] from anywhere else, 10 by default; 0 where you are
  const hop = (S, z) => ((S.pos && S.pos.zone) || S.zone) === z ? 0 : hopMin[z] ?? 10;
  return makeCarry({ db, cfg: { faction: 'alliance', ...cfg }, st, race: 'human', klass: 'warrior', followersOf, mainZone, starterZone, zoneName, uiMap, continent,
    CITIES: new Set([6]), BATTLEGROUNDS: new Set(), START_ZONES: new Set(), HOME: 1, hop, NO_WAY: 600, planZones: () => new Set(plan) });
}
const S0 = (o = {}) => ({ level: 52, xp: 0, zone: 1, pos: { zone: 1, x: 50, y: 50 }, completed: [], active: {}, ...o });

// ---------- revisited ----------
check('revisit: what carries on is not counted down, the rest is', revisited(100, 30, 0.5) === 65, revisited(100, 30, 0.5));
check('revisit: carry above the value counts as the value', revisited(100, 300, 0.5) === 100 && revisited(100, undefined, 0.5) === 50);

// ---------- errands: The Orphan's pattern ----------
// a delivery given in Alterac (zone 2), handed in in the Blasted Lands (4), opening two quests there
const orphan = [
  Q(100, { name: 'The Orphan', level: 54, reqLevel: 45, xp: 3000, from: 2, to: 4 }),
  Q(101, { level: 54, reqLevel: 45, xp: 4000, from: 4, to: 4, pre: [100] }),
  Q(102, { level: 55, reqLevel: 45, xp: 4000, from: 4, to: 4, pre: [101] }),
];
{
  const C = build(orphan, { hopMin: { 2: 8, 4: 10 } });
  const e = C.errandFor(S0(), 4, [4], 10);
  check('errand: the delivery from Alterac is picked up on the way to the Blasted Lands', e && e.zone === 2 && e.quests.map((x) => x.id).join() === '100', e);
  check('...worth its own XP and the chain it opens there', e && e.quests[0].chain > 0, e && e.quests[0]);
  // detour: 8 there + 10 on - 10 straight + 1 = 9 real minutes; scored with a zone change's 15 on top
  check('...its detour is the real minutes, its rate charges a zone change (switchMin)', e && e.detour === 9 && Math.abs(e.rate - e.value / (9 + 15)) < 1e-9, e && { detour: e.detour, rate: e.rate, value: e.value });
  check('...not taken when it pays less than the leg', C.errandFor(S0(), 4, [4], 1e6) === null);
  check('...nor when the giver is in the leg itself', C.errandFor(S0(), 4, [2, 4], 10) === null);
  check('...on the same continent: no boat on its trip', e && e.boat === false);
  const Cs = build(orphan.map((q) => (q.id === 100 ? { ...q, starters: [npc(1100, 7)] } : q)), { hopMin: { 7: 25, 4: 10 } });
  const es = Cs.errandFor(S0(), 4, [4], 1);
  check('...a giver over the sea: the errand knows it takes a boat', es && es.boat === true, es);
}
{
  // a delivery the plan let go of (to keep log room) is not picked up again as an errand
  const C = build(orphan, { st: { log: { 100: { complete: true } } }, cfg: { carryLog: 0 } });
  const act = C.pruneLog(S0({ active: { 100: { complete: false, objectives: [] } } }));
  check('pruneLog lets go of a quest past the cap', !act[100] && C.LET_GO.has(100), { act, letGo: [...C.LET_GO] });
  check('...and errandFor does not bring it back', build(orphan).errandFor(S0(), 4, [4], 10) !== null && C.errandFor(S0(), 4, [4], 10) === null);
}
{
  // the log's room: an errand is one more quest in it
  const filler = Array.from({ length: 32 }, (_, i) => Q(300 + i, { from: 1, to: 1 }));
  const C = build([...orphan, ...filler]);
  const full = Object.fromEntries(filler.map((q) => [q.id, { complete: false, objectives: [] }]));
  check('errand: none when the log holds cfg.carryLog quests already', C.errandFor(S0({ active: full }), 4, [4], 1) === null);
  const one = { ...full }; delete one[300];
  const two = [...orphan, Q(103, { level: 54, reqLevel: 45, xp: 500, from: 2, to: 4, starters: orphan[0].starters })];
  const e = build([...two, ...filler]).errandFor(S0({ active: one }), 4, [4], 1);
  check('...and only as many as it has room for, the most worth first', e && e.quests.length === 1 && e.quests[0].id === 100, e && e.quests);
}

// ---------- pruneLog ----------
// (the budget is 32 - Forever's log holds 40)
{
  const qs = Array.from({ length: 23 }, (_, i) => Q(1400 + i, { from: 1, to: 1, objectives: [{ kind: 'kill' }] }));
  const log = Object.fromEntries(qs.map((q) => [q.id, { complete: false, objectives: [{ done: false }] }]));
  const act = build(qs, { st: { log } }).pruneLog(S0({ active: log }));
  check('budget: 23 quests in your log are all kept by default (32)', Object.keys(act).length === 23, Object.keys(act).length);
}
{
  // a save with 37 quests in its log (LOG0), all at your level, nothing finished: the budget (32) counts them, and the
  // least worth per minute go - the ones with the most work left
  const qs = Array.from({ length: 37 }, (_, i) => Q(400 + i, { from: 1, to: 1, xp: 1000, objectives: [{ kind: 'kill' }, { kind: 'kill' }, { kind: 'kill' }] }));
  const log = Object.fromEntries(qs.map((q, i) => [q.id, { complete: false, objectives: [{ done: i < 32 }, { done: i < 32 }, { done: false }] }]));
  const C = build(qs, { st: { log } });
  const act = C.pruneLog(S0({ active: log }));
  const kept = Object.keys(act).map(Number);
  check('a full log from the save is cut to cfg.carryLog (32)', kept.length === 32, kept.length);
  check('...the ones with the most work left go first', kept.filter((id) => id < 432).length === 32, kept);
  check('...and are not picked up again (LET_GO)', C.LET_GO.size === 5 && [...C.LET_GO].every((id) => id >= 432), [...C.LET_GO]);
}
{
  // gray quests (more than 6 levels below you)
  const qs = [
    Q(500, { level: 40, from: 1, to: 1 }), // gray, finished, hand-in on the plan's way: kept
    Q(501, { level: 40, from: 3, to: 3 }), // gray, finished, hand-in off the plan, opens nothing: let go
    Q(502, { level: 40, from: 3, to: 3 }), // gray, finished, off the plan, opens a chain: kept
    Q(503, { level: 50, from: 3, to: 3, pre: [502] }),
    Q(504, { level: 40, from: 1, to: 1, objectives: [{ kind: 'kill' }] }), // gray, not finished: let go
  ];
  const C = build(qs, { plan: [1] });
  const act = C.pruneLog(S0({ active: { 500: { complete: true }, 501: { complete: true }, 502: { complete: true }, 504: { complete: false, objectives: [{ done: false }] } } }));
  check('gray: a finished one whose hand-in the plan passes is kept', !!act[500], act);
  check('gray: a finished one handed in off the plan, opening nothing, goes', !act[501], act);
  check('gray: a finished one opening a chain is kept', !!act[502], act);
  check('gray: an unfinished one goes', !act[504], act);
}
{
  // past the cap: a finished quest whose hand-in the plan reaches is never let go, before fresh ones with work to do;
  // among the rest, a far hand-in counts against a quest
  const done = Array.from({ length: 27 }, (_, i) => Q(600 + i, { from: 1, to: 1, xp: 200 }));
  const fresh = Array.from({ length: 6 }, (_, i) => Q(640 + i, { from: 1, to: 1, xp: 3000, objectives: [{ kind: 'kill' }] }));
  const far = Q(660, { from: 3, to: 3, xp: 3000, objectives: [{ kind: 'kill' }] });
  const C = build([...done, ...fresh, far], { plan: [1], hopMin: { 3: 60 } });
  const active = { ...Object.fromEntries(done.map((q) => [q.id, { complete: true }])), ...Object.fromEntries([...fresh, far].map((q) => [q.id, { complete: false, objectives: [{ done: false }] }])) };
  const act = C.pruneLog(S0({ active }));
  check('cap: finished quests with a hand-in on the plan are all kept', done.every((q) => act[q.id]), Object.keys(act));
  check('cap: the far one goes first', !act[660] && Object.keys(act).length === 32, Object.keys(act));
}

// ---------- openZones ----------
{
  const L = 50;
  const qs = [
    Q(700, { from: 3, to: 3, level: 50 }), // in your log, handed in in zone 3
    Q(701, { from: 3, to: 3, level: 50 }),
    Q(710, { from: 5, to: 5, level: 50 }), // in your log, handed in in zone 5, which has 4 fresh quests too
    ...Array.from({ length: 4 }, (_, i) => Q(711 + i, { from: 5, to: 5, level: 50 })),
    Q(720, { from: 2, to: 2, level: 30 }), // in your log but gray: no reason to go to zone 2
    ...Array.from({ length: 4 }, (_, i) => Q(721 + i, { from: 2, to: 2, level: 50 })),
    Q(730, { from: 7, to: 7, level: 49 }), Q(731, { from: 7, to: 7, level: 50, pre: [730] }), // a chain's next part in zone 7
    ...Array.from({ length: 4 }, (_, i) => Q(732 + i, { from: 7, to: 7, level: 50 })),
    Q(740, { from: 6, to: 6, level: 50 }), ...Array.from({ length: 6 }, (_, i) => Q(741 + i, { from: 6, to: 6, level: 50 })), // a city
  ];
  const C = build(qs);
  const z = C.openZones(S0({ level: L, completed: [730], active: { 700: { complete: true }, 701: { complete: true }, 710: { complete: true }, 720: { complete: true }, 740: { complete: true } } }));
  check('open zones: two hand-ins and nothing else there is not enough to be chosen', !z.includes(3), z);
  check('open zones: a hand-in with fresh quests around it is', z.includes(5), z);
  check('open zones: a gray quest in your log is no reason to go back', !z.includes(2), z);
  check('open zones: a chain\'s next part with enough around it is', z.includes(7), z);
  check('open zones: never a city', !z.includes(6), z);
}

// ---------- a scripted event (special & 2) is a quest like any other ----------
// The Missing Diplomat: part 14 is 'explore Sentry Point' with the scripted-event flag, part 15 its follow-up. The flag
// is on escorts, fights and explorations alike; only repeatables (special & 1) are left out
{
  const qs = [
    { ...Q(900, { from: 5, to: 5, level: 50 }), special: 2 }, Q(901, { from: 5, to: 5, level: 50, pre: [900] }),
    ...Array.from({ length: 4 }, (_, i) => Q(902 + i, { from: 5, to: 5, level: 50 })),
  ];
  const z = build(qs).openZones(S0({ level: 50, active: { 900: { complete: false } } }));
  check('scripted event: a chain part with the flag in your log opens its zone', z.includes(5), z);
}

// ---------- chainEnds ----------
{
  const qs = [
    Q(800, { from: 1, to: 1, level: 50 }), Q(801, { from: 3, to: 3, level: 51, pre: [800] }), // cut after 800
    Q(810, { from: 1, to: 1, level: 50 }), Q(811, { from: 3, to: 3, level: 51, pre: [810] }), // next part never offered
    Q(820, { from: 1, to: 1, level: 50 }), Q(821, { from: 3, to: 3, level: 50, reqLevel: 58, pre: [820] }), // beyond the plan's levels
    Q(830, { from: 1, to: 1, level: 50 }), Q(831, { from: 1, to: 1, level: 50, pre: [830] }), // taken: no note
    Q(840, { from: 1, to: 1, level: 50 }), Q(841, { from: 1, to: 1, level: 40, pre: [840] }), // gray by then: no note
  ];
  const C = build(qs, { st: { notOffered: [811] } });
  const st = (q, k) => ({ k, q, name: 'q' + q, m: 101 });
  const steps = [st(800, 'accept'), st(800, 'turnin'), st(810, 'turnin'), st(820, 'turnin'), st(830, 'turnin'), st(840, 'turnin'), { k: 'fly' }, st(831, 'accept'), st(831, 'turnin')];
  const legs = [
    { from: 0, levelBefore: 50, state: { level: 52, chainSkip: { 801: 'needs level 52' } } },
    { from: 6, levelBefore: 52, state: { level: 55, chainSkip: { 801: 'not worth the time here' } } },
  ];
  const n = C.chainEnds(steps, legs);
  check('chain end: said where the chain is cut', /q801 is left out/.test(steps[1].note || ''), steps[1]);
  check('...with the reason of the leg that cut it, not a later one', /needs level 52/.test(steps[1].note || ''), steps[1].note);
  check('...not for a next part never offered to you, beyond the plan\'s levels, taken, or gray by then', n === 1, steps.filter((s) => s.note).map((s) => s.q));
}

console.log(fails ? fails + ' failed' : 'all passed');
process.exit(fails ? 1 : 0);
