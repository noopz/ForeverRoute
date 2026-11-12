// Our fixes to the quest data (tools/forever-overrides.json) against what QuestieDB says now. Each overridden field is:
//   now upstream     QuestieDB has the same value: our fix is redundant - remove it
//   upstream moved   QuestieDB's value changed since the last update, to something other than ours: look again
//   still needed     QuestieDB still has the old value
// The upstream values are remembered per update (qdb/overrides-baseline.json) to see what moved.
// usage: node tools/overrides-check.js <db built without overrides> [report.md]
const fs = require('fs');
const path = require('path');
const [rawF, mdOut] = process.argv.slice(2);
const ROOT = path.join(__dirname, '..');
const raw = JSON.parse(fs.readFileSync(rawF, 'utf8')).quests;
const ov = JSON.parse(fs.readFileSync(path.join(__dirname, 'forever-overrides.json'), 'utf8')).quests;
const baseF = path.join(ROOT, 'qdb', 'overrides-baseline.json');
const base = fs.existsSync(baseF) ? JSON.parse(fs.readFileSync(baseF, 'utf8')) : {};
// starters / finishers: ours are "npc:ID", QuestieDB's full records - compared by type and id
const ends = (v) => Array.isArray(v) ? v.map((e) => typeof e === "string" ? e : (e && e.type + ":" + e.id)).sort() : v;
const same = (a, b) => JSON.stringify(ends(a) ?? null) === JSON.stringify(ends(b) ?? null);
const out = { upstream: [], moved: [], needed: [] }, nextBase = {};
for (const [id, fields] of Object.entries(ov)) {
  const q = raw[id]; if (!q) continue;
  const why = fields._why || '';
  for (const [k, v] of Object.entries(fields)) {
    if (k.startsWith('_')) continue;
    const now = q[k], was = base[id] && base[id][k];
    (nextBase[id] = nextBase[id] || {})[k] = now ?? null;
    const row = `${id} ${q.name} - ${k}: ours ${JSON.stringify(v)}, QuestieDB ${JSON.stringify(now ?? null)}${was !== undefined && !same(was, now) ? ` (was ${JSON.stringify(was)})` : ''}`;
    if (same(now, v)) out.upstream.push(row);
    else if (was !== undefined && !same(was, now)) out.moved.push(row + (why ? ` - ours because: ${why.slice(0, 120)}` : ''));
    else out.needed.push(row);
  }
}
fs.writeFileSync(baseF, JSON.stringify(nextBase, null, 1));
const md = ['# Our quest fixes against QuestieDB', '', `- now upstream (remove ours): ${out.upstream.length}`, `- upstream changed differently (look again): ${out.moved.length}`, `- still needed: ${out.needed.length}`,
  '', '## Now upstream', '', ...out.upstream.map((r) => '- ' + r), '', '## Upstream changed differently', '', ...out.moved.map((r) => '- ' + r), '', '## Still needed', '', ...out.needed.map((r) => '- ' + r)];
if (mdOut) fs.writeFileSync(mdOut, md.join('\n') + '\n');
console.log(`our fixes: ${out.upstream.length} now upstream (remove ours), ${out.moved.length} where upstream changed differently (look again), ${out.needed.length} still needed`);
