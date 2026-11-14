// Quest chains as objects (docs: the design for zones and chains, stage 2): a chain is a set of quests joined by
// prerequisites (QuestieDB preGroup / preSingle - a preSingle of more than two is a hub, not a link), two quests at least. Its head is the part with no prerequisite inside
// the chain (the lowest level, then the lowest id, when there are several); it is named after the head. The parts are
// listed in level order (then id), each with the zone its giver stands in.
// Used by gen-quest-data.js (ns.CHAINS for the addon) and kept in step with chain-report.js's idea of a chain.
// usage: const { buildChains } = require('./chains'); buildChains(db.quests, { zoneOf }) -> [{ id, name, q: [...], z: [...] }]

function buildChains(Q, opts = {}) {
  const zoneOf = opts.zoneOf || ((q) => q.zone || 0);
  const take = opts.take || ((q) => q && q.xp > 0 && q.level > 0 && q.level <= 60 && !(q.special & 1));
  // undirected links: a quest and each of its prerequisites
  const links = new Map();
  const link = (a, b) => { (links.get(a) || links.set(a, new Set()).get(a)).add(b); (links.get(b) || links.set(b, new Set()).get(b)).add(a); };
  for (const q of Object.values(Q)) {
    if (!take(q)) continue;
    // "any one of" a long list is a hub (a starting area's quests, one per class), not a chain: only short ones link
    const single = (q.preSingle || []).length <= 2 ? (q.preSingle || []) : [];
    for (const p of [...(q.preGroup || []), ...single]) if (take(Q[p])) link(q.id, +p);
  }
  // connected groups of two or more
  const seen = new Set(), out = [];
  for (const start of links.keys()) {
    if (seen.has(start)) continue;
    const group = [], stack = [start];
    seen.add(start);
    while (stack.length) {
      const x = stack.pop(); group.push(x);
      for (const y of links.get(x) || []) if (!seen.has(y)) { seen.add(y); stack.push(y); }
    }
    if (group.length < 2) continue;
    const inGroup = new Set(group);
    const parts = group.map((id) => Q[id]).sort((a, b) => a.level - b.level || a.id - b.id);
    const heads = parts.filter((q) => ![...(q.preGroup || []), ...(q.preSingle || [])].some((p) => inGroup.has(+p)));
    const head = heads[0] || parts[0];
    out.push({ id: head.id, name: head.name, q: parts.map((q) => q.id), z: parts.map((q) => zoneOf(q) || 0) });
  }
  return out.sort((a, b) => a.id - b.id);
}

module.exports = { buildChains };
