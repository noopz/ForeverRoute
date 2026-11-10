// Route map: walk one zone leg of a planned path with the voxel navigator and write the geometry for drawing.
// usage: node route-map.js <path.json> <terrainDir> <area> <uiMapID> <legNo(1-based visit of that zone)> <out.json>
const fs = require('fs');
const { VoxNav } = require('./voxnav');
const [pathFile, terrainDir, area, mapId, legNo, out] = process.argv.slice(2);
const P = JSON.parse(fs.readFileSync(pathFile, 'utf8'));
const nav = new VoxNav(terrainDir, +area);
const meta = JSON.parse(fs.readFileSync(`${terrainDir}/area${area}.json`, 'utf8'));
// split steps into legs at each fly step; pick the Nth leg whose steps are mostly on this map
const legs = []; let cur = null;
P.steps.forEach((s, i) => { if (s.k === 'fly' || !cur) { cur = { start: i, steps: [] }; legs.push(cur); } cur.steps.push({ ...s, n: i + 1 }); });
const mine = legs.filter((l) => l.steps.filter((s) => s.m === +mapId).length > l.steps.length / 3);
const leg = mine[(+legNo || 1) - 1];
if (!leg) throw new Error('no such leg');
const stops = []; const elsewhere = [];
for (const s of leg.steps) {
  if (s.m === +mapId && s.x) stops.push({ n: s.n, x: s.x * 100, y: s.y * 100, k: s.k, label: (s.k === 'obj' ? s.text : (s.k + ' ' + (s.name || s.text || ''))).slice(0, 60), level: s.lvl });
  else if (s.k !== 'fly') elsewhere.push({ n: s.n, k: s.k, label: s.name || s.text, zone: s.zone });
}
const segs = []; let yards = 0;
for (let i = 1; i < stops.length; i++) {
  const a = stops[i - 1], b = stops[i];
  if (Math.hypot(a.x - b.x, a.y - b.y) < 0.3) continue;
  const r = nav.path(a, b);
  if (!isFinite(r.length)) { segs.push({ straight: true, pts: [[a.x, a.y], [b.x, b.y]] }); continue; }
  yards += r.length;
  const pts = r.floors.map((f) => { const c = nav.colOf[f]; const row = Math.floor(c / nav.W), col = c % nav.W; const B = nav.meta.bounds; return [(col + 0.5) * nav.cell / (B.left - B.right) * 100, (row + 0.5) * nav.cell / (B.top - B.bottom) * 100]; });
  const thin = pts.filter((_, k) => k % 3 === 0 || k === pts.length - 1);
  segs.push({ pts: thin });
}
fs.writeFileSync(out, JSON.stringify({ zone: meta.name, base: `${terrainDir}/area${area}.png`, W: meta.W, H: meta.H, stops, segs, elsewhere, yards: Math.round(yards), steps: leg.steps.length, from: leg.start + 1, to: leg.start + leg.steps.length, lvlFrom: leg.steps[0].lvl || P.startLevel, lvlTo: leg.steps[leg.steps.length - 1].lvl }));
console.log(`${meta.name}: steps ${leg.start + 1}-${leg.start + leg.steps.length}, ${stops.length} stops on map, ${elsewhere.length} elsewhere, ${Math.round(yards)} yd walked`);
