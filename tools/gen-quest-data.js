// Writes addon/ForeverRoute/QuestData.lua from the quest data: two things the addon needs on any plan.
//
// ns.QUEST_ITEMS  quest item -> its name and every quest that uses it (an objective, handed to you by the giver,
//                 needed along the way, or the item that starts it). The quest log check lists the ones in your bags
//                 that nothing needs any more. Only items the game files as quest items (class 12) that no quest
//                 gives as a reward: cloth, meat and potions a quest also asks for are never "left over".
// ns.QUEST_FOR    who can take a quest named there, when not everyone: "A" / "H", then ":CLASS,CLASS".
// ns.SIDE_QUESTS  quests no plan can hold, by the way plans are made: a leg takes the quests whose giver stands in the
//                 leg's zones (route2.js), drops one with an objective outside them, and a capital is never a leg
//                 (campaign.js) - so A Noble Brew (Zardeth in Stormwind; a Tear of Tilloa in Duskwood, a Musquash Root
//                 in the Wetlands) is left out though both zones are on the route. The addon offers such a quest when
//                 you stand next to its giver and its objectives lie near your route (Engine.SideOffer).
//                 Kept simple on purpose: outdoor objectives only (things to loot from the ground, drops and kills of
//                 normal mobs, a decent drop rate), no elites, no dungeon, no profession / reputation / event quests.
// ns.QUEST_PRE    every quest's prerequisites; ns.QUEST_EX every quest's alternatives (Engine.Excluded).
// usage: node tools/gen-quest-data.js [out.lua]     (run after rebuilding qdb; tools/update-questiedb.js does)
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..');
const { CAPITAL_AREAS, CLASS_BIT, unknownWork, leadsOn } = require('./world');
const ALT = require('./exclusive-alternatives'); // a quest's alternatives (closers), and the check that db.json has them
const QDB = process.env.FR_QDB || path.join(ROOT, 'qdb'); // (FR_QDB: the quest data of another checkout)
const db = JSON.parse(fs.readFileSync(path.join(QDB, 'db.json'), 'utf8'));
const rawQ = JSON.parse(fs.readFileSync(path.join(QDB, 'json', 'quests.json'), 'utf8'));
const rawI = JSON.parse(fs.readFileSync(path.join(QDB, 'json', 'items.json'), 'utf8'));
const conv = JSON.parse(fs.readFileSync(path.join(QDB, 'conversion.json'), 'utf8')).geometry.transforms;
const uiMap = {}; for (const t of conv) uiMap[t.area_id] = t.ui_map_id;
const out = process.argv[2] || path.join(ROOT, 'addon', 'ForeverRoute', 'QuestData.lua');

const at = (v, i) => (v == null ? undefined : Array.isArray(v) ? v[i - 1] : v[i]);
const list = (v) => (v == null ? [] : Array.isArray(v) ? v.filter((x) => x != null) : Object.values(v).filter((x) => x != null));
const lua = (s) => '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, ' ') + '"';
const Q = db.quests, N = db.npcs, O = db.objects;

// ---------------------------------------------------------------- who can take a quest
const ALLIANCE = 1n | 4n | 8n | 64n | (1n << 32n), HORDE = 2n | 16n | 32n | 128n | (1n << 33n);
function sideOf(q) {
  const m = BigInt(Math.round(q.races || 0));
  let a = m === 0n || (m & ALLIANCE) !== 0n, h = m === 0n || (m & HORDE) !== 0n;
  // no race mask: the giver's side says it (a Horde-only giver's quest is not an Alliance quest)
  if (m === 0n) {
    const fr = (q.starters || []).map((s) => s.friendly).filter(Boolean);
    if (fr.length && fr.every((f) => f === 'A')) h = false;
    if (fr.length && fr.every((f) => f === 'H')) a = false;
  }
  return a && h ? '' : a ? 'A' : h ? 'H' : '';
}
const CLASS_TOKEN = Object.fromEntries(Object.entries(CLASS_BIT).map(([k, b]) => [b, k.toUpperCase()]));
const classesOf = (q) => (q.classes ? Object.keys(CLASS_TOKEN).filter((b) => q.classes & +b).map((b) => CLASS_TOKEN[b]) : []);
const forOf = (q) => { const s = sideOf(q), c = classesOf(q); return s || c.length ? s + (c.length ? ':' + c.join(',') : '') : null; };

// ---------------------------------------------------------------- quest items
const uses = {}; // item -> Set(quest)
const use = (item, q) => { if (item > 0 && q > 0) (uses[item] = uses[item] || new Set()).add(+q); };
for (const [id, q] of Object.entries(rawQ)) {
  const objs = at(q, 10);
  for (const o of list(at(objs, 3))) use(Array.isArray(o) ? o[0] : o, id);          // item objectives
  for (const o of list(at(objs, 6))) if (Array.isArray(o) && o[2]) use(o[2], id);   // a spell cast with an item
  use(at(q, 11), id);                                                              // handed to you by the giver
  for (const it of list(at(q, 21))) use(it, id);                                    // needed along the way
  for (const it of list(at(at(q, 2), 3))) use(it, id);                              // the item that starts it
}
for (const [id, it] of Object.entries(rawI)) {
  use(+id, at(it, 5));                                                              // starts this quest
  for (const q of list(at(it, 15))) use(+id, q);                                    // related quests
}
const itemLines = [], named = new Set();
for (const id of Object.keys(uses).map(Number).sort((a, b) => a - b)) {
  const it = rawI[id]; if (!it) continue;
  if ((at(it, 12) || 0) !== 12) continue;        // a quest item, by the game's own filing
  if (list(at(it, 6)).length) continue;          // a quest gives it as a reward: yours to keep
  const qs = [...uses[id]].sort((a, b) => a - b);
  for (const q of qs) named.add(q);
  itemLines.push(`  [${id}] = { ${lua(at(it, 1))}, ${qs.join(', ')} },`);
}
const forLines = [];
for (const q of [...named].sort((a, b) => a - b)) { const f = Q[q] && forOf(Q[q]); if (f) forLines.push(`  [${q}] = ${lua(f)},`); }

// ---------------------------------------------------------------- side quests
const HOLIDAY_SORTS = new Set([-22, -284, -366, -364, -369, -370, -1001, -1002, -1003, -1004, -1005, -1006, -1007, -41, -376, -374, -375, -101]);
const RACE_TOKEN = { 1: 'Human', 2: 'Orc', 4: 'Dwarf', 8: 'NightElf', 16: 'Scourge', 32: 'Tauren', 64: 'Gnome', 128: 'Troll' };
const outdoor = (sp) => (sp || []).filter((p) => !p.instance && p.x >= 0 && uiMap[p.zone]);
const spot = (p) => [uiMap[p.zone], +(p.x / 100).toFixed(4), +(p.y / 100).toFixed(4)];
// a few spots that say where an objective is: per zone, the middle one and the ones furthest from those picked
function spread(pts, n) {
  if (pts.length <= n) return pts;
  const cx = pts.reduce((s, p) => s + p.x, 0) / pts.length, cy = pts.reduce((s, p) => s + p.y, 0) / pts.length;
  const d = (a, b) => (a.x - b.x) ** 2 + (a.y - b.y) ** 2;
  const picked = [pts.reduce((b, p) => (d(p, { x: cx, y: cy }) < d(b, { x: cx, y: cy }) ? p : b))];
  while (picked.length < n) picked.push(pts.reduce((b, p) => (Math.min(...picked.map((k) => d(p, k))) > Math.min(...picked.map((k) => d(b, k))) ? p : b)));
  return picked;
}
function objective(q, o) {
  let pts = [], verb = 'Collect', name = o.name;
  const mobsOk = (ids) => ids.every((id) => N[id] && !(N[id].rank >= 1) && (N[id].maxLevel || 0) <= q.level + 3);
  if (o.kind === 'item') {
    // a quest item only: bars, cloth and meat a quest asks for come from professions and the auction house
    if (!rawI[o.item] || (at(rawI[o.item], 12) || 0) !== 12) return null;
    if ((o.vendors || []).length && !(o.objectDrops || []).length && !(o.npcDrops || []).length) return null; // bought: not a place
    for (const id of o.objectDrops || []) if (O[id]) pts.push(...O[id].spawns);
    const drops = (o.npcDrops || []).filter((id) => N[id]);
    if (drops.length) {
      if (!mobsOk(drops)) return null;
      const rates = drops.map((id) => (o.rates && o.rates[id] != null ? o.rates[id] : null)).filter((r) => r != null);
      if (rates.length && Math.max(...rates) < 30) return null; // a poor drop: the planner's "frustrating"
      for (const id of drops) pts.push(...N[id].spawns);
    }
  } else if (o.kind === 'kill') {
    if (!N[o.npc] || !mobsOk([o.npc])) return null;
    // friendly to you: a talk, which the quest data has no text for - left out
    if (N[o.npc].friendly) return null;
    verb = 'Kill'; name = o.text || N[o.npc].name; pts.push(...N[o.npc].spawns);
  } else return null; // use an object, explore, reputation, spells: no text the game shows that the card could match
  if (!name || !pts.length || pts.some((p) => p.instance)) return null;
  pts = outdoor(pts); if (!pts.length) return null;
  const byZone = {}; for (const p of pts) (byZone[p.zone] = byZone[p.zone] || []).push(p);
  const zones = Object.keys(byZone).sort((a, b) => byZone[b].length - byZone[a].length).slice(0, 2);
  return { verb, name, zones: zones.map(Number), pts: zones.flatMap((z) => spread(byZone[z], 3)).map(spot) };
}
const sideLines = [];
for (const q of Object.values(Q).sort((a, b) => a.id - b.id)) {
  if (!q.name || q.special & 3 || q.skill || q.reqSpell || q.minRep || q.parent || q.notInForever || q.needsItems) continue;
  if (HOLIDAY_SORTS.has(q.zone) || !(q.xp > 0) || !(q.level > 0) || q.level > 60) continue;
  if ((q.children || []).length || (q.objectives || []).length > 3) continue;
  // one giver you can stand next to (not a patrol), one place to hand it in
  const giver = (q.starters || []).find((s) => s.type !== 'item' && outdoor(s.spawns).length >= 1 && (s.spawns || []).length <= 2);
  const ender = (q.finishers || []).find((s) => outdoor(s.spawns).length >= 1 && (s.spawns || []).length <= 2);
  if (!giver || !ender) continue;
  const g = outdoor(giver.spawns)[0], e = outdoor(ender.spawns)[0];
  const objs = (q.objectives || []).map((o) => objective(q, o));
  if (objs.some((o) => !o)) continue;
  // the quests a plan cannot hold: the giver in a capital, or an objective with nothing in the giver's zone
  const city = CAPITAL_AREAS.has(g.zone);
  const away = objs.some((o) => !o.zones.includes(g.zone));
  // or work the data lists none of (Brewer's Trade): no plan holds one that leads nowhere (route2.js), so it is offered
  // at its giver, saying where its work is isn't known (u)
  const unknown = unknownWork(q) && !leadsOn(q, Q);
  if (!city && !away && !unknown) continue;
  if (!objs.length && e.zone !== g.zone) continue; // a delivery to another zone: the planner carries those itself
  const mask = BigInt(Math.round(q.races || 0)), side = sideOf(q);
  const whole = side === 'A' ? ALLIANCE : side === 'H' ? HORDE : ALLIANCE | HORDE;
  const races = mask !== 0n && (mask & whole) !== whole ? Object.keys(RACE_TOKEN).filter((b) => mask & BigInt(b)).map((b) => RACE_TOKEN[b]) : [];
  if (mask !== 0n && (mask & whole) !== whole && !races.length) continue; // only for a race this file has no name for
  const f = [`n = ${lua(q.name)}`, `l = ${q.level}`, `r = ${q.reqLevel || 1}`, `xp = ${q.xp}`];
  if (side) f.push(`f = ${lua(side)}`);
  if (races.length) f.push(`rc = ${lua(races.join(','))}`);
  const cl = classesOf(q); if (cl.length) f.push(`cl = ${lua(cl.join(','))}`);
  f.push(`g = { ${lua(giver.name)}, ${spot(g).join(', ')} }`, `e = { ${lua(ender.name)}, ${spot(e).join(', ')} }`);
  if ((q.preGroup || []).length) f.push(`pre = { ${q.preGroup.join(', ')} }`);
  if ((q.preSingle || []).length) f.push(`any = { ${q.preSingle.join(', ')} }`);
  const ex = [...new Set([...ALT.closers(Q, q), ...(q.nextInChain ? [q.nextInChain] : [])])];
  if (ex.length) f.push(`ex = { ${ex.join(', ')} }`);
  if (unknown) f.push('u = true');
  if (objs.length) f.push(`o = { ${objs.map((o) => `{ ${lua(o.verb)}, ${lua(o.name)}, ${o.pts.map((p) => `{ ${p.join(', ')} }`).join(', ')} }`).join(', ')} }`);
  sideLines.push(`  [${q.id}] = { ${f.join(', ')} },`);
}

const preLines = [];
for (const q of Object.values(db.quests)) {
  const g = (q.preGroup || []).filter((x) => x > 0), one = (q.preSingle || []).filter((x) => x > 0);
  if (!g.length && !one.length) continue;
  preLines.push(`  [${q.id}] = { ${g.length ? 'g = { ' + g.join(', ') + ' }' : ''}${g.length && one.length ? ', ' : ''}${one.length ? 's = { ' + one.join(', ') + ' }' : ''} },`);
}
// alternatives: quest -> the quests that close it (its exclusive list - QuestieDB's, and the same-name alternatives
// tools/exclusive-alternatives.js marks when the data is built). Only the pick-ups' side matters to the addon.
// The same db.json the planner reads, marked: a QuestData.lua made from another one (a local copy with marks the
// planner's lacked) had the addon close quests the plans still sent you to. So a db.json whose marks are missing or
// stale stops here, with the command that brings it up to date
{
  const fresh = { quests: JSON.parse(JSON.stringify(db.quests)) };
  ALT.mark(fresh);
  const off = Object.values(db.quests).filter((q) => JSON.stringify([...(q.exclusive || [])].sort()) !== JSON.stringify([...(fresh.quests[q.id].exclusive || [])].sort()));
  if (off.length) {
    console.error(`${path.join(QDB, 'db.json')}: the same-name alternatives are not marked as a build marks them (${off.slice(0, 5).map((q) => q.id + ' ' + q.name).join(', ')}${off.length > 5 ? '...' : ''}).\nRun node tools/apply-overrides.js${process.env.FR_QDB ? ' ' + path.join(QDB, 'db.json') : ''} first (or rebuild: node tools/update-questiedb.js).`);
    process.exit(1);
  }
}
const exLines = [];
for (const q of Object.values(db.quests)) {
  // (through closers: not a quest's own prerequisites, which QuestieDB lists there now and then - Stars of Elune)
  const ex = [...new Set(ALT.closers(db.quests, q).filter((x) => db.quests[x]))].sort((a, b) => a - b);
  if (ex.length) exLines.push(`  [${q.id}] = { ${ex.join(', ')} },`);
}
const L = ['-- Generated by tools/gen-quest-data.js from the quest data - edit that, not this.', 'local _, ns = ...',
  '-- quest item -> its name, then every quest that uses it (objective, handed to you, needed along the way, starts it)',
  'ns.QUEST_ITEMS = {', ...itemLines, '}',
  '-- who can take a quest named above, when not everyone: "A" / "H", then ":CLASS,CLASS"',
  'ns.QUEST_FOR = {', ...forLines, '}',
  '-- quests no plan can hold (the giver in a capital, or an objective in another zone than the giver), for Engine.SideOffer:',
  '-- n name, l level, r level needed, xp, f side, rc races, cl classes, g giver / e hand-in { name, map, x, y },',
  '-- pre all of these done first, any one of these done first, ex not with these, o objectives { verb, name, { map, x, y }... },',
  '-- u: the quest data lists none of its work (where it is is not known)',
  'ns.SIDE_QUESTS = {', ...sideLines, '}',
  '-- prerequisites of every quest (QuestieDB): g = all of these handed in first, s = any one of these. The addon checks a',
  '-- pick-up against them whatever the plan says (a plan that left out Gleaning Our Future sent you to For Further Study)',
  'ns.QUEST_PRE = {', ...preLines, '}',
  '-- alternatives: a quest is no longer offered once any of these is done or in your log (one quest from givers in',
  '-- several towns - In Search of Menara Voidrender from Briarthorn or Demisette Cloyce: you take it from one)',
  'ns.QUEST_EX = {', ...exLines, '}'];
fs.writeFileSync(out, L.join('\n') + '\n');
console.log(`${itemLines.length} quest items, ${sideLines.length} side quests -> ${out}`);
