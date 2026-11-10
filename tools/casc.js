// Minimal read-only CASC reader for a local WoW install (one product).
// Opens files only for reading; never writes into the game folder.
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

class Casc {
  constructor(root, product) {
    this.root = root;
    const lines = fs.readFileSync(path.join(root, '.build.info'), 'utf8').trim().split(/\r?\n/);
    const head = lines[0].split('|').map((h) => h.split('!')[0]);
    const rows = lines.slice(1).map((l) => Object.fromEntries(l.split('|').map((v, i) => [head[i], v])));
    const row = rows.find((r) => r.Product === product);
    if (!row) throw new Error('product not found: ' + product);
    this.version = row.Version;
    const bk = row['Build Key'];
    this.buildConfig = this.readConfig(bk);
    this.dataDir = path.join(root, 'Data', 'data');
    this.loadIndices(this.dataDir);
    this.fds = {};
  }
  readConfig(key) {
    const txt = fs.readFileSync(path.join(this.root, 'Data', 'config', key.slice(0, 2), key.slice(2, 4), key), 'utf8');
    const out = {};
    for (const l of txt.split(/\r?\n/)) { const m = /^([\w-]+) = (.*)$/.exec(l); if (m) out[m[1]] = m[2].split(' '); }
    return out;
  }
  loadIndices(dir) {
    // keep the newest .idx per bucket
    const best = {};
    for (const f of fs.readdirSync(dir)) {
      const m = /^([0-9a-f]{2})([0-9a-f]{8})\.idx$/i.exec(f);
      if (!m) continue;
      const v = parseInt(m[2], 16);
      if (!best[m[1]] || best[m[1]].v < v) best[m[1]] = { v, f };
    }
    this.index = new Map();
    for (const { f } of Object.values(best)) {
      const b = fs.readFileSync(path.join(dir, f));
      const keyLen = b[8 + 6], offLen = b[8 + 5], sizeLen = b[8 + 4], offBits = b[8 + 7];
      // entries block: aligned to 16 after the 0x18-byte header area
      let p = (8 + 16 + 15) & ~15;
      const entriesSize = b.readUInt32LE(p); p += 8;
      const rec = keyLen + offLen + sizeLen;
      for (let e = 0; e + rec <= entriesSize; e += rec) {
        const o = p + e;
        const k = b.toString('hex', o, o + keyLen);
        if (this.index.has(k)) continue;
        let packed = 0;
        for (let i = 0; i < offLen; i++) packed = packed * 256 + b[o + keyLen + i];
        const div = 2 ** offBits;
        const archive = Math.floor(packed / div), offset = packed % div;
        const size = b.readUInt32LE(o + keyLen + offLen);
        this.index.set(k, { archive, offset, size });
      }
    }
  }
  readRaw(ekey) {
    const e = this.index.get(ekey.slice(0, 18).toLowerCase());
    if (!e) return null;
    const fd = this.fds[e.archive] ?? (this.fds[e.archive] = fs.openSync(path.join(this.dataDir, 'data.' + String(e.archive).padStart(3, '0')), 'r'));
    const buf = Buffer.alloc(e.size);
    fs.readSync(fd, buf, 0, e.size, e.offset);
    return buf.subarray(30); // 30-byte local header
  }
  static blte(b) {
    if (b.toString('latin1', 0, 4) !== 'BLTE') throw new Error('not BLTE');
    const hs = b.readUInt32BE(4);
    const chunks = [];
    if (hs === 0) chunks.push({ c: b.length - 8, start: 8 });
    else {
      const n = b.readUIntBE(9, 3);
      let p = 12, start = hs;
      for (let i = 0; i < n; i++) { const c = b.readUInt32BE(p); chunks.push({ c, start }); start += c; p += 24; }
    }
    const out = [];
    for (const { c, start } of chunks) {
      const mode = String.fromCharCode(b[start]), d = b.subarray(start + 1, start + c);
      if (mode === 'N') out.push(d);
      else if (mode === 'Z') out.push(zlib.inflateSync(d));
      else if (mode === 'E') throw new Error('encrypted chunk');
      else throw new Error('BLTE mode ' + mode);
    }
    return Buffer.concat(out);
  }
  readEKey(ekey) { const r = this.readRaw(ekey); return r && Casc.blte(r); }
  loadEncoding() {
    const b = this.readEKey(this.buildConfig.encoding[1]);
    const ckeyLen = b[3], ekeyLen = b[4], pageKB = b.readUInt16BE(5), pages = b.readUInt32BE(9), especSize = b.readUInt32BE(18);
    let p = 22 + especSize + pages * 32;
    this.enc = new Map();
    for (let i = 0; i < pages; i++) {
      const end = p + pageKB * 1024;
      let q = p;
      while (q < end) {
        const n = b[q]; if (!n) break;
        const ck = b.toString('hex', q + 6, q + 6 + ckeyLen);
        this.enc.set(ck, b.toString('hex', q + 6 + ckeyLen, q + 6 + ckeyLen + ekeyLen));
        q += 6 + ckeyLen + n * ekeyLen;
      }
      p = end;
    }
  }
  readCKey(ckey) { const ek = this.enc.get(ckey); if (!ek) return null; return this.readEKey(ek); }
  loadRoot() {
    const b = this.readCKey(this.buildConfig.root[0]);
    this.fdid = new Map();
    let p = 0, version = 0;
    if (b.toString('latin1', 0, 4) === 'TSFM') {
      const hs = b.readUInt32LE(4); version = b.readUInt32LE(8);
      p = hs > 1000 ? 12 : hs; // old v1 header had no size field
      if (hs > 1000) version = 1;
    }
    while (p < b.length) {
      const n = b.readUInt32LE(p);
      let content, locale;
      if (version >= 2) { locale = b.readUInt32LE(p + 4); const f1 = b.readUInt32LE(p + 8), f2 = b.readUInt32LE(p + 12), f3 = b[p + 16]; content = f1 | f2 | (f3 << 17); p += 17; }
      else { content = b.readUInt32LE(p + 4); locale = b.readUInt32LE(p + 8); p += 12; }
      const ids = new Array(n); let id = -1;
      for (let i = 0; i < n; i++) { id += b.readInt32LE(p + 4 * i) + 1; ids[i] = id; }
      p += 4 * n;
      const ckOff = p; p += 16 * n;
      const noNames = content & 0x10000000;
      if (!noNames) p += 8 * n;
      const enUS = locale & 0x2 || locale === 0xffffffff || locale === 0;
      for (let i = 0; i < n; i++) if (enUS || !this.fdid.has(ids[i])) this.fdid.set(ids[i], b.toString('hex', ckOff + 16 * i, ckOff + 16 * i + 16));
    }
  }
  readFdid(id) { const ck = this.fdid.get(id); return ck ? this.readCKey(ck) : null; }
}
module.exports = Casc;

if (require.main === module) {
  const c = new Casc(process.argv[2], process.argv[3] || 'wowf');
  console.log('version', c.version, 'index entries', c.index.size);
  c.loadEncoding(); console.log('encoding entries', c.enc.size);
  c.loadRoot(); console.log('root fdids', c.fdid.size);
  const wdt = c.readFdid(775971);
  console.log('azeroth.wdt', wdt ? wdt.length + ' bytes, first chunk ' + wdt.toString('latin1', 0, 4) : 'missing');
}
