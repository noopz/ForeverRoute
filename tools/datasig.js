// A fingerprint of the quest data one planned leg can see, so a QuestieDB update re-plans only what it touched. The
// leg cache (campaign.js) used to be keyed on db.json's modification time: every update threw away every leg. Now each
// leg's key carries this, made from exactly what route2.js reads for those zones:
//   - every quest given or ended in the leg's zones: its whole record (level, races, prerequisites, objectives, XP...)
//   - for those quests: the quests that follow them and the ones that are breadcrumbs to them (route2's FOLLOW and
//     BREADCRUMB_OF are built from the whole database, but only these entries are ever asked about)
//   - the NPCs and objects those quests use (givers, enders, objective mobs and objects, item drops, vendors), with
//     their spawns, and how many quests each giver has (questCount decides which NPCs make a hub)
//   - the NPCs in the zones that make hubs without quests (innkeepers, flight masters)
//   - the items those quests reward (their value comes from items.json)
//   - global: the median XP per level (route2's fallback XP) and the dungeon list file
// A changed leg changes your level or quests done for the legs after it, so their keys change too and they're re-planned
// by construction: a delta rebuild gives the same plan as a full one (tools/test-delta.js checks that).
const fs = require('fs');
const crypto = require('crypto');
const h = (x) => crypto.createHash('sha1').update(typeof x === 'string' ? x : JSON.stringify(x)).digest('hex').slice(0, 20);
function make(db, items, dungeonFile) {
  const Q = db.quests, N = db.npcs, O = db.objects;
  // indexes built once: quests by the zones their givers/enders stand in, followers, breadcrumbs, quests per giver name
  const byZone = new Map(), follow = new Map(), crumbsTo = new Map(), questCount = {};
  const add = (m, k, v) => { if (!m.has(k)) m.set(k, new Set()); m.get(k).add(v); };
  for (const q of Object.values(Q)) {
    for (const s of [...(q.starters || []), ...(q.finishers || [])]) {
      for (const sp of s.spawns || []) add(byZone, sp.zone, q.id);
      if (s.type === 'npc') questCount[s.name] = (questCount[s.name] || 0) + 1;
    }
    for (const p of [...(q.preSingle || []), ...(q.preGroup || [])]) add(follow, p, q.id);
    for (const b of q.breadcrumbs || []) add(crumbsTo, b, q.id);
  }
  // the items a quest rewards: items.json lists, per item, the quests that reward it (field 6; quality.js inverts it)
  const rewardsOf = new Map();
  if (items) for (const [id, it] of Object.entries(items)) { const rr = it && it[6]; if (!rr) continue; for (const q of (Array.isArray(rr) ? rr : Object.values(rr))) add(rewardsOf, +q, +id); }
  const zoneNpcs = new Map(); // hub-makers without quests, by zone
  for (const n of Object.values(N)) if (n && /Innkeeper|Gryphon Master|Flight Master/.test(n.sub || '')) for (const sp of n.spawns || []) add(zoneNpcs, sp.zone, n.id);
  // route2's fallback XP: the median XP of quests within two levels
  const by = {}; for (const q of Object.values(Q)) if (q.xp && q.level > 0 && q.level <= 60) (by[q.level] = by[q.level] || []).push(q.xp);
  const med = []; for (let l = 1; l <= 60; l++) { const p = []; for (let d = -2; d <= 2; d++) if (by[l + d]) p.push(...by[l + d]); p.sort((a, b) => a - b); med.push(p.length ? p[p.length >> 1] : 0); }
  let dung = ''; try { dung = h(fs.readFileSync(dungeonFile, 'utf8')); } catch (e) {}
  const global = h({ med, dung });
  const memo = new Map();
  return function legSig(zones) {
    const key = [...new Set(zones)].sort((a, b) => a - b).join(',');
    if (memo.has(key)) return memo.get(key);
    const qs = new Set(); for (const z of key.split(',').map(Number)) for (const id of byZone.get(z) || []) qs.add(id);
    const npcs = new Set(), objs = new Set(), its = new Set(), parts = [];
    for (const id of [...qs].sort((a, b) => a - b)) {
      const q = Q[id];
      parts.push(q, [...(follow.get(id) || [])].sort(), [...(crumbsTo.get(id) || [])].sort());
      for (const s of [...(q.starters || []), ...(q.finishers || [])]) { if (s.type === 'npc') npcs.add(s.id); if (s.type === 'object') objs.add(s.id); }
      for (const o of q.objectives || []) {
        if (o.npc) npcs.add(o.npc); for (const x of o.npcs || []) npcs.add(x); for (const x of o.npcDrops || []) npcs.add(x);
        for (const x of o.vendors || []) npcs.add(x); if (o.object) objs.add(o.object); for (const x of o.objectDrops || []) objs.add(x);
        if (o.item) its.add(o.item);
      }
      for (const it of rewardsOf.get(id) || []) its.add(it);
    }
    for (const z of key.split(',').map(Number)) for (const id of zoneNpcs.get(z) || []) npcs.add(id);
    for (const id of [...npcs].sort((a, b) => a - b)) { const n = N[id]; parts.push(n || null, n ? questCount[n.name] || 0 : 0); }
    for (const id of [...objs].sort((a, b) => a - b)) parts.push(O[id] || null);
    if (items) for (const id of [...its].sort((a, b) => a - b)) parts.push(items[id] || null);
    const sig = h([global, h(parts)]);
    memo.set(key, sig);
    return sig;
  };
}
module.exports = { make };
