// Safety net for quests that were already in the log (or half done) when a route was planned: the planner leaves out
// their accept step and finished objectives, so if the quest is later abandoned the route has nowhere to send you.
// This puts back, for every quest in a route: an accept step (at its giver, before the quest's first step) and an
// objective step for every objective (before its turn-in). In game they show as done straight away from the live
// quest log; abandon the quest and they come back, pointing at the giver and the objective spots.
// ensureSteps(steps, db, conv) -> new steps array (ids renumbered, sections kept)
// an item that drops all over (Linen Cloth: ~250 humanoids in its drop rates, only chests as listed sources) is no place
// to go: its first spawn in the data sent a level-12 paladin to Alterac Mountains. You have it from questing (or buy it)
const COMMON_DROP = 25;
const commonDrop = (o) => o.kind !== 'kill' && Math.max((o.npcDrops || []).length + (o.objectDrops || []).length, Object.keys(o.rates || {}).length) > COMMON_DROP;
function flyLater(steps) {
  steps = steps.slice();
  for (let i = 0; i < steps.length; i++) {
    const f = steps[i]; if (f.k !== 'fly' || !f.to || f.moved) continue;
    let j = i + 1;
    while (j < steps.length && steps[j].m && steps[j].m !== f.to && steps[j].k !== 'fly' && steps[j].k !== 'goto') j++;
    if (j > i + 1) { steps.splice(i, 1); steps.splice(j - 1, 0, { ...f, moved: true, sec: steps[j - 1] ? steps[j - 1].sec : f.sec }); i--; }
  }
  return steps.map(({ moved, ...x }) => x);
}
const { closers } = require('./exclusive-alternatives');
function makeEnsure(db, conv) {
  const Q = db.quests, N = db.npcs, O = db.objects;
  const T = Object.fromEntries(conv.map((t) => [t.area_id, t]));
  const at = (p) => (p && T[p.zone] ? { m: T[p.zone].ui_map_id, x: +(p.x / 100).toFixed(4), y: +(p.y / 100).toFixed(4), zone: T[p.zone].target_name } : {});
  const firstSpawn = (list) => { for (const s of list || []) for (const p of s.spawns || []) if (p.x >= 0 && T[p.zone]) return { who: s.name, p, type: s.type }; return null; };
  function objSpawns(o) {
    const out = [];
    if (o.kind === 'kill') { if (N[o.npc]) out.push(...N[o.npc].spawns); }
    else if (o.kind === 'killcredit') { for (const id of o.npcs || []) if (N[id]) out.push(...N[id].spawns); }
    else if (o.kind === 'item') { for (const n of require('./world').droppers(o, N)) out.push(...n.spawns); for (const id of o.objectDrops || []) if (O[id]) out.push(...O[id].spawns); if (!out.length) for (const id of o.vendors || []) if (N[id]) out.push(...N[id].spawns); }
    else if (o.kind === 'object') { if (O[o.object]) out.push(...O[o.object].spawns); }
    else if (o.kind === 'explore') out.push(...(o.spawns || []));
    return out.filter((p) => p.x >= 0 && T[p.zone]);
  }
  function spot(spawns) {
    if (!spawns.length) return null;
    let best = spawns[0], bn = -1;
    for (const p of spawns) { const n = spawns.filter((q) => q.zone === p.zone && Math.abs(q.x - p.x) < 4 && Math.abs(q.y - p.y) < 4).length; if (n > bn) { bn = n; best = p; } }
    const near = spawns.filter((q) => q.zone === best.zone && Math.abs(q.x - best.x) < 4 && Math.abs(q.y - best.y) < 4);
    return { zone: best.zone, x: near.reduce((s, q) => s + q.x, 0) / near.length, y: near.reduce((s, q) => s + q.y, 0) / near.length };
  }
  const label = (o) => (o.kind === 'kill' ? 'Kill ' + ((N[o.npc] || {}).name || 'target') : o.kind === 'item' ? 'Collect ' + o.name : o.text || (o.kind === 'object' ? 'Use ' + ((O[o.object] || {}).name || 'object') : 'Explore'));
  const match = (o) => (o.kind === 'item' ? o.name : o.kind === 'kill' ? (N[o.npc] || {}).name : undefined);
  const norm = (s) => (s || '').toLowerCase();

  // two alternatives both picked up on the route, neither yours before it (the later one would not be offered): which
  // one goes. The first pick-up alone used to win, so a breadcrumb taken in one city could close the alternative whose
  // own chain the route went on with. Kept, in this order: one whose prerequisites the route meets; the one more of the
  // route's later pick-ups need (all of preGroup, or one of preSingle that the other doesn't also satisfy); the one worth
  // more XP; the first. -> the set of quests to drop
  function alternativeLosers(steps, ctx, inLog) {
    const done = new Set(ctx.done);
    const first = new Map(); // quest -> index of its first pick-up on the route
    steps.forEach((s, i) => { if (s.k === 'accept' && s.q > 0 && Q[s.q] && !inLog.has(s.q) && !done.has(s.q) && !first.has(s.q)) first.set(s.q, i); });
    const turned = new Set(steps.filter((s) => s.k === 'turnin' && s.q > 0).map((s) => s.q));
    const met = (p) => done.has(p) || turned.has(p);
    const viable = (id) => { const q = Q[id], one = q.preSingle || []; return (q.preGroup || []).every(met) && (!one.length || one.some(met)); };
    const needs = (id, other) => {
      let n = 0;
      for (const r of first.keys()) {
        if (r === id || r === other) continue;
        const R = Q[r];
        if ((R.preGroup || []).includes(id) || ((R.preSingle || []).includes(id) && !(R.preSingle || []).includes(other))) n++;
      }
      return n;
    };
    const better = (a, b) => {
      const va = viable(a), vb = viable(b);
      if (va !== vb) return va ? a : b;
      const na = needs(a, b), nb = needs(b, a);
      if (na !== nb) return na > nb ? a : b;
      const xa = Q[a].xp || 0, xb = Q[b].xp || 0;
      if (xa !== xb) return xa > xb ? a : b;
      return first.get(a) <= first.get(b) ? a : b;
    };
    const loser = new Set();
    // pairs in route order: an earlier pick-up that closes a later one
    const order = [...first.keys()].sort((a, b) => first.get(a) - first.get(b));
    for (let j = 0; j < order.length; j++) {
      const b = order[j];
      if (loser.has(b)) continue;
      const cl = new Set(closers(Q, Q[b]));
      for (let i = 0; i < j; i++) {
        const a = order[i];
        if (loser.has(a) || !cl.has(a)) continue;
        loser.add(better(a, b) === a ? b : a);
        if (loser.has(b)) break;
      }
    }
    return loser;
  }

  // ctx (optional): { done: quests completed before the route, active: quests in your log } - for the prerequisite sweep
  return function ensureSteps(steps, ctx) {
    // a flight that's followed by errands somewhere else (Stormwind books before 'Fly to Redridge'): do the errands
    // first, then fly - otherwise the card sends you away from the city you're standing in
    steps = flyLater(steps);
    // a quest picked up on this route but never handed in on it (its turn-in is in a zone this route doesn't go to):
    // not worth carrying - leave it out entirely. Bonus items and books have no turn-in and are kept.
    const turned = new Set(steps.filter((s) => s.k === 'turnin' && s.q > 0).map((s) => s.q));
    const orphan = new Set(steps.filter((s) => s.k === 'accept' && s.q > 0 && !turned.has(s.q)).map((s) => s.q));
    // a "where next?" choice point (_choice, set by campaign.js on the first step of a zone) is a step, not a number:
    // when the step it is on goes, it moves to the step that takes its place, so the prompt stays at the zone boundary
    const moveChoice = (from, to) => { if (from && from._choice && to && !to._choice) to._choice = from._choice; };
    if (orphan.size) {
      const gone = (s) => s.q > 0 && orphan.has(s.q) && (s.k === 'accept' || s.k === 'obj');
      for (let i = steps.length - 1; i >= 0; i--) if (gone(steps[i]) && steps[i]._choice) { const j = steps.findIndex((s, k) => k > i && !gone(s)); if (j >= 0) moveChoice(steps[i], steps[j]); }
      steps = steps.filter((s) => !gone(s));
    }
    // a pick-up whose prerequisites aren't met by then (all of preGroup, one of preSingle: done before the route, or
    // handed in earlier on it) - the legs are planned one zone at a time, and across them a pick-up could land before its
    // prerequisite's hand-in (The Black Shield before James Hyal); the audit counted each, and a plan with the elite
    // fixes was held back for two more of them. Out goes the quest, all its steps; what it unlocked goes the same way
    let prereqDropped = 0;
    if (ctx && ctx.done) {
      const have = new Set(ctx.done), inLog = new Set((ctx.active || []).map(Number)), drop = new Set();
      // ...and a pick-up whose alternative (the quest's exclusive list: In Search of Menara Voidrender from Briarthorn
      // or from Demisette Cloyce) is done before the route, in your log, or taken earlier on it: the game no longer
      // offers it. Legs planned one zone at a time each saw only their own (tester: sent to Briarthorn for it, done)
      // (through closers, exclusive-alternatives.js: a quest's own prerequisite in that list does not close it)
      const taken = new Set([...ctx.done, ...inLog]);
      const loser = alternativeLosers(steps, ctx, inLog);
      for (const s of steps) {
        if (!(s.q > 0)) continue;
        if (s.k === 'accept' && !inLog.has(s.q) && !drop.has(s.q) && Q[s.q]) {
          const q = Q[s.q], g = q.preGroup || [], one = q.preSingle || [];
          if (!(g.every((p) => have.has(p)) && (!one.length || one.some((p) => have.has(p))))) drop.add(s.q);
          else if (loser.has(s.q) || closers(Q, q).some((e) => taken.has(e))) drop.add(s.q);
          else taken.add(s.q);
        }
        if (s.k === 'turnin' && !drop.has(s.q)) have.add(s.q);
      }
      if (drop.size) {
        const gone = (s) => s.q > 0 && drop.has(s.q) && (s.k === 'accept' || s.k === 'obj' || s.k === 'turnin');
        for (let i = steps.length - 1; i >= 0; i--) if (gone(steps[i]) && steps[i]._choice) { const j = steps.findIndex((s, k) => k > i && !gone(s)); if (j >= 0) moveChoice(steps[i], steps[j]); }
        steps = steps.filter((s) => !gone(s));
        prereqDropped = drop.size;
      }
    }
    const byQ = new Map();
    steps.forEach((s, i) => { if (s.q && s.q > 0) { const r = byQ.get(s.q) || { first: i, accept: false, objs: [], turnin: -1 }; if (s.k === 'accept') r.accept = true; if (s.k === 'obj') r.objs.push(s); if (s.k === 'turnin' && r.turnin < 0) r.turnin = i; byQ.set(s.q, r); } });
    const before = new Map(); // index -> steps to insert before it
    // an added step carries the level you are at there (the step it goes before), like every other step - the audit
    // and the card read it
    const add = (i, s) => { if (s.lvl === undefined && steps[i] && steps[i].lvl) s.lvl = steps[i].lvl; if (!before.has(i)) before.set(i, []); before.get(i).push(s); };
    let added = 0;
    for (const [qid, r] of byQ) {
      const q = Q[qid]; if (!q) continue;
      const sec = steps[r.first].sec;
      if (!r.accept) {
        const g = firstSpawn(q.starters.filter((s) => s.type === 'npc')) || firstSpawn(q.starters);
        // a starter with no place in the data (the Tome of Valor: an item with no drops listed) - take it where the quest's
        // first step is, not nowhere (a step with no map gets no travel step before it: Ashenvale straight to Stormwind)
        const f = steps[r.first], item = q.starters.find((s) => s.type === 'item');
        const place = g ? at(g.p) : f && f.m ? { m: f.m, x: f.x, y: f.y, zone: f.zone } : {};
        add(r.first, { k: 'accept', q: qid, name: q.name, npc: g && g.type === 'npc' ? g.who : !g && f && f.npc ? f.npc : undefined, r: 6, level: q.level, note: g && g.type !== 'npc' ? 'Starts from an item: ' + g.who : !g && item ? 'Starts from an item: ' + item.name + (f && f.npc ? ' (' + f.npc + ' has it for you)' : '') : undefined, ...place, sec, ensured: true });
        added++;
      }
      if (r.turnin >= 0) {
        q.objectives.forEach((o) => {
          const m = norm(match(o)), lab = norm(label(o));
          // the planner labels a step by the objective's own text when it has one ("Speak with Ichman's Location Discovered"
          // for kill credit on a friendly trigger): that's the same objective, not a missing one (it was walked twice)
          const ot = norm(o.text);
          const have = r.objs.some((s) => (m && (norm(s.match) === m || norm(s.text).includes(m))) || norm(s.text).startsWith(lab) || (ot && norm(s.text).includes(ot)));
          if (have) return;
          // a spell to cast (done wherever you are) or an objective with no place: no step of its own - the hand-in shows
          // what's left from your quest log (two placeless "Explore" steps for The Goddess Provides could never tick)
          if (o.kind === 'spell') return;
          if (o.kind === 'item' && commonDrop(o)) return; // nor a common drop: the hand-in says to bring it
          const p = spot(objSpawns(o));
          if (!p) return;
          add(r.turnin, { k: 'obj', q: qid, name: q.name, text: label(o), match: match(o), loot: o.kind === 'item' || undefined, r: 40, level: q.level, ...(p ? at(p) : {}), sec: steps[r.turnin].sec, ensured: true });
          added++;
        });
      }
    }
    const out = [];
    steps.forEach((s, i) => { for (const x of before.get(i) || []) out.push(x); out.push(s); });
    // escorts: the NPC walks off with whoever takes the quest, so it often isn't there to give it
    for (const s of out) {
      const q = s.q && Q[s.q];
      // the quest's words say escort. (The scripted-event flag, special & 2, is on escorts, fights and explorations
      // alike: The Missing Diplomat's fight with Tapoke Jahn got "keep them alive", and so did The Master's Glaive)
      const words = ((q && q.text) || []).join(" ") + " " + ((q && q.objectives) || []).map((o) => o.text || "").join(" ");
      // "protect" / "accompany" only as the instruction that opens a sentence ("Protect Kinelory until..."): in the
      // middle of one it was a kill quest's ("...any Horde filth that may attempt to protect him")
      const escort = q && /\bescort|(^|[.!?]\s+)(protect|accompany)\b|keep .{0,30}\balive|show .{0,30}\bthe way|safely through/i.test(words.trim());
      if (!escort) continue;
      if (s.k === "accept") {
        const who = s.npc || (q.starters[0] && q.starters[0].name) || "the NPC";
        const tip = "Escort: " + who + " leaves with whoever takes this. If they aren't here, wait for the respawn (a few minutes) - or join a group that's already on it and ask for a share.";
        s.note = s.note && !/Escort:/.test(s.note) ? s.note + "  ·  " + tip : tip;
        s.warn = true;
      } else if (s.k === "obj") {
        const tip = "Stay close and keep them alive - if they die, abandon and take it again.";
        if (!s.note) s.note = tip;
      }
    }
    // any two steps in a row in different zones get a travel step between them (whatever put them there)
    const travelK = (x) => x.k === "fly" || x.k === "hearth" || x.k === "train";
    // a step put back above for a quest already in your log (its pick-up, an objective you'd finished) is done the moment
    // the route loads: marked inLog (the audit reads it too - lint-route.js), no trip to it, and the steps around it are
    // measured from each other. Six flights Stormwind - Duskwood - Wetlands - Stormwind - ... opened a plan made in
    // Stormwind with three hand-ins ready (tester, 2026-11-13)
    const inLogQ = new Set(((ctx && ctx.active) || []).map(Number));
    for (const x of out) if (x.ensured && x.q > 0 && inLogQ.has(x.q)) x.inLog = true;
    // (a choice point on the first step in the new zone moves to that travel step: you choose before you go)
    let prev = null;
    for (let i = 0; i < out.length; i++) {
      const q = out[i];
      if (q.inLog) continue;
      const p = prev; prev = q;
      if (!p || travelK(p) || travelK(q) || !(p.m && q.m) || p.m === q.m) continue;
      const f = { k: "fly", to: q.m, dest: q.zone, text: q.zone, sec: q.sec, note: "Fly, or ride if it is close." };
      if (q._choice) { f._choice = q._choice; delete q._choice; }
      out.splice(i, 0, f); i++;
    }
    // never two travel steps to the same place in a row (fly X then fly X, or fly X then hearth X)
    // and no hearth straight into a flight elsewhere: the stop the hearth was for was left out above, so it leads nowhere
    // (you keep the stone for later instead)
    // (a choice point on the travel step that goes moves to the one that stays)
    for (let i = out.length - 1; i > 0; i--) { const p = out[i - 1], q = out[i]; if ((p.k === "fly" || p.k === "hearth") && q.k === "fly" && !q.boat && !p.boat && (p.to === q.to || p.dest === q.dest)) { moveChoice(q, p); out.splice(i, 1); } else if (p.k === "fly" && !p.boat && q.k === "hearth" && (p.to === q.to || String(q.dest || "").startsWith(String(p.dest || "~")))) { moveChoice(p, q); out.splice(i - 1, 1); } else if (p.k === "hearth" && p.bindMap && q.k === "fly" && !q.boat && q.to && q.to !== p.bindMap) { moveChoice(p, q); out.splice(i - 1, 1); }
      // a flight straight into a flight somewhere else: the first leads nowhere (the stops it was for were left out above -
      // "fly to the Badlands" then "fly to Ironforge")
      else if (p.k === "fly" && q.k === "fly" && !p.boat && !q.boat) { moveChoice(p, q); out.splice(i - 1, 1); } }
    out.forEach((s, i) => { s.id = i + 1; });
    out.added = added; out.dropped = orphan.size + prereqDropped;
    // where a leg's choice point ended up (step id), 0 if no step carries it
    out.choiceAt = (leg) => out.findIndex((s) => s._choice === leg) + 1;
    return out;
  };
}
module.exports = { makeEnsure, flyLater, commonDrop };
