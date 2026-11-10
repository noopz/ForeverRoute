// README animations: both continents built from our own zone images (terrain/areaN.png) placed by their world bounds,
// plus a plan's route (or a travel trip) in canvas pixels. Output JSON for tools/readme-world.ps1.
// usage: node tools/readme-world.js route <path.json> <out.json>
//        node tools/readme-world.js travel <out.json> [race]   (trips across the travel network)
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..');
const conv = JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'conversion.json'), 'utf8')).geometry.transforms;
const H = 520; // panel height, px
// Kalimdor (1) on the left, the Eastern Kingdoms (0) on the right, one scale for both
const insts = [1, 0];
const bounds = {};
for (const t of conv) { const b = t.target_bounds || t.source_bounds; if (b && (t.map_id === 0 || t.map_id === 1)) bounds[t.ui_map_id] = { ...b, inst: t.map_id, area: t.area_id, name: t.target_name }; }
const ext = {};
for (const inst of insts) {
  let L = -1e9, R = 1e9, T = -1e9, B = 1e9;
  for (const b of Object.values(bounds)) if (b.inst === inst && fs.existsSync(path.join(ROOT, 'terrain', 'area' + b.area + '.png'))) { L = Math.max(L, b.left); R = Math.min(R, b.right); T = Math.max(T, b.top); B = Math.min(B, b.bottom); }
  ext[inst] = { L, R, T, B };
}
const s = H / Math.max(...insts.map((i) => ext[i].T - ext[i].B));
let x = 10; const panel = {};
for (const inst of insts) { const e = ext[inst]; panel[inst] = { inst, x, w: (e.L - e.R) * s, h: (e.T - e.B) * s, name: inst === 0 ? 'Eastern Kingdoms' : 'Kalimdor' }; x += panel[inst].w + 16; }
const mapW = Math.ceil(x);
const zones = [];
for (const [ui, b] of Object.entries(bounds)) {
  const png = path.join(ROOT, 'terrain', 'area' + b.area + '.png');
  if (!fs.existsSync(png)) continue;
  const e = ext[b.inst], p = panel[b.inst];
  zones.push({ ui: +ui, name: b.name, png, x: p.x + (e.L - b.left) * s, y: (e.T - b.top) * s, w: (b.left - b.right) * s, h: (b.top - b.bottom) * s });
}
// a map point (ui map, 0-1) -> canvas px on its continent, or null
function px(m, mx, my) {
  const b = bounds[m]; if (!b) return null;
  const Y = b.left + mx * (b.right - b.left), X = b.top + my * (b.bottom - b.top);
  const e = ext[b.inst], p = panel[b.inst];
  return { x: +(p.x + (e.L - Y) * s).toFixed(1), y: +((e.T - X) * s).toFixed(1), inst: b.inst };
}
// the layout, for the other README scripts (tools/readme-hero.js)
module.exports = { px, zones, panels: Object.values(panel), W: mapW, H };
if (require.main === module) {
const [mode, a1, a2, a3] = process.argv.slice(2);
const out = { W: mapW, H, panels: Object.values(panel), zones };
if (mode === 'route') {
  const P = JSON.parse(fs.readFileSync(a1, 'utf8'));
  const pts = [];
  for (const st of P.steps) {
    if (st.k === 'fly' || !st.m || st.x == null) continue;
    const p = px(st.m, st.x, st.y); if (!p) continue;
    const last = pts[pts.length - 1];
    if (last && Math.hypot(last.x - p.x, last.y - p.y) < 1.2 && last.zone === st.zone) { last.lvl = st.lvl || last.lvl; continue; }
    pts.push({ ...p, lvl: st.lvl || (last && last.lvl) || 1, zone: st.zone || '' });
  }
  out.pts = pts;
  out.title = 'A 1-60 plan, leg by leg';
  out.sub = `human paladin: ${P.legs ? new Set(P.legs).size : '?'} zones, ~${Math.round((P.minutes || 0) / 60)} h`;
  fs.writeFileSync(a2, JSON.stringify(out));
  console.log(`${pts.length} points, canvas ${mapW}x${H}, ${zones.length} zone images`);
} else if (mode === 'travel') {
  const T = require('./travel'); T.init(path.join(ROOT, 'qdb', 'conversion.json'));
  const net = JSON.parse(fs.readFileSync(path.join(__dirname, 'travel-net.json'), 'utf8'));
  const nodes = {}; for (const n of net.nodes) { const p = px(n.m, n.x, n.y); if (p) nodes[n.id] = { ...p, kind: n.kind, name: n.name }; }
  out.nodes = Object.values(nodes);
  // each stop's three shortest links (a zone links every stop to every other: drawn whole it is a solid web)
  const near = {};
  for (const e of net.edges) { const u = nodes[e.a], v = nodes[e.b]; if (!u || !v || u.inst !== v.inst) continue; const d = Math.hypot(u.x - v.x, u.y - v.y); for (const k of [e.a, e.b]) (near[k] = near[k] || []).push({ d, l: [u.x, u.y, v.x, v.y] }); }
  const keep = new Set();
  for (const list of Object.values(near)) for (const x of list.sort((p, q) => p.d - q.d).slice(0, 3)) keep.add(x.l.join(','));
  out.edges = [...keep].map((s) => s.split(',').map(Number));
  const facts = require('./travel-facts.json');
  out.boats = facts.BOATS.map(([u, v, , kind]) => { const a = facts.DOCKS[u], b = facts.DOCKS[v]; const pa = a && px(a.m, a.x, a.y), pb = b && px(b.m, b.x, b.y); return pa && pb ? [pa.x, pa.y, pb.x, pb.y, kind || 'boat'] : null; }).filter(Boolean);
  // the trips shown, in order
  const trips = [
    { title: 'Goldshire to Auberdine, level 15', from: { m: 1429, x: 0.42, y: 0.65 }, to: { m: 1439, x: 0.37, y: 0.44 }, level: 15, known: [1429, 1453] },
    { title: 'Thelsamar to Southshore, level 22', from: { m: 1432, x: 0.34, y: 0.47 }, to: { m: 1424, x: 0.51, y: 0.58 }, level: 22, known: [1432, 1455, 1453, 1437] },
  ];
  out.trips = [];
  for (const tr of trips) {
    const known = new Set(tr.known);
    const r = T.plan(tr.from, tr.to, { level: tr.level, knownFP: known, race: a2 || 'human' });
    if (!r) { console.log('no way: ' + tr.title); continue; }
    const legs = r.legs.map((l) => {
      const ps = [l.from, ...(l.via || []), l.to].map((n) => px(n.m, n.x, n.y)).filter(Boolean);
      const label = l.how === 'ride' ? 'Ride to ' + (l.to.id === 'target' ? 'the quest' : l.to.name || 'the next stop') : l.how === 'fly' ? 'Fly to ' + (l.to.name || 'the flight master') : l.how === 'boat' ? 'Boat to ' + (l.to.town || l.to.name) : l.how;
      return { how: l.how, label, pts: ps.map((p) => [p.x, p.y]) };
    });
    out.trips.push({ title: tr.title, minutes: Math.round(r.sec / 60), legs, describe: T.describe(r) });
    console.log(tr.title + ': ' + T.describe(r));
  }
  fs.writeFileSync(a1, JSON.stringify(out));
  console.log(`${out.nodes.length} nodes, ${out.edges.length} edges, ${out.boats.length} boat lines`);
}
}
