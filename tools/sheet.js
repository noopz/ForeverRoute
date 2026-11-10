// Contact sheet: crop regions out of PNG screenshots and tile them into one PNG.
// usage: node sheet.js <out.png> <cols> <file:x,y,w,h:label> ...
const fs = require('fs');
const zlib = require('zlib');
function decode(file) {
  const b = fs.readFileSync(file);
  let p = 8, W, H, ct, idat = [];
  while (p < b.length) {
    const len = b.readUInt32BE(p), t = b.toString('latin1', p + 4, p + 8), d = b.subarray(p + 8, p + 8 + len);
    if (t === 'IHDR') { W = d.readUInt32BE(0); H = d.readUInt32BE(4); ct = d[9]; }
    if (t === 'IDAT') idat.push(d);
    p += 12 + len;
  }
  const bpp = ct === 6 ? 4 : 3, stride = W * bpp, raw = zlib.inflateSync(Buffer.concat(idat)), out = Buffer.alloc(W * H * 3);
  let prev = Buffer.alloc(stride);
  for (let y = 0; y < H; y++) {
    const ft = raw[y * (stride + 1)], line = Buffer.from(raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1)));
    for (let i = 0; i < stride; i++) {
      const a = i >= bpp ? line[i - bpp] : 0, up = prev[i], c = i >= bpp ? prev[i - bpp] : 0;
      let v = line[i];
      if (ft === 1) v += a; else if (ft === 2) v += up; else if (ft === 3) v += (a + up) >> 1;
      else if (ft === 4) { const pp = a + up - c, pa = Math.abs(pp - a), pb = Math.abs(pp - up), pc = Math.abs(pp - c); v += pa <= pb && pa <= pc ? a : pb <= pc ? up : c; }
      line[i] = v & 255;
    }
    for (let x = 0; x < W; x++) for (let k = 0; k < 3; k++) out[(y * W + x) * 3 + k] = line[x * bpp + k];
    prev = line;
  }
  return { W, H, px: out };
}
const [outFile, colsArg, ...items] = process.argv.slice(2);
const cols = +colsArg;
const tiles = items.map((it) => { const [f, r] = it.split(':'); const [x, y, w, h] = r.split(',').map(Number); return { img: decode(f), x, y, w, h }; });
const cw = Math.max(...tiles.map((t) => t.w)), ch = Math.max(...tiles.map((t) => t.h)), gap = 8;
const rows = Math.ceil(tiles.length / cols), W = cols * cw + (cols + 1) * gap, H = rows * ch + (rows + 1) * gap;
const out = Buffer.alloc(W * H * 3, 20);
tiles.forEach((t, n) => {
  const ox = gap + (n % cols) * (cw + gap), oy = gap + Math.floor(n / cols) * (ch + gap);
  for (let y = 0; y < t.h; y++) for (let x = 0; x < t.w; x++) {
    const sx = t.x + x, sy = t.y + y; if (sx >= t.img.W || sy >= t.img.H) continue;
    for (let k = 0; k < 3; k++) out[((oy + y) * W + ox + x) * 3 + k] = t.img.px[(sy * t.img.W + sx) * 3 + k];
  }
});
const raw = Buffer.alloc((W * 3 + 1) * H);
for (let y = 0; y < H; y++) out.copy(raw, y * (W * 3 + 1) + 1, y * W * 3, (y + 1) * W * 3);
const crcT = new Int32Array(256).map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c; });
const crc = (b) => { let c = -1; for (const x of b) c = crcT[(c ^ x) & 255] ^ (c >>> 8); return (c ^ -1) >>> 0; };
const chunk = (t, d) => { const l = Buffer.alloc(4); l.writeUInt32BE(d.length); const td = Buffer.concat([Buffer.from(t), d]); const cb = Buffer.alloc(4); cb.writeUInt32BE(crc(td)); return Buffer.concat([l, td, cb]); };
const ih = Buffer.alloc(13); ih.writeUInt32BE(W, 0); ih.writeUInt32BE(H, 4); ih[8] = 8; ih[9] = 2;
fs.writeFileSync(outFile, Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ih), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]));
console.log(`sheet ${W}x${H}`);
