// The planner works for other characters too: generates settings for a few (tools/make-character.js), plans each
// (fast pass, a few zones) and runs the route audit with that character's class and race on every path. Takes several
// minutes (one plan per character). Alliance only until the Horde travel facts are in.
// usage: node tools/test-characters.js [scratchDir]
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const ROOT = path.join(__dirname, '..');
const dir = process.argv[2] || fs.mkdtempSync(path.join(os.tmpdir(), 'fr-chars-'));
fs.mkdirSync(dir, { recursive: true });

const CHARS = [
  { name: 'TestDruid', race: 'nightelf', class: 'druid', level: 12, zone: 148 },   // Darkshore
  { name: 'TestPaladin', race: 'human', class: 'paladin', level: 15, zone: 40 },   // Westfall
  { name: 'TestHunter', race: 'dwarf', class: 'hunter', level: 20, zone: 11 },     // Wetlands
  { name: 'TestMage', race: 'gnome', class: 'mage', level: 10, zone: 38 },          // Loch Modan
];
let fails = 0;
for (const c of CHARS) {
  const work = path.join(dir, c.name), cfgFile = path.join(work, 'campaign.json');
  fs.mkdirSync(work, { recursive: true });
  execFileSync(process.execPath, [path.join(__dirname, 'make-character.js'), '--name', c.name, '--race', c.race, '--class', c.class, '--level', String(c.level), '--zone', String(c.zone), '--out', cfgFile], { cwd: ROOT, stdio: 'ignore' });
  const cfg = JSON.parse(fs.readFileSync(cfgFile, 'utf8'));
  Object.assign(cfg, { targetLevel: c.level + 6, maxLegs: 3, routesOut: path.join(work, 'Route.lua'), dungeons: 'none', learnedFile: false });
  fs.writeFileSync(cfgFile, JSON.stringify(cfg));
  let ok = true, msg = '';
  try {
    execFileSync(process.execPath, ['--max-old-space-size=8000', path.join(__dirname, 'paths.js'), cfgFile, '3', '0', '--work', work], { cwd: ROOT, stdio: 'ignore', timeout: 15 * 60000 });
    const text = fs.readFileSync(path.join(work, 'Route.lua'), 'utf8');
    const ids = [...text.matchAll(/^ {4}id = "((?:path|zone):[^"]+)",/gm)].map((m) => m[1]);
    if (!ids.length) { ok = false; msg = 'no paths'; }
    for (const id of ids) {
      const out = execFileSync(process.execPath, [path.join(__dirname, 'lint-route.js'), path.join(work, 'Route.lua'), path.join(ROOT, 'qdb', 'db.json'), id, c.class + ',' + c.race], { encoding: 'utf8' });
      const lines = out.trim().split('\n');
      if (/^0 steps/.test(lines[0])) { ok = false; msg += ` ${id}: empty;`; }
      else if (lines[1] !== 'no issues found') { ok = false; msg += ` ${id}: ${lines.slice(1, 3).join(' / ')};`; }
    }
    if (ok) msg = `${ids.length} routes, all pass`;
  } catch (e) { ok = false; msg = 'planner failed: ' + String(e.message).split('\n')[0]; }
  if (!ok) fails++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${c.name} (${c.race} ${c.class} ${c.level}): ${msg}`);
}
console.log(fails ? fails + ' failed' : 'all passed');
process.exit(fails ? 1 : 0);
