// Build terrain + walk maps for many zones in parallel (one child process per zone, N at a time).
// usage: node build-zones.js <wowRoot> <conversion.json> <terrainDir> <areaId,...|all-ek|all-kalimdor> [parallel]
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const [root, conv, dir, list, par] = process.argv.slice(2);
const P = +(par || Math.max(1, require('os').cpus().length - 2));
const transforms = JSON.parse(fs.readFileSync(conv, 'utf8')).geometry.transforms;
let areas;
if (list === 'all-ek') areas = transforms.filter((t) => t.map_id === 0).map((t) => t.area_id);
else if (list === 'all-kalimdor') areas = transforms.filter((t) => t.map_id === 1).map((t) => t.area_id);
else areas = list.split(',').map(Number);
areas = [...new Set(areas)];
const node = process.execPath, tools = __dirname;
const run = (args) => new Promise((res) => {
  const p = spawn(node, ['--max-old-space-size=10000', ...args], { stdio: ['ignore', 'pipe', 'pipe'] });
  let out = ''; p.stdout.on('data', (d) => (out += d)); p.stderr.on('data', (d) => (out += d));
  p.on('close', (code) => res({ code, out }));
});
(async () => {
  const t0 = Date.now(); let i = 0;
  const one = async () => {
    while (i < areas.length) {
      const a = areas[i++], t = Date.now();
      const r1 = await run([path.join(tools, 'terrain.js'), root, conv, String(a), dir]);
      const r2 = r1.code ? r1 : await run([path.join(tools, 'voxnav.js'), 'build', root, dir, String(a), '2']);
      const name = (transforms.find((x) => x.area_id === a) || {}).target_name;
      console.log(`${a} ${name}: ${r2.code ? 'FAILED ' + r2.out.split('\n').slice(-3).join(' ') : 'ok'} (${((Date.now() - t) / 1000).toFixed(1)}s)`);
    }
  };
  await Promise.all(Array.from({ length: Math.min(P, areas.length) }, one));
  console.log(`${areas.length} zones in ${((Date.now() - t0) / 1000).toFixed(0)}s with ${P} parallel`);
})();
