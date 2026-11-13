// The quests a campaign carries from one zone leg to the next: errands for deliveries, the log kept from filling up,
// zones with open chains, and the card's "the chain ends here". campaign.js builds it once (makeCarry) with its own
// tables and travel cost; tools/test-carry.js builds it on a small made-up quest table to check each rule.
const W = require('./world');
const { raceOk, CLASS_BIT, LEVEL_ABOVE } = W;

// a return to a zone counts for less (cfg.revisitPenalty) - except what carries on there (route2.js carryValue: quests
// picked up elsewhere, chains begun in another zone or going on to another). Counted down too, a chain that crosses
// zones was cut wherever its next part waited for a level or two: the return for it scored like one for stragglers
const revisited = (value, carry, r) => { const c = Math.max(0, Math.min(value, carry || 0)); return (value - c) * r + c; };

// ctx: { db, cfg, st (the save: log, completed, nope, notOffered), race, klass, followersOf, mainZone, starterZone,
//        zoneName, uiMap, continent, CITIES, BATTLEGROUNDS, START_ZONES, HOME, hop(S, zone) -> minutes, NO_WAY,
//        planZones(S) -> Set of the zones the plan may go to at S's level }
function makeCarry(ctx) {
  const { db, cfg, st = {}, race, klass, followersOf, mainZone, starterZone, zoneName, uiMap = {}, continent = {}, hop, planZones } = ctx;
  const CITIES = ctx.CITIES || new Set(), BATTLEGROUNDS = ctx.BATTLEGROUNDS || new Set(), START_ZONES = ctx.START_ZONES || new Set();
  const NO_WAY = ctx.NO_WAY || 600;
  const tkQ = (q) => q && W.raceFits(q.races, race) && W.classFits(q.classes, klass) && !(q.special & 3) && !q.notInForever && !q.skill && !q.reqSpell && !q.minRep;
  const foeMark = cfg.faction === 'horde' ? 'A' : 'H';
  const cap = () => cfg.carryLog ?? 15;
  const preMet = (q, done) => (q.preGroup || []).every((p) => done.has(p)) && (!(q.preSingle || []).length || q.preSingle.some((p) => done.has(p)));
  const handInZone = (q) => { for (const f of q.finishers || []) { const z = mainZone((f.spawns || []).filter((sp) => sp.x >= 0)); if (z) return z; } return null; };
  // a next part you could still take (not done, not gray): handing this one in leads somewhere
  const opensChain = (q, L, done) => (followersOf[q.id] || []).some((f) => { const F = db.quests[f]; return tkQ(F) && !done.has(f) && F.level >= L - 6; });
  // the quests in your log when the plan was made, and the ones the plan let go of (never picked up again on the route)
  const LOG0 = new Set(Object.keys(st.log || {})), LET_GO = new Set();
  const skipSet = () => new Set([...(cfg.skip || []), ...(st.nope || []), ...(st.notOffered || []), ...LET_GO]);

  // ---------- errands: a delivery picked up on the way to a leg ----------
  // carryDeliveries (campaign.js) takes a delivery only from a capital the route passes anyway. A delivery given anywhere
  // else whose hand-in is in the leg you're going to was never taken: The Orphan (Orphan Matron Aria in Alterac
  // Mountains, for Lieutenant Connar in the Blasted Lands) and the four Blasted Lands quests it opens - the plan is never
  // in Alterac at 45+. Before a leg, the deliveries it could hand in (given outside its zones, handed in inside them,
  // nothing to do on the way) are weighed with the chain they open there, against the detour to their giver: worth it
  // when the detour, with a zone change's cfg.switchMin like any other stop, pays at least the leg's own rate
  // (cfg.errandShare of it). One giver per leg, and only as many quests as the log has room for (cfg.carryLog); the leg
  // is then planned with them in your log, so it hands them in and goes on with the chain (route2.js carriedIn).
  function chainXpIn(q, L, zones, done, depth = 1, seen = new Set()) {
    if (depth > 8) return 0;
    let v = 0;
    for (const f of followersOf[q.id] || []) {
      const F = db.quests[f];
      if (seen.has(f) || done.has(f) || !tkQ(F) || !zones.has(starterZone(F)) || F.level < L - 6 || F.reqLevel > L + 2) continue;
      seen.add(f);
      v += Math.pow(cfg.chainDiscount ?? 0.6, depth) * W.questXp(F.xp || 0, F.level, L) + chainXpIn(F, L, zones, done, depth + 1, seen);
    }
    return v;
  }
  function errandFor(S, z, legZones, rate) {
    if (cfg.errands === false || !(rate > 0)) return null;
    const L = S.level, done = new Set(S.completed || []), inLog = S.active || {}, zs = new Set(legZones);
    // the log's room: a delivery is one more quest in it (pruneLog made room before the leg, up to cfg.carryLog)
    const room = cap() - Object.keys(inLog).length;
    if (room <= 0) return null;
    // (LET_GO too: a delivery the plan let go of to keep log room was not picked up again here either)
    const skip = skipSet();
    const byGiver = new Map();
    for (const q of Object.values(db.quests)) {
      if (!q || (q.objectives || []).length || done.has(q.id) || inLog[q.id] || skip.has(q.id) || !(q.xp > 0) || !tkQ(q)) continue;
      if ((q.reqLevel || 1) > L || q.level > L + W.levelAbove(L) || q.level < L - 5) continue;
      if (!preMet(q, done)) continue;
      if ((q.exclusive || []).some((e) => done.has(e) || inLog[e])) continue;
      if (!(q.finishers || []).some((f) => (f.spawns || []).some((sp) => zs.has(sp.zone)))) continue;
      const g = (q.starters || []).find((s) => s.type === 'npc' && (!s.friendly || s.friendly !== foeMark) && (s.spawns || []).some((sp) => sp.x >= 0 && uiMap[sp.zone] && !zs.has(sp.zone) && !BATTLEGROUNDS.has(sp.zone)));
      if (!g || (q.starters || []).some((s) => (s.spawns || []).some((sp) => zs.has(sp.zone)))) continue;
      const gsp = g.spawns.find((sp) => sp.x >= 0 && uiMap[sp.zone] && !zs.has(sp.zone));
      const xp = W.questXp(q.xp, q.level, L), chain = chainXpIn(q, L, zs, done);
      const key = gsp.zone + ':' + g.id;
      const e = byGiver.get(key) || { zone: gsp.zone, spot: gsp, who: g.name, quests: [], value: 0 };
      e.quests.push({ id: q.id, name: q.name, level: q.level, reqLevel: q.reqLevel, xp, chain: Math.round(chain), value: xp + chain });
      byGiver.set(key, e);
    }
    let best = null;
    for (const e of byGiver.values()) {
      e.quests = e.quests.sort((a, b) => b.value - a.value || a.id - b.id).slice(0, room);
      e.value = e.quests.reduce((a, x) => a + x.value, 0);
      const G = { level: L, zone: e.zone, pos: { zone: e.zone, x: e.spot.x, y: e.spot.y } };
      const there = hop(S, e.zone), on = hop(G, z);
      if (there >= NO_WAY || on >= NO_WAY) continue;
      // real minutes (the leg's time grows by these); scored with a zone change's settling-in on top, like any stop
      e.detour = Math.max(1, Math.round(there + on - hop(S, z) + 1));
      e.rate = e.value / (e.detour + (cfg.switchMin ?? 15));
      e.boat = continent[(S.pos && S.pos.zone) || S.zone] != null && continent[e.zone] != null && continent[(S.pos && S.pos.zone) || S.zone] !== continent[e.zone];
      if (e.rate >= rate * (cfg.errandShare ?? 1) && (!best || e.rate > best.rate)) best = e;
    }
    return best;
  }

  // ---------- where a chain ends ----------
  // A chain the route stops partway is a choice the player should see, not a mystery ("why isn't the next part on my
  // route?"): the hand-in after which the route goes no further says so - the next part, and why it is left out. The
  // reason is the one of the leg that cut it (route2.js chainSkip: the leg of the hand-in, else the first later leg that
  // saw the next part and left it), not whatever a leg far on said. Said only of a next part that is really there for
  // you (your race and class, in the game, not one you turned down or were never offered, given by someone you can
  // reach, not gray by the time of the hand-in, within the levels the plan reaches) and that the route never takes:
  // the rest is noise on a card (about one hand-in in seven had a note).
  function chainEnds(steps, legs) {
    const done0 = new Set(st.completed || []);
    const handed = new Set(steps.filter((x) => x.k === 'turnin' && x.q > 0).map((x) => x.q));
    const taken = new Set(steps.filter((x) => x.k === 'accept' && x.q > 0).map((x) => x.q));
    const skip = new Set([...(cfg.skip || []), ...(st.nope || []), ...(st.notOffered || [])]);
    const legOf = (i) => { let k = 0; for (let j = 0; j < legs.length; j++) if (legs[j].from <= i) k = j; return k; };
    const endLevel = legs.length ? Math.max(...legs.map((l) => (l.state && l.state.level) || 0)) : 60;
    const reachable = (F) => (F.starters || []).some((s) => s.type === 'item' || ((s.type === 'npc' || s.type === 'object') && (!s.friendly || s.friendly !== foeMark) && (s.spawns || []).some((sp) => sp.x >= 0 && zoneName[sp.zone])));
    let n = 0;
    steps.forEach((x, i) => {
      if (x.k !== 'turnin' || !(x.q > 0)) return;
      const k = legOf(i), lvl = (legs[k] && legs[k].levelBefore) || x.lvl || 0;
      const have = (p) => handed.has(p) || done0.has(p);
      const next = (followersOf[x.q] || []).map((f) => db.quests[f]).filter((F) => tkQ(F) && F.level <= 60 && (F.zone > 0 || F.classes)
        && !skip.has(F.id) && reachable(F) && F.level >= lvl - 6 && (F.reqLevel || 1) <= endLevel
        && !(F.exclusive || []).some((e) => have(e) || taken.has(e))
        && (F.preGroup || []).every(have) && (!(F.preSingle || []).length || F.preSingle.some(have)));
      if (!next.length || next.some((F) => have(F.id))) return;
      const F = next.sort((a, b) => (b.xp || 0) - (a.xp || 0) || a.id - b.id)[0];
      let why = null;
      for (let j = k; j < legs.length && !why; j++) why = (legs[j].state && legs[j].state.chainSkip && legs[j].state.chainSkip[F.id]) || null;
      if (!why) { const z = starterZone(F); why = taken.has(F.id) ? 'picked up, but not handed in on this route' : z && zoneName[z] ? 'it starts in ' + zoneName[z] + ', and the route does not go back there for it' : 'not on this route'; }
      x.chainEnd = F.name;
      x.note = (x.note ? x.note + '  ·  ' : '') + 'The chain ends here on this route: ' + F.name + ' is left out (' + why + ').';
      n++;
    });
    return n;
  }

  // ---------- the quests the plan carries ----------
  // Open quests carried from leg to leg (the hand-in elsewhere, a chain's next part for later) take log slots: route2
  // accepts nothing once your log holds cfg.maxLog (30), every quest in it counted - the ones in your save's log too. A
  // human warrior plan's log was full by 55, Mount Hyjal's legs could take nothing, and the plan ground three levels
  // instead. Before each leg the plan lets go of what is no longer worth its slot, whoever picked it up (a quest from
  // your save's log let go is one the quest log check, /fr logcheck, then says to abandon):
  //  - quests gone gray (more than 6 levels below you), unless finished with a next part to take or a hand-in on the
  //    plan's way (the work is done, the hand-in is a stop - route2.js hands in a finished gray quest it passes)
  //  - then, past cfg.carryLog quests, the least worth per minute still to spend on them: the work left (cfg.carryObjMin
  //    per objective not done) and the trip to the hand-in. A finished quest whose hand-in the plan reaches is never let
  //    go: dropped, its work - already in the earlier legs' minutes and kill XP - would be for nothing.
  // A quest let go is not handed in on the route; the safety net (ensure-steps.js) then leaves its pick-up out - and it
  // is not picked up again later (LET_GO joins the legs' skip list): taken again, its objective was planned twice (an
  // orc warrior's Salve via Hunting, let go after its shard was collected, then taken whole in the next Felwood leg)
  function pruneLog(S) {
    const L = S.level, act = { ...(S.active || {}) }, done = new Set(S.completed || []), out = [];
    const reach = planZones ? planZones(S) : new Set([S.zone]);
    const keep = (id, q) => !!(act[id] && act[id].complete) && (opensChain(q, L, done) || reach.has(handInZone(q)));
    const letGo = (id, q) => { delete act[id]; LET_GO.add(+id); out.push(q.name + (LOG0.has(String(id)) ? ' (in your log: abandon it)' : '')); };
    for (const id of Object.keys(act)) { const q = db.quests[id]; if (q && q.level < L - 6 && !keep(id, q)) letGo(id, q); }
    const ids = Object.keys(act);
    if (ids.length > cap()) {
      const perMin = (id) => {
        const q = db.quests[id], a = act[id] || {};
        const left = a.complete ? 0 : (a.objectives || []).length ? a.objectives.filter((o) => !o.done).length : (q.objectives || []).length;
        const z = handInZone(q), trip = z == null ? NO_WAY : hop ? Math.min(NO_WAY, hop(S, z)) : 0;
        return W.questXp(q.xp || 0, q.level, L) * (opensChain(q, L, done) ? 1.5 : 1) / (1 + left * (cfg.carryObjMin ?? 5) + trip);
      };
      const loose = ids.filter((id) => db.quests[id] && !keep(id, db.quests[id])).map((id) => [id, perMin(id)]).sort((a, b) => a[1] - b[1] || a[0] - b[0]);
      for (const [id] of loose.slice(0, ids.length - cap())) letGo(id, db.quests[id]);
    }
    if (out.length) console.log(`  let go of ${out.length} carried quest(s) to keep log room: ${out.join(', ')}`);
    return act;
  }

  // ---------- zones with open chains ----------
  // the zones with something waiting for you: the hand-in of a quest in your log, or the next part of a chain you began
  // (its earlier parts handed in), at your level - candidates even when they have few fresh quests left (a zone needs 6
  // quests at your level to be one): an open chain is a reason to go back. Only a zone with enough to do to be chosen,
  // though (cfg.minTurnins, the open work with the fresh quests there): each candidate costs an evaluation per leg (up to
  // cfg.evalTimeoutSec), and one with two or three hand-ins was almost never picked
  let SZ = null; // quest -> the zone its giver stands in
  const szOf = (q) => { if (!SZ) SZ = new Map(); if (!SZ.has(q.id)) SZ.set(q.id, starterZone(q)); return SZ.get(q.id); };
  function openZones(S, floor) { // floor: the hand-ins a zone needs (cfg.minTurnins; 1 to look wide before a grind)
    const done = new Set(S.completed || []), L = S.level, act = S.active || {}, open = new Map();
    const inWindow = (q) => q.level >= L - 2 && q.level <= L + 4 && (q.reqLevel || 1) <= L;
    for (const id of Object.keys(act)) {
      const q = db.quests[id];
      if (!q || q.level < L - 6 || q.level > L + W.levelAbove(L) + 1) continue; // gray, or not doable yet
      const z = handInZone(q); if (z) open.set(z, (open.get(z) || 0) + 1);
    }
    for (const id of done) for (const f of followersOf[id] || []) {
      const F = db.quests[f];
      if (!tkQ(F) || done.has(f) || act[f] || !inWindow(F) || !preMet(F, done)) continue;
      const z = szOf(F); if (z && !open.has(z)) open.set(z, 0); // counted below with the zone's other quests
    }
    // a chain not begun yet whose later parts still pay at your level: its head is low, the chain runs on (The Tower of
    // Althalaxx: the head is 18 in Darkshore, the chain runs to 28 - ~7k XP at 27). Narrowing open zones to chains
    // already begun lost it, and every chain whose head the plan passed too early (a human warrior plan lost 98
    // hand-ins). The zone opens with the chain's parts still in range counted as its hand-ins, when the chain is worth
    // cfg.headChainShare (5%) of a level
    // the walk goes through the chain's low parts (Althalaxx's second and third are 18 too) to the ones that pay: it
    // counts and values only the parts in range, but a part below the window doesn't end the chain
    const walk = (q, depth = 0, seen = new Set()) => {
      let n = 0, xp = 0;
      for (const f of followersOf[q.id] || []) {
        const F = db.quests[f];
        if (depth > 10 || seen.has(f) || done.has(f) || !tkQ(F) || (F.reqLevel || 1) > L + 3) continue; // across zones too: the chain is the point (Althalaxx: Darkshore, Ashenvale, Darkshore)
        seen.add(f);
        if (F.level >= L - 6) { n++; xp += W.questXp(F.xp || 0, F.level, L); }
        const r = walk(F, depth + 1, seen); n += r.n; xp += r.xp;
      }
      return { n, xp };
    };
    if (cfg.headChains !== false) for (const q of Object.values(db.quests)) {
      if (!q || done.has(q.id) || act[q.id] || !(followersOf[q.id] || []).length || (q.preGroup || []).length || (q.preSingle || []).length) continue;
      if (!tkQ(q) || (q.reqLevel || 1) > L || q.level < L - 12) continue;
      const z = szOf(q); if (!z) continue; // a zone already open (a quest in your log is handed in there) counts the chain too
      const r = walk(q);
      if (W.questXp(q.xp || 0, q.level, L) + r.xp < (cfg.headChainShare ?? 0.05) * (W.XP_TO_LEVEL[L] || 1)) continue;
      open.set(z, (open.get(z) || 0) + 1 + r.n); // the head is a hand-in too
    }
    const ok = (z) => zoneName[z] && !CITIES.has(z) && !BATTLEGROUNDS.has(z) && !(START_ZONES.has(z) && z !== ctx.HOME && !cfg.allowOtherStartZones);
    const zs = [...open.keys()].filter(ok);
    if (!zs.length) return [];
    // the quests you could take there now (the chains' next parts among them)
    const fresh = new Map(zs.map((z) => [z, 0])), skip = skipSet();
    const chainHere = new Set();
    for (const q of Object.values(db.quests)) {
      if (!q || done.has(q.id) || act[q.id] || skip.has(q.id) || !tkQ(q) || !inWindow(q) || !preMet(q, done)) continue;
      const z = szOf(q); if (!fresh.has(z)) continue;
      fresh.set(z, fresh.get(z) + 1);
      if ([...(q.preGroup || []), ...(q.preSingle || [])].some((p) => done.has(p))) chainHere.add(z);
    }
    return zs.filter((z) => (open.get(z) > 0 || chainHere.has(z)) && open.get(z) + fresh.get(z) >= (floor ?? (cfg.minTurnins || 5)));
  }

  return { tkQ, chainXpIn, errandFor, chainEnds, pruneLog, openZones, LOG0, LET_GO, handInZone };
}

module.exports = { makeCarry, revisited };
