// README animation data: a zone as the planner sees it - hubs, quests as spokes from a giver out to their objective,
// chains between quests, what was cut and why, and the order the plan does them in (route2.js cfg.graphOut).
// usage: node tools/readme-graph.js <graph.json from route2 graphOut> <zone name> <out.json>
const fs = require('fs');
const [inF, zoneName, outF] = process.argv.slice(2);
const g = JSON.parse(fs.readFileSync(inF, 'utf8'));
const Z = g.zone, here = (p) => p && p.zone === Z;
const short = (why) => {
  let m;
  if ((m = /about (\d+) kills/.exec(why))) return `${m[1]} kills: not worth it`;
  if (/objectives outside/.test(why)) return 'objective outside this zone';
  if (/needs an earlier quest/.test(why)) return 'chain not started';
  if ((m = /frustrating: ([^,]+)/.exec(why))) return m[1].replace(/ around the objective/, ' nearby');
  if (/elite/.test(why)) return 'elites: a group quest';
  if (/low level/.test(why)) return 'gray for you';
  if (/lonely detour/.test(why)) return 'a lonely detour';
  if (/low XP for the time/.test(why)) return 'too slow for its XP';
  if (/alternative to/.test(why)) return 'you did the other one';
  return why.split(':')[0];
};
// hubs: the planner's names, shortened ("Duskwood: Jitters, Night Watch Guard" -> "Jitters")
const hubs = g.hubs.filter(here).map((h) => ({ name: h.name.includes(':') ? h.name.split(':')[1].split(',')[0].trim() : h.name, x: h.x, y: h.y, npcs: h.npcs }));
const node = (p) => (here(p) ? { x: p.x, y: p.y } : null);
const quests = [];
for (const k of g.kept) {
  const giver = node(k.giver); const obj = (k.objs || []).find(here);
  if (!giver && !obj) continue;
  quests.push({ id: k.id, name: k.name, level: k.level, xp: k.xp, xpm: k.xpm, pre: k.pre, giver, obj: obj ? { x: obj.x, y: obj.y } : null, label: obj ? obj.label : null, status: k.status });
}
for (const c of g.cut) {
  const giver = node(c.giver); if (!giver) continue;
  quests.push({ id: c.id, name: c.name, level: c.level, xp: c.xp, pre: c.pre, giver, obj: node(c.obj), status: 'cut', why: short(c.why) });
}
// chains: a link from each quest to the one it opens, both drawn here
const ids = new Set(quests.map((q) => q.id));
const chains = []; for (const q of quests) for (const p of q.pre || []) if (ids.has(p)) chains.push([p, q.id]);
// the plan's order here (objective and hand-in stops)
// (only the stops on this zone's map: a leg here also plans Stormwind's hand-ins)
const ui = (JSON.parse(fs.readFileSync(require('path').join(__dirname, '..', 'qdb', 'conversion.json'), 'utf8')).geometry.transforms.find((t) => t.area_id === Z) || {}).ui_map_id;
const order = g.order.filter((s) => s.x != null && s.m === ui).map((s) => ({ k: s.k, q: s.q, x: +(s.x * 100).toFixed(2), y: +(s.y * 100).toFixed(2), text: s.text }));
// real walking paths on the walk map (tools/voxnav.js), not straight lines: Duskwood's ring of mountains can't be
// walked through, and straight lines across it read as if it could (a player saw the GIF's loops cross it)
const { VoxNav } = require('./voxnav');
let nav = null; try { nav = new VoxNav(require('path').join(__dirname, '..', 'terrain'), Z); } catch (e) {}
const walk = (a, b) => {
  if (!nav || !a || !b) return null;
  // a spot inside a building has no walkable floor to start or end on: try a few yards around it
  let r = null;
  for (const [dx, dy] of [[0, 0], [0.6, 0], [-0.6, 0], [0, 0.6], [0, -0.6], [1.2, 0], [-1.2, 0], [0, 1.2], [0, -1.2], [1.2, 1.2], [-1.2, -1.2]]) {
    for (const [ex, ey] of [[0, 0], [0.6, 0], [-0.6, 0], [0, 0.6], [0, -0.6]]) { r = nav.path({ x: a.x + ex, y: a.y + ey }, { x: b.x + dx, y: b.y + dy }); if (isFinite(r.length)) break; }
    if (isFinite(r.length)) break;
  }
  if (!isFinite(r.length)) return null;
  const B = nav.meta.bounds;
  const pts = r.floors.map((fl) => { const col0 = nav.colOf[fl]; const row = Math.floor(col0 / nav.W), col = col0 % nav.W; return [+((col + 0.5) * nav.cell / (B.left - B.right) * 100).toFixed(2), +((row + 0.5) * nav.cell / (B.top - B.bottom) * 100).toFixed(2)]; });
  return pts.filter((_, k) => k % 4 === 0 || k === pts.length - 1);
};
for (const q of quests) if (q.giver && q.obj) q.path = walk(q.giver, q.obj);
for (let i = 1; i < order.length; i++) order[i].path = walk(order[i - 1], order[i]);
const out = { zone: zoneName, zoneId: Z, level: g.level, hubs, quests, chains, order };
fs.writeFileSync(outF, JSON.stringify(out));
const n = (st) => quests.filter((q) => q.status === st).length;
console.log(`${zoneName}: ${hubs.length} hubs, ${quests.length} quests (done ${n('done')}, later ${n('later') + n('carried')}, cut ${n('cut')}), ${chains.length} chain links, ${order.length} stops`);
