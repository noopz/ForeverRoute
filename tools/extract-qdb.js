// Decode QuestieDB's baked TOC metadata store (base64 + CBOR, ID list deflated) into JSON.
// usage: node extract-qdb.js <path to QuestieDB_Forever.toc> <outDir>
const fs = require('fs');
const zlib = require('zlib');
const path = require('path');

const [tocPath, outDir] = process.argv.slice(2);
const lines = fs.readFileSync(tocPath, 'latin1').split(/\r?\n/);
const meta = new Map();
for (const l of lines) {
  const m = /^## (X-[^:]+):\s?(.*)$/.exec(l);
  if (m) meta.set(m[1], m[2]);
}

function getStored(key) {
  const v = meta.get(key);
  if (v === undefined) return undefined;
  const c = /^~(\d+)~$/.exec(v);
  if (!c) return v;
  let s = '';
  for (let i = 1; i <= +c[1]; i++) {
    const p = meta.get(key + '-' + i);
    if (p === undefined) throw new Error('missing chunk ' + key + '-' + i);
    s += p;
  }
  return s;
}

function cbor(buf) {
  let o = 0;
  const half = (h) => {
    const e = (h >> 10) & 0x1f, f = h & 0x3ff, s = h & 0x8000 ? -1 : 1;
    if (e === 0) return s * f * 2 ** -24;
    if (e === 31) return f ? NaN : s * Infinity;
    return s * (1 + f / 1024) * 2 ** (e - 15);
  };
  function arg(ai) {
    if (ai < 24) return ai;
    if (ai === 24) return buf[o++];
    if (ai === 25) { const v = buf.readUInt16BE(o); o += 2; return v; }
    if (ai === 26) { const v = buf.readUInt32BE(o); o += 4; return v; }
    if (ai === 27) { const v = Number(buf.readBigUInt64BE(o)); o += 8; return v; }
    if (ai === 31) return -1;
    throw new Error('bad ai ' + ai);
  }
  function item() {
    const b = buf[o++], mt = b >> 5, ai = b & 31;
    if (mt === 7) {
      if (ai === 20) return false; if (ai === 21) return true;
      if (ai === 22 || ai === 23) return null;
      if (ai === 25) { const v = half(buf.readUInt16BE(o)); o += 2; return v; }
      if (ai === 26) { const v = buf.readFloatBE(o); o += 4; return v; }
      if (ai === 27) { const v = buf.readDoubleBE(o); o += 8; return v; }
      throw new Error('bad simple ' + ai);
    }
    const n = arg(ai);
    switch (mt) {
      case 0: return n;
      case 1: return -1 - n;
      case 2: { const v = buf.slice(o, o + n); o += n; return v.toString('latin1'); }
      case 3: { const v = buf.slice(o, o + n); o += n; return v.toString('utf8'); }
      case 4: { const a = []; if (n < 0) { while (buf[o] !== 0xff) a.push(item()); o++; } else for (let i = 0; i < n; i++) a.push(item()); return a; }
      case 5: { const m = {}; const rd = () => { const k = item(); m[k] = item(); }; if (n < 0) { while (buf[o] !== 0xff) rd(); o++; } else for (let i = 0; i < n; i++) rd(); return m; }
      case 6: return item(); // tag: ignore
    }
  }
  return item();
}
const b64 = (s) => Buffer.from(s, 'base64');
function inflate(b) {
  for (const f of [zlib.inflateSync, zlib.inflateRawSync, zlib.gunzipSync]) { try { return f(b); } catch (e) {} }
  throw new Error('cannot inflate');
}

fs.mkdirSync(outDir, { recursive: true });
for (const ent of ['Quest', 'Npc', 'Object', 'Item']) {
  const prefix = 'X-' + ent + '-';
  const idsRaw = getStored(prefix + 'IDS');
  if (!idsRaw) { console.log('no ids for', ent); continue; }
  const ids = cbor(inflate(b64(idsRaw)));
  const fieldRe = new RegExp('^' + prefix + '(\\d+)-(\\d+)$');
  const fieldsById = new Map();
  for (const k of meta.keys()) {
    const m = fieldRe.exec(k);
    if (m) { if (!fieldsById.has(+m[1])) fieldsById.set(+m[1], []); fieldsById.get(+m[1]).push(+m[2]); }
  }
  const out = {};
  for (const id of ids) {
    const s = getStored(prefix + id + '-S');
    const row = s ? cbor(b64(s)) : {};
    const rec = {};
    if (Array.isArray(row)) row.forEach((v, i) => { if (v !== null) rec[i + 1] = v; });
    else for (const [k, v] of Object.entries(row)) rec[k] = v;
    for (const f of fieldsById.get(id) || []) {
      const v = getStored(prefix + id + '-' + f);
      // chunk parts look like <id>-<field>-<n>; they don't match fieldRe, so no clash
      if (v !== undefined) { try { rec[f] = cbor(b64(v)); } catch (e) { rec[f] = { _err: String(e) }; } }
    }
    out[id] = rec;
  }
  fs.writeFileSync(path.join(outDir, ent.toLowerCase() + 's.json'), JSON.stringify(out));
  console.log(ent, ids.length);
}
