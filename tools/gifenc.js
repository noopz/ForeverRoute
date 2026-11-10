// A small animated-GIF encoder for the README animations: one global palette (no dithering: flat UI colors stay
// flat), and each frame after the first stores only the rectangle that changed, with unchanged pixels transparent.
// GDI+ saved every frame in full, dithered: 7 MB for 40 frames of a map; this gets a fraction of that.
// usage: node tools/gifenc.js <dir of frame-NNN.png> <out.gif> [delay cs=8] [last frame cs=250] [hold "k:cs,k:cs"]
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

// ---- PNG reader (8-bit RGB / RGBA, not interlaced: what GDI+ writes) ----
function readPng(file) {
  const b = fs.readFileSync(file);
  let p = 8, W = 0, H = 0, ct = 0; const idat = [];
  while (p < b.length) {
    const len = b.readUInt32BE(p), type = b.toString('ascii', p + 4, p + 8), d = b.subarray(p + 8, p + 8 + len);
    if (type === 'IHDR') { W = d.readUInt32BE(0); H = d.readUInt32BE(4); if (d[8] !== 8 || d[12] !== 0) throw new Error(file + ': only 8-bit, non-interlaced'); ct = d[9]; }
    else if (type === 'IDAT') idat.push(d);
    else if (type === 'IEND') break;
    p += 12 + len;
  }
  const bpp = ct === 6 ? 4 : ct === 2 ? 3 : 0; if (!bpp) throw new Error(file + ': colour type ' + ct);
  const raw = zlib.inflateSync(Buffer.concat(idat)), stride = W * bpp, out = Buffer.alloc(W * H * 3);
  let prev = Buffer.alloc(stride), cur = Buffer.alloc(stride);
  for (let y = 0; y < H; y++) {
    const f = raw[y * (stride + 1)], row = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    for (let i = 0; i < stride; i++) {
      const a = i >= bpp ? cur[i - bpp] : 0, up = prev[i], c = i >= bpp ? prev[i - bpp] : 0, x = row[i];
      let v;
      if (f === 0) v = x; else if (f === 1) v = x + a; else if (f === 2) v = x + up; else if (f === 3) v = x + ((a + up) >> 1);
      else { const pp = a + up - c, pa = Math.abs(pp - a), pb = Math.abs(pp - up), pc = Math.abs(pp - c); v = x + (pa <= pb && pa <= pc ? a : pb <= pc ? up : c); }
      cur[i] = v & 255;
    }
    for (let x = 0; x < W; x++) { const o = (y * W + x) * 3; out[o] = cur[x * bpp]; out[o + 1] = cur[x * bpp + 1]; out[o + 2] = cur[x * bpp + 2]; }
    [prev, cur] = [cur, prev];
  }
  return { W, H, px: out };
}

// ---- palette: the 255 most used colours (5 bits a channel), index 255 = transparent ----
function palette(frames) {
  const count = new Map();
  for (const f of frames) for (let i = 0; i < f.px.length; i += 3) { const k = ((f.px[i] >> 3) << 10) | ((f.px[i + 1] >> 3) << 5) | (f.px[i + 2] >> 3); count.set(k, (count.get(k) || 0) + 1); }
  const top = [...count.entries()].sort((a, b) => b[1] - a[1]).slice(0, 255).map(([k]) => [((k >> 10) & 31) * 8 + 4, ((k >> 5) & 31) * 8 + 4, (k & 31) * 8 + 4]);
  while (top.length < 256) top.push([0, 0, 0]);
  const cache = new Map();
  const index = (r, g, b) => {
    const k = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
    let v = cache.get(k); if (v !== undefined) return v;
    let best = 0, bd = Infinity;
    for (let i = 0; i < 255; i++) { const c = top[i], d = (c[0] - r) ** 2 * 2 + (c[1] - g) ** 2 * 4 + (c[2] - b) ** 2 * 3; if (d < bd) { bd = d; best = i; } }
    cache.set(k, best); return best;
  };
  return { colors: top, index };
}

// ---- LZW (GIF flavour) ----
function lzw(indices, minCode = 8) {
  const out = []; let cur = 0, nbits = 0;
  const clear = 1 << minCode, eoi = clear + 1;
  let codeSize = minCode + 1, next = eoi + 1, dict = new Map();
  const emit = (code) => { cur |= code << nbits; nbits += codeSize; while (nbits >= 8) { out.push(cur & 255); cur >>>= 8; nbits -= 8; } };
  emit(clear);
  let prefix = indices[0];
  for (let i = 1; i < indices.length; i++) {
    const k = indices[i], key = prefix * 256 + k, hit = dict.get(key);
    if (hit !== undefined) { prefix = hit; continue; }
    emit(prefix);
    if (next < 4096) { dict.set(key, next++); if (next > (1 << codeSize) && codeSize < 12) codeSize++; }
    else { emit(clear); dict = new Map(); codeSize = minCode + 1; next = eoi + 1; }
    prefix = k;
  }
  emit(prefix); emit(eoi);
  if (nbits > 0) out.push(cur & 255);
  // sub-blocks of at most 255 bytes
  const blocks = [];
  for (let i = 0; i < out.length; i += 255) { const n = Math.min(255, out.length - i); blocks.push(n, ...out.slice(i, i + n)); }
  blocks.push(0);
  return Buffer.from(blocks);
}

const [dir, outFile, delayArg = '8', lastArg = '250', holdArg = ''] = process.argv.slice(2);
const files = fs.readdirSync(dir).filter((f) => /^frame-\d+\.png$/.test(f)).sort();
const frames = files.map((f) => readPng(path.join(dir, f)));
const { W, H } = frames[0];
const pal = palette(frames);
const hold = Object.fromEntries((holdArg || '').split(',').filter(Boolean).map((x) => x.split(':').map(Number)));
const parts = [];
const head = Buffer.alloc(13); head.write('GIF89a', 0); head.writeUInt16LE(W, 6); head.writeUInt16LE(H, 8); head[10] = 0xf7; head[11] = 0; head[12] = 0;
parts.push(head, Buffer.from(pal.colors.flat()));
parts.push(Buffer.from([0x21, 0xff, 0x0b, ...Buffer.from('NETSCAPE2.0'), 0x03, 0x01, 0x00, 0x00, 0x00])); // loop forever
let prevIdx = null;
frames.forEach((f, n) => {
  const idx = new Uint8Array(W * H);
  for (let i = 0, j = 0; i < idx.length; i++, j += 3) idx[i] = pal.index(f.px[j], f.px[j + 1], f.px[j + 2]);
  // the changed rectangle (all of it for the first frame)
  let x0 = 0, y0 = 0, x1 = W - 1, y1 = H - 1;
  if (prevIdx) {
    x0 = W; y0 = H; x1 = -1; y1 = -1;
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) { const i = y * W + x; if (idx[i] !== prevIdx[i]) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; } }
    if (x1 < 0) { x0 = y0 = 0; x1 = y1 = 0; }
  }
  const w = x1 - x0 + 1, h = y1 - y0 + 1, sub = new Uint8Array(w * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const i = (y + y0) * W + (x + x0);
    sub[y * w + x] = prevIdx && idx[i] === prevIdx[i] ? 255 : idx[i];
  }
  const delay = n === frames.length - 1 ? +lastArg : hold[n] !== undefined ? hold[n] : +delayArg;
  const gce = Buffer.from([0x21, 0xf9, 0x04, prevIdx ? 0x05 : 0x04, delay & 255, delay >> 8, 255, 0]); // keep the frame under, index 255 transparent
  const desc = Buffer.alloc(10); desc[0] = 0x2c; desc.writeUInt16LE(x0, 1); desc.writeUInt16LE(y0, 3); desc.writeUInt16LE(w, 5); desc.writeUInt16LE(h, 7); desc[9] = 0;
  parts.push(gce, desc, Buffer.from([8]), lzw(sub));
  prevIdx = idx;
});
parts.push(Buffer.from([0x3b]));
fs.writeFileSync(outFile, Buffer.concat(parts));
console.log(`wrote ${outFile} (${frames.length} frames, ${W}x${H}, ${Math.round(fs.statSync(outFile).size / 1024)} KB)`);
