// Collision geometry for a zone: WMO (buildings, caves, bridges) and M2 (doodads) placed in world space.
// Exports collect(casc, wdt, tiles, bounds) -> { tris: Float32Array (9 floats per triangle, world X,Y,Z), count, stats }
const TILE = 1600 / 3, ORIGIN = 32 * TILE;

function chunks(b, s = 0, e = b.length) {
  const o = [];
  for (let p = s; p + 8 <= e;) { const id = b.toString('latin1', p, p + 4).split('').reverse().join(''), sz = b.readUInt32LE(p + 4); o.push({ id, start: p + 8, size: sz }); p += 8 + sz; }
  return o;
}

// model -> world. Fitted against the stored placement bounding boxes (exact match):
// model (mx,my,mz) -> placement space v = (my, mz, mx); rotate by M = Ry(rot.y) * Rx(rot.x) * Rz(rot.z) (degrees);
// scale; add placement position; placement (px,py,pz) -> world (ORIGIN - pz, ORIGIN - px, py).
function transform(pos, rot, scale) {
  const d = Math.PI / 180;
  const Rx = (t) => [[1, 0, 0], [0, Math.cos(t), -Math.sin(t)], [0, Math.sin(t), Math.cos(t)]];
  const Ry = (t) => [[Math.cos(t), 0, Math.sin(t)], [0, 1, 0], [-Math.sin(t), 0, Math.cos(t)]];
  const Rz = (t) => [[Math.cos(t), -Math.sin(t), 0], [Math.sin(t), Math.cos(t), 0], [0, 0, 1]];
  const mul = (A, B) => A.map((r) => [0, 1, 2].map((j) => r[0] * B[0][j] + r[1] * B[1][j] + r[2] * B[2][j]));
  const M = mul(mul(Ry(rot[1] * d), Rx(rot[0] * d)), Rz(rot[2] * d)).map((r) => r.map((v) => v * scale));
  return (x, y, z) => {
    const v0 = y, v1 = z, v2 = x;
    const px = M[0][0] * v0 + M[0][1] * v1 + M[0][2] * v2 + pos[0];
    const py = M[1][0] * v0 + M[1][1] * v1 + M[1][2] * v2 + pos[1];
    const pz = M[2][0] * v0 + M[2][1] * v1 + M[2][2] * v2 + pos[2];
    return [ORIGIN - pz, ORIGIN - px, py];
  };
}

// WMO collision triangles in model space (cached per file)
const wmoCache = new Map();
function wmoTris(casc, fdid) {
  if (wmoCache.has(fdid)) return wmoCache.get(fdid);
  const out = [];
  const root = casc.readFdid(fdid);
  if (root) {
    const rc = chunks(root), gfid = rc.find((c) => c.id === 'GFID'), mohd = rc.find((c) => c.id === 'MOHD');
    const nGroups = root.readUInt32LE(mohd.start + 4);
    for (let g = 0; g < nGroups && gfid; g++) {
      const gb = casc.readFdid(root.readUInt32LE(gfid.start + 4 * g));
      if (!gb) continue;
      const mogp = chunks(gb).find((c) => c.id === 'MOGP');
      if (!mogp) continue;
      const sub = chunks(gb, mogp.start + 68, mogp.start + mogp.size);
      // newer models (Forever's rebuilt cities) use MPY2 (u16 flags + u16 material) and MOVX (u32 indices)
      const mopy = sub.find((c) => c.id === 'MOPY'), mpy2 = sub.find((c) => c.id === 'MPY2');
      const movi = sub.find((c) => c.id === 'MOVI'), movx = sub.find((c) => c.id === 'MOVX'), movt = sub.find((c) => c.id === 'MOVT');
      if (!(mopy || mpy2) || !(movi || movx) || !movt) continue;
      const idx = movx ? (k) => gb.readUInt32LE(movx.start + 4 * k) : (k) => gb.readUInt16LE(movi.start + 2 * k);
      const nTri = movx ? movx.size / 12 : movi.size / 6;
      for (let t = 0; t < nTri; t++) {
        const flags = mpy2 ? gb.readUInt16LE(mpy2.start + 4 * t) : gb[mopy.start + 2 * t];
        const mat = mpy2 ? gb.readUInt16LE(mpy2.start + 4 * t + 2) : gb[mopy.start + 2 * t + 1];
        // collidable: F_COLLISION, or rendered and not detail; material 0xFF is collision-only
        const collide = (flags & 0x08) || (flags & 0x20) || mat === 0xff || mat === 0xffff; // Forever's models flag lots of cave surface as 'detail'; count everything rendered
        if (!collide) continue;
        for (let v = 0; v < 3; v++) {
          const i = idx(3 * t + v);
          out.push(gb.readFloatLE(movt.start + 12 * i), gb.readFloatLE(movt.start + 12 * i + 4), gb.readFloatLE(movt.start + 12 * i + 8));
        }
      }
    }
  }
  const f = Float32Array.from(out);
  wmoCache.set(fdid, f);
  return f;
}

// M2 collision mesh in model space (cached per file)
const m2Cache = new Map();
function m2Tris(casc, fdid) {
  if (m2Cache.has(fdid)) return m2Cache.get(fdid);
  let f = new Float32Array(0);
  const b = casc.readFdid(fdid);
  if (b) {
    let md = 0;
    if (b.toString('latin1', 0, 4) === 'MD21') md = 8; else if (b.toString('latin1', 0, 4) !== 'MD20') md = -1;
    if (md >= 0) {
      const nIdx = b.readUInt32LE(md + 216), oIdx = b.readUInt32LE(md + 220), nPos = b.readUInt32LE(md + 224), oPos = b.readUInt32LE(md + 228);
      if (nIdx && nPos) {
        const out = new Float32Array(nIdx * 3);
        for (let i = 0; i < nIdx; i++) { const v = b.readUInt16LE(md + oIdx + 2 * i); for (let k = 0; k < 3; k++) out[3 * i + k] = b.readFloatLE(md + oPos + 12 * v + 4 * k); }
        f = out;
      }
    }
  }
  m2Cache.set(fdid, f);
  return f;
}

function collect(casc, wdt, tiles, inBox) {
  const maid = chunks(wdt).find((c) => c.id === 'MAID');
  const seen = new Set(), parts = [], placements = [], kinds = [];
  let total = 0, nWmo = 0, nM2 = 0;
  const add = (src, xf, kind, id) => {
    const out = new Float32Array(src.length);
    let any = false;
    for (let i = 0; i < src.length; i += 3) { const p = xf(src[i], src[i + 1], src[i + 2]); out[i] = p[0]; out[i + 1] = p[1]; out[i + 2] = p[2]; if (!any && inBox(p[0], p[1])) any = true; }
    if (any) { parts.push(out); kinds.push(kind === 'wmo' ? 1 : 0); total += out.length; }
    return any;
  };
  for (const [row, col] of tiles) {
    const objFdid = wdt.readUInt32LE(maid.start + (row * 64 + col) * 32 + 4);
    const obj = objFdid && casc.readFdid(objFdid);
    if (!obj) continue;
    const ch = chunks(obj);
    const modf = ch.find((c) => c.id === 'MODF'), mddf = ch.find((c) => c.id === 'MDDF');
    if (modf) for (let p = modf.start; p < modf.start + modf.size; p += 64) {
      const fdid = obj.readUInt32LE(p), uid = obj.readUInt32LE(p + 4);
      if (seen.has('w' + uid)) continue; seen.add('w' + uid);
      const pos = [0, 1, 2].map((k) => obj.readFloatLE(p + 8 + 4 * k)), rot = [0, 1, 2].map((k) => obj.readFloatLE(p + 20 + 4 * k));
      const flags = obj.readUInt16LE(p + 56), scale = flags & 0x4 ? obj.readUInt16LE(p + 62) / 1024 : 1;
      const xf = transform(pos, rot, scale);
      if (add(wmoTris(casc, fdid), xf, 'wmo', fdid)) { nWmo++; const c = xf(0, 0, 0); placements.push({ kind: 'wmo', fdid, X: c[0], Y: c[1], Z: c[2] }); }
    }
    if (mddf) for (let p = mddf.start; p < mddf.start + mddf.size; p += 36) {
      const fdid = obj.readUInt32LE(p), uid = obj.readUInt32LE(p + 4);
      if (seen.has('m' + uid)) continue; seen.add('m' + uid);
      const pos = [0, 1, 2].map((k) => obj.readFloatLE(p + 8 + 4 * k)), rot = [0, 1, 2].map((k) => obj.readFloatLE(p + 20 + 4 * k));
      const scale = obj.readUInt16LE(p + 32) / 1024;
      const tris = m2Tris(casc, fdid);
      if (!tris.length) continue;
      if (add(tris, transform(pos, rot, scale), 'm2', fdid)) nM2++;
    }
  }
  const tris = new Float32Array(total); let o = 0; for (const p of parts) { tris.set(p, o); o += p.length; }
  // per triangle: 1 = building (WMO), 0 = prop (M2)
  const triKind = new Uint8Array(total / 9); let t = 0; parts.forEach((p, k) => { triKind.fill(kinds[k], t, t + p.length / 9); t += p.length / 9; });
  return { tris, triKind, count: total / 9, placements, stats: { wmo: nWmo, m2: nM2, wmoModels: wmoCache.size, m2Models: m2Cache.size } };
}
module.exports = { collect, chunks, transform, TILE, ORIGIN };
