// Walking waypoints for route steps: the terrain/building-aware path from the previous stop (or the flight master when
// you've just arrived in a zone) to each step, simplified to a handful of turns, with floor heights kept so the arrow
// can say "upstairs" / "downstairs". Runs one worker per zone, caches every leg in paths/waypoints-cache.json.
// addWaypoints(routes, { terrainDir, conv, db, workers }) -> routes (steps gain wp = "x,y,z;x,y,z;..." 0-1 map coords)
const fs = require('fs');
const path = require('path');
const os = require('os');
const { Worker, isMainThread, parentPort, workerData } = require('worker_threads');

const AVOID_COST = +(process.env.FR_AVOID_COST || 8); // a hostile town's ground: 8 yards of walking a yard
// ...out to its guards' reach: the town's radius is its NPCs' spread, its guards patrol and come for you well beyond it
// (a Booty Bay to Nesingwary walk passed 140 yd from Grom'gol's centre, its radius 83 - along the camp's road)
const AVOID_MARGIN = +(process.env.FR_AVOID_MARGIN || 110);

function simplify(pts, eps) {
  // Douglas-Peucker in yards; never drop a point where the height changes a lot (stairs, ramps, lifts)
  if (pts.length < 3) return pts;
  const keep = new Uint8Array(pts.length); keep[0] = keep[pts.length - 1] = 1;
  for (let i = 1; i < pts.length - 1; i++) if (Math.abs(pts[i].z - pts[i - 1].z) > 3.5) keep[i] = keep[i - 1] = 1;
  const stack = [[0, pts.length - 1]];
  while (stack.length) {
    const [a, b] = stack.pop();
    let best = -1, bd = eps;
    const A = pts[a], B = pts[b], dx = B.X - A.X, dy = B.Y - A.Y, L = Math.hypot(dx, dy) || 1;
    for (let i = a + 1; i < b; i++) { const d = Math.abs((pts[i].X - A.X) * dy - (pts[i].Y - A.Y) * dx) / L; if (d > bd) { bd = d; best = i; } }
    if (best >= 0) { keep[best] = 1; stack.push([a, best], [best, b]); }
  }
  return pts.filter((_, i) => keep[i]);
}

if (!isMainThread) {
  const { VoxNav } = require('./voxnav');
  const { terrainDir, area, pairs, avoid } = workerData;
  const nav = new VoxNav(terrainDir, area);
  const B = nav.meta.bounds, wY = B.left - B.right, wX = B.top - B.bottom;
  // the other faction's towns in this zone (avoid: [{ x, y (0-1), r yards }]): their ground costs AVOID_COST times its
  // length, so a path goes round when there is a way round (Grom'gol: a Booty Bay to Nesingwary walk went through it)
  if (avoid && avoid.length) {
    const cc = new Float32Array(nav.W * nav.H).fill(1);
    for (const t of avoid) {
      const X = t.x * wY, Y = t.y * wX, R = t.r + AVOID_MARGIN;
      const c0 = Math.max(0, Math.floor((X - R) / nav.cell)), c1 = Math.min(nav.W - 1, Math.ceil((X + R) / nav.cell));
      const r0 = Math.max(0, Math.floor((Y - R) / nav.cell)), r1 = Math.min(nav.H - 1, Math.ceil((Y + R) / nav.cell));
      for (let r = r0; r <= r1; r++) for (let col = c0; col <= c1; col++) if (Math.hypot((col + 0.5) * nav.cell - X, (r + 0.5) * nav.cell - Y) <= R) cc[r * nav.W + col] = AVOID_COST;
    }
    nav.colCost = cc;
  }
  const out = {};
  for (const [key, a, b] of pairs) {
    try {
      const fa = nav.anchor(a), fb = nav.anchor(b);
      if (fa < 0 || fb < 0) { out[key] = null; continue; }
      nav.wantPrev = true; const d = nav.field(fa, [fb]); nav.wantPrev = false;
      if (!isFinite(d[fb])) { out[key] = null; continue; }
      const floors = []; for (let f = fb; f >= 0 && floors.length < 200000; f = nav.lastPrev[f]) floors.push(f);
      floors.reverse();
      const pts = floors.map((f) => { const c = nav.colOf[f]; const row = Math.floor(c / nav.W), col = c % nav.W; const X = (col + 0.5) * nav.cell, Y = (row + 0.5) * nav.cell; return { X, Y, z: nav.z[f], x: X / wY, y: Y / wX }; });
      const s = simplify(pts, 4);
      // (the walked length, not the search's cost: with towns to walk round the two differ)
      let walked = 0; for (let i = 1; i < pts.length; i++) walked += Math.hypot(pts[i].X - pts[i - 1].X, pts[i].Y - pts[i - 1].Y);
      out[key] = { yards: Math.round(walked || d[fb]), wp: s.slice(1, -1).map((p) => p.x.toFixed(4) + ',' + p.y.toFixed(4) + ',' + Math.round(p.z)).join(';'), z0: Math.round(s[0].z), z1: Math.round(s[s.length - 1].z) };
    } catch (e) { out[key] = null; }
  }
  parentPort.postMessage(out);
  return;
}

async function addWaypoints(routes, opts) {
  const conv = opts.conv;
  const areaOf = Object.fromEntries(conv.map((t) => [t.ui_map_id, t.area_id]));
  const cacheFile = opts.cacheFile;
  const cache = cacheFile && fs.existsSync(cacheFile) ? JSON.parse(fs.readFileSync(cacheFile, 'utf8')) : {};
  // legs in a city whose recorded trails changed are planned again (the trails can open up new connections)
  cache.__trails = cache.__trails || {};
  for (const f of fs.readdirSync(opts.terrainDir).filter((n) => /^area[0-9]+[.]trails[.]json$/.test(n))) {
    // by content: the file is rewritten (same trails) more often than the trails change
    const area = f.match(/[0-9]+/)[0], sig = require('crypto').createHash('sha1').update(fs.readFileSync(path.join(opts.terrainDir, f))).digest('hex').slice(0, 16);
    if (cache.__trails[area] !== sig) { for (const k of Object.keys(cache)) if (k.startsWith(area + ':')) delete cache[k]; cache.__trails[area] = sig; }
  }
  // flight masters per area (where you start after flying in)
  const FM = {};
  for (const n of Object.values(opts.db.npcs)) if (n && /^(Gryphon Master|Hippogryph Master|Flight Master|Wind Rider Master|Bat Handler)$/i.test(n.sub || '')) for (const s of n.spawns || []) if (s.x >= 0) (FM[s.zone] = FM[s.zone] || []).push(s);
  const hasTerrain = (a) => fs.existsSync(path.join(opts.terrainDir, `area${a}.vox.json`));
  // the other faction's towns per zone, for the plan's faction (tools/hostile-towns.json lists what is hostile to whom):
  // a zone with one gets its walks keyed by faction - the rest stay shared by both
  const avoidOf = {};
  if (opts.faction) {
    let H = null; try { H = JSON.parse(fs.readFileSync(path.join(__dirname, 'hostile-towns.json'), 'utf8')); } catch (e) {}
    for (const t of (H && H[opts.faction]) || []) { const a = areaOf[t.m]; if (a) (avoidOf[a] = avoidOf[a] || []).push({ x: t.x, y: t.y, r: t.r }); }
  }
  const k = (a, p, q) => `${a}:${p.x.toFixed(1)},${p.y.toFixed(1)}>${q.x.toFixed(1)},${q.y.toFixed(1)}` + (avoidOf[a] ? ':' + opts.faction : '');
  const todo = {}; // area -> [[key, a, b]]
  const legs = []; // [step, key]
  for (const r of routes) {
    let prev = null;
    for (const s of r.steps) {
      if (s.k === 'fly' || s.k === 'hearth') { prev = null; continue; }
      if (!(s.m && s.x)) continue;
      if (s.unknown) continue; // a "do the work" step with no known place (route2: unknownWork): no walk to it
      const area = areaOf[s.m];
      const here = { x: s.x * 100, y: s.y * 100 };
      let from = prev && prev.area === area ? prev.p : null;
      if (!from && FM[area]) { // just arrived: from the nearest flight master in this zone
        from = FM[area].reduce((b, f) => (!b || Math.hypot(f.x - here.x, f.y - here.y) < Math.hypot(b.x - here.x, b.y - here.y) ? f : b), null);
      }
      prev = { area, p: here };
      if (!from || !hasTerrain(area) || Math.hypot(from.x - here.x, from.y - here.y) < 0.6) continue;
      const key = k(area, from, here);
      legs.push([s, key]);
      if (!(key in cache)) (todo[area] = todo[area] || new Map()).set(key, [key, { x: from.x, y: from.y }, here]);
    }
  }
  const areas = Object.keys(todo);
  const n = areas.reduce((s, a) => s + todo[a].size, 0);
  if (n) {
    const t0 = Date.now();
    let left = areas.slice().sort((a, b) => todo[b].size - todo[a].size), done = 0;
    const W = Math.max(1, opts.workers || Math.min(6, os.cpus().length - 1));
    await Promise.all(Array.from({ length: Math.min(W, left.length) }, async () => {
      while (left.length) {
        const area = left.shift();
        const pairs = [...todo[area].values()];
        const res = await new Promise((resolve) => {
          const w = new Worker(__filename, { workerData: { terrainDir: opts.terrainDir, area: +area, pairs, avoid: avoidOf[area] || null }, resourceLimits: { maxOldGenerationSizeMb: 3000 } });
          w.on('message', (m) => { resolve(m); w.terminate(); }); // done with it: don't leave the thread alive w.on('error', (e) => { console.error('waypoints area ' + area + ': ' + e.message); resolve({}); });
        });
        Object.assign(cache, res); done += pairs.length;
        if (opts.log) opts.log(`  waypoints: area ${area} ${pairs.length} legs (${done}/${n}, ${Math.round((Date.now() - t0) / 1000)}s)`);
      }
    }));
    if (cacheFile) {
      // a shared cache (every built-in plan): keep what another planner saved meanwhile
      try { const disk = JSON.parse(fs.readFileSync(cacheFile, 'utf8')); for (const [kk, v] of Object.entries(disk)) if (kk !== '__trails' && !(kk in cache) && !(disk.__trails && cache.__trails && disk.__trails[kk.split(':')[0]] !== cache.__trails[kk.split(':')[0]])) cache[kk] = v; } catch (e) {}
      fs.mkdirSync(path.dirname(cacheFile), { recursive: true });
      require('./safewrite').replaceCache(cacheFile, JSON.stringify(cache)); // shared: skipped if another planner has it open
    }
  }
  let added = 0;
  for (const [s, key] of legs) { const c = cache[key]; if (c && c.wp !== undefined && c.yards) { if (c.wp) s.wp = c.wp; s.walk = c.yards; s.z = c.z1; s.z0 = c.z0; added++; } }
  return added;
}

module.exports = { addWaypoints, simplify };
