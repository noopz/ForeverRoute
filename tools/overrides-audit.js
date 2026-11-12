// Are our Forever corrections (tools/forever-overrides.json) still right? Run on every plan rebuild
// (tools/rebuild-plans.sh), not only when QuestieDB releases. Two ways a correction goes stale:
//   1. QuestieDB caught up (our fix is now redundant) or changed the same field differently (look again):
//      the data is rebuilt WITHOUT our corrections from the release we're on, and tools/overrides-check.js compares.
//      --prune removes the redundant ones (same value upstream: removing them changes nothing).
//   2. Forever itself changed: a hotfix or patch note (reports/patch-watch.md, tools/patch-watch.js) names a quest we
//      correct - e.g. a bug we worked around is fixed, or a level we corrected moved again. Those are listed to check.
// Exit 3 when anything needs a person to look (a changed-differently field, or a correction a patch note mentions).
// usage: node tools/overrides-audit.js [--prune]
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const ROOT = path.join(__dirname, '..');
const QDB = path.join(ROOT, 'qdb');
const OV = path.join(__dirname, 'forever-overrides.json');
const prune = process.argv.includes('--prune');

// the release we're on, unpacked by tools/update-questiedb.js
const version = JSON.parse(fs.readFileSync(path.join(QDB, 'questiedb-version.json'), 'utf8')).version;
const out = path.join(QDB, 'questiedb', version, 'files');
const find = (rel) => { for (const base of [path.join(out, 'QuestieDB'), out]) { const p = path.join(base, rel); if (fs.existsSync(p)) return p; } return null; };
const toc = find('QuestieDB_Forever.toc');
if (!toc) { console.log(`overrides audit: QuestieDB ${version} isn't unpacked in qdb/questiedb (run tools/update-questiedb.js --force)`); process.exit(1); }
const sup = path.join(path.dirname(toc), 'support', 'Forever');
const xp = ['xpDB-classic.lua', 'xpDB-traces.lua'].map((f) => path.join(sup, 'QuestXP', f)).filter((f) => fs.existsSync(f));
const drops = ['classicItemDrops.lua', 'itemDropCorrections.lua'].map((f) => path.join(sup, 'DropTables', f)).filter((f) => fs.existsSync(f));
const raw = path.join(QDB, 'db.audit-raw.json');
const report = path.join(ROOT, 'reports', 'overrides-check.md');

// 1. against QuestieDB as it is
execFileSync(process.execPath, ['--max-old-space-size=8000', path.join(__dirname, 'build-db.js'), path.join(QDB, 'json'), xp.join(','), raw, drops.join(',')],
  { cwd: ROOT, env: { ...process.env, FR_NO_OVERRIDES: '1' }, stdio: 'ignore' });
const check = execFileSync(process.execPath, [path.join(__dirname, 'overrides-check.js'), raw, report], { cwd: ROOT, encoding: 'utf8' }).trim();
const rawDb = JSON.parse(fs.readFileSync(raw, 'utf8'));
fs.rmSync(raw, { force: true });
const md = fs.readFileSync(report, 'utf8');
const section = (title) => { const part = md.split(/^## /m).find((x) => x.startsWith(title)); return part ? part.split(/\r?\n/).filter((l) => l.startsWith("- ")) : []; };
const upstream = section('Now upstream'), moved = section('Upstream changed differently');
console.log(`overrides vs QuestieDB ${version}: ${upstream.length} now upstream, ${moved.length} changed differently (${path.relative(ROOT, report)})`);
for (const l of moved) console.log('  LOOK AGAIN ' + l.slice(2));

// --prune: drop the fields QuestieDB now has with our value
const ov = JSON.parse(fs.readFileSync(OV, 'utf8'));
if (prune && upstream.length) {
  let n = 0;
  for (const l of upstream) {
    const m = /^- (\d+) .*? - (\w+): ours/.exec(l);
    if (!m) continue;
    const q = ov.quests[m[1]];
    if (!q || !(m[2] in q)) continue;
    delete q[m[2]];
    if (q['_why' + m[2][0].toUpperCase() + m[2].slice(1)]) delete q['_why' + m[2][0].toUpperCase() + m[2].slice(1)];
    if (!Object.keys(q).some((k) => !k.startsWith('_'))) delete ov.quests[m[1]];
    n++; console.log('  pruned ' + l.slice(2));
  }
  fs.writeFileSync(OV, JSON.stringify(ov, null, 2) + '\n');
  console.log(`  ${n} redundant correction(s) removed from tools/forever-overrides.json (rebuild the data: node tools/apply-overrides.js)`);
} else if (upstream.length) for (const l of upstream) console.log('  REDUNDANT ' + l.slice(2) + '   (--prune removes it)');

// 2. against Forever's own notes: a patch note naming a quest we correct
let hits = [];
const reviewed = (() => { try { return JSON.parse(fs.readFileSync(path.join(__dirname, "overrides-reviewed.json"), "utf8")).notes || {}; } catch (e) { return {}; } })();
const pw = path.join(ROOT, 'reports', 'patch-watch.md');
if (fs.existsSync(pw)) {
  const notes = fs.readFileSync(pw, 'utf8');
  for (const id of Object.keys(ov.quests || {})) {
    const name = rawDb.quests[id] && rawDb.quests[id].name;
    if (!name || name.length < 6) continue;
    const re = new RegExp('[^\\n]*' + name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '[^\\n]*', 'i');
    const m = re.exec(notes);
    const seen = m && reviewed[id] && m[0].includes(reviewed[id].note);
    if (m && !seen) hits.push(`${id} ${name}: a patch note mentions it - is our correction still right? "${m[0].replace(/^[\s>*_-]+/, '').slice(0, 140)}"`);
  }
}
console.log(`overrides vs Forever's patch notes: ${hits.length} correction(s) a note mentions`);
for (const h of hits) console.log('  CHECK ' + h);
process.exitCode = (moved.length || hits.length) ? 3 : 0;
