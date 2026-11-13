// Zone routes ("bored of this zone? go there instead", docs/research/shared-trunk.md): at every zone change of a faction
// trunk (tools/tree.js), each runner-up zone within share (60%) of the pick's xp/h gets a leg of its own, planned from the
// trunk's state there - one per zone and 3-level band. Every race x class plan carries them (tools/tree-assemble.js ->
// paths.js extraZoneRoutes): the addon's path picker offers the ones that fit your level, and "Back to my path" returns
// to the trunk, which skips what the zone route did.
// usage: node tools/zone-routes.js <tree dir> [--share 0.6]   (tree.js runs it after the trunk)
const fs = require('fs'), path = require('path');
const { spawn } = require('child_process');
// a planner run, waited for without blocking the other workers
const runAsync = (args) => new Promise((res) => { const p = spawn(process.execPath, args, { cwd: ROOT, stdio: 'ignore' }); p.on('close', (code) => res({ status: code })); });
const ROOT = path.join(__dirname, '..');
const readJson = (f) => JSON.parse(fs.readFileSync(f, 'utf8'));
async function build(out, o = {}) {
  const trunkDir = path.join(out, 'trunk');
  const cfg = readJson(path.join(trunkDir, 'campaign.json'));
  const trunkPath = readJson(path.join(trunkDir, 'path-0.json'));
  const share = o.share ?? 0.6;
  const want = new Map();
  for (const c of trunkPath.choices || []) {
    const pick = (c.options || []).find((x) => x.z === c.chosen);
    if (!pick || !c.beforeFile) continue;
    for (const x of c.options) {
      if (x.z === c.chosen || x.xph < share * pick.xph) continue;
      const key = x.z + ':' + Math.floor(c.level / 3);
      if (!want.has(key)) want.set(key, { z: x.z, name: x.name, level: c.level, beforeFile: c.beforeFile, xph: x.xph });
    }
  }
  const dir = path.join(out, 'zone-routes');
  fs.mkdirSync(dir, { recursive: true });
  const jobs = [...want.values()];
  console.log(`zone routes: ${jobs.length} to plan`);
  const done = [];
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(o.parallel || 3, jobs.length) }, async () => {
    while (i < jobs.length) {
      const j = jobs[i++];
      const tag = `zone-${j.z}-${j.level}`;
      const c = { ...cfg, startStateFile: j.beforeFile, firstZone: j.z, forceLegs: [j.z], maxLegs: 1, parallel: 2, workDir: path.join(dir, 'work-' + tag), routeOut: path.join(dir, tag + '.lua'), pathOut: path.join(dir, tag + '.json') };
      delete c.routesOut;
      const f = path.join(dir, tag + '-cfg.json'); fs.writeFileSync(f, JSON.stringify(c));
      const r = await runAsync(['--max-old-space-size=4000', path.join(__dirname, 'campaign.js'), f]);
      const p = fs.existsSync(c.pathOut) ? readJson(c.pathOut) : null;
      if (r.status || !p || !(p.steps || []).some((s) => s.k === 'turnin')) { console.log(`  ${j.name} at ${j.level}: nothing (${r.status ? 'failed' : 'no hand-ins'})`); continue; }
      done.push({ z: j.z, name: j.name, level: j.level, endLevel: p.endLevel, file: path.relative(out, c.pathOut), turnins: p.steps.filter((s) => s.k === 'turnin').length, xph: j.xph });
    }
  }));
  done.sort((a, b) => a.level - b.level);
  fs.writeFileSync(path.join(dir, 'index.json'), JSON.stringify(done, null, 1));
  console.log(`zone routes: ${done.length} written (${done.map((d) => d.name + '@' + d.level).join(', ')})`);
  return done;
}
module.exports = { build };
if (require.main === module) {
  const a = process.argv.slice(2), i = a.indexOf('--share');
  build(path.resolve(a[0]), { share: i >= 0 ? +a[i + 1] : 0.6 }).then(() => process.exit(0));
}
