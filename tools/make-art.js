// Draws the addon's textures as anti-aliased 32-bit TGAs (white glyphs; tinted in game with SetVertexColor).
// usage: node make-art.js <outDir>
const fs = require('fs');
const path = require('path');
const out = process.argv[2];
fs.mkdirSync(out, { recursive: true });

function tga(name, size, shade) {
  const S = 4; // supersampling per axis
  const buf = Buffer.alloc(18 + size * size * 4);
  buf[2] = 2; buf.writeUInt16LE(size, 12); buf.writeUInt16LE(size, 14); buf[16] = 32; buf[17] = 8 | 0x20; // top-left origin, 8 alpha bits
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
    let a = 0, lum = 0;
    for (let sy = 0; sy < S; sy++) for (let sx = 0; sx < S; sx++) {
      const u = (x + (sx + 0.5) / S) / size * 2 - 1, v = (y + (sy + 0.5) / S) / size * 2 - 1; // -1..1, y down
      const r = shade(u, v);
      if (r) { a += r[0]; lum += r[0] * r[1]; }
    }
    a /= S * S; const l = a ? lum / (a * S * S) : 1;
    const o = 18 + (y * size + x) * 4, c = Math.round(255 * l);
    buf[o] = c; buf[o + 1] = c; buf[o + 2] = c; buf[o + 3] = Math.round(255 * a);
  }
  fs.writeFileSync(path.join(out, name + '.tga'), buf);
}
// helpers: each returns [alpha 0..1, luminance 0..1] or null
const inPoly = (pts, u, v) => { let c = false; for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) { const [xi, yi] = pts[i], [xj, yj] = pts[j]; if ((yi > v) !== (yj > v) && u < (xj - xi) * (v - yi) / (yj - yi) + xi) c = !c; } return c; };
const segDist = (u, v, ax, ay, bx, by) => { const dx = bx - ax, dy = by - ay, t = Math.max(0, Math.min(1, ((u - ax) * dx + (v - ay) * dy) / (dx * dx + dy * dy))); return Math.hypot(u - ax - t * dx, v - ay - t * dy); };
const any = (...fs) => (u, v) => { for (const f of fs) { const r = f(u, v); if (r) return r; } return null; };

// Arrow: a sleek chevron-dart pointing up, with a lighter top facet for depth
tga('arrow', 128, (u, v) => {
  const outer = [[0, -0.92], [0.62, 0.78], [0, 0.42], [-0.62, 0.78]];
  if (!inPoly(outer, u, v)) return null;
  return [1, u < 0 ? 1.0 : 0.78];
});
// Soft ring (arrival pulse) and solid disc
tga('ring', 128, (u, v) => { const r = Math.hypot(u, v); return r > 0.78 && r < 0.92 ? [1, 1] : null; });
tga('glow', 128, (u, v) => { const r = Math.hypot(u, v); return r < 1 ? [Math.pow(1 - r, 2), 1] : null; });
tga('disc', 64, (u, v) => (Math.hypot(u, v) < 0.9 ? [1, 1] : null));
// Map pin: teardrop with a hole
tga('pin', 64, (u, v) => {
  const head = Math.hypot(u, v + 0.25) < 0.62, tip = inPoly([[-0.5, 0.05], [0.5, 0.05], [0, 0.95]], u, v);
  if (!(head || tip)) return null;
  if (Math.hypot(u, v + 0.25) < 0.24) return null;
  return [1, 1];
});
// Icons on a 64px canvas
tga('icon-accept', 64, any(
  (u, v) => (Math.abs(u) < 0.13 && v > -0.78 && v < 0.28 ? [1, 1] : null),
  (u, v) => (Math.hypot(u, v - 0.62) < 0.16 ? [1, 1] : null)));
tga('icon-turnin', 64, (u, v) => {
  const arc = Math.hypot(u, v + 0.3) < 0.5 && Math.hypot(u, v + 0.3) > 0.24 && !(u < 0 && v > -0.3);
  const stem = Math.abs(u) < 0.13 && v > -0.08 && v < 0.32;
  const dot = Math.hypot(u, v - 0.66) < 0.16;
  return arc || stem || dot ? [1, 1] : null;
});
tga('icon-kill', 64, (u, v) => { // crossed swords
  const s1 = segDist(u, v, -0.7, -0.7, 0.55, 0.55) < 0.1, s2 = segDist(u, v, 0.7, -0.7, -0.55, 0.55) < 0.1;
  const g1 = segDist(u, v, 0.32, 0.72, 0.72, 0.32) < 0.09, g2 = segDist(u, v, -0.32, 0.72, -0.72, 0.32) < 0.09;
  return s1 || s2 || g1 || g2 ? [1, 1] : null;
});
tga('icon-loot', 64, (u, v) => { // sack
  const body = Math.hypot(u / 0.72, (v - 0.22) / 0.62) < 1, neck = inPoly([[-0.22, -0.32], [0.22, -0.32], [0.38, -0.7], [-0.38, -0.7]], u, v);
  const tie = Math.abs(v + 0.36) < 0.06 && Math.abs(u) < 0.32;
  if (tie) return [1, 0.55];
  return body || neck ? [1, 1] : null;
});
tga('icon-fly', 64, (u, v) => { // wing
  const feathers = [0, 1, 2, 3].some((k) => segDist(u, v, -0.7 + k * 0.08, 0.5 - k * 0.12, 0.75 - k * 0.12, -0.55 + k * 0.32) < 0.08);
  return feathers ? [1, 1] : null;
});
tga('icon-hearth', 64, (u, v) => { // house
  const roof = inPoly([[0, -0.82], [0.82, -0.05], [-0.82, -0.05]], u, v), body = Math.abs(u) < 0.58 && v > -0.08 && v < 0.78;
  const door = Math.abs(u) < 0.17 && v > 0.32 && v < 0.78;
  if (door) return null;
  return roof || body ? [1, 1] : null;
});
tga('icon-train', 64, (u, v) => { // open book
  const l = inPoly([[-0.85, -0.5], [-0.05, -0.35], [-0.05, 0.7], [-0.85, 0.55]], u, v), r = inPoly([[0.85, -0.5], [0.05, -0.35], [0.05, 0.7], [0.85, 0.55]], u, v);
  return l ? [1, 1] : r ? [1, 0.8] : null;
});
tga('icon-goto', 64, (u, v) => { // compass-ish waypoint flag
  const pole = Math.abs(u + 0.45) < 0.08 && v > -0.8 && v < 0.85, flag = inPoly([[-0.4, -0.78], [0.7, -0.5], [-0.4, -0.18]], u, v);
  return pole || flag ? [1, 1] : null;
});
tga('icon-grind', 64, (u, v) => { // crosshair
  const r = Math.hypot(u, v); const ring = r > 0.5 && r < 0.66, cross = (Math.abs(u) < 0.07 && Math.abs(v) > 0.25 && Math.abs(v) < 0.9) || (Math.abs(v) < 0.07 && Math.abs(u) > 0.25 && Math.abs(u) < 0.9);
  return ring || cross ? [1, 1] : null;
});
tga('icon-check', 64, (u, v) => (segDist(u, v, -0.6, 0.05, -0.15, 0.5) < 0.13 || segDist(u, v, -0.15, 0.5, 0.65, -0.45) < 0.13 ? [1, 1] : null));
tga('icon-note', 64, (u, v) => { const r = Math.hypot(u, v); const ring = r > 0.68 && r < 0.84; const i = (Math.abs(u) < 0.1 && v > -0.15 && v < 0.5) || Math.hypot(u, v + 0.42) < 0.12; return ring || i ? [1, 1] : null; });
// 1px-ish white for backdrops/bars (tinted)
tga('white', 8, () => [1, 1]);
console.log('art written to', out);

// ---- v2 UI art: rounded 9-slice panel, its edge, a soft shadow, icon-button glyphs ----
const rrect = (u, v, r, inset) => { // signed-ish distance test for a rounded rect filling -1..1 minus inset
  const a = 1 - inset, qx = Math.abs(u) - (a - r), qy = Math.abs(v) - (a - r);
  return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - r;
};
tga('panel', 64, (u, v) => (rrect(u, v, 0.32, 0.0) <= 0 ? [1, 1] : null));
tga('panel-edge', 64, (u, v) => { const d = rrect(u, v, 0.32, 0.0); return d <= 0 && d > -0.045 ? [1, 1] : null; });
tga('shadow', 64, (u, v) => { const d = rrect(u, v, 0.45, 0.1); if (d > 0.1) return null; const a = d < -0.1 ? 1 : 1 - (d + 0.1) / 0.2; return [a * a, 0]; });
tga('btn-back', 32, (u, v) => (segDist(u, v, 0.25, -0.5, -0.25, 0) < 0.12 || segDist(u, v, -0.25, 0, 0.25, 0.5) < 0.12 ? [1, 1] : null));
tga('btn-next', 32, (u, v) => (segDist(u, v, -0.25, -0.5, 0.25, 0) < 0.12 || segDist(u, v, 0.25, 0, -0.25, 0.5) < 0.12 ? [1, 1] : null));
tga('btn-skip', 32, (u, v) => (segDist(u, v, -0.55, -0.45, -0.05, 0) < 0.11 || segDist(u, v, -0.05, 0, -0.55, 0.45) < 0.11 || segDist(u, v, 0.05, -0.45, 0.55, 0) < 0.11 || segDist(u, v, 0.55, 0, 0.05, 0.45) < 0.11 ? [1, 1] : null));
tga('btn-undo', 32, (u, v) => { const r = Math.hypot(u, v - 0.1); const arc = r > 0.36 && r < 0.56 && !(u < 0 && v < 0.1); const head = inPoly([[-0.75, 0.1], [-0.15, 0.1], [-0.45, -0.35]], u, v); return arc || head ? [1, 1] : null; });
tga('btn-list', 32, (u, v) => ([-0.45, 0, 0.45].some((y) => Math.abs(v - y) < 0.1 && Math.abs(u) < 0.6) ? [1, 1] : null));
tga('btn-gear', 32, (u, v) => { const r = Math.hypot(u, v), a = Math.atan2(v, u); const teeth = r < 0.75 && r > 0.45 && Math.cos(a * 8) > 0.2; const ring = r < 0.55 && r > 0.25; return teeth || ring ? [1, 1] : null; });
tga('btn-min', 32, (u, v) => (Math.abs(v) < 0.1 && Math.abs(u) < 0.55 ? [1, 1] : null));
tga('dot', 16, (u, v) => (Math.hypot(u, v) < 0.75 ? [1, 1] : null));
console.log('v2 art written');
// the card's quest buttons: "not doing this quest" is an X (tinted red in game); "the giver doesn't offer it" is the
// quest giver's "!" struck through
tga('btn-x', 32, (u, v) => (segDist(u, v, -0.5, -0.5, 0.5, 0.5) < 0.13 || segDist(u, v, 0.5, -0.5, -0.5, 0.5) < 0.13 ? [1, 1] : null));
tga('btn-no-offer', 32, (u, v) => {
  const bang = (Math.abs(u) < 0.2 && v > -0.9 && v < 0.3) || Math.hypot(u, v - 0.68) < 0.22;
  const d = segDist(u, v, -0.6, 0.6, 0.6, -0.6);
  // a gap either side of the slash keeps the "!" readable under it at icon size
  return d < 0.1 || (bang && d > 0.22) ? [1, 1] : null;
});
