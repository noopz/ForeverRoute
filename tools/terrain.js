// Extract a zone's terrain (heights, holes, water) from the local client into a grid,
// mark walkability by slope, and render a PNG preview.
// usage: node terrain.js <wowRoot> <conversion.json> <areaId> <outDir> [maxSlopeDeg=50]
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const Casc = require('./casc');

const [root, convPath, areaArg, outDir, slopeArg] = process.argv.slice(2);
const AREA = +areaArg, MAX_SLOPE = +(slopeArg || 50);
const TILE = 1600 / 3, CHUNK = TILE / 16, UNIT = CHUNK / 8; // 533.33, 33.33, 4.1667 yards
const WDT_BY_MAP = { 0: 775971, 1: 782779 }; // Azeroth (Eastern Kingdoms), Kalimdor

const conv = JSON.parse(fs.readFileSync(convPath, 'utf8'));
const tr = conv.geometry.transforms.find((t) => t.area_id === AREA);
if (!tr) throw new Error('area not in conversion.json: ' + AREA);
const B = tr.target_bounds; // world: left/right = Y, top/bottom = X
console.log(`${tr.target_name}: map ${tr.map_id}, X ${B.bottom.toFixed(0)}..${B.top.toFixed(0)}, Y ${B.right.toFixed(0)}..${B.left.toFixed(0)}`);

const casc = new Casc(root, 'wowf');
casc.loadEncoding(); casc.loadRoot();

function chunks(buf, start = 0, end = buf.length) {
  const out = [];
  for (let p = start; p + 8 <= end;) {
    const id = buf.toString('latin1', p, p + 4).split('').reverse().join('');
    const size = buf.readUInt32LE(p + 4);
    out.push({ id, start: p + 8, size });
    p += 8 + size;
  }
  return out;
}
const wdt = casc.readFdid(WDT_BY_MAP[tr.map_id]);
const maid = chunks(wdt).find((c) => c.id === 'MAID');
const adtFdid = (row, col) => wdt.readUInt32LE(maid.start + (row * 64 + col) * 32);

// grid over the zone bounds at vertex resolution
// north-west corner snapped onto the terrain vertex lattice (world origin + n * UNIT), so every vertex lands on a cell
const LAT = 32 * TILE;
const X0 = LAT - Math.floor((LAT - B.top) / UNIT) * UNIT, Y0 = LAT - Math.floor((LAT - B.left) / UNIT) * UNIT;
const W = Math.ceil((Y0 - B.right) / UNIT) + 1, H = Math.ceil((X0 - B.bottom) / UNIT) + 1;
const height = new Float32Array(W * H).fill(NaN), water = new Float32Array(W * H).fill(NaN), hole = new Uint8Array(W * H);
const toCell = (X, Y) => [Math.round((Y0 - Y) / UNIT), Math.round((X0 - X) / UNIT)]; // [col, row]

const tiles = new Set();
for (let X = B.bottom; X <= B.top + TILE; X += TILE) for (let Y = B.right; Y <= B.left + TILE; Y += TILE) {
  const row = Math.floor(32 - Math.min(X, B.top) / TILE), col = Math.floor(32 - Math.min(Y, B.left) / TILE);
  tiles.add(row + ',' + col);
}
let loaded = 0;
for (const t of tiles) {
  const [row, col] = t.split(',').map(Number);
  const fdid = adtFdid(row, col);
  if (!fdid) continue;
  const adt = casc.readFdid(fdid);
  if (!adt) { console.log('missing adt', row, col, fdid); continue; }
  loaded++;
  const top = chunks(adt);
  const mcnks = top.filter((c) => c.id === 'MCNK');
  const liquidLevel = new Map();
  const mh2o = top.find((c) => c.id === 'MH2O');
  if (mh2o) for (let i = 0; i < 256; i++) {
    const h = mh2o.start + i * 12, ofs = adt.readUInt32LE(h), n = adt.readUInt32LE(h + 4);
    if (!n || !ofs) continue;
    const inst = mh2o.start + ofs;
    const maxH = adt.readFloatLE(inst + 8);
    const xo = adt[inst + 12], yo = adt[inst + 13], w = adt[inst + 14], hh = adt[inst + 15];
    liquidLevel.set(i, { level: maxH, xo, yo, w, h: hh });
  }
  for (const mc of mcnks) {
    const s = mc.start;
    const ix = adt.readUInt32LE(s + 4), iy = adt.readUInt32LE(s + 8);
    const flags = adt.readUInt32LE(s);
    const holesLow = adt.readUInt16LE(s + 0x3c);
    const highRes = flags & 0x10000 ? adt.readBigUInt64LE(s + 0x14) : 0n; // 8x8 bits, one per quad
    const px = adt.readFloatLE(s + 0x68), py = adt.readFloatLE(s + 0x6c), pz = adt.readFloatLE(s + 0x70);
    const sub = chunks(adt, s + 128, s + mc.size);
    const mcvt = sub.find((c) => c.id === 'MCVT');
    if (!mcvt) continue;
    const liq = liquidLevel.get(iy * 16 + ix);
    // 9x9 outer vertices: index r*17 + c
    for (let r = 0; r <= 8; r++) for (let c = 0; c <= 8; c++) {
      const z = pz + adt.readFloatLE(mcvt.start + 4 * (r * 17 + c));
      const X = px - r * UNIT, Y = py - c * UNIT;
      const [gc, gr] = toCell(X, Y);
      if (gc < 0 || gr < 0 || gc >= W || gr >= H) continue;
      const k = gr * W + gc;
      height[k] = z;
      // holes: 4x4 bits over the chunk, each covering 2x2 quads
      if (r < 8 && c < 8) { if (highRes ? (highRes >> BigInt(r * 8 + c)) & 1n : holesLow && (holesLow >> ((r >> 1) * 4 + (c >> 1))) & 1) hole[k] = 1; }
      if (liq && c >= liq.xo && c <= liq.xo + liq.w && r >= liq.yo && r <= liq.yo + liq.h) water[k] = liq.level;
    }
  }
}
console.log(`tiles ${loaded}/${tiles.size}, grid ${W}x${H} (${UNIT.toFixed(2)} yd cells)`);

// walkability: a cell is blocked when any edge to a neighbour is steeper than MAX_SLOPE,
// it's a terrain hole (cave mouth / building), or water is deeper than ~2 yd (swim)
const tanMax = Math.tan(MAX_SLOPE * Math.PI / 180);
const walk = new Uint8Array(W * H); // 0 = no data, 1 = walk, 2 = steep, 3 = swim, 4 = hole
for (let r = 0; r < H; r++) for (let c = 0; c < W; c++) {
  const k = r * W + c, z = height[k];
  if (isNaN(z)) continue;
  if (hole[k]) { walk[k] = 4; continue; }
  if (!isNaN(water[k]) && water[k] - z > 2) { walk[k] = 3; continue; }
  let steep = false;
  for (const [dr, dc] of [[0, 1], [1, 0], [0, -1], [-1, 0]]) {
    const n = (r + dr) * W + (c + dc);
    if (r + dr < 0 || r + dr >= H || c + dc < 0 || c + dc >= W || isNaN(height[n])) continue;
    if (Math.abs(height[n] - z) / UNIT > tanMax) { steep = true; break; }
  }
  walk[k] = steep ? 2 : 1;
}
fs.mkdirSync(outDir, { recursive: true });
const base = path.join(outDir, `area${AREA}`);
fs.writeFileSync(base + '.json', JSON.stringify({ area: AREA, name: tr.target_name, map: tr.map_id, bounds: B, X0, Y0, W, H, unit: UNIT, maxSlope: MAX_SLOPE }));
fs.writeFileSync(base + '.height.f32', Buffer.from(height.buffer));
fs.writeFileSync(base + '.walk.u8', Buffer.from(walk.buffer));
const counts = [0, 0, 0, 0, 0]; for (const v of walk) counts[v]++;
console.log('cells: walk', counts[1], 'steep', counts[2], 'swim', counts[3], 'hole', counts[4], 'nodata', counts[0]);

// ---- PNG preview: hillshade, red = too steep, blue = swim, magenta = hole ----
let zmin = Infinity, zmax = -Infinity; for (const z of height) if (!isNaN(z)) { zmin = Math.min(zmin, z); zmax = Math.max(zmax, z); }
const px = Buffer.alloc((W * 3 + 1) * H);
for (let r = 0; r < H; r++) {
  px[r * (W * 3 + 1)] = 0;
  for (let c = 0; c < W; c++) {
    const k = r * W + c, o = r * (W * 3 + 1) + 1 + c * 3, z = height[k];
    if (isNaN(z)) { px[o] = px[o + 1] = px[o + 2] = 0; continue; }
    const zl = isNaN(height[k - 1]) ? z : height[k - 1], zu = isNaN(height[k - W]) ? z : height[k - W];
    const shade = Math.max(0, Math.min(1, 0.6 + ((zl - z) + (zu - z)) / (UNIT * 2.5)));
    const t = (z - zmin) / (zmax - zmin || 1);
    let rgb = [60 + 140 * t, 110 + 90 * t, 50 + 60 * t].map((v) => v * shade);
    if (walk[k] === 2) rgb = [200, 40, 40];
    if (walk[k] === 3) rgb = [40, 80, 200];
    if (walk[k] === 4) rgb = [220, 0, 220];
    px[o] = rgb[0]; px[o + 1] = rgb[1]; px[o + 2] = rgb[2];
  }
}
const crcT = new Int32Array(256).map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c; });
const crc = (b) => { let c = -1; for (const x of b) c = crcT[(c ^ x) & 255] ^ (c >>> 8); return (c ^ -1) >>> 0; };
const chunk = (t, d) => { const l = Buffer.alloc(4); l.writeUInt32BE(d.length); const td = Buffer.concat([Buffer.from(t), d]); const cb = Buffer.alloc(4); cb.writeUInt32BE(crc(td)); return Buffer.concat([l, td, cb]); };
const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(W, 0); ihdr.writeUInt32BE(H, 4); ihdr[8] = 8; ihdr[9] = 2;
fs.writeFileSync(base + '.png', Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(px)), chunk('IEND', Buffer.alloc(0))]));
console.log('wrote', base + '.png', `(height ${zmin.toFixed(0)}..${zmax.toFixed(0)} yd)`);
