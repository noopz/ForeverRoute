// The backward look (docs/research/shared-trunk.md): where a plan has to grind, and what could fill it. For a planned
// path, band by band (a level at a time, from the top down): the XP that level needs, the XP the plan earned there
// (hand-ins and kills, from its steps), and what it ground. A level that was ground is a deficit band; for each, the
// quests that could have filled it - by kind - that the plan never handed in:
//   chain      a later part of a chain, at a level in the band's reach, whose head is lower (start it earlier)
//   away       a quest whose work is in another zone than its giver's
//   item       a quest started by an item
//   elite      all-elite objectives (a group)
//   dungeon    a dungeon's (a group run; never forced)
//   plain      anything else the plan skipped
// "In reach" for level L: the quest's level up to L + the gate (world.levelAbove), not below L - 6 (gray).
// usage: node tools/band-budget.js <plan folder with path-0.json and campaign.json> [--top 5]
const fs = require('fs'), path = require('path');
const W = require('./world');
const ROOT = path.join(__dirname, '..');
const dir = path.resolve(process.argv[2] || '.');
const TOP = +(process.argv[process.argv.indexOf('--top') + 1] || 5) || 5;
const plan = JSON.parse(fs.readFileSync(path.join(dir, 'path-0.json'), 'utf8'));
const cfg = JSON.parse(fs.readFileSync(path.join(dir, 'campaign.json'), 'utf8'));
const db = JSON.parse(fs.readFileSync(path.join(ROOT, cfg.db || 'qdb/db.json'), 'utf8'));
const Q = db.quests, N = db.npcs || {};
const race = cfg.race, klass = cfg.class;
const conv = JSON.parse(fs.readFileSync(path.join(ROOT, cfg.conversion || 'qdb/conversion.json'), 'utf8')).geometry.transforms;
const zoneName = Object.fromEntries(conv.map((t) => [t.area_id, t.target_name]));
let dungeonAreas = new Set();
try { dungeonAreas = new Set(Object.keys(require('./dungeons').loadDungeons(path.join(ROOT, 'qdb', 'support', 'Forever', 'Zones', 'dungeons.lua')).list).map(Number)); } catch (e) {}
// what the plan earned at each level: hand-ins at the level they happened, kills from the objective's own count
const handed = new Set(), earned = {}, ground = {};
let lvl = 1;
for (const s of plan.steps) {
  if (s.lvl) lvl = s.lvl;
  if (s.k === 'turnin' && s.q > 0 && Q[s.q]) { handed.add(s.q); earned[lvl] = (earned[lvl] || 0) + W.questXp(Q[s.q].xp || 0, Q[s.q].level, lvl); }
}
const log = fs.existsSync(path.join(dir, 'path-0.log')) ? fs.readFileSync(path.join(dir, 'path-0.log'), 'utf8') : '';
for (const m of log.matchAll(/-> grind in ([^:]+): level (\d+) -> (\d+), ~(\d+) min/g)) ground[+m[2]] = { zone: m[1], min: +m[4] };
const giverZone = (q) => { for (const s of q.starters || []) for (const sp of s.spawns || []) if (sp.x >= 0 && zoneName[sp.zone]) return sp.zone; return null; };
const O = db.objects || {};
// where a quest's work is: its mobs' and objects' spawns (an instance spawn - x < 0 - is inside a dungeon)
const workSpawns = (q) => { const out = []; for (const o of q.objectives || []) { for (const id of [...(o.kind === 'kill' ? [o.npc] : o.npcs || []), ...(o.npcDrops || [])]) out.push(...((N[id] || {}).spawns || [])); for (const id of [...(o.kind === 'object' ? [o.object] : []), ...(o.objectDrops || [])]) out.push(...((O[id] || {}).spawns || [])); } return out; };
const workZones = (q) => new Set(workSpawns(q).filter((sp) => sp.x >= 0).map((sp) => sp.zone));
const inInstance = (q) => { const sp = workSpawns(q); return sp.length > 0 && sp.every((p) => p.x < 0 || dungeonAreas.has(p.zone)); };
// all-elite: every mob its objectives need - kill targets and the ones that drop its items (as route2 judges it)
const allElite = (q) => { const ids = (q.objectives || []).flatMap((o) => [...(o.kind === 'kill' ? [o.npc] : o.npcs || []), ...(o.npcDrops || [])]); const ns = ids.map((i) => N[i]).filter(Boolean); return ns.length > 0 && ns.every((n) => n.rank >= 1 && n.rank <= 3); };
function kind(q) {
  const gz = giverZone(q);
  if (!gz && (q.starters || []).some((s) => s.type === 'item')) return 'item';
  if (dungeonAreas.has(q.zone) || inInstance(q)) return 'dungeon';
  if (allElite(q)) return 'elite';
  if ((q.preSingle || []).length || (q.preGroup || []).length) return 'chain';
  const wz = workZones(q);
  if (gz && wz.size && !wz.has(gz)) return 'away';
  return 'plain';
}
const levels = Object.keys(ground).map(Number).sort((a, b) => b - a);
console.log(`${path.basename(dir)}: ${handed.size} hand-ins; ground at ${levels.length} level(s): ${levels.sort((a, b) => a - b).join(', ')}`);
for (const L of levels.sort((a, b) => a - b)) {
  const need = W.XP_TO_LEVEL[L];
  const cands = Object.values(Q).filter((q) => q.xp > 0 && !handed.has(q.id) && (giverZone(q) || (q.starters || []).some((st) => st.type === 'item')) && !/Arathi Basin|Warsong Gulch|Alterac Valley|Darkspear Islands|Darkmoon/.test(zoneName[giverZone(q)] + ' ' + q.name) && !(q.special & 3) && !q.skill && !q.notInForever && W.canTake(q, race, klass) && q.level >= L - 6 && q.level <= L + W.levelAbove(L) && (q.reqLevel || 1) <= L + 1);
  const by = {};
  // a chain part counts as lost only when the plan handed in what it needs (else it's the head's loss, counted there)
  const preDone = (q) => (q.preGroup || []).every((p) => handed.has(p)) && (!(q.preSingle || []).length || q.preSingle.some((p) => handed.has(p)));
  for (const q of cands) { const k = kind(q); if (k === 'chain' && !preDone(q)) continue; (by[k] = by[k] || []).push(q); }
  const xpOf = (qs) => Math.round(qs.reduce((s, q) => s + W.questXp(q.xp, q.level, L), 0));
  console.log(`\nlevel ${L}: needs ${need} xp, ground ${ground[L].min} min in ${ground[L].zone}; earned from quests at this level ${Math.round(earned[L] || 0)}`);
  for (const k of ['chain', 'away', 'item', 'plain', 'elite', 'dungeon']) {
    const qs = (by[k] || []).sort((a, b) => b.xp - a.xp);
    if (!qs.length) continue;
    console.log(`  ${k.padEnd(8)} ${String(qs.length).padStart(3)} quests, ${String(xpOf(qs)).padStart(7)} xp  e.g. ${qs.slice(0, TOP).map((q) => `${q.name} [${q.level}] (${zoneName[giverZone(q)] || '?'})`).join('; ')}`);
  }
}
