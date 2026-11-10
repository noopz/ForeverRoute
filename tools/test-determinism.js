// The same save must give the same plan: plans twice at the same time (sharing the CPU, which must not matter), with
// no leg cache, and compares the two Route.lua files apart from their time stamps. Takes a few minutes.
// usage: node tools/test-determinism.js <campaign.json> [scratchDir]
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const [cfgFile, scratch0] = process.argv.slice(2);
if (!cfgFile) { console.log('usage: node tools/test-determinism.js <campaign.json> [scratchDir]'); process.exit(2); }
const scratch = scratch0 || fs.mkdtempSync(path.join(os.tmpdir(), 'fr-det-'));
const cfg = JSON.parse(fs.readFileSync(cfgFile, 'utf8'));
const runs = ['A', 'B'].map((k) => {
  const dir = path.join(scratch, k); fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'campaign.json'), JSON.stringify({ ...cfg, routesOut: path.join(dir, 'Route.lua'), noCache: true }));
  return new Promise((res) => {
    const p = spawn(process.execPath, ['--max-old-space-size=8000', path.join(__dirname, 'paths.js'), path.join(dir, 'campaign.json'), '3', '0', '--work', dir], { cwd: path.join(__dirname, '..'), stdio: 'ignore' });
    p.on('close', (code) => res({ dir, code }));
  });
});
Promise.all(runs).then((rs) => {
  if (rs.some((r) => r.code)) { console.log('a planner run failed: ' + rs.map((r) => r.code).join(', ')); process.exit(1); }
  // time stamps and generated ids are the only things allowed to differ
  const norm = (f) => fs.readFileSync(f, 'utf8').split('\n').slice(1).join('\n').replace(/(generated|fromSave) = \d+/g, '').replace(/id = "[^"]*@\d+"/g, '');
  const [a, b] = rs.map((r) => norm(path.join(r.dir, 'Route.lua')));
  if (a === b) { console.log(`all passed (two plans, ${a.split('\n').length} lines, identical)`); process.exit(0); }
  const la = a.split('\n'), lb = b.split('\n');
  const i = la.findIndex((l, k) => l !== lb[k]);
  console.log(`FAIL the plans differ first at line ${i + 2}:\n  ${la[i]}\n  ${lb[i]}`);
  process.exit(1);
});
