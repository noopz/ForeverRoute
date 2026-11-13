// Layered walk map (Recast-style, simplified) from terrain + building/doodad collision.
//  build:  node voxnav.js build <wowRoot> <terrainDir> <area> [cell=2]
//  test:   node voxnav.js test <terrainDir> <area> x1,y1 x2,y2 ...
// Each 2-yard column holds solid spans (from triangles); a span top is a walkable floor when the surface
// there is under maxSlope and there is >= 2 yards of headroom. Floors connect to neighbouring floors when
// the step up is small (or the slope is walkable) or the drop is under maxDrop.
const fs = require('fs');
const path = require('path');

const P = { maxSlope: 50, climb: 1.2, maxDrop: 10, headroom: 2.0, swimDepth: 2.0, swimFactor: 1.5 };

function build(root, dir, area, cell) {
  const Casc = require('./casc');
  const { collect, TILE } = require('./geometry');
  const meta = JSON.parse(fs.readFileSync(path.join(dir, `area${area}.json`), 'utf8'));
  const B = meta.bounds;
  const hb = fs.readFileSync(path.join(dir, `area${area}.height.f32`)), TH = new Float32Array(hb.buffer, hb.byteOffset, hb.length / 4);
  const TW = fs.readFileSync(path.join(dir, `area${area}.walk.u8`));
  const casc = new Casc(root, 'wowf'); casc.loadEncoding(); casc.loadRoot();
  const wdt = casc.readFdid({ 0: 775971, 1: 782779 }[meta.map]);
  const tiles = [];
  for (let X = B.bottom; X < B.top + TILE; X += TILE) for (let Y = B.right; Y < B.left + TILE; Y += TILE) {
    const r = Math.floor(32 - Math.min(X, B.top) / TILE), c = Math.floor(32 - Math.min(Y, B.left) / TILE);
    if (!tiles.some(([a, b]) => a === r && b === c)) tiles.push([r, c]);
  }
  const inBox = (X, Y) => X <= B.top + 50 && X >= B.bottom - 50 && Y <= B.left + 50 && Y >= B.right - 50;
  const g = collect(casc, wdt, tiles, inBox);
  const W = Math.ceil((B.left - B.right) / cell), H = Math.ceil((B.top - B.bottom) / cell), N = W * H;
  console.log(`grid ${W}x${H} @${cell}yd, object triangles ${g.count}`);
  const colOf = (X, Y) => { const c = Math.floor((B.left - Y) / cell), r = Math.floor((B.top - X) / cell); return r < 0 || c < 0 || r >= H || c >= W ? -1 : r * W + c; };

  // terrain height (bilinear on the 4.17-yard grid) and water level per column
  const tz = (X, Y) => {
    const fc = (meta.Y0 - Y) / meta.unit, fr = (meta.X0 - X) / meta.unit;
    const c0 = Math.max(0, Math.min(meta.W - 2, Math.floor(fc))), r0 = Math.max(0, Math.min(meta.H - 2, Math.floor(fr)));
    const u = Math.min(1, Math.max(0, fc - c0)), v = Math.min(1, Math.max(0, fr - r0));
    const k = r0 * meta.W + c0;
    return { z: (TH[k] * (1 - u) + TH[k + 1] * u) * (1 - v) + (TH[k + meta.W] * (1 - u) + TH[k + meta.W + 1] * u) * v, walk: TW[k], k };
  };

  // samples: column, zmin, zmax, walkable-top flag
  let cap = 1 << 22, n = 0;
  let sCol = new Int32Array(cap), sLo = new Float32Array(cap), sHi = new Float32Array(cap), sWalk = new Uint8Array(cap);
  const grow = () => { cap *= 2; const a = new Int32Array(cap); a.set(sCol); sCol = a; const b = new Float32Array(cap); b.set(sLo); sLo = b; const c = new Float32Array(cap); c.set(sHi); sHi = c; const d = new Uint8Array(cap); d.set(sWalk); sWalk = d; };
  const add = (col, lo, hi, walk) => { if (n === cap) grow(); sCol[n] = col; sLo[n] = lo; sHi[n] = hi; sWalk[n] = walk; n++; };

  const terrainZ = new Float32Array(N).fill(NaN), waterTop = new Float32Array(N).fill(NaN), tWalk = new Uint8Array(N), covered = new Uint8Array(N), coverLo = new Float32Array(N).fill(Infinity);
  for (let r = 0; r < H; r++) for (let c = 0; c < W; c++) {
    const X = B.top - (r + 0.5) * cell, Y = B.left - (c + 0.5) * cell, t = tz(X, Y), k = r * W + c;
    if (isNaN(t.z) || t.walk === 4) continue; // hole: no ground here (cave mouth / building floor instead)
    terrainZ[k] = t.z;
    tWalk[k] = t.walk === 2 ? 0 : 1; // ground is added after the objects: ground buried under a city is left out
  }
  // water level: reuse terrain.js classification (swim where walk==3): approximate surface = terrain + depth flag
  // objects: sample each triangle densely enough to hit every column it touches
  const cosMax = Math.cos(P.maxSlope * Math.PI / 180), T = g.tris;
  for (let i = 0; i < T.length; i += 9) {
    const ax = T[i], ay = T[i + 1], az = T[i + 2], bx = T[i + 3], by = T[i + 4], bz = T[i + 5], cx = T[i + 6], cy = T[i + 7], cz = T[i + 8];
    const ux = bx - ax, uy = by - ay, uz = bz - az, vx = cx - ax, vy = cy - ay, vz = cz - az;
    const nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx, nl = Math.hypot(nx, ny, nz) || 1;
    const walkable = Math.abs(nz) / nl >= cosMax ? 1 : 0;
    const span = Math.max(Math.hypot(ux, uy), Math.hypot(vx, vy), Math.hypot(cx - bx, cy - by));
    const steps = Math.max(1, Math.ceil(span / (cell * 0.5)));
    // per triangle: z-range per column
    const local = new Map();
    for (let s = 0; s <= steps; s++) for (let t = 0; t <= steps - s; t++) {
      const a = s / steps, b = t / steps;
      const X = ax + ux * a + vx * b, Y = ay + uy * a + vy * b, Z = az + uz * a + vz * b;
      const col = colOf(X, Y); if (col < 0) continue;
      const e = local.get(col); if (e) { if (Z < e[0]) e[0] = Z; if (Z > e[1]) e[1] = Z; } else local.set(col, [Z, Z]);
    }
    const isWmo = g.triKind ? g.triKind[i / 9] : 0;
    for (const [col, [lo, hi]] of local) { add(col, lo - 0.1, hi, walkable); if (isWmo && !isNaN(terrainZ[col]) && lo > terrainZ[col] + 3) { covered[col] = 1; if (lo < coverLo[col]) coverLo[col] = lo; } }
  }
  // ground with a building over it across a wide area is the hidden sheet a city model sits on (Stormwind's is
  // 30-50 yd below the streets): leave it out. Ground under a bridge or a single building stays.
  const R = 15; // 30 yards each way
  const sat = new Int32Array((W + 1) * (H + 1));
  for (let rr = 0; rr < H; rr++) { let row = 0; for (let cc = 0; cc < W; cc++) { row += covered[rr * W + cc]; sat[(rr + 1) * (W + 1) + cc + 1] = sat[rr * (W + 1) + cc + 1] + row; } }
  const box = (r0, c0, r1, c1) => sat[r1 * (W + 1) + c1] - sat[r0 * (W + 1) + c1] - sat[r1 * (W + 1) + c0] + sat[r0 * (W + 1) + c0];
  let buried = 0;
  for (let rr = 0; rr < H; rr++) for (let cc = 0; cc < W; cc++) {
    const k = rr * W + cc; if (isNaN(terrainZ[k])) continue;
    if (covered[k]) {
      const r0 = Math.max(0, rr - R), c0 = Math.max(0, cc - R), r1 = Math.min(H, rr + R + 1), c1 = Math.min(W, cc + R + 1);
      // buried: covered across a wide area, or a building surface 20+ yd straight above (bridges are much lower)
      if (box(r0, c0, r1, c1) >= 0.85 * (r1 - r0) * (c1 - c0) || coverLo[k] - terrainZ[k] >= 20) { buried++; continue; }
    }
    add(k, terrainZ[k] - 1.5, terrainZ[k], tWalk[k]); // thin ground shell, so caves below it survive
  }
  console.log('ground left out under buildings:', buried);
  console.log('samples', n);

  // sort samples by column, merge into spans, emit walkable floors
  const order = new Int32Array(n); for (let i = 0; i < n; i++) order[i] = i;
  order.sort((a, b) => sCol[a] - sCol[b] || sLo[a] - sLo[b]);
  const fCol = [], fZ = [], fC = [];
  const colStart = new Int32Array(N + 1);
  let i = 0;
  for (let col = 0; col < N; col++) {
    colStart[col] = fCol.length;
    const spans = [];
    while (i < n && sCol[order[i]] === col) {
      const s = order[i++], lo = sLo[s], hi = sHi[s], w = sWalk[s];
      const last = spans[spans.length - 1];
      if (last && lo <= last.hi + 0.5) { if (hi > last.hi) { last.hi = hi; last.w = w; } else if (hi === last.hi) last.w = last.w || w; }
      else spans.push({ lo, hi, w });
    }
    for (let k = 0; k < spans.length; k++) {
      const s = spans[k], above = spans[k + 1];
      if (!s.w) continue;
      if (above && above.lo - s.hi < P.headroom) continue;
      fCol.push(col); fZ.push(s.hi); fC.push(above ? above.lo : 1e6);
    }
  }
  colStart[N] = fCol.length;
  const swim = new Uint8Array(fCol.length);
  for (let f = 0; f < fCol.length; f++) {
    const col = fCol[f], r = Math.floor(col / W), c = col % W;
    const t = tz(B.top - (r + 0.5) * cell, B.left - (c + 0.5) * cell);
    if (t.walk === 3 && Math.abs(fZ[f] - t.z) < 0.5) swim[f] = 1; // floor is the lake/sea bed
  }
  console.log('floors', fCol.length);
  const out = path.join(dir, `area${area}.vox`);
  fs.writeFileSync(out + '.json', JSON.stringify({ area: +area, W, H, cell, bounds: B, floors: fCol.length, P }));
  fs.writeFileSync(out + '.colstart', Buffer.from(colStart.buffer));
  fs.writeFileSync(out + '.z', Buffer.from(Float32Array.from(fZ).buffer));
  fs.writeFileSync(out + '.ceil', Buffer.from(Float32Array.from(fC).buffer));
  fs.writeFileSync(out + '.swim', Buffer.from(swim.buffer));
}

class VoxNav {
  constructor(dir, area) {
    const base = path.join(dir, `area${area}.vox`);
    this.meta = JSON.parse(fs.readFileSync(base + '.json', 'utf8'));
    const rd = (ext, T) => { const b = fs.readFileSync(base + ext); return new T(b.buffer, b.byteOffset, b.length / T.BYTES_PER_ELEMENT); };
    this.cs = rd('.colstart', Int32Array); this.z = rd('.z', Float32Array); this.ceil = rd('.ceil', Float32Array); this.swim = rd('.swim', Uint8Array);
    this.W = this.meta.W; this.H = this.meta.H; this.cell = this.meta.cell;
    const F = this.z.length; this.colOf = new Int32Array(F);
    for (let c = 0; c < this.W * this.H; c++) for (let f = this.cs[c]; f < this.cs[c + 1]; f++) this.colOf[f] = c;
    this.tanMax = Math.tan(P.maxSlope * Math.PI / 180);
    this.cache = new Map();
    // your recorded walking (tools/trails.js): proof that two spots connect where the building data has a gap
    const tf = path.join(dir, `area${area}.trails.json`);
    this.trailsRaw = fs.existsSync(tf) ? JSON.parse(fs.readFileSync(tf, 'utf8')) : null;
    this.extra = undefined;
  }
  // links from trails: consecutive trail points are connected. They cost their real distance (a roundabout walk is
  // never preferred); a drop of more than 3 yd only links downwards (dropping off a ledge proves nothing about climbing).
  trailLinks() {
    if (this.extra !== undefined) return this.extra;
    this.extra = null; // building: no trail links while anchoring
    if (!this.trailsRaw) return null;
    const B = this.meta.bounds, wY = B.left - B.right, wX = B.top - B.bottom;
    const ex = new Map(); let n = 0;
    const link = (a, b, cost) => { let l = ex.get(a); if (!l) ex.set(a, (l = [])); l.push(b, cost); n++; };
    for (const tr of this.trailsRaw) {
      let pf = -1, pp = null;
      for (const [x, y, zr] of tr) {
        const p = { x, y };
        let f = -1;
        const cand = this.floorsAround(p, 1);
        if (!cand.length) { pf = -1; continue; }
        const want = zr != null ? zr : pf >= 0 ? this.z[pf] : null;
        if (want == null) f = this.anchor(p);
        else { let bd = Infinity; for (const g of cand) { const e = Math.abs(this.z[g] - want); if (e < bd) { bd = e; f = g; } } if (bd > 6) f = -1; }
        if (f >= 0 && pf >= 0 && f !== pf) {
          // measured between the floor squares actually linked (a trail point can snap a couple of yards away)
          const ca = this.colOf[pf], cb = this.colOf[f];
          const hx = ((cb % this.W) - (ca % this.W)) * this.cell, hy = (Math.floor(cb / this.W) - Math.floor(ca / this.W)) * this.cell, hz = this.z[f] - this.z[pf];
          const horiz = Math.hypot(hx, hy);
          if (horiz < 25 && Math.abs(hz) <= Math.max(3, horiz * 0.9)) {
            const cost = Math.hypot(horiz, hz);
            link(pf, f, cost);
            if (hz >= -3) link(f, pf, cost);
          }
        }
        if (f >= 0) { pf = f; pp = p; }
      }
    }
    this.extra = ex; this.trailLinkCount = n;
    return ex;
  }
  // lifts (Thunder Bluff's elevators, Undercity's): the walk map can't ride a moving platform, so each lift joins the
  // bottom floor of its shaft to the floor at the top - the one at the shaft's roof (Undercity: the throne room above),
  // or for an open shaft (Thunder Bluff's cliffs) the lowest walkable floor above. costYd: the ride and the wait.
  // Call before any field (fields are cached). points: map points { x, y } (0-100) of this area's map.
  addLifts(points, costYd = 200) {
    const ex = this.trailLinks() || new Map(); this.extra = ex;
    const ref = this.reference(), added = [];
    const link = (a, b) => { let l = ex.get(a); if (!l) ex.set(a, (l = [])); l.push(b, costYd); };
    const B = this.meta.bounds;
    const at = (f) => { const c = this.colOf[f]; return { x: ((c % this.W) + 0.5) * this.cell / (B.left - B.right) * 100, y: (Math.floor(c / this.W) + 0.5) * this.cell / (B.top - B.bottom) * 100 }; };
    const yd = (a, b) => Math.hypot((a.x - b.x) / 100 * (B.left - B.right), (a.y - b.y) / 100 * (B.top - B.bottom));
    for (const p of points) {
      const cand = this.floorsAround(p, 4).filter((f) => isFinite(ref[f]) || this.bigArea(f));
      if (!cand.length) continue;
      let bot = cand.reduce((a, b) => (this.z[b] < this.z[a] ? b : a));
      let above = cand.filter((f) => this.z[f] > this.z[bot] + 20);
      if (!above.length) {
        // the spot is a top station (Thunder Bluff's are on the mesa): the bottom is the nearest connected floor at least
        // 30 yd lower, within 60 yd (the car drops beside the cliff)
        const topF = cand.reduce((a, b) => (this.z[b] < this.z[a] ? b : a));
        const low = this.floorsAround(p, 30).filter((f) => this.z[f] < this.z[topF] - 30 && (isFinite(ref[f]) || this.bigArea(f)));
        if (!low.length) continue;
        bot = low.reduce((a, b) => (yd(at(b), p) < yd(at(a), p) ? b : a));
        above = [topF];
      }
      const roof = this.ceil[bot];
      const top = roof < 1e5
        ? above.reduce((a, b) => (Math.abs(this.z[b] - roof) < Math.abs(this.z[a] - roof) ? b : a))
        : above.reduce((a, b) => (this.z[b] < this.z[a] ? b : a));
      link(bot, top); link(top, bot);
      added.push({ p, bottom: +this.z[bot].toFixed(1), top: +this.z[top].toFixed(1) });
    }
    this.cache.clear();
    return added;
  }
  col(p) { const B = this.meta.bounds; const c = Math.floor(p.x / 100 * (B.left - B.right) / this.cell), r = Math.floor(p.y / 100 * (B.top - B.bottom) / this.cell); return Math.max(0, Math.min(this.H - 1, r)) * this.W + Math.max(0, Math.min(this.W - 1, c)); }
  // floors in a small radius around a map point (NPCs stand on spots our grid may call steep)
  floorsNear(p, rad = 3) {
    const c0 = this.col(p), r0 = Math.floor(c0 / this.W), k0 = c0 % this.W, out = [];
    for (let rr = 0; rr <= rad && !out.length; rr++) for (let dr = -rr; dr <= rr; dr++) for (let dc = -rr; dc <= rr; dc++) {
      const r = r0 + dr, c = k0 + dc; if (r < 0 || c < 0 || r >= this.H || c >= this.W) continue;
      const col = r * this.W + c; for (let f = this.cs[col]; f < this.cs[col + 1]; f++) out.push(f);
    }
    return out;
  }
  // Dijkstra over floors. 16-connected (8 neighbours + knight moves) so open-ground distances are within ~2-3%
  // of straight lines instead of up to 8% long. Knight moves must pass over walkable floor in both cells they cross.
  // targets (optional): stop as soon as all of them are settled.
  field(src, targets) {
    if (!targets && this.cache.has(src)) return this.cache.get(src);
    const F = this.z.length, d = new Float32Array(F).fill(Infinity), done = new Uint8Array(F), prev = this.wantPrev ? new Int32Array(F).fill(-1) : null;
    let hk = new Float64Array(1 << 16), hv = new Int32Array(1 << 16), hn = 0;
    const push = (key, v) => { if (hn === hk.length) { const a = new Float64Array(hn * 2); a.set(hk); hk = a; const b = new Int32Array(hn * 2); b.set(hv); hv = b; } let i = hn++; while (i) { const p = (i - 1) >> 1; if (hk[p] <= key) break; hk[i] = hk[p]; hv[i] = hv[p]; i = p; } hk[i] = key; hv[i] = v; };
    const pop = () => { const top = hv[0]; hn--; const key = hk[hn], v = hv[hn]; let i = 0; for (;;) { const l = 2 * i + 1, r = l + 1; let m = -1, mk = key; if (l < hn && hk[l] < mk) { m = l; mk = hk[l]; } if (r < hn && hk[r] < mk) { m = r; mk = hk[r]; } if (m < 0) break; hk[i] = hk[m]; hv[i] = hv[m]; i = m; } hk[i] = key; hv[i] = v; return top; };
    const srcs = Array.isArray(src) ? src : [src];
    for (const s of srcs) { d[s] = 0; push(0, s); }
    let left = 0, isT = null;
    if (targets) { isT = new Uint8Array(F); for (const t of targets) if (t >= 0 && !isT[t]) { isT[t] = 1; left++; } }
    const W = this.W, H = this.H, cell = this.cell, z = this.z, cs = this.cs, ceil = this.ceil, swim = this.swim, tanMax = this.tanMax;
    // colCost: a cost factor per ground column (Float32Array W*H, or none): ground to walk round, not over - the other
    // faction's towns for a walking path (waypoints.js avoid)
    const colCost = this.colCost || null;
    const extra = this.extra === undefined ? this.trailLinks() : this.extra;
    const ok = (f, g, run) => {
      const dz = z[g] - z[f];
      if (Math.min(ceil[f], ceil[g]) - Math.max(z[f], z[g]) < P.headroom) return 0;
      const sw = swim[g] || swim[f];
      if (!sw) { if (dz > Math.max(P.climb, run * tanMax) || dz < -P.maxDrop) return 0; } else if (dz > P.climb + 1) return 0;
      return sw ? P.swimFactor : 1;
    };
    const floorAt = (col, zt) => { let best = -1, bd = P.climb + 0.5; for (let g = cs[col]; g < cs[col + 1]; g++) { const e = Math.abs(z[g] - zt); if (e < bd) { bd = e; best = g; } } return best; };
    const N8 = [[-1, -1], [-1, 0], [-1, 1], [0, -1], [0, 1], [1, -1], [1, 0], [1, 1]];
    const NK = [[1, 2], [2, 1], [-1, 2], [-2, 1], [1, -2], [2, -1], [-1, -2], [-2, -1]];
    const K = Math.sqrt(5) * cell;
    while (hn) {
      const f = pop(); if (done[f]) continue; done[f] = 1;
      if (isT && isT[f] && --left === 0) break;
      const col = this.colOf[f], r = Math.floor(col / W), c = col % W, df = d[f];
      const ex = extra && extra.get(f);
      if (ex) for (let k = 0; k < ex.length; k += 2) { const g = ex[k]; if (done[g]) continue; const nd = df + ex[k + 1]; if (nd < d[g]) { d[g] = nd; if (prev) prev[g] = f; push(nd, g); } }
      for (const [dr, dc] of N8) {
        const rr = r + dr, cc = c + dc; if (rr < 0 || cc < 0 || rr >= H || cc >= W) continue;
        const ncol = rr * W + cc, run = dr && dc ? cell * Math.SQRT2 : cell;
        for (let g = cs[ncol]; g < cs[ncol + 1]; g++) {
          if (done[g]) continue;
          const m = ok(f, g, run); if (!m) continue;
          const nd = df + run * m * (colCost ? colCost[ncol] : 1);
          if (nd < d[g]) { d[g] = nd; if (prev) prev[g] = f; push(nd, g); }
        }
      }
      for (const [dr, dc] of NK) {
        const rr = r + dr, cc = c + dc; if (rr < 0 || cc < 0 || rr >= H || cc >= W) continue;
        const ncol = rr * W + cc;
        // the two cells the knight line crosses
        const m1 = (r + (Math.abs(dr) === 2 ? Math.sign(dr) : 0)) * W + (c + (Math.abs(dc) === 2 ? Math.sign(dc) : 0));
        const m2 = (r + Math.sign(dr)) * W + (c + Math.sign(dc));
        for (let g = cs[ncol]; g < cs[ncol + 1]; g++) {
          if (done[g]) continue;
          const zm = (z[f] + z[g]) / 2, a1 = floorAt(m1, zm), a2 = floorAt(m2, zm);
          if (a1 < 0 || a2 < 0) continue;
          const mA = ok(f, a1, K / 2), mB = ok(a1, g, K / 2), mC = ok(f, a2, K / 2), mD = ok(a2, g, K / 2);
          if (!mA || !mB || !mC || !mD) continue;
          const nd = df + K * Math.max(mA, mB, mC, mD) * (colCost ? Math.max(colCost[ncol], colCost[m1], colCost[m2]) : 1);
          if (nd < d[g]) { d[g] = nd; if (prev) prev[g] = f; push(nd, g); }
        }
      }
    }
    if (targets) { if (prev) this.lastPrev = prev; return d; }
    if (prev) { this.lastPrev = prev; return d; }
    if (this.cache.size > 60) this.cache.delete(this.cache.keys().next().value);
    this.cache.set(src, d);
    return d;
  }
  floorsAround(p, rad) {
    const c0 = this.col(p), r0 = Math.floor(c0 / this.W), k0 = c0 % this.W, out = [];
    for (let dr = -rad; dr <= rad; dr++) for (let dc = -rad; dc <= rad; dc++) {
      const r = r0 + dr, c = k0 + dc; if (r < 0 || c < 0 || r >= this.H || c >= this.W) continue;
      const col = r * this.W + c; for (let f = this.cs[col]; f < this.cs[col + 1]; f++) out.push(f);
    }
    return out.length ? out : this.floorsNear(p, 8);
  }
  // A map point has no height, so we pick a floor: the lowest floor (in the point's own column, or the nearest
  // column with floors) that is connected to the big walkable network. That puts cave mobs in the cave and
  // ground-floor NPCs on the ground floor instead of on a roof or the hill above a mine.
  anchor(p) {
    const key = p.x.toFixed(2) + ',' + p.y.toFixed(2);
    this.anchors = this.anchors || new Map();
    if (this.anchors.has(key)) return this.anchors.get(key);
    const cand = this.floorsAround(p, 3).sort((x, y) => this.z[x] - this.z[y]);
    const ref = this.reference();
    let pick = -1;
    for (const f of cand) {
      if (isFinite(ref[f])) { pick = f; break; }
      // not joined to the outside: still real ground if it is part of a big walkable area (a city inside a mountain)
      if (this.bigArea(f)) { pick = f; break; }
    }
    if (pick < 0) pick = cand.length ? cand[0] : -1;
    this.anchors.set(key, pick);
    return pick;
  }
  // is this floor part of a large walkable area? (flood once per area; remembered for every floor it reaches)
  bigArea(f) {
    this.areaOf = this.areaOf || new Int32Array(this.z.length).fill(0); // 0 unknown, 1 big, -1 small
    if (this.areaOf[f]) return this.areaOf[f] > 0;
    const d = this.field(f); this.cache.delete(f);
    let n = 0; const F = this.z.length; for (let g = 0; g < F; g++) if (isFinite(d[g])) n++;
    const v = n >= Math.max(20000, F * 0.03) ? 1 : -1;
    for (let g = 0; g < F; g++) if (isFinite(d[g])) this.areaOf[g] = v;
    return v > 0;
  }
  // reachability from a well-connected open-ground floor (computed once)
  reference() {
    if (this.ref) return this.ref;
    let best = 0, bf = -1;
    for (let c = Math.floor(this.W * this.H / 2); c < this.W * this.H && bf < 0; c += 97) if (this.cs[c + 1] - this.cs[c] === 1 && !this.swim[this.cs[c]]) bf = this.cs[c];
    this.ref = this.field(bf); this.cache.delete(bf);
    return this.ref;
  }
  path(a, b) {
    const fa = this.anchor(a), fb = this.anchor(b);
    this.wantPrev = true; const d = this.field(fa); this.wantPrev = false;
    const out = []; for (let f = fb; f >= 0; f = this.lastPrev[f]) out.push(f);
    return { length: d[fb], floors: out.reverse() };
  }
  dist(a, b) {
    const fa = this.anchor(a), fb = this.anchor(b);
    if (fa < 0 || fb < 0) return Infinity;
    if (this.cache.has(fb) && !this.cache.has(fa)) return this.field(fb)[fa];
    return this.field(fa)[fb];
  }
}
module.exports = { VoxNav, build };

if (require.main === module) {
  const [cmd, ...a] = process.argv.slice(2);
  if (cmd === 'build') build(a[0], a[1], a[2], +(a[3] || 2));
  if (cmd === 'test') {
    const nav = new VoxNav(a[0], a[1]); const B = nav.meta.bounds;
    const pts = a.slice(2).map((s) => { const [x, y] = s.split(',').map(Number); return { x, y }; });
    for (let i = 0; i + 1 < pts.length; i += 2) {
      const t0 = Date.now(), d = nav.dist(pts[i], pts[i + 1]);
      const s = Math.hypot((pts[i].x - pts[i + 1].x) / 100 * (B.left - B.right), (pts[i].y - pts[i + 1].y) / 100 * (B.top - B.bottom));
      console.log(`${a[2 + i]} -> ${a[3 + i]}: ${Math.round(d)} yd (straight ${Math.round(s)}, x${(d / s).toFixed(2)}) ${Date.now() - t0}ms`);
    }
  }
}
