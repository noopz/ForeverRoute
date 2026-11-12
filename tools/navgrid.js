// Navigation grid for the addon: one byte per map square, baked from a zone's walk map (terrain/areaN.vox.*), shipped
// as packed text (addon/ForeverRoute/Nav/Nav<uiMap>.lua) and searched in game (addon/ForeverRoute/Nav.lua), so the map
// line runs from where you really stand, along streets, bridges and ramps, to the step.
// Design and measurements: docs/research/navigation-paths.md.
//
//   node navgrid.js build <uiMap[,uiMap]|all> [cell]   -> addon/ForeverRoute/Nav/Nav<uiMap>.lua (+ stats on stderr)
//   node navgrid.js stats <uiMap[,uiMap]|all> [cell]   -> counts and byte sizes only
//   node navgrid.js test <uiMap> <cell|-> x1,y1 x2,y2 [...]  -> search the baked grid between map points (%)
//   node navgrid.js png <uiMap> <out.png> [x1,y1 x2,y2]      -> picture of the grid (and a path), for a look
//
// The graph. The zone is cut into squares of `cell` yards (4 in a city, 8 outdoors, 16 in the biggest zones). The
// walk map's 2-yard floors inside a square that are joined to each other both ways form one patch. Only patches you
// can walk to AND back from the zone's big network are kept (no roofs you could only drop from, no pits). In each
// square the biggest patch (the lowest on a tie) is the *base* node; any other patch (a bridge over the canal, an
// upper floor, the far side of a wall that cuts the square) is an *overlay* node. A node is joined to a neighbour
// where the walk map has a step between their floors, one way or both (a drop is one way).
//
// What ships (text, unpacked by Nav.lua when you first need the zone):
//   base    one byte per square: bit d set = you can step INTO this square's base node from the base node of the
//           neighbour in direction d (the search runs from the target backwards, so it asks "who can reach me").
//           0 = no base node. Packed by rows: runs, copies of the row above, literals (see packBase()).
//   swim    one bit per square (its base node is water: costs x1.5), packed as runs
//   over    overlay nodes with their height and their links to the nodes around them (see pack())
//   far     the few links that are not between neighbours: lifts, recorded trails (from, to, yards)
//   solo    base nodes whose byte is 0 (reached only through links)
//   terr    (outdoor zones) one byte per square, packed like base: what the ground is like, for the search's costs -
//           bit 7 water (the swim bit again), bit 6 road (tools/roads.js: the ground is painted as a road), bit 5 a
//           hostile spawn within MOB_CLOSE yd, bits 0-4 the highest level of the hostile spawns within MOB_NEAR yd,
//           halved and rounded up (0 = none). Hostile = to both factions (QuestieDB's friendlyToFaction is empty).
//   terrA, terrH  the same mob bits for spawns hostile to the Alliance / the Horde only (the other side's guards
//           and townsfolk), when the zone has any
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const { VoxNav } = require('./voxnav');
const ROOT = path.join(__dirname, '..');
const MAIN = process.env.FR_MAIN || 'D:/git/ForeverRoute'; // a worktree has no data folders: read the main checkout's
const pick = (name) => (fs.existsSync(path.join(ROOT, name)) ? path.join(ROOT, name) : path.join(MAIN, name));
const TERRAIN = process.env.FR_TERRAIN || pick('terrain');
const QDB = process.env.FR_QDB || pick('qdb');
const Roads = require('./roads');
const ROAD_SHARE = 0.25;  // a square is road when this much of it is painted as one
const MOB_NEAR = 24;      // yards from a hostile spawn that count as "by a mob" (about where it would come for you, plus its wandering)
const MOB_CLOSE = 12;     // ...and as "right on top of it"
// (dr, dc) of the 8 directions; bit d of a square's byte = "from the neighbour at DIRS[d] into me"
const DIRS = [[-1, -1], [-1, 0], [-1, 1], [0, -1], [0, 1], [1, -1], [1, 0], [1, 1]];
const CITY = /City|Ironforge|Darnassus|Orgrimmar|Undercity|Thunder Bluff/;

function zones() { return JSON.parse(fs.readFileSync(path.join(QDB, 'conversion.json'), 'utf8')).geometry.transforms; }
function zoneOf(uiMap) {
  const t = zones().find((z) => z.ui_map_id === +uiMap);
  if (!t) throw new Error('no conversion entry for map ' + uiMap);
  return { ui: t.ui_map_id, area: t.area_id, inst: t.map_id, name: t.target_name, bounds: t.target_bounds || t.source_bounds };
}
// square size: 4 yd in a city (streets, doors), 8 outdoors, 16 where the zone is huge (the Barrens)
function cellFor(zone) {
  if (CITY.test(zone.name)) return 4;
  const B = zone.bounds, sq = (B.left - B.right) * (B.top - B.bottom);
  return sq / 64 > 400000 ? 16 : 8;
}

// the walk map with its lifts (travel-facts LIFTS) and recorded trails, the way the planner uses it
function navOf(area) {
  const nav = new VoxNav(TERRAIN, area);
  let facts = {}; try { facts = JSON.parse(fs.readFileSync(path.join(__dirname, 'travel-facts.json'), 'utf8')); } catch (e) {}
  const L = (facts.LIFTS || {})[area];
  if (L) nav.addLifts(L.map(([x, y]) => ({ x, y }))); else nav.trailLinks();
  return nav;
}

class UF {
  constructor(n) { this.p = new Int32Array(n); for (let i = 0; i < n; i++) this.p[i] = i; }
  find(a) { const p = this.p; while (p[a] !== a) { p[a] = p[p[a]]; a = p[a]; } return a; }
  union(a, b) { a = this.find(a); b = this.find(b); if (a !== b) this.p[a] = b; }
}

function buildGraph(area, cell, log = () => {}) {
  const nav = navOf(area);
  const M = nav.meta, P = M.P, B = M.bounds, vc = M.cell, W = nav.W, H = nav.H, F = nav.z.length;
  const z = nav.z, ceil = nav.ceil, swim = nav.swim, cs = nav.cs, colOf = nav.colOf;
  const tanMax = Math.tan(P.maxSlope * Math.PI / 180);
  const ok = (f, g, run) => {
    const dz = z[g] - z[f];
    if (Math.min(ceil[f], ceil[g]) - Math.max(z[f], z[g]) < P.headroom) return 0;
    const sw = swim[g] || swim[f];
    if (!sw) { if (dz > Math.max(P.climb, run * tanMax) || dz < -P.maxDrop) return 0; } else if (dz > P.climb + 1) return 0;
    return 1;
  };
  const k = Math.round(cell / vc); // walk-map columns per square side
  const CW = Math.ceil(W / k), CH = Math.ceil(H / k), NC = CW * CH;
  const cellOfCol = (col) => Math.floor(Math.floor(col / W) / k) * CW + Math.floor((col % W) / k);
  const extra = nav.extra || null;
  let t0 = Date.now();
  // 1. patches: floors of one square joined both ways
  const ufc = new UF(F);
  for (let f = 0; f < F; f++) {
    const col = colOf[f], r = Math.floor(col / W), c = col % W, cf = cellOfCol(col);
    for (const [dr, dc] of DIRS) {
      if (dr < 0 || (dr === 0 && dc < 0)) continue; // each pair once
      const rr = r + dr, cc = c + dc; if (rr < 0 || cc < 0 || rr >= H || cc >= W) continue;
      const ncol = rr * W + cc; if (cellOfCol(ncol) !== cf) continue;
      const run = dr && dc ? vc * Math.SQRT2 : vc;
      for (let g = cs[ncol]; g < cs[ncol + 1]; g++) if (ok(f, g, run) && ok(g, f, run)) ufc.union(f, g);
    }
  }
  // water in one square is one patch: you swim over whatever splits the bed below
  { const firstSwim = new Int32Array(NC).fill(-1); for (let f = 0; f < F; f++) if (swim[f]) { const c = cellOfCol(colOf[f]); if (firstSwim[c] < 0) firstSwim[c] = f; else ufc.union(f, firstSwim[c]); } }
  const candOf = new Int32Array(F).fill(-1); let NN = 0;
  for (let f = 0; f < F; f++) { const r = ufc.find(f); if (candOf[r] < 0) candOf[r] = NN++; }
  for (let f = 0; f < F; f++) candOf[f] = candOf[ufc.find(f)];
  const cCell = new Int32Array(NN), cCount = new Int32Array(NN), cZ = new Float64Array(NN), cSwim = new Int32Array(NN);
  for (let f = 0; f < F; f++) { const n = candOf[f]; cCell[n] = cellOfCol(colOf[f]); cCount[n]++; cZ[n] += z[f]; cSwim[n] += swim[f]; }
  for (let n = 0; n < NN; n++) cZ[n] /= cCount[n];
  // directed edges between patches (to -> cost; 0 = an ordinary step, measured between the squares in game)
  const out = new Array(NN);
  const addEdge = (a, b, cost) => { let m = out[a]; if (!m) out[a] = m = new Map(); const c = m.get(b); if (c === undefined || (c !== 0 && (cost === 0 || cost < c))) m.set(b, cost); };
  for (let f = 0; f < F; f++) {
    const a = candOf[f], col = colOf[f], r = Math.floor(col / W), c = col % W;
    for (const [dr, dc] of DIRS) {
      const rr = r + dr, cc = c + dc; if (rr < 0 || cc < 0 || rr >= H || cc >= W) continue;
      const ncol = rr * W + cc, run = dr && dc ? vc * Math.SQRT2 : vc;
      for (let g = cs[ncol]; g < cs[ncol + 1]; g++) { const b = candOf[g]; if (b !== a && ok(f, g, run)) addEdge(a, b, 0); }
    }
    if (extra) { const ex = extra.get(f); if (ex) for (let i = 0; i < ex.length; i += 2) { const b = candOf[ex[i]]; if (b !== a) addEdge(a, b, Math.max(1, ex[i + 1])); } }
  }
  log(`patches ${NN}, ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  t0 = Date.now();
  // 2. strongly connected parts (Tarjan, iterative): keep the big ones - ground you can reach and leave
  const idx = new Int32Array(NN).fill(-1), low = new Int32Array(NN), onSt = new Uint8Array(NN), comp = new Int32Array(NN).fill(-1);
  const adj = out.map((m) => (m ? [...m.keys()] : []));
  for (let n = 0; n < NN; n++) if (!adj[n]) adj[n] = [];
  let counter = 0, nComp = 0; const st = [], compFloors = [];
  for (let s = 0; s < NN; s++) {
    if (idx[s] >= 0) continue;
    const work = [[s, 0]]; idx[s] = low[s] = counter++; st.push(s); onSt[s] = 1;
    while (work.length) {
      const top = work[work.length - 1], u = top[0], a = adj[u];
      if (top[1] < a.length) {
        const v = a[top[1]++];
        if (idx[v] < 0) { idx[v] = low[v] = counter++; st.push(v); onSt[v] = 1; work.push([v, 0]); }
        else if (onSt[v] && idx[v] < low[u]) low[u] = idx[v];
      } else {
        work.pop();
        if (work.length) { const p = work[work.length - 1][0]; if (low[u] < low[p]) low[p] = low[u]; }
        if (low[u] === idx[u]) { let n = 0; for (;;) { const v = st.pop(); onSt[v] = 0; comp[v] = nComp; n += cCount[v]; if (v === u) break; } compFloors.push(n); nComp++; }
      }
    }
  }
  const MIN = Math.max(500, Math.floor(F * 0.002));
  const kept = (n) => compFloors[comp[n]] >= MIN;
  // 3. base node per square: the biggest kept patch, the lowest on a tie
  const baseOf = new Int32Array(NC).fill(-1);
  for (let n = 0; n < NN; n++) {
    if (!kept(n)) continue;
    const c = cCell[n], b = baseOf[c];
    if (b < 0 || cCount[n] > cCount[b] || (cCount[n] === cCount[b] && cZ[n] < cZ[b])) baseOf[c] = n;
  }
  // a small patch (half a square or less) joined both ways to a neighbouring square's base is part of that ground
  // (the strip of a terrace that pokes into the next square, the far side of a wall that cuts a corner off)
  const half = k * k / 2;
  const alias = new Int32Array(NN); for (let n = 0; n < NN; n++) alias[n] = n;
  const inn0 = new Array(NN); for (let a0 = 0; a0 < NN; a0++) if (kept(a0)) for (const b0 of adj[a0]) if (kept(b0)) (inn0[b0] = inn0[b0] || []).push(a0);
  let nAlias = 0;
  for (let n = 0; n < NN; n++) {
    if (!kept(n) || baseOf[cCell[n]] === n || cCount[n] > half || !out[n]) continue;
    let best = -1;
    for (const [b, cost] of out[n]) {
      if (cost !== 0 || !kept(b) || baseOf[cCell[b]] !== b || cCell[b] === cCell[n] || !(out[b] && out[b].get(n) === 0)) continue;
      // ...and only where everything the patch touches is next to that square too (else the merge would leave links
      // between squares that are not neighbours, which cost ten times a neighbour link to ship)
      if (process.env.FR_NAV_ALIAS === 'near') { // (measured: no smaller - off)
        let fits = true; const br = Math.floor(cCell[b] / CW), bc = cCell[b] % CW;
        const nextTo = (x) => Math.abs(Math.floor(cCell[x] / CW) - br) <= 1 && Math.abs((cCell[x] % CW) - bc) <= 1;
        for (const x of out[n].keys()) if (kept(x) && !nextTo(x)) { fits = false; break; }
        if (fits && inn0[n]) for (const x of inn0[n]) if (!nextTo(x)) { fits = false; break; }
        if (!fits) continue;
      }
      if (best < 0 || Math.abs(cZ[b] - cZ[n]) < Math.abs(cZ[best] - cZ[n])) best = b;
    }
    if (best >= 0) { alias[n] = best; nAlias++; }
  }
  // the node graph: base nodes are their square's index, the other patches come after (NC + j)
  const tid = new Int32Array(NN).fill(-1); const ovPatch = [];
  for (let n = 0; n < NN; n++) { if (!kept(n) || alias[n] !== n) continue; if (baseOf[cCell[n]] === n) tid[n] = cCell[n]; else { tid[n] = NC + ovPatch.length; ovPatch.push(n); } }
  const NT = NC + ovPatch.length;
  const E = new Array(NT), Rv = new Array(NT), alive = new Uint8Array(NT);
  for (let n = 0; n < NN; n++) if (tid[n] >= 0) alive[tid[n]] = 1;
  for (let a0 = 0; a0 < NN; a0++) {
    if (!kept(a0) || !out[a0]) continue;
    const ia = tid[alias[a0]];
    for (const [b0, cost] of out[a0]) {
      if (!kept(b0)) continue;
      const ib = tid[alias[b0]]; if (ia === ib) continue;
      let m = E[ia]; if (!m) E[ia] = m = new Map();
      const c = m.get(ib); if (c === undefined || (c !== 0 && (cost === 0 || cost < c))) m.set(ib, cost);
    }
  }
  for (let a0 = 0; a0 < NT; a0++) if (E[a0]) for (const b0 of E[a0].keys()) (Rv[b0] = Rv[b0] || new Set()).add(a0);
  const sqOf = (t) => (t < NC ? t : cCell[ovPatch[t - NC]]);
  const adjacent = (x, y) => { const sx = sqOf(x), sy = sqOf(y); return Math.abs(Math.floor(sx / CW) - Math.floor(sy / CW)) <= 1 && Math.abs((sx % CW) - (sy % CW)) <= 1; };
  const mark = new Int32Array(NT).fill(-1); let stamp = 0;
  // is b within `hops` steps of a, not through `skip` and not by the edge a -> b itself?
  const reach = (a0, targets, hops, skip, noDirect) => {
    stamp++; mark[a0] = stamp; let frontier = [a0], left = targets.length;
    const want = new Set(targets);
    for (let hop = 0; hop < hops && frontier.length && left; hop++) {
      const nx = [];
      for (const u of frontier) { const m = E[u]; if (!m) continue; for (const v of m.keys()) {
        if (v === skip || !alive[v] || mark[v] === stamp) continue;
        if (noDirect && u === a0 && want.has(v)) continue;
        mark[v] = stamp; nx.push(v); if (want.has(v)) left--;
      } }
      frontier = nx;
    }
    return left === 0;
  };
  const delNode = (n) => { alive[n] = 0; if (E[n]) for (const v of E[n].keys()) Rv[v] && Rv[v].delete(n); if (Rv[n]) for (const u of Rv[n]) E[u] && E[u].delete(n); E[n] = undefined; Rv[n] = undefined; };
  // overlay nodes the network does not need: every way in can get to each way out within a few steps without it
  // (a rock, the top of a bank). A bridge deck or an upper floor has no such way round and stays. Smallest first.
  const order = ovPatch.map((p, j) => NC + j).sort((x, y) => cCount[ovPatch[x - NC]] - cCount[ovPatch[y - NC]]);
  // ...unless it is part of something big enough to stand on its own (an upper floor, a long ledge): overlay nodes
  // joined to each other form a structure, and one of STRUCT floors or more (about a room) is kept whole
  const STRUCT = +(process.env.FR_NAV_STRUCT || 20);
  const sp = new Int32Array(ovPatch.length); for (let j = 0; j < sp.length; j++) sp[j] = j;
  const sfind = (x) => { while (sp[x] !== x) { sp[x] = sp[sp[x]]; x = sp[x]; } return x; };
  for (let j = 0; j < ovPatch.length; j++) { const m = E[NC + j]; if (m) for (const v of m.keys()) if (v >= NC) { const x = sfind(j), y = sfind(v - NC); if (x !== y) sp[x] = y; } }
  const sFloors = new Int32Array(ovPatch.length); for (let j = 0; j < ovPatch.length; j++) sFloors[sfind(j)] += cCount[ovPatch[j]];
  let nBypass = 0;
  for (const n of order) {
    if (sFloors[sfind(n - NC)] >= STRUCT) continue;
    const outs = E[n] ? [...E[n].keys()] : [], ins = Rv[n] ? [...Rv[n]] : [];
    let need = false;
    for (const a0 of ins) { if (!reach(a0, outs.filter((v) => v !== a0), 4, n, false)) { need = true; break; } }
    if (!need) { delNode(n); nBypass++; }
  }
  // links between squares that are not neighbours (left by the merging above): keep one only if there is no short
  // way round
  let nFar = 0;
  for (let a0 = 0; a0 < NT; a0++) {
    if (!alive[a0] || !E[a0]) continue;
    for (const [b0, cost] of [...E[a0]]) {
      if (cost !== 0 || adjacent(a0, b0)) continue;
      if (reach(a0, [b0], 3, -1, true)) { E[a0].delete(b0); Rv[b0].delete(a0); nFar++; }
    }
  }
  // a recorded trail or a lift between two nodes: never cheaper than the squares are apart (a trail must not become a
  // highway just because its points sit a little closer than the squares' middles), and not kept at all when plain
  // steps get there about as fast
  const centre = (x, y) => { const sx = sqOf(x), sy = sqOf(y); return Math.hypot(Math.floor(sx / CW) - Math.floor(sy / CW), (sx % CW) - (sy % CW)) * cell; };
  let nTrail = 0;
  for (let a0 = 0; a0 < NT; a0++) {
    if (!alive[a0] || !E[a0]) continue;
    for (const [b0, cost] of [...E[a0]]) {
      if (cost === 0) continue;
      const c2 = Math.max(cost, centre(a0, b0));
      if (reach(a0, [b0], Math.ceil(c2 * 1.25 / cell) + 1, -1, true)) { E[a0].delete(b0); Rv[b0].delete(a0); nTrail++; } else E[a0].set(b0, c2);
    }
  }
  // 4. number the overlay nodes by square, then the base bytes and the explicit links
  const id = new Int32Array(NT).fill(-1); const over = [];
  for (let c = 0; c < NC; c++) if (alive[c]) id[c] = c;
  const ovAlive = []; for (let j = 0; j < ovPatch.length; j++) if (alive[NC + j]) ovAlive.push(j);
  ovAlive.sort((x, y) => cCell[ovPatch[x]] - cCell[ovPatch[y]] || cZ[ovPatch[x]] - cZ[ovPatch[y]]);
  const repOf = new Int32Array(NN).fill(-1); for (let f = F - 1; f >= 0; f--) repOf[candOf[f]] = f; // a floor of each patch (for checks against the walk map)
  for (const j of ovAlive) { const p = ovPatch[j]; id[NC + j] = NC + over.length; over.push({ cell: cCell[p], z: cZ[p], swim: cSwim[p] / cCount[p] > 0.5 ? 1 : 0, count: cCount[p], rep: repOf[p] }); }
  const base = new Uint8Array(NC), swimBits = new Uint8Array(NC), baseZ = new Float32Array(NC).fill(NaN);
  const links = [];
  const dirBit = new Map(); DIRS.forEach(([dr, dc], d) => dirBit.set(dr * 3 + dc, d));
  let nNodes = 0;
  for (let a0 = 0; a0 < NT; a0++) {
    if (!alive[a0]) continue;
    nNodes++;
    if (!E[a0]) continue;
    for (const [b0, cost] of E[a0]) {
      const ia = id[a0], ib = id[b0];
      if (ia < NC && ib < NC && cost === 0) {
        const dr = Math.floor(ia / CW) - Math.floor(ib / CW), dc = (ia % CW) - (ib % CW);
        const d = Math.abs(dr) <= 1 && Math.abs(dc) <= 1 ? dirBit.get(dr * 3 + dc) : undefined;
        if (d !== undefined) { base[ib] |= 1 << d; continue; }
      }
      links.push([ia, ib, Math.round(cost)]);
    }
  }
  // a base node nothing steps into from a neighbouring base still has to read as "there is ground here": the search
  // and the line check ask the byte. Such a node (reached only by links) is told apart by the overlay table instead.
  for (let c = 0; c < NC; c++) { const n = baseOf[c]; if (n >= 0 && alive[c]) { swimBits[c] = cSwim[n] / cCount[n] > 0.5 ? 1 : 0; baseZ[c] = cZ[n]; } }
  log(`kept ${nNodes} nodes (${over.length} overlay; ${nAlias} small patches merged into a neighbour, ${nBypass} not needed), ${links.length} links (${nFar} far and ${nTrail} trail links not needed), ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  const repFloor = (n) => (n < NC ? repOf[baseOf[n]] : over[n - NC].rep);
  const nodeOfFloor = new Int32Array(F).fill(-1);
  for (let f = 0; f < F; f++) { const p = candOf[f]; if (kept(p)) { const t = tid[alias[p]]; if (t >= 0 && alive[t]) nodeOfFloor[f] = id[t]; } }
  // can this chain of nodes really be walked on the walk map, staying on their floors? -> yards, or Infinity
  const walkable = (nodes) => {
    const allow = new Set(nodes), goal = nodes[nodes.length - 1];
    const d = new Map(); let frontier = [];
    for (let f = 0; f < F; f++) if (nodeOfFloor[f] === nodes[0]) { d.set(f, 0); frontier.push(f); }
    // Dijkstra with a plain sorted frontier (the corridor is small)
    const done = new Set();
    for (;;) {
      let best = -1, bd = Infinity; for (const f of frontier) { const v = d.get(f); if (!done.has(f) && v < bd) { bd = v; best = f; } }
      if (best < 0) return Infinity;
      done.add(best); frontier = frontier.filter((f) => f !== best);
      if (nodeOfFloor[best] === goal) return bd;
      const col = colOf[best], r = Math.floor(col / W), c = col % W;
      const relax = (g, cost) => { if (done.has(g) || !allow.has(nodeOfFloor[g])) return; const nd = bd + cost; if (!d.has(g)) frontier.push(g); if (!d.has(g) || nd < d.get(g)) d.set(g, nd); };
      for (const [dr, dc] of DIRS) { const rr = r + dr, cc = c + dc; if (rr < 0 || cc < 0 || rr >= H || cc >= W) continue; const ncol = rr * W + cc, run = dr && dc ? vc * Math.SQRT2 : vc; for (let g = cs[ncol]; g < cs[ncol + 1]; g++) if (ok(best, g, run)) relax(g, run); }
      if (extra) { const ex = extra.get(best); if (ex) for (let i = 0; i < ex.length; i += 2) relax(ex[i], ex[i + 1]); }
    }
  };
  return { area, cell, CW, CH, NC, bounds: B, base, swim: swimBits, baseZ, baseOf, over, links, floors: F, nNodes, nav, repFloor, walkable, hasBase: alive.subarray(0, NC) };
}

// What the ground of each square is like (see "terr" at the top): { terr, terrA, terrH (Uint8Array(NC) or null),
// roads, mobs (counts) }, or null for a city (streets everywhere, nothing hostile to walk round).
let DB = null, RAW = null;
function terrainOf(G, zone) {
  if (CITY.test(zone.name)) return null;
  const { NC, CW, CH, cell, bounds: B, hasBase, swim } = G;
  const terr = new Uint8Array(NC), layers = { A: new Uint8Array(NC), H: new Uint8Array(NC) };
  let roads = 0;
  const R = Roads.load(zone.area);
  if (R) {
    const n = Math.max(2, Math.round(cell / R.cell));
    for (let c = 0; c < NC; c++) {
      if (!hasBase[c] || swim[c]) continue;
      const Y = B.left - (c % CW) * cell, X = B.top - Math.floor(c / CW) * cell; // the square's north-west corner
      let on = 0;
      for (let i = 0; i < n; i++) for (let j = 0; j < n; j++) if (R.at(X - (i + 0.5) * cell / n, Y - (j + 0.5) * cell / n) >= 128) on++;
      if (on >= ROAD_SHARE * n * n) { terr[c] |= 64; roads++; }
    }
  }
  if (!DB) { DB = JSON.parse(fs.readFileSync(path.join(QDB, 'db.json'), 'utf8')); RAW = JSON.parse(fs.readFileSync(path.join(QDB, 'json', 'npcs.json'), 'utf8')); }
  const mobs = { both: 0, A: 0, H: 0 }; let unknown = 0;
  const rad = Math.ceil(MOB_NEAR / cell) + 1;
  for (const n of Object.values(DB.npcs)) {
    if (!n || n.friendly === 'AH' || !(n.maxLevel > 0) || !n.spawns || !n.spawns.length) continue;
    // hostile is only known where QuestieDB has the NPC's faction (field 12). The NPCs Forever added have none: for
    // them "friendly to nobody" only means nobody filled it in, and their "spawns" are sightings along the way they
    // roam (one rare bear: 153 points; Wowhead Forever shows 7) - a cloud that says little about where it stands.
    if (!(RAW[n.id] && RAW[n.id][12])) { unknown++; continue; }
    // not a spawn of this zone: a hunter's or warlock's pet someone was seen with ("Cat", level 7-30, in 40 zones;
    // "Infernal" in the capitals) - a level range no wild mob has, or sightings all over the world
    if (n.maxLevel - (n.minLevel || n.maxLevel) > 5 || new Set(n.spawns.map((p) => p.zone)).size > 6) continue;
    const who = !n.friendly ? 'both' : n.friendly === 'H' ? 'A' : 'H'; // hostile to whom
    const grid = who === 'both' ? terr : layers[who];
    const code = Math.min(31, Math.ceil(n.maxLevel / 2));
    for (const p of n.spawns) {
      if (p.zone !== zone.area) continue;
      const Y = B.left - (p.x / 100) * (B.left - B.right), X = B.top - (p.y / 100) * (B.top - B.bottom);
      const c0 = Math.floor((B.left - Y) / cell), r0 = Math.floor((B.top - X) / cell);
      mobs[who]++;
      for (let r = Math.max(0, r0 - rad); r <= Math.min(CH - 1, r0 + rad); r++) for (let c = Math.max(0, c0 - rad); c <= Math.min(CW - 1, c0 + rad); c++) {
        const d = Math.hypot(B.left - (c + 0.5) * cell - Y, B.top - (r + 0.5) * cell - X);
        if (d > MOB_NEAR) continue;
        const k = r * CW + c; if (!hasBase[k]) continue;
        const was = grid[k];
        grid[k] = (was & 0xc0) | ((was & 32) || d <= MOB_CLOSE ? 32 : 0) | Math.max(was & 31, code);
      }
    }
  }
  for (let c = 0; c < NC; c++) if (swim[c]) terr[c] |= 128;
  return { terr, terrA: mobs.A ? layers.A : null, terrH: mobs.H ? layers.H : null, roads, mobs, unknown, hasRoads: !!R };
}

// --- packing -------------------------------------------------------------------------------------------------------
// Text the addon can unpack quickly with string.byte / string.rep / string.sub (Lua 5.1 has no bit library).
// 85 printable characters, none of them trouble inside a Lua long string (no brackets, quotes or backslash):
const ALPHA = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$&()*+,-./:;<=>?@_{}~';
const A = ALPHA.length; if (A !== 85) throw new Error("the alphabet must have 85 characters");
const num2 = (n) => { if (n < 0 || n >= A * A) throw new Error('num2 ' + n); return ALPHA[Math.floor(n / A)] + ALPHA[n % A]; };
const num3 = (n) => { if (n < 0 || n >= A * A * A) throw new Error('num3 ' + n); return ALPHA[Math.floor(n / A / A)] + ALPHA[Math.floor(n / A) % A] + ALPHA[n % A]; };
const num4 = (n) => num2(Math.floor(n / (A * A))) + num2(n % (A * A));
// The base grid, row by row, as tokens:
//   run     the same byte n times
//   above   n bytes copied from the row above (same columns)
//   literal n bytes, each one character of the zone's own alphabet (its 84 commonest bytes) or an escape
// Token head: one character t (0..84): t < 28 run of t+1 of the byte that follows; 28..55 "above" of t-27;
// 56..83 literal of t-55 bytes; 84 long form: kind (0 run, 1 above) and the length as 2 characters follow (then the
// byte for a run). A byte: its one-character code, or the escape (code 84) and its value as 2 characters (hi*16+lo).
function packBase(G, grid) {
  const { CW, CH } = G, base = grid || G.base;
  const freq = new Array(256).fill(0); for (const b of base) freq[b]++;
  const order = [...Array(256).keys()].filter((b) => freq[b] > 0).sort((x, y) => freq[y] - freq[x]);
  const codes = order.slice(0, A - 1), codeOf = new Map(codes.map((b, i) => [b, i]));
  const sym = (b) => (codeOf.has(b) ? ALPHA[codeOf.get(b)] : ALPHA[A - 1] + ALPHA[b >> 4] + ALPHA[b & 15]);
  const parts = [];
  for (let r = 0; r < CH; r++) {
    const o = r * CW; let c = 0; let lit = [];
    const flush = () => { while (lit.length) { const n = Math.min(28, lit.length); parts.push(ALPHA[55 + n] + lit.splice(0, n).map(sym).join('')); } };
    while (c < CW) {
      let run = 1; while (c + run < CW && base[o + c + run] === base[o + c]) run++;
      let up = 0; if (r > 0) while (c + up < CW && base[o + c + up] === base[o - CW + c + up]) up++;
      if (up >= 2 && up >= run) { flush(); if (up <= 28) parts.push(ALPHA[27 + up]); else parts.push(ALPHA[84] + '1' + num2(up)); c += up; }
      else if (run >= 3 || (run >= 2 && !lit.length)) { flush(); if (run <= 28) parts.push(ALPHA[run - 1] + sym(base[o + c])); else parts.push(ALPHA[84] + '0' + num2(run) + sym(base[o + c])); c += run; }
      else { lit.push(base[o + c]); c++; }
    }
    flush();
  }
  return { codes: codes.map((b) => ALPHA[b >> 4] + ALPHA[b & 15]).join(''), data: parts.join('') };
}
// one bit per square as alternating runs (starting with 0s), each run one character (0..83) or 84 + 3 characters
function packBits(bits) {
  const parts = []; let cur = 0, n = 0;
  const emit = (len) => { parts.push(len < 84 ? ALPHA[len] : ALPHA[84] + num3(len)); };
  for (let i = 0; i < bits.length; i++) { if (bits[i] === cur) n++; else { emit(n); cur ^= 1; n = 1; } }
  emit(n);
  return parts.join('');
}
// Overlay nodes, in square order (then by height). For each node:
//   square   the step from the previous overlay node's square: one character (0..83) or 84 + 4 characters
//   base z   2 characters, only for the first overlay node of a square: the height of that square's base node
//   z        2 characters (yards above zmin)
//   head     1 character: swim * 42 + the number of near links (0..41)
//   links    1 character each: where * 9 + slot * 3 + kind
//            where: 0..7 the neighbouring square in that direction, 8 this square; slot: 0 its base node, 1 or 2 its
//            first or second overlay node; kind: 0 it steps to me, 1 I step to it, 2 both ways
//            (a third or later overlay node of a square: 84, then (where * 251 + slot) * 3 + kind as 2 characters)
// A link between two overlay nodes is written once, at the later node. Everything else (lifts, trails, links between
// squares that are not neighbours, a third overlay node) goes to the far list: from (4), to (4), yards (2; 0 = measure).
function pack(G) {
  const { over, links, baseZ, NC, CW } = G;
  const b = packBase(G);
  let zmin = 0; for (const o of over) if (o.z < zmin) zmin = o.z; for (const v of baseZ) if (v < zmin) zmin = v;
  zmin = Math.floor(zmin) - 1;
  const zq = (v) => Math.max(0, Math.min(A * A - 1, Math.round(v - zmin)));
  const sq = (n) => (n < NC ? n : over[n - NC].cell);
  const slotOf = new Int32Array(over.length); // 1-based place among the overlay nodes of its square
  for (let j = 0; j < over.length; j++) slotOf[j] = j > 0 && over[j - 1].cell === over[j].cell ? slotOf[j - 1] + 1 : 1;
  const dirIdx = new Map(); DIRS.forEach(([dr, dc], d) => dirIdx.set(dr * 3 + dc, d)); dirIdx.set(0, 8);
  const near = over.map(() => new Map()); // owner overlay node -> (other node -> kind bits: 1 it->me, 2 me->it)
  const far = [];
  for (const [x, y, cost] of links) {
    let owner = -1, other = -1, bit = 0;
    if (cost === 0 && (x >= NC || y >= NC)) {
      if (x >= NC && (y < NC || x > y)) { owner = x; other = y; bit = 2; } else { owner = y; other = x; bit = 1; }
      const so = sq(owner), st = sq(other), dr = Math.floor(st / CW) - Math.floor(so / CW), dc = (st % CW) - (so % CW);
      const slot = other < NC ? 0 : slotOf[other - NC];
      if (Math.abs(dr) > 1 || Math.abs(dc) > 1 || slot > 250) owner = -1;
    }
    if (owner < 0) { far.push([x, y, cost]); continue; }
    const m = near[owner - NC]; m.set(other, (m.get(other) || 0) | bit);
  }
  const parts = []; let prev = 0;
  over.forEach((o, j) => {
    const step = o.cell - prev; prev = o.cell;
    parts.push(step < 84 ? ALPHA[step] : ALPHA[84] + num4(step));
    if (slotOf[j] === 1) parts.push(num2(zq(isNaN(baseZ[o.cell]) ? o.z : baseZ[o.cell])));
    let list = [...near[j]];
    if (list.length > 41) { for (const [other, bits] of list.slice(41)) { if (bits & 1) far.push([other, NC + j, 0]); if (bits & 2) far.push([NC + j, other, 0]); } list = list.slice(0, 41); }
    parts.push(num2(zq(o.z)) + ALPHA[(o.swim ? 42 : 0) + list.length]);
    for (const [other, bits] of list) {
      const st = sq(other), dr = Math.floor(st / CW) - Math.floor(o.cell / CW), dc = (st % CW) - (o.cell % CW);
      const where = dirIdx.get(dr * 3 + dc), slot = other < NC ? 0 : slotOf[other - NC];
      if (slot <= 2) parts.push(ALPHA[where * 9 + slot * 3 + (bits - 1)]);
      else parts.push(ALPHA[84] + num2((where * 251 + slot) * 3 + (bits - 1))); // a crowded square: the long form
    }
  });
  const farS = far.map(([x, y, cost]) => num4(x) + num4(y) + num2(Math.min(A * A - 1, Math.round(cost)))).join('');
  // base nodes nothing steps into from a neighbouring base (their byte is 0, like a square with no ground): listed,
  // so the addon still knows there is ground there
  const solo = []; for (let c = 0; c < NC; c++) if (!G.base[c] && G.hasBase[c]) solo.push(num4(c));
  return { codes: b.codes, base: b.data, swim: packBits(G.swim), over: parts.join(''), nOver: over.length, far: farS, nFar: far.length, solo: solo.join(''), zmin };
}

function luaText(uiMap, zone, G, pk, T) {
  const B = G.bounds, L = [];
  L.push(`-- Generated by tools/navgrid.js from terrain/area${G.area}.vox.* (${zone.name}): the navigation grid the map line runs`);
  L.push(`-- on (Nav.lua). ${G.CW}x${G.CH} squares of ${G.cell} yd, ${G.over.length} overlay nodes, ${G.links.length} links. Regenerate, don't edit.`);
    L.push('ForeverRouteNavData = ForeverRouteNavData or {}');
  L.push(`ForeverRouteNavData[${uiMap}] = {`);
  L.push(`  v = 2, area = ${G.area}, inst = ${zone.inst}, cell = ${G.cell}, W = ${G.CW}, H = ${G.CH},`);
  L.push(`  left = ${B.left}, top = ${B.top}, right = ${B.right}, bottom = ${B.bottom}, zmin = ${pk.zmin},`);
  L.push(`  codes = [==[${pk.codes}]==],`);
  L.push(`  base = [==[${pk.base}]==],`);
  L.push(`  swim = [==[${pk.swim}]==],`);
  L.push(`  nOver = ${pk.nOver}, over = [==[${pk.over}]==],`);
  L.push(`  far = [==[${pk.far}]==],`);
  L.push(`  solo = [==[${pk.solo}]==],`);
  if (T) for (const k of ['terr', 'terrA', 'terrH']) if (T[k]) { const p = packBase(G, T[k]); L.push(`  ${k}Codes = [==[${p.codes}]==], ${k} = [==[${p.data}]==],`); }
  L.push('}');
  return L.join('\n') + '\n';
}

// --- the search the addon runs, here for measuring and pictures (Nav.lua is the real one) --------------------------
// unpack the base grid again the way Nav.lua does: the packing must round-trip
function unpackCheck(G, pk, grid) {
  if (!pk.base) pk = { codes: pk.codes, base: pk.data };
  grid = grid || G.base;
  const { CW, CH } = G, codes = []; for (let i = 0; i < pk.codes.length; i += 2) codes.push(ALPHA.indexOf(pk.codes[i]) * 16 + ALPHA.indexOf(pk.codes[i + 1]));
  const out = new Uint8Array(CW * CH); let p = 0, o = 0; const s = pk.base, v = (i) => ALPHA.indexOf(s[i]);
  const readSym = () => { const c = v(p++); if (c < A - 1) return codes[c]; const b = v(p) * 16 + v(p + 1); p += 2; return b; };
  while (p < s.length) {
    const t = v(p++); let kind, n;
    if (t === 84) { kind = v(p++); n = v(p) * A + v(p + 1); p += 2; } else if (t < 28) { kind = 0; n = t + 1; } else if (t < 56) { kind = 1; n = t - 27; } else { kind = 2; n = t - 55; }
    if (kind === 0) { const b = readSym(); out.fill(b, o, o + n); } else if (kind === 1) { for (let i = 0; i < n; i++) out[o + i] = out[o + i - CW]; } else for (let i = 0; i < n; i++) out[o + i] = readSym();
    o += n;
  }
  if (o !== out.length) throw new Error(`unpack: ${o} of ${out.length} squares`);
  for (let i = 0; i < out.length; i++) if (out[i] !== grid[i]) throw new Error('unpack: square ' + i + ' differs');
}
function runtime(G) {
  const { NC, over, links } = G;
  const inc = new Map(), nodesAt = new Map();
  for (const [a, b, cost] of links) { let l = inc.get(b); if (!l) inc.set(b, (l = [])); l.push(a, cost); }
  over.forEach((o, j) => { let l = nodesAt.get(o.cell); if (!l) nodesAt.set(o.cell, (l = [])); l.push(NC + j); });
  return { inc, nodesAt };
}
// from/to: world { x (HBD x = wow Y), y (HBD y = wow X) }. Searches from the target backwards (like Nav.lua).
function search(G, from, to, opts = {}) {
  const { CW, CH, NC, cell, bounds: B, base, swim, over } = G;
  const R = G._rt || (G._rt = runtime(G));
  const cellAt = (wx, wy) => { const c = Math.floor((B.left - wx) / cell), r = Math.floor((B.top - wy) / cell); return r < 0 || c < 0 || r >= CH || c >= CW ? -1 : r * CW + c; };
  const cellOf = (n) => (n < NC ? n : over[n - NC].cell);
  const zOf = (n) => (n < NC ? G.baseZ[n] : over[n - NC].z);
  const near = (wx, wy, zWant) => {
    const c0 = cellAt(wx, wy); if (c0 < 0) return [];
    const r0 = Math.floor(c0 / CW), k0 = c0 % CW;
    for (let rad = 0; rad <= 6; rad++) {
      const found = [];
      for (let dr = -rad; dr <= rad; dr++) for (let dc = -rad; dc <= rad; dc++) {
        if (Math.max(Math.abs(dr), Math.abs(dc)) !== rad) continue;
        const r = r0 + dr, c = k0 + dc; if (r < 0 || c < 0 || r >= CH || c >= CW) continue;
        const ci = r * CW + c;
        if (base[ci] || G.hasBase[ci]) found.push(ci);
        const l = R.nodesAt.get(ci); if (l) found.push(...l);
      }
      if (found.length) {
        if (zWant == null) return found.filter((n) => n < NC).length ? found.filter((n) => n < NC) : found;
        let best = found[0]; for (const n of found) if (Math.abs(zOf(n) - zWant) < Math.abs(zOf(best) - zWant)) best = n;
        return [best];
      }
    }
    return [];
  };
  const goals = near(to.x, to.y, opts.tz), starts = new Set(near(from.x, from.y, opts.fz));
  if (!goals.length || !starts.size) return { path: null, expansions: 0 };
  const sc = cellOf([...starts][0]), sr = Math.floor(sc / CW), scc = sc % CW;
  const wgt = opts.weight || 1.2;
  const h = (n) => { const c = cellOf(n), dr = Math.abs(Math.floor(c / CW) - sr), dc = Math.abs((c % CW) - scc); return ((dr > dc ? dr : dc) + 0.4142 * (dr > dc ? dc : dr)) * cell * wgt; };
  const g = new Map(), next = new Map(), closed = new Set();
  const hk = [], hv = [];
  const push = (key, v) => { hk.push(key); hv.push(v); let i = hk.length - 1; while (i) { const p = (i - 1) >> 1; if (hk[p] <= hk[i]) break; [hk[p], hk[i]] = [hk[i], hk[p]]; [hv[p], hv[i]] = [hv[i], hv[p]]; i = p; } };
  const pop = () => { const top = hv[0]; const lk = hk.pop(), lv = hv.pop(); if (hk.length) { hk[0] = lk; hv[0] = lv; let i = 0; for (;;) { const l = 2 * i + 1, r = l + 1; let m = i; if (l < hk.length && hk[l] < hk[m]) m = l; if (r < hk.length && hk[r] < hk[m]) m = r; if (m === i) break; [hk[m], hk[i]] = [hk[i], hk[m]]; [hv[m], hv[i]] = [hv[i], hv[m]]; i = m; } } return top; };
  for (const t of goals) { g.set(t, 0); push(h(t), t); }
  const isSwim = (n) => (n < NC ? swim[n] : over[n - NC].swim);
  let expansions = 0, found = -1;
  while (hk.length) {
    const u = pop(); if (closed.has(u)) continue; closed.add(u); expansions++;
    if (starts.has(u)) { found = u; break; }
    const gu = g.get(u), su = isSwim(u);
    const relax = (v, cost) => { if (closed.has(v)) return; const nv = gu + cost * (su || isSwim(v) ? 1.5 : 1); if (nv < (g.has(v) ? g.get(v) : Infinity)) { g.set(v, nv); next.set(v, u); push(nv + h(v), v); } };
    if (u < NC) { const m = base[u], r = Math.floor(u / CW), c = u % CW; for (let d = 0; d < 8; d++) if (m & (1 << d)) relax((r + DIRS[d][0]) * CW + c + DIRS[d][1], d === 0 || d === 2 || d === 5 || d === 7 ? cell * Math.SQRT2 : cell); }
    const l = R.inc.get(u);
    if (l) for (let i = 0; i < l.length; i += 2) { const v = l[i]; let cost = l[i + 1]; if (!cost) { const a = cellOf(u), b = cellOf(v); cost = Math.max(cell / 2, Math.hypot(Math.floor(a / CW) - Math.floor(b / CW), (a % CW) - (b % CW)) * cell); } relax(v, cost); }
  }
  if (found < 0) return { path: null, expansions };
  const nodes = []; for (let n = found; n !== undefined; n = next.get(n)) nodes.push(n);
  const pt = (n) => { const c = cellOf(n); return { x: B.left - ((c % CW) + 0.5) * cell, y: B.top - (Math.floor(c / CW) + 0.5) * cell, n }; };
  return { expansions, length: g.get(found), nodes, path: nodes.map(pt) };
}

function toWorld(B, px, py) { return { x: B.left + (px / 100) * (B.right - B.left), y: B.top + (py / 100) * (B.bottom - B.top) }; }

function bake(ui, cellArg, write, log) {
  const zone = zoneOf(ui);
  if (!fs.existsSync(path.join(TERRAIN, `area${zone.area}.vox.json`))) { log(`${zone.name} (${ui}): no walk map`); return null; }
  const cell = +cellArg || cellFor(zone);
  const t0 = Date.now();
  const G = buildGraph(zone.area, cell, (m) => log('  ' + m));
  const pk = pack(G);
  unpackCheck(G, pk);
  const T = terrainOf(G, zone);
  if (T) for (const k of ['terr', 'terrA', 'terrH']) if (T[k]) unpackCheck(G, packBase(G, T[k]), T[k]);
  const text = luaText(ui, zone, G, pk, T);
  if (T) log(`  ground: ${T.hasRoads ? T.roads + ' road squares' : 'NO ROAD DATA (node tools/roads.js build ' + zone.area + ')'}; hostile spawns ${T.mobs.both} (to both), ${T.mobs.A} (to the Alliance only), ${T.mobs.H} (to the Horde only); ${['terr', 'terrA', 'terrH'].map((k) => (T[k] ? k + ' ' + (packBase(G, T[k]).data.length + packBase(G, T[k]).codes.length) + ' B' : '')).filter(Boolean).join(', ')}`);
  const sizes = { base: pk.base.length + pk.codes.length, swim: pk.swim.length, over: pk.over.length, far: pk.far.length, file: Buffer.byteLength(text), gz: zlib.gzipSync(text, { level: 9 }).length };
  log(`${zone.name} (map ${ui}, area ${zone.area}) @${cell} yd: ${G.CW}x${G.CH} = ${G.NC} squares, ${G.nNodes} nodes, ${G.over.length} overlay, ${G.links.length} links (${pk.nFar} far); base ${sizes.base} B, swim ${sizes.swim}, overlay ${sizes.over}, far ${sizes.far}; file ${sizes.file} B (zipped ${sizes.gz}) (${((Date.now() - t0) / 1000).toFixed(1)}s)`);
  if (write) { const out = path.join(ROOT, 'addon', 'ForeverRoute', 'Nav', `Nav${ui}.lua`); fs.mkdirSync(path.dirname(out), { recursive: true }); fs.writeFileSync(out, text); log('  wrote ' + out); }
  return { zone, G, pk, sizes, T };
}

if (require.main === module) {
  const [cmd, ui, ...rest] = process.argv.slice(2);
  const log = (m) => console.error(m);
  if (cmd === 'build' || cmd === 'stats') {
    const list = ui === 'all' ? zones().map((z) => z.ui_map_id) : String(ui).split(',');
    let total = 0, gz = 0;
    for (const u of list) { const r = bake(u, rest[0], cmd === 'build', log); if (r) { total += r.sizes.file; gz += r.sizes.gz; } }
    if (list.length > 1) log(`total ${total} B (${(total / 1048576).toFixed(2)} MB), zipped ${(gz / 1048576).toFixed(2)} MB`);
  } else if (cmd === 'test') {
    const r = bake(ui, rest[0] === '-' ? null : rest[0], false, log); const G = r.G;
    const pts = rest.slice(1).map((s) => s.split(',').map(Number));
    for (let i = 0; i + 1 < pts.length; i += 2) {
      const a = toWorld(G.bounds, pts[i][0], pts[i][1]), b = toWorld(G.bounds, pts[i + 1][0], pts[i + 1][1]);
      const straight = Math.hypot(a.x - b.x, a.y - b.y);
      // the walk map's own answer (what the planner would say), to compare
      let ref = NaN, fz, tz; try { const P1 = { x: pts[i][0], y: pts[i][1] }, P2 = { x: pts[i + 1][0], y: pts[i + 1][1] }; ref = G.nav.dist(P1, P2); const f1 = G.nav.anchor(P1), f2 = G.nav.anchor(P2); if (f1 >= 0) fz = G.nav.z[f1]; if (f2 >= 0) tz = G.nav.z[f2]; } catch (e) {}
      for (const weight of [1, 1.2, 1.5]) {
        const t1 = Date.now(); const s = search(G, a, b, { weight, fz, tz });
        let wm = NaN; if (s.path) { const fa = G.repFloor(s.nodes[0]), fb = G.repFloor(s.nodes[s.nodes.length - 1]); wm = G.nav.field(fa, [fb])[fb]; }
        console.log(`${pts[i]} -> ${pts[i + 1]} w${weight}: ${s.path ? Math.round(s.length) + ' yd (straight ' + Math.round(straight) + ', walk map between the same floors ' + Math.round(wm) + ', walking these very squares ' + Math.round(G.walkable(s.nodes)) + ', planner anchors ' + Math.round(ref) + '), ' + s.path.length + ' squares' : 'no path'}, ${s.expansions} expansions, ${Date.now() - t1}ms`);
      }
    }
  } else if (cmd === 'png') {
    // dark = no ground, green = base ground (lighter where some neighbour is cut off), blue = water, orange = a square
    // with overlay nodes; the path in yellow (red on overlay nodes)
    const r = bake(ui, null, false, log); const G = r.G;
    const S = Math.max(1, Math.floor(1740 / G.CW)), Wd = G.CW * S, Hd = G.CH * S, img = Buffer.alloc((Wd * 3 + 1) * Hd);
    const R = runtime(G);
    const put = (c, col) => { const r0 = Math.floor(c / G.CW) * S, c0 = (c % G.CW) * S; for (let y = 0; y < S; y++) for (let x = 0; x < S; x++) { const o = (r0 + y) * (Wd * 3 + 1) + 1 + (c0 + x) * 3; img[o] = col[0]; img[o + 1] = col[1]; img[o + 2] = col[2]; } };
    for (let c = 0; c < G.NC; c++) put(c, R.nodesAt.has(c) ? [200, 120, 40] : G.base[c] === 255 ? (G.swim[c] ? [40, 60, 120] : [60, 90, 60]) : G.base[c] ? (G.swim[c] ? [50, 80, 150] : [90, 130, 90]) : [15, 15, 18]);
    if (rest[1]) {
      const p1 = rest[1].split(',').map(Number), p2 = rest[2].split(',').map(Number);
      const s = search(G, toWorld(G.bounds, p1[0], p1[1]), toWorld(G.bounds, p2[0], p2[1]));
      console.error(s.path ? `path ${Math.round(s.length)} yd, ${s.expansions} expansions` : 'no path');
      if (s.path) for (const n of s.nodes) put(n < G.NC ? n : G.over[n - G.NC].cell, n < G.NC ? [255, 240, 80] : [255, 80, 80]);
    }
    const crcT = new Int32Array(256).map((_, n) => { let c = n; for (let i = 0; i < 8; i++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c; });
    const crc = (buf) => { let c = -1; for (const x of buf) c = crcT[(c ^ x) & 255] ^ (c >>> 8); return (c ^ -1) >>> 0; };
    const ch = (t, d) => { const l = Buffer.alloc(4); l.writeUInt32BE(d.length); const td = Buffer.concat([Buffer.from(t), d]); const cb = Buffer.alloc(4); cb.writeUInt32BE(crc(td)); return Buffer.concat([l, td, cb]); };
    const ih = Buffer.alloc(13); ih.writeUInt32BE(Wd, 0); ih.writeUInt32BE(Hd, 4); ih[8] = 8; ih[9] = 2;
    fs.writeFileSync(rest[0], Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), ch('IHDR', ih), ch('IDAT', zlib.deflateSync(img)), ch('IEND', Buffer.alloc(0))]));
  } else console.error('usage: node navgrid.js build|stats <uiMap|all> [cell] | test <uiMap> <cell|-> x,y x,y ... | png <uiMap> <out.png> [x,y x,y]');
}
module.exports = { buildGraph, pack, luaText, search, zoneOf, toWorld, cellFor, bake, terrainOf, DIRS, MOB_NEAR, MOB_CLOSE };
