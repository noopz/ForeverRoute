// Carried deliveries (campaign.js): a quest with no objectives, picked up in a capital the path passes through and
// handed in on a later leg of the path in its hand-in zone - free XP for a stop the path makes anyway.
// carry(steps, legs, ctx) inserts the pick-ups and hand-ins into steps (and moves legs[].from), and returns what it
// added, one line each. ctx: { db, conv, completed, log, level, race, klass, faction }
// (its own file so it can be tested without a whole campaign: tools/test-exclusive.js)
const { raceFits, classFits, CAPITAL_MAPS } = require('./world');
const { closers } = require('./exclusive-alternatives');

function carry(steps, legs, ctx) {
  if (!legs.length) return [];
  const { db, conv, race, klass } = ctx;
  const N = db.npcs, Q = db.quests;
  const zoneName = Object.fromEntries(conv.map((t) => [t.area_id, t.target_name]));
  const uiMap = Object.fromEntries(conv.map((t) => [t.area_id, t.ui_map_id]));
  const areaOfMap = Object.fromEntries(conv.map((t) => [t.ui_map_id, t.area_id]));
  const side = ctx.faction === 'horde' ? 'H' : 'A';
  const onRoute = new Set(steps.filter((x) => x.q > 0).map((x) => x.q));
  const done0 = new Set(ctx.completed || []), inLog = new Set(Object.keys(ctx.log || {}).map(Number));
  const legAt = (i) => { let k = 0; for (let j = 0; j < legs.length; j++) if (legs[j].from <= i) k = j; return k; };
  // the quests handed in before step i (memo per index: steps are only inserted after the stop being worked on, so
  // the indexes before it, the only ones asked about again, keep their meaning)
  const turnedMemo = new Map();
  const turnedBefore = (i) => { if (!turnedMemo.has(i)) turnedMemo.set(i, new Set(steps.slice(0, i).filter((x) => x.k === 'turnin' && x.q > 0).map((x) => x.q))); return turnedMemo.get(i); };
  const sq = (a, b) => (a.x - b.x) ** 2 + (a.y - b.y) ** 2;
  // the end of each run of steps in a city
  const stops = [];
  for (let i = 0; i < steps.length; i++) if (CAPITAL_MAPS.has(steps[i].m) && !(steps[i + 1] && steps[i + 1].m === steps[i].m)) stops.push(i);

  // how quest q would be carried from the city stop at index `stop`, or null when it can't be: the same test for the
  // quest itself and for its alternatives (below)
  function plan(qid, stop) {
    const q = Q[qid];
    if (!q || onRoute.has(qid) || done0.has(qid) || inLog.has(qid) || q.objectives.length || q.special & 3) return null;
    const city = steps[stop].m, cityArea = areaOfMap[city], k = legAt(stop);
    const level = legs[k].levelBefore || ctx.level;
    if (!raceFits(q.races, race)) return null;
    // class quests only for your class (a warlock was sent to deliver the warrior quest Yorus Barleybrew)
    if (!classFits(q.classes, klass)) return null;
    if ((q.reqLevel || 1) > level || !(q.xp > 0)) return null;
    const before = turnedBefore(stop);
    const pre = [...(q.preGroup || []), ...((q.preSingle || []).length === 1 ? q.preSingle : [])];
    if (!pre.every((x) => done0.has(x) || before.has(x))) return null;
    const giver = q.starters.find((g) => g.type === 'npc' && (g.spawns || []).some((sp) => sp.zone === cityArea && sp.x >= 0));
    if (!giver) return null;
    const gn = N[giver.id]; if (gn && gn.friendly && gn.friendly !== 'AH' && gn.friendly !== side) return null;
    const fin = q.finishers.find((f) => (f.spawns || []).some((sp) => sp.x >= 0 && uiMap[sp.zone]));
    if (!fin) return null;
    const fsp = fin.spawns.find((sp) => sp.x >= 0 && uiMap[sp.zone]);
    // a later leg of this path in the hand-in zone, while the quest still gives real XP (not gray)
    const j = legs.findIndex((L, jj) => jj > k && L.zone === fsp.zone && (L.levelBefore || 0) <= q.level + 5);
    if (j < 0) return null;
    const gsp = giver.spawns.find((sp) => sp.zone === cityArea && sp.x >= 0);
    // hand-in: cheapest spot among that leg's steps on the same map
    const from = legs[j].from, to = j + 1 < legs.length ? legs[j + 1].from : steps.length;
    const tm = uiMap[fsp.zone], T = { x: fsp.x / 100, y: fsp.y / 100 };
    let at = -1, best = Infinity;
    for (let i = from; i < to; i++) {
      const a = steps[i], b = steps[i + 1];
      if (a.m !== tm || !a.x) continue;
      const c = b && b.m === tm && b.x ? Math.sqrt(sq(a, T)) + Math.sqrt(sq(T, b)) - Math.sqrt(sq(a, b)) : Math.sqrt(sq(a, T));
      if (c < best) { best = c; at = i + 1; }
    }
    if (at < 0) return null;
    return { q, city, cityArea, giver, gsp, fin, fsp, tm, T, at };
  }

  const added = [];
  for (const stop of [...stops].reverse()) { // from the end, so earlier indexes stay valid while inserting
    for (const id of Object.keys(Q)) {
      const qid = +id, q = Q[qid];
      if (onRoute.has(qid) || q.objectives.length) continue; // (quick no before the alternatives' test)
      // one of a set of alternatives (In Search of Menara Voidrender from Demisette Cloyce in Stormwind or Briarthorn
      // in Ironforge): not when another is done, in your log or already on the route - the plan sent a warlock who had
      // taken it in Stormwind to Briarthorn for it. And the first city the route passes where one can be carried is
      // where it is taken; a later city's is left for that one. "Can be carried" is the whole test the quest itself
      // passes (race, class, level by then, XP, prerequisites, a friendly giver, a later leg to hand it in): a giver
      // in an earlier city alone skipped Goblin Engineering for a character who couldn't take the earlier one
      const alts = closers(Q, q).filter((e) => Q[e]);
      if (alts.some((e) => onRoute.has(e) || done0.has(e) || inLog.has(e))) continue;
      if (alts.some((e) => stops.some((s2) => s2 < stop && plan(e, s2)))) continue;
      const p = plan(qid, stop);
      if (!p) continue;
      const { city, cityArea, giver, gsp, fin, fsp, tm, T, at } = p;
      steps.splice(at, 0, { k: 'turnin', npc: fin.name, r: 6, q: qid, name: q.name, level: q.level, m: tm, x: +T.x.toFixed(4), y: +T.y.toFixed(4), zone: zoneName[fsp.zone], sec: steps[Math.min(at, steps.length - 1)].sec, note: 'Carried from ' + zoneName[cityArea] + '.' });
      steps.splice(stop + 1, 0, { k: 'accept', npc: giver.name, r: 6, minLevel: q.reqLevel > 1 ? q.reqLevel : undefined, q: qid, name: q.name, level: q.level, m: city, x: +(gsp.x / 100).toFixed(4), y: +(gsp.y / 100).toFixed(4), zone: zoneName[cityArea], sec: steps[stop].sec, note: 'Delivery - handed in later in ' + zoneName[fsp.zone] + ' (' + q.xp + ' xp).' });
      for (const L of legs) if (L.from > stop) L.from += 1;
      for (const L of legs) if (L.from > at) L.from += 1;
      onRoute.add(qid); added.push(q.name + ' (' + zoneName[cityArea] + ' -> ' + zoneName[fsp.zone] + ')');
    }
  }
  return added;
}

module.exports = { carry };
