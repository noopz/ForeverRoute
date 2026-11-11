// Builds the travel network both the planner (tools/travel.js) and the addon (TravelData.lua) ride over, from the
// walk maps (terrain/areaN.vox.*, which include walls and buildings): instead of riding in straight lines across zones
// (over mountains, through Mor'shan Rampart), a ride goes town -> zone crossing -> ... with real walking distances.
//   1. each zone's town: where most of its friendly NPCs stand; a walk field from there
//   2. crossings between two zones whose maps overlap: sample points (every STEP yd) reachable on foot in BOTH zones'
//      walk maps; each connected patch of them gives one crossing, at the point closest to both towns
//   3. per zone, walking distances between its key points (towns, flight masters, docks, crossings)
// usage: node crossings.js   -> tools/travel-net.json (then node gen-travel-data.js)
const fs = require('fs');
const path = require('path');
const { VoxNav } = require('./voxnav');
const ROOT = path.join(__dirname, '..');
const TERRAIN = path.join(ROOT, 'terrain');
const STEP = 30;
const conv = JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'conversion.json'), 'utf8')).geometry.transforms;
const db = JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'db.json'), 'utf8'));
const facts = JSON.parse(fs.readFileSync(path.join(__dirname, 'travel-facts.json'), 'utf8'));
const T = require('./travel'); T.init(path.join(ROOT, 'qdb', 'conversion.json'));
// both factions' flight masters, each node tagged with the side(s) that can fly from it (travel.js, Travel.lua)
const FL = T.flights();
const ISLAND = new Set([141]); // Teldrassil: the boat or nothing (swimming the strait is not a route)

const zones = [];
for (const t of conv) {
  if (!fs.existsSync(path.join(TERRAIN, `area${t.area_id}.vox.json`))) continue;
  const b = JSON.parse(fs.readFileSync(path.join(TERRAIN, `area${t.area_id}.vox.json`), 'utf8')).bounds;
  zones.push({ area: t.area_id, ui: t.ui_map_id, name: t.target_name, inst: t.map_id, b });
}
const byArea = Object.fromEntries(zones.map((z) => [z.area, z]));
// world <-> zone percent
const toWorld = (z, x, y) => [z.b.left + (x / 100) * (z.b.right - z.b.left), z.b.top + (y / 100) * (z.b.bottom - z.b.top)];
const toPct = (z, wx, wy) => ({ x: (100 * (wx - z.b.left)) / (z.b.right - z.b.left), y: (100 * (wy - z.b.top)) / (z.b.bottom - z.b.top) });
const rect = (z) => { const [x1, y1] = toWorld(z, 0, 0), [x2, y2] = toWorld(z, 100, 100); return [Math.min(x1, x2), Math.max(x1, x2), Math.min(y1, y2), Math.max(y1, y2)]; };

// the town: the 3% cell with the most NPCs friendly to a side (any NPCs if none are). The Alliance town places the
// crossings; the Horde one, where it is somewhere else, is one more key point
function townOf(z, mine = 'A') {
  const cnt = new Map();
  for (const side of [mine, null]) {
    for (const n of Object.values(db.npcs)) {
      if (!n || (side && !(n.friendly === side || n.friendly === 'AH'))) continue;
      for (const s of n.spawns || []) if (s.zone === z.area && s.x >= 0) { const k = Math.floor(s.x / 3) + ',' + Math.floor(s.y / 3); cnt.set(k, (cnt.get(k) || 0) + 1); }
    }
    if (cnt.size) break;
  }
  // every cluster of 3+ NPCs is a seed (one point can land on an isolated roof or ledge); the biggest is "the town"
  const cells = [...cnt].filter(([, v]) => v >= 3).sort((a, b) => b[1] - a[1]).slice(0, 15);
  if (!cells.length) { let best = null, bn = 0; for (const [k, v] of cnt) if (v > bn) { bn = v; best = k; } if (best) cells.push([best, bn]); }
  if (!cells.length) return [{ x: 50, y: 50 }];
  return cells.map(([k]) => { const [cx, cy] = k.split(',').map(Number); return { x: cx * 3 + 1.5, y: cy * 3 + 1.5 }; });
}
// the distance a field gives a map point: the best floor in the cells around it (and that floor's height)
function at(nav, d, p) { let best = Infinity; for (const f of nav.floorsNear(p, 2)) if (d[f] < best) best = d[f]; return best; }
function atZ(nav, d, p) { let best = Infinity, z = null; for (const f of nav.floorsNear(p, 2)) if (d[f] < best) { best = d[f]; z = nav.z[f]; } return [best, z]; }
// a walk map with its lifts (travel-facts LIFTS: Thunder Bluff's elevators, Undercity's)
function navOf(area) { const nav = new VoxNav(TERRAIN, area); const L = (facts.LIFTS || {})[area]; if (L) nav.addLifts(L.map(([x, y]) => ({ x, y }))); return nav; }
// the other faction's towns and camps, both lists (tools/hostile-towns.json): a crossing never sits in or by one (the
// planner would ride an Alliance player through Mor'shan Rampart)
const HOSTILE = (() => { try { const H = JSON.parse(fs.readFileSync(path.join(__dirname, 'hostile-towns.json'), 'utf8')); return [...(H.alliance || []), ...(H.horde || [])]; } catch (e) { return []; } })();
const NEAR_CAMP = 400; // yards beyond a camp's radius: the clear crossing keeps well away (Mor'shan Rampart: the breach to the east)
// a crossing's two sides at most this far apart in height - for Undercity, which lies under other zones' land (without
// it Undercity 'joined' Silverpine and Alterac through the ground above). Not for Ironforge: its walk map has no gate
// tunnel shared with Dun Morogh's, and it joins only where the heights differ
const HEIGHT = 10, UNDERGROUND = new Set([1497]);

const t0 = Date.now();
// pass 1: towns, and which overlap samples each zone's town reaches
const reach = {}; // area -> Map(sampleKey -> yards from town)
for (const z of zones) {
  const nav = navOf(z.area);
  const seeds = townOf(z);
  z.town = seeds[0];
  // the Horde town, when it isn't the same place (more than 10% of the map away): Razor Hill, the Crossroads
  // (only in a zone with Horde NPCs: elsewhere townOf falls back to any NPCs, a mob camp)
  const hasH = Object.values(db.npcs).some((n) => n && n.friendly === 'H' && (n.spawns || []).some((s) => s.zone === z.area && s.x >= 0));
  const h = hasH && townOf(z, 'H')[0];
  if (h && Math.hypot(h.x - z.town.x, h.y - z.town.y) > 10) z.townH = h;
  const src = seeds.map((p) => nav.anchor(p)).filter((f) => f >= 0);
  if (!src.length) { console.error(z.name + ': no floor at the town'); continue; }
  const d = nav.field(src); nav.cache.clear();
  const [ax1, ax2, ay1, ay2] = rect(z), R = new Map();
  for (const o of zones) {
    if (o === z || o.inst !== z.inst || ISLAND.has(o.area) || ISLAND.has(z.area)) continue;
    const [bx1, bx2, by1, by2] = rect(o);
    const x1 = Math.max(ax1, bx1), x2 = Math.min(ax2, bx2), y1 = Math.max(ay1, by1), y2 = Math.min(ay2, by2);
    if (x1 >= x2 || y1 >= y2) continue;
    for (let wx = Math.ceil(x1 / STEP) * STEP; wx <= x2; wx += STEP) for (let wy = Math.ceil(y1 / STEP) * STEP; wy <= y2; wy += STEP) {
      const k = wx + ',' + wy; if (R.has(k)) continue;
      const [v, hz] = atZ(nav, d, toPct(z, wx, wy)); if (isFinite(v)) R.set(k, [v, hz]);
    }
  }
  reach[z.area] = R;
  console.error(`${z.name}: town ${z.town.x.toFixed(1)},${z.town.y.toFixed(1)}, ${R.size} overlap points reached (${((Date.now() - t0) / 1000).toFixed(0)}s)`);
}
// pass 2: crossings
const crossings = [];
for (let i = 0; i < zones.length; i++) for (let j = i + 1; j < zones.length; j++) {
  const A = zones[i], B = zones[j], RA = reach[A.area], RB = reach[B.area];
  if (!RA || !RB || A.inst !== B.inst) continue;
  // a sample both towns reach on foot, at the same height in both walk maps
  const under = UNDERGROUND.has(A.area) || UNDERGROUND.has(B.area);
  const both = new Map(); for (const [k, [v, za]] of RA) { const w = RB.get(k); if (w !== undefined && (!under || Math.abs(za - w[1]) <= HEIGHT)) both.set(k, v + w[0]); }
  // the camps on either map, in these world coords
  const camps = HOSTILE.flatMap((h) => { const Z = [A, B].find((q) => q.ui === h.m); if (!Z) return []; const [cx, cy] = toWorld(Z, h.x * 100, h.y * 100); return [{ cx, cy, r: h.r + NEAR_CAMP }]; });
  const byCamp = (k) => { const [x, y] = k.split(',').map(Number); return camps.some((c) => Math.hypot(x - c.cx, y - c.cy) < c.r); };
  if (!both.size) continue;
  const seen = new Set();
  for (const k0 of both.keys()) {
    if (seen.has(k0)) continue;
    const comp = [], stack = [k0]; seen.add(k0);
    while (stack.length) {
      const k = stack.pop(); comp.push(k); const [x, y] = k.split(',').map(Number);
      for (const [dx, dy] of [[STEP, 0], [-STEP, 0], [0, STEP], [0, -STEP]]) { const n = (x + dx) + ',' + (y + dy); if (both.has(n) && !seen.has(n)) { seen.add(n); stack.push(n); } }
    }
    if (comp.length < 3) continue;
    // the point nearest both towns; when that is in or by a town or camp (Mor'shan Rampart, Dun Algaz), also the best
    // point clear of them: each faction's routes choose (the other faction's towns cost HOSTILE_SEC)
    let bk = null, bv = Infinity, ck = null, cv = Infinity;
    for (const k of comp) { const v = both.get(k); if (v < bv) { bv = v; bk = k; } if (v < cv && !byCamp(k)) { cv = v; ck = k; } }
    for (const k of byCamp(bk) && ck ? [bk, ck] : [bk]) {
      const [wx, wy] = k.split(',').map(Number);
      crossings.push({ id: `x${A.area}-${B.area}-${crossings.length}`, a: A.area, b: B.area, wx, wy, size: comp.length, via: Math.round(both.get(k)) });
    }
  }
}
console.error(crossings.length + ' crossings');
// pass 3: key points per zone and walking distances between them
const nodes = [], edges = [];
const addNode = (n) => { nodes.push(n); return n; };
for (const z of zones) z.keys = [];
for (const z of zones) z.keys.push(addNode({ id: 'town' + z.area, kind: 'town', area: z.area, ui: z.ui, ...z.town, name: z.name }));
for (const z of zones) if (z.townH) z.keys.push(addNode({ id: 'townH' + z.area, kind: 'town', area: z.area, ui: z.ui, ...z.townH, name: z.name }));
for (const z of zones) {
  const fps = new Map(); // one node per flight master, with the sides it serves ('A', 'H', 'AH')
  for (const [side, L] of [['A', FL.alliance], ['H', FL.horde]]) for (const [x, y, npc] of L[z.ui] || []) {
    const id = 'fp' + z.ui + '-' + npc.replace(/\W/g, '');
    if (fps.has(id)) { fps.get(id).side += side; continue; }
    fps.set(id, { id, kind: 'fp', area: z.area, ui: z.ui, x: x * 100, y: y * 100, name: npc, side });
  }
  for (const n of fps.values()) z.keys.push(addNode(n));
}
for (const [key, d] of Object.entries(facts.DOCKS)) { const z = zones.find((q) => q.ui === d.m); if (z) z.keys.push(addNode({ id: 'dock-' + key, kind: 'dock', dock: key, area: z.area, ui: z.ui, x: d.x * 100, y: d.y * 100, name: d.name })); }
for (const c of crossings) {
  const A = byArea[c.a], B = byArea[c.b], pa = toPct(A, c.wx, c.wy), pb = toPct(B, c.wx, c.wy);
  const n = addNode({ id: c.id, kind: 'cross', area: c.a, ui: A.ui, x: pa.x, y: pa.y, other: { area: c.b, ui: B.ui, x: pb.x, y: pb.y }, name: A.name + ' / ' + B.name });
  A.keys.push({ ...n, x: pa.x, y: pa.y }); B.keys.push({ ...n, x: pb.x, y: pb.y });
}
for (const z of zones) {
  if (z.keys.length < 2) continue;
  const nav = navOf(z.area);
  for (let i = 0; i < z.keys.length; i++) {
    const src = nav.anchor(z.keys[i]); if (src < 0) continue;
    const d = nav.field(src); nav.cache.clear();
    for (let j = i + 1; j < z.keys.length; j++) {
      const v = at(nav, d, z.keys[j]);
      if (isFinite(v)) edges.push({ a: z.keys[i].id, b: z.keys[j].id, zone: z.ui, yd: Math.round(v) });
    }
  }
  console.error(`${z.name}: ${z.keys.length} key points (${((Date.now() - t0) / 1000).toFixed(0)}s)`);
}
// node coords as 0-1 on their (first) map, the way the addon and travel.js use them
const out = {
  _about: 'Generated by tools/crossings.js from the walk maps. Ride network: key points (towns, flight masters, docks, zone crossings) and walking yards between key points of the same zone.',
  nodes: nodes.map((n) => ({ id: n.id, kind: n.kind, m: n.ui, x: +(n.x / 100).toFixed(4), y: +(n.y / 100).toFixed(4), name: n.name, ...(n.side ? { side: n.side } : {}), ...(n.dock ? { dock: n.dock } : {}), ...(n.other ? { m2: n.other.ui, x2: +(n.other.x / 100).toFixed(4), y2: +(n.other.y / 100).toFixed(4) } : {}) })),
  edges,
};
fs.writeFileSync(path.join(__dirname, 'travel-net.json'), JSON.stringify(out));
console.error(`wrote ${nodes.length} nodes, ${edges.length} edges in ${((Date.now() - t0) / 1000).toFixed(0)}s`);
