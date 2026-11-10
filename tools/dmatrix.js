// Parallel distance tables over a zone's walk map.
// matrix(terrainDir, area, points[], {workers}) -> Promise<Float32Array n*n> (yards; Infinity = unreachable)
// One Dijkstra per point, spread over worker threads; each worker loads the walk map once.
// Results are cached on disk per zone, keyed by point, so reruns only compute new points.
const fs = require('fs');
const path = require('path');
const os = require('os');
const { Worker, isMainThread, parentPort, workerData } = require('worker_threads');

if (!isMainThread) {
  const { VoxNav } = require('./voxnav');
  const ZoneNav = require('./nav');
  const { dir, area, points } = workerData;
  const vox = fs.existsSync(path.join(dir, `area${area}.vox.json`));
  const nav = vox ? new VoxNav(dir, area) : new ZoneNav(dir, area);
  const anchors = vox ? points.map((p) => nav.anchor(p)) : null;
  parentPort.on('message', (i) => {
    if (i < 0) { process.exit(0); }
    let row;
    if (vox) {
      const d = nav.field(anchors[i], anchors); nav.cache.clear();
      row = Float32Array.from(anchors, (f) => (f < 0 ? Infinity : d[f]));
    } else row = Float32Array.from(points, (q) => nav.dist(points[i], q));
    parentPort.postMessage({ i, row });
  });
  parentPort.postMessage({ ready: true });
  return;
}

const key = (p) => `${(+p.x).toFixed(1)},${(+p.y).toFixed(1)}`;

async function matrix(dir, area, points, opts = {}) {
  const cacheFile = path.join(dir, `area${area}.dist.json`);
  let cache = {};
  try { if (fs.existsSync(cacheFile)) cache = JSON.parse(fs.readFileSync(cacheFile, 'utf8')); } catch (e) { cache = {}; } // another run mid-write: recompute
  // the walking you recorded (areaN.trails.json) can open shortcuts the building data lacks: new trails, new distances
  const tf = path.join(dir, `area${area}.trails.json`);
  // keyed on what the trails say, not when the file was written
  const trailSig = fs.existsSync(tf) ? require('crypto').createHash('sha1').update(fs.readFileSync(tf)).digest('hex').slice(0, 16) : 'none';
  if (cache.__trails !== trailSig) cache = { __trails: trailSig };
  const uniq = [...new Map(points.map((p) => [key(p), { x: +(+p.x).toFixed(1), y: +(+p.y).toFixed(1) }])).values()];
  const keys = uniq.map(key);
  const todo = keys.map((k, i) => i).filter((i) => !cache[keys[i]] || keys.some((k2) => cache[keys[i]][k2] === undefined));
  if (todo.length) {
    const n = Math.max(1, Math.min(opts.workers || os.cpus().length - 1, todo.length));
    const t0 = Date.now();
    await new Promise((resolve, reject) => {
      let next = 0, done = 0;
      const workers = [];
      for (let w = 0; w < n; w++) {
        const wk = new Worker(__filename, { workerData: { dir, area, points: uniq }, resourceLimits: { maxOldGenerationSizeMb: 4096 } });
        workers.push(wk);
        const feed = () => { if (next < todo.length) wk.postMessage(todo[next++]); else wk.postMessage(-1); };
        wk.on('message', (m) => {
          if (m.ready) return feed();
          const row = cache[keys[m.i]] = cache[keys[m.i]] || {};
          m.row.forEach((d, j) => { row[keys[j]] = isFinite(d) ? Math.round(d) : -1; });
          if (++done === todo.length) resolve();
          feed();
        });
        wk.on('error', reject);
      }
    });
    // merge with whatever another run saved meanwhile, then write atomically
    try { const disk = JSON.parse(fs.readFileSync(cacheFile, 'utf8')); if (disk.__trails === trailSig) for (const [k, v] of Object.entries(disk)) if (k !== '__trails') cache[k] = Object.assign({}, v, cache[k]); } catch (e) {}
    // a shared cache: if another planner has it open the write is skipped (tools/safewrite.js); this run has it in memory
    if (!require('./safewrite').replaceCache(cacheFile, JSON.stringify(cache)) && !opts.quiet) console.error(`zone ${area}: distance cache not saved (another planner had it open)`);
    if (!opts.quiet) console.error(`zone ${area}: ${todo.length} paths on ${n} threads in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  }
  // lookup closure: dist between any two of the given points (symmetric fallback)
  return (a, b) => {
    const ra = cache[key(a)], rb = cache[key(b)];
    let d = ra && ra[key(b)];
    if (d === undefined || d < 0) { const e = rb && rb[key(a)]; if (e !== undefined && e >= 0) d = e; }
    return d === undefined ? undefined : d < 0 ? Infinity : d;
  };
}
module.exports = { matrix, key };
