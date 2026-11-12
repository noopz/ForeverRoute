// Roads for the walking line: where the ground of a zone is painted with a road texture (cobblestone, a dirt road, a
// bridge's planks), read from the client's terrain texture layers the way tools/terrain.js reads heights.
// Read-only on the game folder.
//
//   node roads.js build <areaId[,areaId]|all> [outDir=terrain]  -> <outDir>/area<N>.road.u8 + area<N>.road.json
//   node roads.js textures <areaId[,..]> [listfile.csv]         -> every ground texture of the zone and how much of
//                                                                  it it covers (to check road-textures.json against)
//   node roads.js pick <areaId[,..]|all> <listfile.csv>         -> tools/road-textures.json: the ground textures of
//                                                                  these zones whose name says road (kept: what is
//                                                                  already in it, and its "not" list)
//   node roads.js png <areaId> <out.png> [dir]                  -> the raster, for a look
//
// How: each terrain tile has a texture file (_tex0.adt): the tile's ground textures (MDID, file ids) and, for each of
// its 16x16 chunks, up to 4 layers (MCLY) with a 64x64 alpha map each (MCAL). The weight of a layer at a point is its
// alpha times what the layers above leave of it. A point is road where the road textures (tools/road-textures.json:
// file id -> name, picked by name from the community listfile and checked on a picture of each zone) hold at
// least half of the weight. The raster has one byte per 2.08-yd cell (a quarter of a terrain quad): 0-255 = the share
// of road in it. tools/navgrid.js turns it into one bit per square of the addon's walk map.
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const Casc = require('./casc');
const ROOT = path.join(__dirname, '..');
const MAIN = process.env.FR_MAIN || 'D:/git/ForeverRoute';
const pick = (name) => (fs.existsSync(path.join(ROOT, name)) ? path.join(ROOT, name) : path.join(MAIN, name));
const TERRAIN = process.env.FR_TERRAIN || pick('terrain');
const QDB = process.env.FR_QDB || pick('qdb');
const TILE = 1600 / 3, CHUNK = TILE / 16, UNIT = CHUNK / 8, CELL = UNIT / 2; // 533.33, 33.33, 4.17, 2.08 yards
const WDT_BY_MAP = { 0: 775971, 1: 782779 }; // Azeroth (Eastern Kingdoms), Kalimdor
const ROADTEX = path.join(__dirname, 'road-textures.json');

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
let casc = null;
function openGame() {
  if (casc) return casc;
  const WOW = process.env.FR_WOW || require(fs.existsSync(path.join(ROOT, 'game-dir.txt')) ? './game-dir' : path.join(MAIN, 'tools', 'game-dir')).WOW;
  casc = new Casc(WOW, 'wowf'); casc.loadEncoding(); casc.loadRoot();
  return casc;
}
const wdts = {};
function wdtOf(map) {
  if (wdts[map]) return wdts[map];
  const b = openGame().readFdid(WDT_BY_MAP[map]);
  const top = chunks(b);
  const maid = top.find((c) => c.id === 'MAID'), mphd = top.find((c) => c.id === 'MPHD');
  const flags = b.readUInt32LE(mphd.start);
  return (wdts[map] = { b, maid, bigAlpha: !!(flags & 0x4) || !!(flags & 0x80) });
}
function transforms() { return JSON.parse(fs.readFileSync(path.join(QDB, 'conversion.json'), 'utf8')).geometry.transforms; }
function areaInfo(area) {
  const tr = transforms().find((t) => t.area_id === +area);
  if (!tr) throw new Error('area not in conversion.json: ' + area);
  return { area: +area, name: tr.target_name, map: tr.map_id, ui: tr.ui_map_id, B: tr.target_bounds || tr.source_bounds };
}
function allAreas() {
  return transforms().filter((t) => WDT_BY_MAP[t.map_id] && fs.existsSync(path.join(TERRAIN, `area${t.area_id}.vox.json`))).map((t) => t.area_id);
}
// one alpha map (64x64 bytes) of a layer
function alphaOf(b, at, flags, bigAlpha) {
  const out = new Uint8Array(4096);
  if (flags & 0x200) { // compressed: runs
    let p = at, o = 0;
    while (o < 4096) {
      const h = b[p++], n = h & 0x7f;
      if (!n) break;
      if (h & 0x80) { const v = b[p++]; for (let i = 0; i < n && o < 4096; i++) out[o++] = v; } else for (let i = 0; i < n && o < 4096; i++) out[o++] = b[p++];
    }
  } else if (bigAlpha) out.set(b.subarray(at, at + 4096));
  else for (let i = 0; i < 2048; i++) { const v = b[at + i]; out[2 * i] = (v & 15) * 17; out[2 * i + 1] = (v >> 4) * 17; } // 4 bits a point
  return out;
}
// every chunk of the tiles under a zone: fn({ px, py (its north-west corner, world yards), tex: [file id per layer],
// weight: [Float32Array(64 * 64) per layer] })
function eachChunk(info, fn) {
  const W = wdtOf(info.map), B = info.B, c = openGame();
  const tiles = new Set();
  for (let X = B.bottom; X <= B.top + TILE; X += TILE) for (let Y = B.right; Y <= B.left + TILE; Y += TILE) {
    tiles.add(Math.floor(32 - Math.min(X, B.top) / TILE) + ',' + Math.floor(32 - Math.min(Y, B.left) / TILE));
  }
  for (const t of tiles) {
    const [row, col] = t.split(',').map(Number);
    const e = W.maid.start + (row * 64 + col) * 32;
    const texId = W.b.readUInt32LE(e + 12);
    if (!texId) continue;
    const tex = c.readFdid(texId); if (!tex) continue;
    const top = chunks(tex);
    const mdid = top.find((k) => k.id === 'MDID'); if (!mdid) continue;
    const ids = []; for (let p = 0; p < mdid.size; p += 4) ids.push(tex.readUInt32LE(mdid.start + p));
    top.filter((k) => k.id === 'MCNK').forEach((mc, i) => {
      const sub = chunks(tex, mc.start, mc.start + mc.size);
      const mcly = sub.find((k) => k.id === 'MCLY'), mcal = sub.find((k) => k.id === 'MCAL');
      if (!mcly) return;
      const n = mcly.size / 16, layers = [];
      if (!n) return;
      for (let l = 0; l < n; l++) {
        const o = mcly.start + l * 16, flags = tex.readUInt32LE(o + 4);
        layers.push({ tex: ids[tex.readUInt32LE(o)], alpha: l > 0 && (flags & 0x100) && mcal ? alphaOf(tex, mcal.start + tex.readUInt32LE(o + 8), flags, W.bigAlpha) : null });
      }
      const weight = layers.map(() => new Float32Array(4096)); // from the top layer down
      for (let k = 0; k < 4096; k++) {
        let left = 1;
        for (let l = n - 1; l >= 1; l--) { const a = layers[l].alpha ? layers[l].alpha[k] / 255 : 0; weight[l][k] = a * left; left *= 1 - a; }
        weight[0][k] = left;
      }
      const cy = i % 16, cx = (i - cy) / 16; // chunk i of the tile: row cx (south), column cy (east)
      fn({ px: (32 - row) * TILE - cx * CHUNK, py: (32 - col) * TILE - cy * CHUNK, tex: layers.map((l) => l.tex), weight });
    });
  }
}
function listfile(file, want) {
  const names = new Map();
  if (!file) return names;
  const txt = fs.readFileSync(file, 'latin1');
  let p = 0;
  while (p < txt.length) {
    let e = txt.indexOf('\n', p); if (e < 0) e = txt.length;
    const s = txt.indexOf(';', p);
    if (s > p && s < e) { const id = +txt.slice(p, s); if (want.has(id)) names.set(id, txt.slice(s + 1, e).trim()); }
    p = e + 1;
  }
  return names;
}
function known() { try { return JSON.parse(fs.readFileSync(ROADTEX, 'utf8')); } catch (e) { return { road: {} }; } }

function textures(areas, lf) {
  const all = new Set(), perArea = {};
  for (const a of areas) {
    const info = areaInfo(a), cov = new Map(); let total = 0;
    eachChunk(info, (ch) => {
      if (ch.px < info.B.bottom || ch.px - CHUNK > info.B.top || ch.py < info.B.right || ch.py - CHUNK > info.B.left) return;
      ch.tex.forEach((id, l) => { let s = 0; const w = ch.weight[l]; for (let k = 0; k < 4096; k += 7) s += w[k]; cov.set(id, (cov.get(id) || 0) + s); total += s; });
    });
    perArea[a] = { info, cov, total };
    for (const id of cov.keys()) all.add(id);
  }
  const names = listfile(lf, all), K = known();
  for (const a of areas) {
    const { info, cov, total } = perArea[a];
    console.log(`${info.name} (area ${a})`);
    for (const [id, s] of [...cov].sort((x, y) => y[1] - x[1])) {
      console.log(`  ${String(id).padStart(8)} ${(100 * s / total).toFixed(2).padStart(6)}%  ${K.road[id] ? 'ROAD' : '    '} ${names.get(id) || K.road[id] || '?'}`);
    }
  }
}

// a road by its name in the classic tilesets (elwynncobblestonebase, redridgerockroadbase, wetlandsroad01,
// lochmodanbrickroadbase). A name that lies goes into road-textures.json "not" by hand; a road with a plain name in "road".
const ROAD_NAME = /cobble|road|brick|pave/;
function pickRoads(areas, lf) {
  const all = new Map();
  for (const a of areas) { const info = areaInfo(a); eachChunk(info, (ch) => { for (const id of ch.tex) if (!all.has(id)) all.set(id, info.name); }); }
  const names = listfile(lf, all), K = known();
  K.not = K.not || {};
  for (const [id, nm] of names) if (ROAD_NAME.test(path.basename(nm)) && !K.not[id]) K.road[id] = nm;
  const sorted = {}; for (const id of Object.keys(K.road).sort((x, y) => x - y)) sorted[id] = K.road[id];
  K.road = sorted;
  K._about = K._about || 'Ground textures that are roads (file id -> name), for tools/roads.js. Made by "roads.js pick" from the names in the community listfile (github.com/wowdev/wow-listfile); "not" = ids whose name says road but are not one.';
  fs.writeFileSync(ROADTEX, JSON.stringify({ _about: K._about, road: K.road, not: K.not }, null, 1) + String.fromCharCode(10));
  console.log(Object.keys(K.road).length + ' road textures');
}

function build(area, outDir) {
  const info = areaInfo(area), B = info.B, road = new Set(Object.keys(known().road).map(Number));
  const T = JSON.parse(fs.readFileSync(path.join(TERRAIN, `area${area}.json`), 'utf8')); // the height grid's lattice
  const X0 = T.X0, Y0 = T.Y0;
  const W = Math.ceil((Y0 - B.right) / CELL) + 1, H = Math.ceil((X0 - B.bottom) / CELL) + 1;
  const sum = new Float32Array(W * H), cnt = new Uint16Array(W * H);
  const px = CHUNK / 64;
  eachChunk(info, (ch) => {
    const layers = []; ch.tex.forEach((id, l) => { if (road.has(id)) layers.push(ch.weight[l]); });
    for (let r = 0; r < 64; r++) {
      const row = Math.floor((X0 - (ch.px - (r + 0.5) * px)) / CELL); if (row < 0 || row >= H) continue;
      for (let c = 0; c < 64; c++) {
        const col = Math.floor((Y0 - (ch.py - (c + 0.5) * px)) / CELL); if (col < 0 || col >= W) continue;
        let w = 0; for (const L of layers) w += L[r * 64 + c];
        sum[row * W + col] += w; cnt[row * W + col]++;
      }
    }
  });
  const out = new Uint8Array(W * H); let n = 0;
  for (let k = 0; k < W * H; k++) if (cnt[k]) { out[k] = Math.round(255 * sum[k] / cnt[k]); if (out[k] >= 128) n++; }
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, `area${area}.road.u8`), out);
  fs.writeFileSync(path.join(outDir, `area${area}.road.json`), JSON.stringify({ area: +area, name: info.name, X0, Y0, W, H, cell: CELL, roadShare: +(n / (W * H)).toFixed(4) }));
  console.log(`${info.name}: ${W}x${H} cells of ${CELL.toFixed(2)} yd, ${(100 * n / (W * H)).toFixed(2)}% road`);
}
// the raster for a zone, or null: { W, H, X0, Y0, cell, data, at(X, Y) -> 0..255 }
function load(area, dir) {
  for (const d of dir ? [dir] : [process.env.FR_ROADS, TERRAIN].filter(Boolean)) {
    const jf = path.join(d, `area${area}.road.json`);
    if (!fs.existsSync(jf)) continue;
    const M = JSON.parse(fs.readFileSync(jf, 'utf8')), data = fs.readFileSync(path.join(d, `area${area}.road.u8`));
    M.data = data;
    M.at = (X, Y) => { const r = Math.floor((M.X0 - X) / M.cell), c = Math.floor((M.Y0 - Y) / M.cell); return r < 0 || c < 0 || r >= M.H || c >= M.W ? 0 : data[r * M.W + c]; };
    return M;
  }
  return null;
}
function png(area, file, dir) {
  const M = load(area, dir); if (!M) throw new Error('no road raster for area ' + area);
  const W = M.W, H = M.H, raw = Buffer.alloc((W + 1) * H);
  for (let r = 0; r < H; r++) for (let c = 0; c < W; c++) raw[r * (W + 1) + 1 + c] = M.data[r * W + c];
  const crcT = []; for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; crcT[n] = c >>> 0; }
  const crc = (b) => { let c = 0xffffffff; for (const v of b) c = crcT[(c ^ v) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  const chunk = (t, d) => { const l = Buffer.alloc(4); l.writeUInt32BE(d.length); const td = Buffer.concat([Buffer.from(t), d]); const cb = Buffer.alloc(4); cb.writeUInt32BE(crc(td)); return Buffer.concat([l, td, cb]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(W, 0); ihdr.writeUInt32BE(H, 4); ihdr[8] = 8; ihdr[9] = 0;
  fs.writeFileSync(file, Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]));
}
module.exports = { load, CELL };

if (require.main === module) {
  const [cmd, a, b, c] = process.argv.slice(2);
  const list = (s) => (s === 'all' ? allAreas() : s.split(',').map(Number));
  if (cmd === 'build') for (const area of list(a)) build(area, b || TERRAIN);
  else if (cmd === 'textures') textures(list(a), b);
  else if (cmd === 'pick') pickRoads(list(a), b);
  else if (cmd === 'png') png(+a, b, c);
  else console.log('usage: node roads.js build|textures|pick|png ... (see the top of the file)');
}
