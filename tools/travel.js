// The planner's copy of the addon's travel graph (addon/ForeverRoute/Travel.lua), over the same data:
// tools/travel-facts.json (speeds, docks, zone levels, boats, gates) and tools/travel-net.json (the ride network from
// the walk maps: towns, flight masters, docks and zone crossings, with walking yards between key points of a zone).
// Edges: rides along the network (never through a zone more than DANGER_ABOVE levels above you, except a town walk),
// from you / to the target to the key points of your / its zone, flights between known flight paths, and the boats.
// Shortest trip by time (Dijkstra). Keep the rules in step with Travel.lua: tools/test-travel.js checks reported trips.
const fs = require('fs');
const path = require('path');
const F = JSON.parse(fs.readFileSync(path.join(__dirname, 'travel-facts.json'), 'utf8'));
const NET_FILE = path.join(__dirname, 'travel-net.json');
const NET = require('./net').load(F); void NET_FILE;
const OFFNET = 1.25; // straight-line yards to the network's key points count this much longer (roads bend)

let bounds = null, uiOfArea = null, areaOfUi = null, FLIGHT = null;
function init(conversionPath) {
  if (bounds) return;
  const conv = JSON.parse(fs.readFileSync(conversionPath, 'utf8')).geometry.transforms;
  bounds = {}; uiOfArea = {}; areaOfUi = {};
  for (const t of conv) {
    uiOfArea[t.area_id] = t.ui_map_id; areaOfUi[t.ui_map_id] = t.area_id;
    const b = t.target_bounds || t.source_bounds;
    if (b) bounds[t.ui_map_id] = { ...b, inst: t.map_id };
  }
  // FlightMasters.lua holds both factions' flight masters (Alliance = { ... }, Horde = { ... }); neutral ones are in both
  FLIGHTS = { alliance: {}, horde: {} };
  const lua = fs.readFileSync(path.join(__dirname, '..', 'addon', 'ForeverRoute', 'FlightMasters.lua'), 'utf8');
  let side = 'alliance';
  for (const line of lua.split('\n')) {
    if (/^\s*Horde = \{/.test(line)) side = 'horde'; else if (/^\s*Alliance = \{/.test(line)) side = 'alliance';
    const m = line.match(/\[(\d+)\] = \{ (.*) \},/);
    // each one { x, y, "flight master", "flight point name" } (the name is what the flight map calls it: the addon's)
    if (m) FLIGHTS[side][+m[1]] = [...m[2].matchAll(/\{ ([\d.]+), ([\d.]+), "([^"]*)"(?:, "[^"]*")? \}/g)].map((x) => [+x[1], +x[2], x[3]]);
  }
  FLIGHT = FLIGHTS.alliance;
}
let FLIGHTS = null;
const CROSS_CLEAR = 150; // yards beyond a hostile town's radius where a border crossing is no way for you
const sideOf = (faction) => (faction === 'horde' ? 'horde' : 'alliance');
const flightFor = (faction) => FLIGHTS[sideOf(faction)];
// a fact (crossing, spell, gate) for one faction only: is it there for this one?
const forSide = (only, faction) => !only || only === sideOf(faction);
function world(m, x, y) {
  const b = bounds[m]; if (!b) return null;
  return [b.left + x * (b.right - b.left), b.top + y * (b.bottom - b.top), b.inst];
}
const dist = (a, b) => Math.hypot(a.w[0] - b.w[0], a.w[1] - b.w[1]);
// the other faction's towns and camps (tools/hostile-towns.json), as world points with a radius in yards
let HOSTILE_RAW = null;
const hostileTowns = (faction) => {
  if (!HOSTILE_RAW) { try { HOSTILE_RAW = JSON.parse(fs.readFileSync(path.join(__dirname, 'hostile-towns.json'), 'utf8')); } catch (e) { HOSTILE_RAW = {}; } }
  return (HOSTILE_RAW[faction === 'horde' ? 'horde' : 'alliance'] || []).map((h) => ({ w: world(h.m, h.x, h.y), r: h.r })).filter((h) => h.w);
};
// shortest distance from point p to the segment a-b (world coords)
function segDist(a, b, p) {
  const dx = b[0] - a[0], dy = b[1] - a[1], L = dx * dx + dy * dy;
  const t = L ? Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / L)) : 0;
  return Math.hypot(a[0] + t * dx - p[0], a[1] + t * dy - p[1]);
}

// from/to: { m (uiMap), x, y (0-1) }; opts: { level, race, class, knownFP: Set of uiMaps whose flight path you know, docks: learned
// dock coords (ForeverRouteDB.docks) } -> { sec, legs: [{ how, from, to }] } or null when there is no safe way
function plan(from, to, opts = {}) {
  const level = opts.level ?? 60, known = opts.knownFP || new Set();
  const RIDE = F.MOUNT && level >= F.MOUNT.level ? F.MOUNT.speed : F.RIDE; // mounted from 40
  // zone levels: a Horde player's own lands are not the 60 that keeps the Alliance out (ZONE_MIN_HORDE)
  const horde = sideOf(opts.faction) === 'horde';
  const zoneMin = (m) => (horde && F.ZONE_MIN_HORDE && F.ZONE_MIN_HORDE[m] !== undefined ? F.ZONE_MIN_HORDE[m] : F.ZONE_MIN[m]);
  const risky = (m) => { const z = zoneMin(m); return z !== undefined && z > level + F.DANGER_ABOVE; };
  const GATES = F.GATES.filter((g) => forSide(g.faction, opts.faction));
  const mySide = horde ? 'H' : 'A';
  const N = [{ id: 'you', ...from, w: world(from.m, from.x, from.y) }, { id: 'target', ...to, w: world(to.m, to.x, to.y) }];
  if (!N[0].w || !N[1].w) return null;
  const adj = [[], []];
  const add = (n) => { N.push(n); adj.push([]); return N.length - 1; };
  // a ride through the other faction's town or camp costs extra (opts.faction, default alliance)
  const HOST = hostileTowns(opts.faction);
  const through = (a, b) => HOST.some((h) => h.w[2] === a.w[2] && segDist(a.w, b.w, h.w) < h.r);
  const edge = (u, v, c, how) => { if (how === 'ride' && through(N[u], N[v])) c += F.HOSTILE_SEC || 0; adj[u].push([v, c, how]); adj[v].push([u, c, how]); };
  const idx = {};
  const netMaps = new Set();
  if (NET) {
    for (const n of NET.nodes) {
      const w = world(n.m, n.x, n.y); if (!w) continue;
      // a border crossing inside the other faction's town or camp (Mor'shan Rampart's gate) is no way for you: a
      // crossing is a chokepoint, and the border has another one clear of it (tools/crossings.js)
      if (n.kind === 'cross' && HOST.some((h) => h.w[2] === w[2] && Math.hypot(h.w[0] - w[0], h.w[1] - w[1]) < h.r + CROSS_CLEAR)) continue;
      // a flight master of the other faction is only a spot on the road for you
      idx[n.id] = add({ ...n, w, fp: n.kind === 'fp' && (!n.side || n.side.includes(mySide)) && known.has(n.m) });
      netMaps.add(n.m); if (n.m2) netMaps.add(n.m2);
    }
    for (const e of NET.edges) {
      const u = idx[e.a], v = idx[e.b]; if (u === undefined || v === undefined) continue;
      if (risky(e.zone) && e.yd > F.TOWN_WALK) continue;
      edge(u, v, e.yd / RIDE, 'ride');
    }
  }
  // without the network (or off it): flight paths and docks as plain nodes, straight rides (the old graph)
  if (!NET) {
    for (const [m, list] of Object.entries(flightFor(opts.faction))) { if (!known.has(+m) || !list.length) continue; const [x, y, npc] = list[0], w = world(+m, x, y); if (w) add({ id: 'fp' + m, kind: 'fp', fp: true, m: +m, x, y, name: npc, w }); }
    for (const [key, d] of Object.entries(F.DOCKS)) { const w = world(d.m, d.x, d.y); if (w) idx['dock-' + key] = add({ id: 'dock-' + key, kind: 'dock', dock: key, ...d, w }); }
  }
  // docks the network doesn't have (a map without a walk map: Zephras Isle's skyship): plain nodes joined in straight
  // rides to the key points of their own map, like the gates (Travel.lua does the same)
  if (NET) for (const [key, d] of Object.entries(F.DOCKS)) {
    if (idx['dock-' + key] !== undefined) continue;
    const w = world(d.m, d.x, d.y); if (!w) continue;
    const u = idx['dock-' + key] = add({ id: 'dock-' + key, kind: 'dock', dock: key, ...d, w });
    for (let v = 2; v < u; v++) if (N[v].m === d.m || N[v].m2 === d.m) edge(u, v, (dist(N[u], N[v]) * OFFNET) / RIDE, 'ride');
  }
  // learned dock spots move the dock node (the network's walking yards stay)
  for (const [key, d] of Object.entries(F.DOCKS)) {
    const i = idx['dock-' + key], L = (opts.docks || {})[d.learned || key];
    if (i !== undefined && L && L.m === d.m) { N[i].x = L.x; N[i].y = L.y; N[i].w = world(d.m, L.x, L.y); }
  }
  // you and the target join the network at the key points of their own map (anywhere on the continent if the map has none)
  const onMap = (n, m) => n.m === m || n.m2 === m;
  const gated = (a, b) => !(a.gate || b.gate) && GATES.some((g) => (a.m === g.a && b.m === g.b) || (a.m === g.b && b.m === g.a));
  // gates (the breach past Mor'shan Rampart) join the key points of their own map (and the straight-line fallback)
  const firstGate = N.length;
  GATES.forEach((g, k) => { const w = world(g.via.m, g.via.x, g.via.y); if (w) add({ id: 'gate' + k, kind: 'gate', gate: true, ...g.via, w }); });
  for (let gi = firstGate; gi < N.length; gi++) for (let v = 2; v < firstGate; v++) {
    const n = N[v]; if (NET ? onMap(n, N[gi].m) : n.w[2] === N[gi].w[2] && !gated(n, N[gi])) edge(gi, v, (dist(N[gi], n) * (NET ? OFFNET : 1)) / RIDE, 'ride');
  }
  if (!NET) for (let u = 2; u < firstGate; u++) for (let v = u + 1; v < firstGate; v++) {
    const a = N[u], b = N[v];
    if (a.w[2] === b.w[2] && !gated(a, b) && (dist(a, b) <= F.TOWN_WALK || !(risky(a.m) || risky(b.m)))) edge(u, v, dist(a, b) / RIDE, 'ride');
  }
  // the danger rule holds where you join and leave the network too: no riding through a zone far above you to reach
  // (or leave) a spot inside it, except a town walk
  for (const end of [0, 1]) {
    const e = N[end], local = netMaps.has(e.m);
    for (let v = 2; v < N.length; v++) {
      const n = N[v]; if (n.w[2] !== e.w[2]) continue;
      if (local ? !onMap(n, e.m) : gated(e, n)) continue;
      if (dist(e, n) > F.TOWN_WALK && (risky(e.m) || risky(n.m))) continue;
      edge(end, v, (dist(e, n) * OFFNET) / RIDE, 'ride');
    }
  }
  if (N[0].m === N[1].m || !netMaps.has(N[0].m) || !netMaps.has(N[1].m)) {
    if (N[0].w[2] === N[1].w[2] && !gated(N[0], N[1]) && (N[0].m === N[1].m || !(risky(N[0].m) || risky(N[1].m)))) edge(0, 1, (dist(N[0], N[1]) * OFFNET) / RIDE, 'ride');
  }
  // flights between flight paths you know (same continent)
  const fps = []; for (let v = 2; v < N.length; v++) if (N[v].fp) fps.push(v);
  for (const u of fps) for (const v of fps) if (u < v && N[u].w[2] === N[v].w[2]) edge(u, v, F.FLY_EXTRA + dist(N[u], N[v]) / F.FLY, 'fly');
  // a crossing limited to some races (5th entry: the Skyborne-only portal) is not there for anyone else
  // (or classes: the druids' hippogryph out of Moonglade)
  // (6th entry: a faction's own crossings - the zeppelins, the Stormwind boat)
  // (7th entry true: one way - a portal with none back)
  for (const [a, b, cost = F.BOAT, , races, only, oneway] of F.BOATS) {
    if (!forSide(only, opts.faction)) continue;
    if (races && !((opts.race && races.includes(opts.race)) || (opts.class && races.includes(opts.class)))) continue;
    const u = idx['dock-' + a], v = idx['dock-' + b];
    if (u === undefined || v === undefined) continue;
    if (oneway) adj[u].push([v, cost, 'boat']); else edge(u, v, cost, 'boat');
  }
  // a class spell that takes you somewhere from anywhere (Teleport: Moonglade): one way, from where you stand
  for (const s of F.SPELLS || []) if (opts.class === s.class && level >= s.level && forSide(s.faction, opts.faction) && idx['dock-' + s.dock] !== undefined && N[idx['dock-' + s.dock]].m !== from.m) adj[0].push([idx['dock-' + s.dock], s.cast || 10, 'spell']);
  // Dijkstra
  const D = N.map(() => Infinity), prev = [], how = [], done = [];
  D[0] = 0;
  for (;;) {
    let u = -1, best = Infinity;
    for (let i = 0; i < N.length; i++) if (!done[i] && D[i] < best) { u = i; best = D[i]; }
    if (u < 0 || u === 1) break;
    done[u] = true;
    for (const [v, c, h] of adj[u]) if (!done[v] && D[u] + c < D[v]) { D[v] = D[u] + c; prev[v] = u; how[v] = h; }
  }
  if (D[1] === Infinity) return null;
  const legs = [];
  for (let v = 1; v !== 0; v = prev[v]) legs.unshift({ how: how[v], from: N[prev[v]], to: N[v] });
  // consecutive rides read as one ride (through the crossings)
  const merged = [];
  for (const l of legs) { const p = merged[merged.length - 1]; if (p && p.how === 'ride' && l.how === 'ride') { p.to = l.to; p.via.push(l.from); } else merged.push({ ...l, via: [] }); }
  return { sec: D[1], legs: merged };
}
// where you arrive in a zone: your faction's flight master there (the middle of the map if it has none)
const arrival = (m, faction) => { const FL = flightFor(faction), f = FL[m] && FL[m][0]; return f ? { m, x: f[0], y: f[1] } : { m, x: 0.5, y: 0.5 }; };
const label = (n) => (n.id === 'target' ? 'there' : n.id === 'you' ? 'you' : n.name || n.id);
const describe = (r) => (r ? r.legs.map((l) => l.how + ' ' + label(l.to) + (l.via && l.via.length ? ' (via ' + l.via.map(label).join(', ') + ')' : '')).join(' > ') + ` (${Math.round(r.sec / 60)} min)` : 'no safe way');
module.exports = { hostileTowns, segDist, init, plan, arrival, describe, world, facts: F, net: NET, uiOfArea: (a) => uiOfArea[a], areaOfUi: (m) => areaOfUi[m], flight: (faction) => (faction ? flightFor(faction) : FLIGHT), flights: () => FLIGHTS };
