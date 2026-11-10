// README animation data: how a trip is found. The travel network (tools/travel-net.json + travel-facts.json) on the
// world canvas (tools/readme-data/world-layout.json), the time at which each stop can be reached from the start (a
// shortest-path search: rides at riding speed, boats, flights between flight masters you know), and the trip the
// planner picks (tools/travel.js plan) leg by leg.
// usage: node tools/readme-trip.js <out.json>
const fs = require('fs');
const path = require('path');
const T = require('./travel');
const ROOT = path.join(__dirname, '..');
T.init(path.join(ROOT, 'qdb', 'conversion.json'));
const F = T.facts, NET = T.net, FLIGHT = T.flight();
const layout = JSON.parse(fs.readFileSync(path.join(__dirname, 'readme-data', 'world-layout.json'), 'utf8'));
const rect = {}; for (const z of layout.zones) rect[z.ui] = z;
// canvas position from world coordinates: any zone image on the same continent gives the scale and offset, so a map
// with no image of its own (Stormwind City, a dock, a capital) still lands in the right place
const conv = JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'conversion.json'), 'utf8')).geometry.transforms;
const ref = {};
for (const z of layout.zones) { const t = conv.find((q) => q.ui_map_id === z.ui); const b = t && (t.target_bounds || t.source_bounds); if (b && ref[t.map_id] === undefined) ref[t.map_id] = { b, r: z }; }
const C = (m, x, y) => {
  const w = T.world(m, x, y); if (!w) return null; const R = ref[w[2]]; if (!R) return null;
  const { b, r } = R; // world: w[0] = Y (west), w[1] = X (north); canvas x grows east, y grows south
  return [+(r.x + (b.left - w[0]) / (b.left - b.right) * r.w).toFixed(1), +(r.y + (b.top - w[1]) / (b.top - b.bottom) * r.h).toFixed(1)];
};
const level = 22, start = { m: 1429, x: 0.42, y: 0.65, name: 'Goldshire' }, target = { m: 1440, x: 0.36, y: 0.50, name: 'Astranaar' };
const known = new Set(Object.keys(FLIGHT).map(Number)); // a well-travelled level 22: the flight paths of both continents
// the graph: network stops, flight masters, the start
const nodes = NET.nodes.map((n) => ({ id: n.id, m: n.m, x: n.x, y: n.y, w: T.world(n.m, n.x, n.y), kind: n.kind }));
const idx = Object.fromEntries(nodes.map((n, i) => [n.id, i]));
const adj = nodes.map(() => []);
const link = (a, b, sec, how) => { adj[a].push([b, sec, how]); adj[b].push([a, sec, how]); };
for (const e of NET.edges) if (idx[e.a] !== undefined && idx[e.b] !== undefined) link(idx[e.a], idx[e.b], e.yd / F.RIDE, 'ride');
for (const [a, b, cost = F.BOAT, , races] of F.BOATS) if (!races && idx['dock-' + a] !== undefined && idx['dock-' + b] !== undefined) link(idx['dock-' + a], idx['dock-' + b], cost, 'boat');
const fps = nodes.map((n, i) => (n.kind === 'fp' && known.has(n.m) ? i : -1)).filter((i) => i >= 0);
const d2 = (a, b) => (a.w && b.w && a.w[2] === b.w[2] ? Math.hypot(a.w[0] - b.w[0], a.w[1] - b.w[1]) : Infinity);
for (const a of fps) for (const b of fps) if (a < b && isFinite(d2(nodes[a], nodes[b]))) link(a, b, F.FLY_EXTRA + d2(nodes[a], nodes[b]) / F.FLY, 'fly');
const s = nodes.length; nodes.push({ id: 'start', m: start.m, x: start.x, y: start.y, w: T.world(start.m, start.x, start.y), kind: 'you' }); adj.push([]);
for (let i = 0; i < s; i++) if (nodes[i].m === start.m) link(s, i, (d2(nodes[s], nodes[i]) * 1.25) / F.RIDE, 'ride');
// arrival times
const t = nodes.map(() => Infinity), pred = nodes.map(() => -1), via = nodes.map(() => ''); t[s] = 0; const done = [];
for (;;) { let u = -1, b = Infinity; for (let i = 0; i < nodes.length; i++) if (!done[i] && t[i] < b) { b = t[i]; u = i; } if (u < 0) break; done[u] = true; for (const [v, c, how] of adj[u]) if (t[u] + c < t[v]) { t[v] = t[u] + c; pred[v] = u; via[v] = how; } }
// the planner's own trip
const plan = T.plan(start, target, { level, knownFP: known });
const legs = plan.legs.map((l) => {
  const pts = [l.from, ...(l.via || []), l.to].map((n) => C(n.m, n.x, n.y)).filter(Boolean);
  let sec = 0;
  if (l.how === 'boat') { const bt = F.BOATS.find((b) => (('dock-' + b[0]) === l.from.id && ('dock-' + b[1]) === l.to.id) || (('dock-' + b[1]) === l.from.id && ('dock-' + b[0]) === l.to.id)); sec = (bt && bt[2]) || F.BOAT; }
  else { const ns = [l.from, ...(l.via || []), l.to]; let yd = 0; for (let k = 1; k < ns.length; k++) yd += d2(ns[k - 1], ns[k]); sec = l.how === 'fly' ? F.FLY_EXTRA + yd / F.FLY : (yd * 1.25) / F.RIDE; }
  const to = l.to.id === 'target' ? target.name : (l.to.town || l.to.name || l.to.id);
  return { how: l.how, to, pts, min: Math.max(1, Math.round(sec / 60)) };
});
const alt = (label, opts, boats) => { const keep = F.BOATS; if (boats) F.BOATS = boats; const r = T.plan(start, target, { level, ...opts }); F.BOATS = keep; return { label, min: r ? Math.round(r.sec / 60) : null, how: r ? r.legs.map((l) => l.how).join(' > ') : 'no way' }; };
const alternatives = [
  { label: 'Boat from Stormwind, then fly', min: Math.round(plan.sec / 60), how: plan.legs.map((l) => l.how).join(' > '), best: true },
  alt('No flight paths yet: ride from Auberdine', { knownFP: new Set() }),
  alt('Without the Stormwind boat', { knownFP: known }, F.BOATS.filter((b) => !(b[0] === 'stormwind' && b[1] === 'auberdine'))),
];
const out = {
  alternatives,
  start: { ...start, at: C(start.m, start.x, start.y) }, target: { ...target, at: C(target.m, target.x, target.y) }, level, total: Math.round(plan.sec / 60),
  nodes: nodes.map((n, i) => ({ at: C(n.m, n.x, n.y), t: isFinite(t[i]) ? Math.round(t[i]) : null, kind: n.kind, from: pred[i] >= 0 ? C(nodes[pred[i]].m, nodes[pred[i]].x, nodes[pred[i]].y) : null, how: via[i] })).filter((n) => n.at),
  edges: NET.edges.map((e) => [nodes[idx[e.a]], nodes[idx[e.b]]]).filter(([a, b]) => a && b).map(([a, b]) => [...C(a.m, a.x, a.y) || [], ...C(b.m, b.x, b.y) || []]).filter((e) => e.length === 4),
  legs,
};
fs.writeFileSync(process.argv[2], JSON.stringify(out));
console.log(`${out.nodes.length} stops, ${out.edges.length} links; trip ${start.name} -> ${target.name}: ${legs.map((l) => l.how + ' ' + l.to + ' ' + l.min + 'm').join(', ')} (${out.total} min)`);
