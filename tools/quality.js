// Quest quality: how frustrating a quest is, what its rewards are worth to this character, and how fun/varied it is.
// makeQuality({ quests, npcs, objects, items, cls, nav? }) -> (q, level) => { frustration, reasons[], rewardValue, rewardText, funValue, tags[] }
const CLASS_ARMOR = { warlock: [0, 1], mage: [0, 1], priest: [0, 1], rogue: [0, 1, 2], druid: [0, 1, 2], hunter: [0, 1, 2], shaman: [0, 1, 2, 6], warrior: [0, 1, 2, 3, 6], paladin: [0, 1, 2, 3, 6] };
const CLASS_WEAPON = { warlock: [7, 10, 15, 19], mage: [7, 10, 15, 19], priest: [4, 10, 15, 19], druid: [4, 5, 10, 13, 15], shaman: [0, 1, 4, 5, 10, 13, 15],
  rogue: [0, 2, 3, 4, 7, 13, 15, 16, 18], hunter: [0, 1, 2, 3, 6, 7, 8, 10, 13, 15, 16, 18], warrior: [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 13, 15, 16, 18], paladin: [0, 1, 4, 5, 6, 7, 8] };

// verdicts: { itemID: d } from the game (the addon's Gear.lua compares each gear reward with what you wear in that slot,
// weighted for your class, counting an enchant you'd lose): d <= 0 means not an upgrade for you, so no reward value
function makeQuality({ quests: Q, npcs: N, objects: O, items: I, cls, verdicts }) {
  // invert item -> rewarding quests
  const rewardsOf = {};
  for (const [id, it] of Object.entries(I)) {
    const r = it[6]; if (!r) continue;
    for (const q of (Array.isArray(r) ? r : Object.values(r))) (rewardsOf[q] = rewardsOf[q] || []).push(+id);
  }
  const armorOk = new Set(CLASS_ARMOR[cls] || [0, 1]), weaponOk = new Set(CLASS_WEAPON[cls] || []);
  // chain depth (how many quests lead into / out of this one)
  const depthCache = {};
  const chainLen = (id, seen = new Set()) => {
    if (depthCache[id] !== undefined) return depthCache[id];
    if (seen.has(id)) return 0; seen.add(id);
    const q = Q[id]; if (!q) return 0;
    const pre = [...(q.preSingle || []), ...(q.preGroup || [])];
    const d = pre.length ? 1 + Math.max(...pre.map((p) => chainLen(p, seen))) : 0;
    return (depthCache[id] = d);
  };
  const followers = {};
  for (const q of Object.values(Q)) for (const p of [...(q.preSingle || []), ...(q.preGroup || [])]) (followers[p] = followers[p] || []).push(q.id);

  return function quality(q, level) {
    const reasons = [], tags = [];
    let fr = 0;
    for (const o of q.objectives || []) {
      if (o.kind === 'item' && o.rates) {
        const rs = Object.values(o.rates).filter((r) => r > 0.5 && r < 79).map((r) => r / 100);
        const best = rs.length ? Math.max(...rs) : null;
        if (best !== null && best < 0.15) { fr += 0.5; reasons.push(`drop rate ~${Math.round(best * 100)}%`); }
        else if (best !== null && best < 0.3) { fr += 0.2; reasons.push(`drop rate ~${Math.round(best * 100)}%`); }
      }
      // few spawns for what's needed: waiting on respawns / fighting other players for them
      const ids = o.kind === 'kill' ? [o.npc] : o.kind === 'item' ? o.npcDrops : [];
      const spawns = ids.reduce((s, id) => s + ((N[id] && N[id].spawns.filter((p) => !p.instance).length) || 0), 0);
      const need = (/(\d+)/.exec((q.text || []).join(' ')) || [0, 1])[1];
      if (ids.length && spawns > 0 && spawns <= 2 && (N[ids[0]] && N[ids[0]].rank !== 1)) { fr += 0.25; reasons.push('single-spawn target (respawn waits)'); }
      if (o.kind === 'object' || (o.kind === 'item' && o.objectDrops && o.objectDrops.length && !o.npcDrops.length)) {
        const objIds = o.kind === 'object' ? [o.object] : o.objectDrops;
        const os = objIds.reduce((s, id) => s + ((O[id] && O[id].spawns.length) || 0), 0);
        if (os > 0 && os <= 3 && +need > 3) { fr += 0.3; reasons.push('few loot spots for many items'); }
      }
      if (o.kind === 'explore' && /escort|protect|accompany|lead/i.test(o.text || '')) { fr += 0.3; reasons.push('escort (can fail)'); tags.push('escort'); }
      // elites crowding the objective (not dungeon content)
      if (ids.length) {
        const pts = ids.flatMap((id) => (N[id] ? N[id].spawns.filter((p) => !p.instance) : []));
        if (pts.length) {
          const cx = pts.reduce((s, p) => s + p.x, 0) / pts.length, cy = pts.reduce((s, p) => s + p.y, 0) / pts.length, z = pts[0].zone;
          let elites = 0;
          for (const n of Object.values(N)) if (n && n.rank === 1 && n.friendly !== 'A' && n.friendly !== 'AH') for (const p of n.spawns) if (p.zone === z && Math.abs(p.x - cx) < 4 && Math.abs(p.y - cy) < 4) elites++;
          if (elites >= 4 && !(N[ids[0]] && N[ids[0]].rank === 1)) { fr += 0.3; reasons.push(`${elites} elites around the objective`); }
        }
      }
    }
    // rewards: best usable choice for this class, as an XP-equivalent value
    let rewardValue = 0, rewardText = null, rewardItem = null;
    const expected = level + 3;
    for (const iid of rewardsOf[q.id] || []) {
      const it = I[iid]; if (!it) continue;
      const ilvl = it[9] || 0, cl = it[12], sub = it[13], name = it[1];
      let v = 0, why = null;
      if (cl === 1) { v = 1800; why = 'bag'; }
      else if (cl === 4 && armorOk.has(sub ?? 0)) { const d = ilvl - expected; if (d >= -3) { v = 500 + 140 * Math.max(0, d + 3); why = sub === 0 ? 'jewelry/trinket' : 'armor upgrade'; } }
      else if (cl === 2 && weaponOk.has(sub)) { const d = ilvl - expected; if (d >= -3) { v = 900 + 200 * Math.max(0, d + 3); why = 'weapon upgrade'; } }
      const vd = verdicts && (cl === 4 || cl === 2) ? verdicts[iid] : undefined;
      if (v && vd !== undefined && vd <= 0) continue; // the game says it isn't better than what you wear
      if (v && vd !== undefined) why = 'upgrade for you';
      if (v > rewardValue) { rewardValue = v; rewardText = `${name} (${why}, ilvl ${ilvl})`; rewardItem = cl === 4 || cl === 2 ? +iid : null; }
    }
    if (rewardValue) tags.push('reward');
    // fun / variety: story chains, Forever-new content, dungeons
    const depth = chainLen(q.id), next = (followers[q.id] || []).length;
    let funValue = 0;
    if (depth + (next ? 1 : 0) >= 2) { funValue += 0.15; tags.push('story chain'); }
    if (q.id >= 79000 && q.id < 100000) { funValue += 0.15; tags.push('Forever'); }
    return { frustration: Math.min(1.5, fr), reasons, rewardValue, rewardText, rewardItem, funValue, tags };
  };
}
module.exports = { makeQuality };

if (require.main === module) {
  const db = require(process.argv[2]); const items = require(process.argv[3]);
  const qual = makeQuality({ ...db, items, cls: 'warlock' });
  for (const id of [9, 22, 36, 38, 64, 102, 103, 151, 152, 153, 155, 166, 214, 92909, 92745, 104, 12]) { const q = db.quests[id]; const r = qual(q, 17); console.log(String(id).padEnd(6), q.name.padEnd(32), 'frust', r.frustration.toFixed(2), r.reasons.join('; ').padEnd(40), '| reward', r.rewardValue, r.rewardText || '', '| fun', r.funValue, r.tags.join(',')); }
}
