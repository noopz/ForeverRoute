// The quests done inside each dungeon, for the card's "inside a dungeon" state (addon DungeonQuests.lua): in there the
// game gives no coordinates, so the card shows what your quest log has for that dungeon instead of a plan step.
//
// Sources:
//   - QuestieDB (qdb/db.json, built by tools/build-db.js): quests, their objectives and where those spawn; and
//     qdb/support/Forever/Zones/dungeons.lua: the dungeon list (area id, name, alternative area ids).
//   - Forever's client tables Map and AreaTable (wago.tools db2 csv, the build in BUILD below): the instance map id of
//     each dungeon - what UnitPosition("player") (4th value) and GetInstanceInfo() (8th value) return inside. A dungeon
//     area's AreaTable.ContinentID is its instance map; where the area row is missing, the Map row of the same name.
//     Only party and raid maps (Map.InstanceType 1, 2).
//
// (Forever's new dungeons the quest data places nothing in - City of Dalaran, Excavation Site: Wetlands - go by the
// filing alone.) A quest belongs to a dungeon when one of its objectives is done only in there (all its known spawns are in the
// dungeon's areas), or - nothing known about where its objectives are - when QuestieDB files the quest under the
// dungeon (zoneOrSort) and its work or its people are in there. A quest filed under the dungeon whose objectives are
// all outside (Collecting Memories: the Miners' Union Cards drop in the mine before the portal) is left out.
//
// usage: node dungeon-quests.js [--fetch] [db.json] [dungeons.lua] [clientDir] [out.lua] [conversion.json]
//   --fetch   download Map.csv and AreaTable.csv for BUILD into clientDir first (default qdb/client)
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { droppers } = require('./world');

const BUILD = process.env.FR_CLIENT_BUILD || '1.60.1.70862';
const ROOT = path.join(__dirname, '..');
const argv = process.argv.slice(2);
const fetch = argv.includes('--fetch');
const [dbPath = path.join(ROOT, 'qdb', 'db.json'), dungeonPath = path.join(ROOT, 'qdb', 'support', 'Forever', 'Zones', 'dungeons.lua'),
  clientDir = path.join(ROOT, 'qdb', 'client'), out = path.join(ROOT, 'addon', 'ForeverRoute', 'DungeonQuests.lua'),
  convPath = path.join(ROOT, 'qdb', 'conversion.json')] = argv.filter((a) => !a.startsWith('--'));

if (fetch) {
  fs.mkdirSync(clientDir, { recursive: true });
  for (const t of ['Map', 'AreaTable']) execFileSync('curl', ['-sS', '-L', '--fail', '-A', 'db2-fetch', '-o', path.join(clientDir, t + '.csv'), `https://wago.tools/db2/${t}/csv?build=${BUILD}`], { stdio: 'inherit' });
}
// csv with quoted fields (a Map description holds commas and line breaks)
function csv(file) {
  const t = fs.readFileSync(file, 'utf8');
  const rows = []; let row = [], c = '', q = false;
  for (let i = 0; i < t.length; i++) {
    const ch = t[i];
    if (q) { if (ch === '"') { if (t[i + 1] === '"') { c += '"'; i++; } else q = false; } else c += ch; }
    else if (ch === '"') q = true;
    else if (ch === ',') { row.push(c); c = ''; }
    else if (ch === '\n') { row.push(c); c = ''; rows.push(row); row = []; }
    else if (ch !== '\r') c += ch;
  }
  if (c || row.length) { row.push(c); rows.push(row); }
  const head = rows[0];
  return rows.slice(1).map((r) => Object.fromEntries(r.map((v, i) => [head[i], v])));
}
for (const t of ['Map', 'AreaTable']) if (!fs.existsSync(path.join(clientDir, t + '.csv'))) { console.error(`missing ${path.join(clientDir, t + '.csv')}: run with --fetch`); process.exit(1); }
const maps = Object.fromEntries(csv(path.join(clientDir, 'Map.csv')).map((m) => [+m.ID, m]));
const areas = Object.fromEntries(csv(path.join(clientDir, 'AreaTable.csv')).map((a) => [+a.ID, a]));
const db = JSON.parse(fs.readFileSync(dbPath, 'utf8'));
// the dungeon list: [areaId] = {"name", {alternative area ids} or nil, parent zone, ...}. Read here and not with
// tools/dungeons.js, which wants an entrance in its own spacing and so misses rows (Dire Maul's wings 10022-10027)
const D = { list: {}, byArea: {} };
for (const m of fs.readFileSync(dungeonPath, 'utf8').matchAll(/^\s*\[(\d+)\] = \{"([^"]+)",\s*(\{[\d, ]*\}|nil),\s*(\d+),/gm)) {
  D.list[m[1]] = { id: +m[1], name: m[2], alt: m[3] === 'nil' ? [] : m[3].slice(1, -1).split(',').map(Number).filter(Boolean), parent: +m[4] };
}
for (const d of Object.values(D.list)) { D.byArea[d.id] = D.byArea[d.id] || d; for (const a of d.alt) D.byArea[a] = D.byArea[a] || d; }
const N = db.npcs, O = db.objects;
const zoneName = {};
if (fs.existsSync(convPath)) for (const t of JSON.parse(fs.readFileSync(convPath, 'utf8')).geometry.transforms) zoneName[t.area_id] = t.target_name;
for (const a of Object.values(areas)) if (!zoneName[+a.ID]) zoneName[+a.ID] = a.AreaName_lang;

// ---------- each dungeon's instance map(s) ----------
const isInstance = (m) => m && (m.InstanceType === '1' || m.InstanceType === '2');
const norm = (s) => String(s || '').toLowerCase().replace(/^the /, '');
const mapsOf = (d) => {
  const byName = Object.values(maps).filter((m) => isInstance(m) && norm(m.MapName_lang) === norm(d.name)).map((m) => +m.ID);
  const byArea = [...new Set([d.id, ...d.alt].map((a) => areas[a] && +areas[a].ContinentID).filter((id) => id != null && isInstance(maps[id])))];
  return { byName, byArea };
};
// a map goes to the dungeon of its own name first (area 206 is Utgarde Keep in QuestieDB's list and a Deadmines area
// in this client), then to the one whose area sits on it
const owner = {}; // map id -> dungeon
const list = Object.values(D.list).sort((a, b) => a.id - b.id);
for (const d of list) for (const m of mapsOf(d).byName) owner[m] = owner[m] || d;
for (const d of list) for (const m of mapsOf(d).byArea) owner[m] = owner[m] || d;
const dungeonMaps = new Map(); // dungeon -> [map ids]
for (const [m, d] of Object.entries(owner)) { if (!dungeonMaps.has(d)) dungeonMaps.set(d, []); dungeonMaps.get(d).push(+m); }
// the same dungeon under several QuestieDB ids (Scholomance 2057 and 6066, Stratholme 2017 and 10001): one entry
const sameDungeon = (a, b) => a === b || (a && b && norm(a.name) === norm(b.name));
const primary = (d) => { for (const p of dungeonMaps.keys()) if (sameDungeon(p, d)) return p; return null; };

// ---------- which quests are done in there ----------
function objSpawns(o) {
  const outp = [];
  if (o.kind === 'kill') { if (N[o.npc]) outp.push(...N[o.npc].spawns); }
  else if (o.kind === 'killcredit') { for (const id of o.npcs || []) if (N[id]) outp.push(...N[id].spawns); }
  else if (o.kind === 'item') {
    for (const n of droppers(o, N)) outp.push(...(n.spawns || []));
    for (const id of o.objectDrops || []) if (O[id]) outp.push(...O[id].spawns);
    if (!outp.length) for (const id of o.vendors || []) if (N[id]) outp.push(...N[id].spawns);
  } else if (o.kind === 'object') { if (O[o.object]) outp.push(...O[o.object].spawns); }
  else if (o.kind === 'explore') outp.push(...(o.spawns || []));
  return outp;
}
const dungeonAt = (zone) => { const d = D.byArea[zone]; return d ? primary(d) : null; };
const allIn = (spawns, d) => spawns.length > 0 && spawns.every((p) => dungeonAt(p.zone) === d);
const anyIn = (spawns, d) => spawns.some((p) => dungeonAt(p.zone) === d);
const whoSpawns = (list2) => (list2 || []).flatMap((s) => s.spawns || []);
const placed = new Set(); // dungeons with mobs or objects of their own in the quest data
for (const t of [N, O]) for (const n of Object.values(t)) for (const p of (n && n.spawns) || []) { const d = dungeonAt(p.zone); if (d) placed.add(d); }
function dungeonOfQuest(q) {
  if (q.notInForever) return null;
  // an objective done only in a dungeon
  for (const o of q.objectives || []) { const sp = objSpawns(o); if (sp.length) { const d = dungeonAt(sp[0].zone); if (d && allIn(sp, d)) return d; } }
  const d = dungeonAt(q.zone);
  if (!d) return null;
  const known = (q.objectives || []).map(objSpawns);
  // filed under a dungeon the quest data places nothing in (City of Dalaran: its mobs are listed under Alterac
  // Mountains, the zone around it): the filing is all there is to go by - for a quest with something to do
  if (!placed.has(d)) return known.length ? d : null;
  // filed under the dungeon: an objective with a place in there, or one nobody knows the place of...
  if (known.some((sp) => (sp.length ? anyIn(sp, d) : true))) return d;
  // ...or nothing to do but talk, to someone in there (picked up or handed in inside)
  if (!known.length && (anyIn(whoSpawns(q.starters), d) || anyIn(whoSpawns(q.finishers), d))) return d;
  return null;
}

// ---------- "you could have picked this up": what the addon needs to tell ----------
const ALLIANCE = 1 | 4 | 8 | 64, HORDE = 2 | 16 | 32 | 128, ALL = ALLIANCE | HORDE;
function side(q) {
  const m = Number(BigInt(Math.round(q.races || 0)) & BigInt(ALL));
  if (m && !(m & HORDE)) return 'A';
  if (m && !(m & ALLIANCE)) return 'H';
  const fr = new Set((q.starters || []).map((s) => s.friendly).filter(Boolean));
  if (fr.size === 1 && fr.has('A')) return 'A';
  if (fr.size === 1 && fr.has('H')) return 'H';
  return null;
}
// a quest anyone of its side and class picks up from a person or a drop: not a repeatable, a profession, reputation or
// event quest (the addon can't tell those are open to you)
const plainQuest = (q) => !(q.special & 1) && !q.skill && !q.minRep && !q.reqSpell && !(q.needsItems || []).length && !q.parent && (q.starters || []).length > 0;
function giver(q, d) {
  const inside = (q.starters || []).find((s) => s.type === 'item' || anyIn(s.spawns || [], d));
  if (inside) return { inside: true, from: inside.type === 'item' ? 'a drop inside' : inside.name };
  const s = (q.starters || []).find((x) => (x.spawns || []).some((p) => p.x >= 0)) || q.starters[0];
  const sp = (s.spawns || []).find((p) => p.x >= 0);
  const z = sp && zoneName[sp.zone];
  return { inside: false, from: s.name ? s.name + (z ? ', ' + z : '') : null };
}

const lua = (v) => (v == null ? 'nil' : typeof v === 'string' ? JSON.stringify(v) : String(v));
const byDungeon = new Map();
for (const q of Object.values(db.quests)) { const d = q && dungeonOfQuest(q); if (d) { if (!byDungeon.has(d)) byDungeon.set(d, []); byDungeon.get(d).push(q); } }
const L = [
  `-- Generated by tools/dungeon-quests.js from QuestieDB (quests, objective spawns, the dungeon list) and Forever's client`,
  `-- tables Map and AreaTable (wago.tools db2, build ${BUILD}). The quests done inside each dungeon, by the dungeon's`,
  `-- instance map id: what UnitPosition("player") (4th value) and GetInstanceInfo() (8th value) give inside.`,
  `--   ns.DUNGEONS[mapID] = name`,
  `--   ns.DUNGEON_QUESTS[mapID] = { ids = "id id ...",  every quest with work in there`,
  `--     open = { { id, name, minLevel, side ("A"/"H"/nil), classMask or nil, from, startsInside, any = {ids}, all = {ids} }, ... } }`,
  `--   open: the ones you could simply pick up (party dungeons only) - "any"/"all" are the quests to have done first.`,
  'local _, ns = ...',
  'ns.DUNGEONS = {',
];
const report = []; let nq = 0, nopen = 0;
const rows = [...byDungeon.entries()].filter(([d]) => dungeonMaps.has(d)).sort((a, b) => Math.min(...dungeonMaps.get(a[0])) - Math.min(...dungeonMaps.get(b[0])));
for (const [d] of rows) for (const m of dungeonMaps.get(d).sort((a, b) => a - b)) L.push(`  [${m}] = ${lua(d.name)},`);
L.push('}', 'ns.DUNGEON_QUESTS = {');
const shared = [];
for (const [d, qs] of rows) {
  const ids = dungeonMaps.get(d).sort((a, b) => a - b);
  const party = ids.some((m) => maps[m].InstanceType === '1');
  qs.sort((a, b) => a.id - b.id);
  const open = party ? qs.filter(plainQuest) : [];
  L.push(`  [${ids[0]}] = { -- ${d.name}`, `    ids = "${qs.map((q) => q.id).join(' ')}",`);
  if (open.length) {
    L.push('    open = {');
    for (const q of open) {
      const g = giver(q, d);
      const f = [q.id, lua(q.name), q.reqLevel || 1, lua(side(q)), q.classes ? q.classes : 'nil', lua(g.from), g.inside ? 'true' : 'nil'];
      const any = (q.preSingle || []).filter((x) => x > 0), all = (q.preGroup || []).filter((x) => x > 0);
      let extra = '';
      if (any.length) extra += `, any = { ${any.join(', ')} }`;
      if (all.length) extra += `, all = { ${all.join(', ')} }`;
      // trailing nils dropped
      while (f.length > 3 && f[f.length - 1] === 'nil') f.pop();
      L.push(`      { ${f.join(', ')}${extra} },`);
    }
    L.push('    },');
  }
  L.push('  },');
  for (const m of ids.slice(1)) shared.push(`ns.DUNGEON_QUESTS[${m}] = ns.DUNGEON_QUESTS[${ids[0]}]`);
  nq += qs.length; nopen += open.length;
  report.push(`${d.name} [${ids.join(',')}]: ${qs.length}${open.length ? ' (' + open.length + ' open)' : ''}`);
}
L.push('}', ...shared);
fs.writeFileSync(out, L.join('\n') + '\n');
const noMap = [...byDungeon.entries()].filter(([d]) => !dungeonMaps.has(d)).map(([d, qs]) => `${d.name} (${qs.length})`);
console.log(`${rows.length} dungeons, ${nq} quests (${nopen} with pick-up details), ${(fs.statSync(out).size / 1024).toFixed(1)} KB -> ${out}`);
console.log(report.join('; '));
if (noMap.length) console.log('not in this client (no instance map), left out: ' + noMap.join(', '));
