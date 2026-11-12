// The built-in plans as two load-on-demand addons, one per faction (ForeverRoute_Plans_Alliance / _Horde), instead of
// one addon per race and class: 51 entries filled the game's addon list. Each plan's Lua (addon/ForeverRoute_Starter_*/
// Plan.lua, written by tools/starter.js) goes in as a string; the addon turns only yours into code (Core.lua
// LoadMyPlan) and drops the rest, so memory ends up as before - just your plan.
// The per-plan folders stay the build's output in the repo; tools/package.sh and tools/install.sh call this.
// usage: node tools/bundle-plans.js <out dir>   (writes <out>/ForeverRoute_Plans_Alliance and _Horde)
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..');
const out = process.argv[2];
if (!out) { console.log('usage: node tools/bundle-plans.js <out dir>'); process.exit(2); }
const HORDE = new Set(['orc', 'undead', 'tauren', 'troll', 'skybornehorde']);
const mainToc = fs.readFileSync(path.join(ROOT, 'addon', 'ForeverRoute', 'ForeverRoute.toc'), 'utf8');
const iface = (/## Interface: (\S+)/.exec(mainToc) || [, '16001'])[1];
const sides = { Alliance: [], Horde: [] };
for (const d of fs.readdirSync(path.join(ROOT, 'addon')).sort()) {
  const m = /^ForeverRoute_Starter_([a-z]+)_([a-z]+)$/.exec(d);
  if (!m) continue;
  const file = path.join(ROOT, 'addon', d, 'Plan.lua');
  if (!fs.existsSync(file)) continue;
  const key = `${m[1]}-${m[2]}`;
  sides[HORDE.has(m[1]) ? 'Horde' : 'Alliance'].push({ key, src: fs.readFileSync(file, 'utf8') });
}
// a long bracket that the text never closes by accident
const longString = (s) => { let n = 1; while (s.includes(']' + '='.repeat(n) + ']')) n++; const eq = '='.repeat(n); return `[${eq}[\n${s}]${eq}]`; };
for (const [side, plans] of Object.entries(sides)) {
  if (!plans.length) continue;
  const name = `ForeverRoute_Plans_${side}`;
  const dir = path.join(out, name);
  fs.mkdirSync(dir, { recursive: true });
  const stamps = [...new Set(plans.map((p) => (/-- (plans \d{4}-\d\d-\d\d[^\n]*)/.exec(p.src) || [])[1]).filter(Boolean))];
  fs.writeFileSync(path.join(dir, name + '.toc'), [
    '## Interface: ' + iface,
    `## Title: Forever Route - ${side} plans`,
    `## Notes: The built-in plans for every ${side} race and class. Loaded by Forever Route only for a character with no plan of its own; only that character's plan is kept.`,
    '## Dependencies: ForeverRoute',
    '## Group: ForeverRoute',
    '## LoadOnDemand: 1',
    '## Version: ' + (stamps[0] ? stamps[0].split(' · ')[0] : 'plans'),
    '', 'Plans.lua', ''].join('\n'));
  const L = [`-- The built-in ${side} plans (tools/bundle-plans.js from addon/ForeverRoute_Starter_*): each as text, made into code`,
    '-- only for your race and class (Core.lua LoadMyPlan). Regenerate rather than edit.',
    'ForeverRoutePlanSources = ForeverRoutePlanSources or {}'];
  for (const p of plans) L.push(`ForeverRoutePlanSources[${JSON.stringify(p.key)}] = ${longString(p.src)}`);
  fs.writeFileSync(path.join(dir, 'Plans.lua'), L.join('\n') + '\n');
  // read back: every plan comes out exactly as it went in (the long brackets hold)
  const back = fs.readFileSync(path.join(dir, "Plans.lua"), "utf8");
  for (const p of plans) {
    const head = `ForeverRoutePlanSources[${JSON.stringify(p.key)}] = [`;
    const at = back.indexOf(head); if (at < 0) throw new Error("bundle: " + p.key + " missing");
    let k = at + head.length, eq = 0; while (back[k] === "=") { eq++; k++; }
    const open = k + 2, close = back.indexOf("]" + "=".repeat(eq) + "]", open);
    if (back.slice(open, close) !== p.src) throw new Error("bundle: " + p.key + " does not read back as written");
  }
  console.log(`${name}: ${plans.length} plans, ${(fs.statSync(path.join(dir, 'Plans.lua')).size / 1e6).toFixed(1)} MB`);
}
