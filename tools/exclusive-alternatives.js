// Same-name alternatives the quest data does not mark as exclusive: one quest offered by several people in different
// towns, all of them leading to the same place, of which a character can do only one. Doing one closes the others in
// game, but QuestieDB only says so where its own exclusiveTo field lists them; where it doesn't, the planner and the
// addon offered the other one too (a warlock who had taken In Search of Menara Voidrender from Demisette Cloyce in
// Stormwind was sent to Briarthorn in Ironforge for the same quest - tester).
//
// A group is marked when its quests have
//   - the same name, race mask, class mask and level (the same quest, offered in several places),
//   - different givers, each an NPC (an object or an item that starts a quest is one thing you find; same-name objects
//     like the Beached Sea Turtles of Darkshore are separate quests, all of them doable),
//   - the same destination: the same next quest (nextInChain), or the same hand-in NPC (Remote Contact from Andron
//     Gant, Jes'rimon or Magatha Grimtotem, all to Jediga) - and not two different next quests, nor each handed back
//     to its own giver (see alternatives() below),
//   - not breadcrumbs for one quest (Seeking Strahad from Gan'rul Bloodeye or Carendin Halgar, both leading to
//     Strahad's quest): those close once that quest is yours (route2.js, Engine.Breadcrumbed), and the data says no
//     more than that - while neither is handed in, the game may well offer both,
//   - no prerequisite link either way, through the whole chain (parts of one chain that share a name, like Return to
//     Chillwind Camp twice in the Scourge Cauldron chain, are a chain, not alternatives),
// and none of them repeatable (the Cenarion plants, the Argent Dawn scourgestones, the cloth donations: each giver
// takes its own, again and again). A quest tools/forever-overrides.json gives "notAlternative": true is never marked.
//
// The marks are a guess from the data's shape, not something QuestieDB says: --dry lists them, to check on Wowhead
// Forever. Each run starts from scratch (the links it added before, kept in exclusiveMarked, come off first), so a
// quest given notAlternative later loses its marks on the next run, whichever way the data is rebuilt.
//
// build-db.js runs this on every build, apply-overrides.js on the quick patch of an existing db.json; or run this
// file directly to mark one:
// usage: node tools/exclusive-alternatives.js [db.json] [out.json] [--report report.md]
//   (no out.json: db.json is rewritten in place; --dry: only list the groups)
const fs = require('fs');
const path = require('path');

const REPEATABLE = 1; // QuestieDB specialFlags: 1 = repeatable

// the quests that close q for good once done or in your log: its exclusive list, less the quests that lead to it.
// QuestieDB lists some of those too, against its own prerequisites: Stars of Elune needs one of Returning Home and five
// more (preSingle) and names the same six in exclusiveTo - read as written, nobody could ever take it. A quest that
// opens q (a prerequisite, a breadcrumb for it, the step before it) does not close it; the other way round (Returning
// Home closed once Stars of Elune is yours) stands. Everything that reads the exclusive list goes through this.
function closers(Q, q) {
  if (!q || !(q.exclusive || []).length) return [];
  const leadsHere = new Set([...(q.preGroup || []), ...(q.preSingle || []), ...(q.breadcrumbs || [])].filter((x) => x > 0));
  return q.exclusive.filter((e) => e > 0 && e !== q.id && !leadsHere.has(e) && !(Q[e] && (Q[e].nextInChain === q.id || Q[e].breadcrumbFor === q.id)));
}

// every quest that must (or, for "any one of", may) come before q, through the whole chain
function ancestorsOf(Q) {
  const before = {};
  const add = (q, p) => { if (p && p > 0 && Q[p] && p !== q) (before[q] = before[q] || new Set()).add(+p); };
  for (const q of Object.values(Q)) {
    for (const p of [...(q.preGroup || []), ...(q.preSingle || [])]) add(q.id, Math.abs(p));
    if (q.nextInChain) add(q.nextInChain, q.id);
    if (q.breadcrumbFor) add(q.breadcrumbFor, q.id);
    for (const b of q.breadcrumbs || []) add(q.id, b);
    if (q.parent) add(q.id, q.parent);
    for (const c of q.children || []) add(c, q.id);
  }
  const memo = {};
  const walk = (id) => {
    if (memo[id]) return memo[id];
    const seen = memo[id] = new Set(); // (set first: a loop in the data ends here)
    const stack = [...(before[id] || [])];
    while (stack.length) { const p = stack.pop(); if (seen.has(p)) continue; seen.add(p); for (const x of before[p] || []) stack.push(x); }
    return seen;
  };
  return walk;
}

// -> [{ name, ids, added: [[a, b], ...] }]: the groups found, and the exclusive links each one adds (a -> b)
function find(db) {
  const Q = db.quests;
  const before = ancestorsOf(Q);
  const npcGivers = (q) => (q.starters || []).length > 0 && q.starters.every((s) => s.type === 'npc');
  const ok = (q) => !q.notAlternative && !q.notInForever && !((q.special || 0) & REPEATABLE) && npcGivers(q);
  const buckets = {};
  for (const q of Object.values(Q)) {
    if (!q.name || !ok(q)) continue;
    const k = [q.name, q.races || 0, q.classes || 0, q.level || 0].join('\u0001');
    (buckets[k] = buckets[k] || []).push(q);
  }
  const ids = (list) => (list || []).map((e) => e.type + ':' + e.id);
  const shares = (a, b) => a.some((x) => b.includes(x));
  const leadsTo = (q) => [q.nextInChain, q.breadcrumbFor].filter((x) => x && x > 0);
  // the quests each quest is a breadcrumb for (its own breadcrumbFor, or a quest that lists it among its breadcrumbs)
  const crumbFor = {};
  const crumb = (b, t) => { if (b > 0 && t > 0) (crumbFor[b] = crumbFor[b] || new Set()).add(t); };
  for (const q of Object.values(Q)) { crumb(q.id, q.breadcrumbFor); for (const b of q.breadcrumbs || []) crumb(b, q.id); }
  const alternatives = (a, b) => {
    if (shares(ids(a.starters), ids(b.starters))) return false; // the same giver twice: not a choice of places
    // breadcrumbs for one quest: the breadcrumb rule closes them once that quest is yours, nothing to mark (above)
    if ([...(crumbFor[a.id] || [])].some((t) => crumbFor[b.id] && crumbFor[b.id].has(t))) return false;
    if (before(a.id).has(b.id) || before(b.id).has(a.id)) return false; // one chain
    const ea = ids(a.finishers), eb = ids(b.finishers);
    // each handed back to the one who gave it: that person's own errand (A Donation of Runecloth to each capital's
    // quartermaster, for that faction's standing), not a choice of where to take one quest
    if (ea.length && eb.length && shares(ea, ids(a.starters)) && shares(eb, ids(b.starters))) return false;
    // both lead on, to different quests: two chains that start alike (Call of Earth from Canaga Earthcaller in Durotar
    // goes on to 1518, from Seer Ravenfeather in Mulgore to 1521 - each race's own totem chain)
    const la = leadsTo(a), lb = leadsTo(b);
    if (la.length && lb.length && !shares(la, lb)) return false;
    const sameEnd = ea.length > 0 && ea.length === eb.length && ea.every((x) => eb.includes(x));
    return sameEnd || shares(la, lb);
  };
  const groups = [];
  for (const list of Object.values(buckets)) {
    if (list.length < 2) continue;
    // connected pieces of the "alternatives" relation
    const seen = new Set();
    for (const q of list) {
      if (seen.has(q.id)) continue;
      const comp = [q], stack = [q]; seen.add(q.id);
      while (stack.length) {
        const a = stack.pop();
        for (const b of list) if (!seen.has(b.id) && alternatives(a, b)) { seen.add(b.id); comp.push(b); stack.push(b); }
      }
      if (comp.length < 2) continue;
      // every pair must hold (a chain bent into a piece through a third quest is not a set of alternatives)
      if (!comp.every((a) => comp.every((b) => a === b || !(before(a.id).has(b.id) || before(b.id).has(a.id))))) continue;
      const added = [];
      for (const a of comp) for (const b of comp) if (a !== b && !(a.exclusive || []).includes(b.id)) added.push([a.id, b.id]);
      if (added.length) groups.push({ name: q.name, ids: comp.map((x) => x.id).sort((x, y) => x - y), added });
    }
  }
  return groups.sort((a, b) => a.ids[0] - b.ids[0]);
}

// marks them in db (both ways); returns the groups, for the build's log. From scratch: the links an earlier run added
// (exclusiveMarked) come off first, so a rerun on a patched db.json gives what a full build gives - a quest given
// notAlternative since, or one whose giver or hand-in an override changed, keeps no stale mark
function mark(db) {
  for (const q of Object.values(db.quests)) {
    if (!q.exclusiveMarked) continue;
    const old = new Set(q.exclusiveMarked);
    q.exclusive = (q.exclusive || []).filter((e) => !old.has(e));
    delete q.exclusiveMarked;
  }
  const groups = find(db);
  for (const g of groups) for (const [a, b] of g.added) {
    const q = db.quests[a];
    q.exclusive = [...(q.exclusive || []), b];
    q.exclusiveMarked = [...(q.exclusiveMarked || []), b];
  }
  return groups;
}

// one line per group, for review: who gives each, where it goes
function describe(db, g) {
  const one = (id) => {
    const q = db.quests[id];
    const who = (l) => (l || []).map((e) => e.name).join('/') || '?';
    return `${id} ${who(q.starters)} -> ${who(q.finishers)}${q.nextInChain ? ' (then ' + q.nextInChain + ')' : ''}`;
  };
  const q0 = db.quests[g.ids[0]];
  return `${g.name} [level ${q0.level}, races ${q0.races || 'all'}, classes ${q0.classes || 'all'}]: ${g.ids.map(one).join('; ')}`;
}

module.exports = { find, mark, describe, closers };

if (require.main === module) {
  const argv = process.argv.slice(2);
  const dry = argv.includes('--dry');
  const ri = argv.indexOf('--report'), report = ri >= 0 ? argv[ri + 1] : null;
  const pos = argv.filter((a, i) => !a.startsWith('--') && !(ri >= 0 && i === ri + 1));
  const f = pos[0] || path.join(__dirname, '..', 'qdb', 'db.json');
  const out = pos[1] || f;
  const db = JSON.parse(fs.readFileSync(f, 'utf8'));
  // (marked from scratch either way: --dry on a db.json that has them still lists every group)
  const groups = mark(db);
  const lines = groups.map((g) => describe(db, g));
  if (report) fs.writeFileSync(report, ['# Same-name alternatives marked exclusive (tools/exclusive-alternatives.js)', '', `${groups.length} groups, from ${f}`, '', ...lines.map((l) => '- ' + l)].join('\n') + '\n');
  console.log(lines.join('\n'));
  console.log(`${groups.length} groups of alternatives ${dry ? 'found' : 'marked exclusive'}`);
  // (written also with no group: an earlier run's marks may have come off)
  if (!dry) { const tmp = out + '.tmp'; fs.writeFileSync(tmp, JSON.stringify(db)); fs.renameSync(tmp, out); }
}
