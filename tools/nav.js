// Terrain navigation over the grids made by terrain.js.
// Movement rules (per 4.17-yard step, 8-connected):
//   uphill: allowed while the slope is under maxSlope
//   downhill: any slope, as long as the drop is under maxDrop yards (jumping down a ledge is fine)
//   swimming: water deeper than 2 yards costs swimFactor x (swim ~4.7 y/s vs run 7)
//   terrain holes (cave / building mouths) are passable
const fs = require('fs');
const path = require('path');

class ZoneNav {
  constructor(dir, area, opts = {}) {
    const base = path.join(dir, `area${area}`);
    this.meta = JSON.parse(fs.readFileSync(base + '.json', 'utf8'));
    const hb = fs.readFileSync(base + '.height.f32');
    this.h = new Float32Array(hb.buffer, hb.byteOffset, hb.length / 4);
    this.w = fs.readFileSync(base + '.walk.u8');
    this.W = this.meta.W; this.H = this.meta.H; this.unit = this.meta.unit;
    this.tanMax = Math.tan((opts.maxSlope || this.meta.maxSlope) * Math.PI / 180);
    this.maxDrop = opts.maxDrop || 12;
    this.swimFactor = opts.swimFactor || 1.5;
    this.cache = new Map();
  }
  // Questie map percent -> grid cell
  cell(p) {
    const B = this.meta.bounds;
    const Y = B.left - (p.x / 100) * (B.left - B.right), X = B.top - (p.y / 100) * (B.top - B.bottom);
    const c = Math.round((this.meta.Y0 - Y) / this.unit), r = Math.round((this.meta.X0 - X) / this.unit);
    return Math.max(0, Math.min(this.H - 1, r)) * this.W + Math.max(0, Math.min(this.W - 1, c));
  }
  pct(k) { const B = this.meta.bounds, r = Math.floor(k / this.W), c = k % this.W; const Y = this.meta.Y0 - c * this.unit, X = this.meta.X0 - r * this.unit; return { x: (B.left - Y) / (B.left - B.right) * 100, y: (B.top - X) / (B.top - B.bottom) * 100 }; }
  stepCost(a, b, diag) {
    const wb = this.w[b];
    if (!wb) return Infinity;
    const run = diag ? this.unit * Math.SQRT2 : this.unit;
    const dz = this.h[b] - this.h[a];
    const swim = wb === 3 || this.w[a] === 3;
    if (!swim) {
      if (dz > 0 && dz / run > this.tanMax) return Infinity;
      if (dz < -this.maxDrop) return Infinity;
    }
    return run * (swim ? this.swimFactor : 1);
  }
  // Dijkstra from one point; returns a distance field (yards of running), cached per source cell
  field(src) {
    if (this.cache.has(src)) return this.cache.get(src);
    const N = this.W * this.H, d = new Float64Array(N).fill(Infinity), prev = new Int32Array(N).fill(-1), done = new Uint8Array(N);
    // binary heap over parallel typed arrays (cell ids + keys)
    let hk = new Float64Array(1 << 16), hv = new Int32Array(1 << 16), hn = 0;
    const push = (key, v) => {
      if (hn === hk.length) { const k2 = new Float64Array(hn * 2); k2.set(hk); hk = k2; const v2 = new Int32Array(hn * 2); v2.set(hv); hv = v2; }
      let i = hn++; while (i) { const p = (i - 1) >> 1; if (hk[p] <= key) break; hk[i] = hk[p]; hv[i] = hv[p]; i = p; } hk[i] = key; hv[i] = v;
    };
    const pop = () => {
      const top = hv[0]; hn--; const key = hk[hn], v = hv[hn]; let i = 0;
      for (;;) { const l = 2 * i + 1, r = l + 1; let m = -1, mk = key; if (l < hn && hk[l] < mk) { m = l; mk = hk[l]; } if (r < hn && hk[r] < mk) { m = r; mk = hk[r]; } if (m < 0) break; hk[i] = hk[m]; hv[i] = hv[m]; i = m; }
      hk[i] = key; hv[i] = v; return top;
    };
    d[src] = 0; push(0, src);
    const W = this.W;
    while (hn) {
      const k = pop();
      if (done[k]) continue; done[k] = 1;
      const dk = d[k], r = Math.floor(k / W), c = k % W;
      for (let dr = -1; dr <= 1; dr++) for (let dc = -1; dc <= 1; dc++) {
        if (!dr && !dc) continue;
        const rr = r + dr, cc = c + dc;
        if (rr < 0 || cc < 0 || rr >= this.H || cc >= W) continue;
        const n = rr * W + cc; if (done[n]) continue;
        const nd = dk + this.stepCost(k, n, dr && dc);
        if (nd < d[n]) { d[n] = nd; prev[n] = k; push(nd, n); }
      }
    }
    const f = { d: Float32Array.from(d), prev };
    if (this.cache.size > 120) this.cache.delete(this.cache.keys().next().value);
    this.cache.set(src, f);
    return f;
  }
  // nearest reachable cell to a (possibly blocked) point, so NPCs standing on steep spots still connect
  snap(k) {
    if (this.w[k] === 1 || this.w[k] === 4) return k;
    const r0 = Math.floor(k / this.W), c0 = k % this.W;
    for (let rad = 1; rad < 12; rad++) for (let dr = -rad; dr <= rad; dr++) for (let dc = -rad; dc <= rad; dc++) {
      const r = r0 + dr, c = c0 + dc;
      if (r < 0 || c < 0 || r >= this.H || c >= this.W) continue;
      const n = r * this.W + c; if (this.w[n] === 1 || this.w[n] === 4) return n;
    }
    return k;
  }
  dist(a, b) {
    const ka = this.snap(this.cell(a)), kb = this.snap(this.cell(b));
    // field from whichever end is already cached (paths are near-symmetric)
    if (this.cache.has(kb) && !this.cache.has(ka)) return this.field(kb).d[ka];
    return this.field(ka).d[kb];
  }
  path(a, b) {
    const ka = this.snap(this.cell(a)), kb = this.snap(this.cell(b)), f = this.field(ka);
    const out = []; for (let k = kb; k !== -1; k = f.prev[k]) out.push(k);
    return out.reverse();
  }
}
module.exports = ZoneNav;
