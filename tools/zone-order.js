// A guide-like zone order for a faction trunk (docs/research/shared-trunk.md): instead of choosing each next zone
// greedily - the trunk zig-zagged over ~130 short legs, Duskwood five times - each zone is visited once per chunk of its
// quests, at the level that chunk comes into reach, the way written leveling guides go (Duskwood 20-26, again 27-31).
//   - a zone's quests: the ones every race of the faction may take (world.canTake <faction>, 'none'), with XP, not all
//     elite, not a dungeon's, from the join level to 60
//   - chunks: quest levels in runs of cfg width (6) - a chunk with too few quests (minChunk, 6) joins its neighbour
//   - a visit's level: the chunk's lowest quest level minus the gate (world.minLevelFor), never below the join level
//   - order: by visit level; at the same level, the zone on the continent you are already on first
// The order goes to the campaign as forceLegs: it plans each visit for real, and one that turns out not worth doing
// is dropped and said why (campaign.js forceQueue), so the order is a plan to follow, not a promise.
// usage: node tools/zone-order.js <alliance|horde> [--join 20] [--width 6] [--min-chunk 6]  -> JSON array of area ids
const fs = require('fs'), path = require('path');
const W = require('./world');
const ROOT = path.join(__dirname, '..');
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf('--' + k); return i >= 0 ? +args[i + 1] : d; };
// zoneVisits(faction, { join, width, minChunk }) -> [{ z, at, n }] in order (also the CLI below)
function zoneVisits(faction, o = {}) {
const J = o.join ?? 20, WIDTH = o.width ?? 6, MIN_CHUNK = o.minChunk ?? 6;
const db = JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'db.json'), 'utf8'));
const conv = JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'conversion.json'), 'utf8')).geometry.transforms;
const zoneName = Object.fromEntries(conv.map((t) => [t.area_id, t.target_name]));
const continentOf = Object.fromEntries(conv.map((t) => [t.area_id, t.instance_id ?? t.continent ?? t.map_id]));
let dungeonAreas = new Set();
try { dungeonAreas = new Set(Object.keys(require('./dungeons').loadDungeons(path.join(ROOT, 'qdb', 'support', 'Forever', 'Zones', 'dungeons.lua')).list).map(Number)); } catch (e) {}
const N = db.npcs || {};
const allElite = (q) => { const ids = (q.objectives || []).flatMap((o) => (o.kind === 'kill' ? [o.npc] : o.npcs || [])); const ns = ids.map((i) => N[i]).filter(Boolean); return ns.length > 0 && ns.every((n) => n.rank >= 1 && n.rank <= 3); };
// the zone a quest is done in: where its giver stands (the quest's own zone field is sometimes a sort, not a place)
const giverZone = (q) => { for (const s of q.starters || []) for (const sp of s.spawns || []) if (sp.x >= 0 && zoneName[sp.zone]) return sp.zone; return null; };
const byZone = {};
for (const q of Object.values(db.quests)) {
  if (!(q.xp > 0) || (q.special & 3) || q.skill || q.notInForever || q.level < J - 2 || q.level > 60) continue;
  if (!W.canTake(q, faction, 'none') || allElite(q)) continue;
  const z = giverZone(q);
  if (!z || W.CAPITAL_AREAS.has(z) || dungeonAreas.has(z) || W.START_ZONES.has(z)) continue;
  (byZone[z] = byZone[z] || []).push(q.level);
}
const visits = [];
for (const [z, levels] of Object.entries(byZone)) {
  levels.sort((a, b) => a - b);
  const chunks = [];
  for (const l of levels) { const c = chunks[chunks.length - 1]; if (c && l <= c.lo + WIDTH - 1) c.levels.push(l); else chunks.push({ lo: l, levels: [l] }); }
  // too-small chunks join the one before (or after, for the first)
  for (let i = chunks.length - 1; i >= 0; i--) if (chunks[i].levels.length < MIN_CHUNK && chunks.length > 1) { const into = chunks[i - 1] || chunks[i + 1]; into.levels.push(...chunks[i].levels); into.lo = Math.min(into.lo, chunks[i].lo); chunks.splice(i, 1); }
  for (const c of chunks) if (c.levels.length >= MIN_CHUNK) visits.push({ z: +z, at: Math.max(J, W.minLevelFor(c.lo)), n: c.levels.length });
}
visits.sort((a, b) => a.at - b.at || b.n - a.n);
// at the same visit level, stay on the continent you are on
const out = [];
let here = null;
while (visits.length) {
  const lvl = visits[0].at;
  const same = visits.filter((v) => v.at <= lvl + 1);
  const pick = same.find((v) => here != null && continentOf[v.z] === here) || same[0];
  out.push(pick); here = continentOf[pick.z];
  visits.splice(visits.indexOf(pick), 1);
}
return out.map((v) => ({ ...v, name: zoneName[v.z] }));
}
module.exports = { zoneVisits };
if (require.main === module) {
  const faction = (args[0] || '').toLowerCase();
  if (!W.FACTION_RACES[faction]) { console.error('usage: node tools/zone-order.js <alliance|horde> [--join 20]'); process.exit(2); }
  const out = zoneVisits(faction, { join: opt('join', 20), width: opt('width', 6), minChunk: opt('min-chunk', 6) });
  if (args.includes('--explain')) for (const v of out) console.error(`${String(v.at).padStart(2)}  ${v.name} (${v.n} quests)`);
  console.log(JSON.stringify(out.map((v) => v.z)));
}
