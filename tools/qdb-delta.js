// What a QuestieDB update changed, between two built quest databases: quests added, removed and changed (which
// fields), NPCs and objects that moved or changed, and the zones those touch - the zones whose legs get re-planned.
// usage: node tools/qdb-delta.js <old db.json> <new db.json> [report.md]
const fs = require('fs');
const [oldF, newF, mdOut] = process.argv.slice(2);
const A = JSON.parse(fs.readFileSync(oldF, 'utf8')), B = JSON.parse(fs.readFileSync(newF, 'utf8'));
let zoneName = {}; try { zoneName = Object.fromEntries(JSON.parse(fs.readFileSync(require('path').join(__dirname, '..', 'qdb', 'conversion.json'), 'utf8')).geometry.transforms.map((t) => [t.area_id, t.target_name])); } catch (e) {}
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const zonesOfQuest = (q) => new Set([...(q.starters || []), ...(q.finishers || [])].flatMap((s) => (s.spawns || []).map((p) => p.zone)));
const zonesOfEnt = (e) => new Set((e && e.spawns || []).map((p) => p.zone));
const touched = new Map(); // zone -> count
const touch = (zs) => { for (const z of zs) if (z > 0) touched.set(z, (touched.get(z) || 0) + 1); };
const res = { added: [], removed: [], changed: [], npcs: 0, objects: 0 };
for (const [id, q] of Object.entries(B.quests)) {
  const o = A.quests[id];
  if (!o) { res.added.push(q); touch(zonesOfQuest(q)); continue; }
  if (same(o, q)) continue;
  const fields = Object.keys({ ...o, ...q }).filter((k) => !same(o[k], q[k]));
  res.changed.push({ q, fields, xp: fields.includes('xp') ? [o.xp, q.xp] : null });
  touch(new Set([...zonesOfQuest(o), ...zonesOfQuest(q)]));
}
for (const [id, o] of Object.entries(A.quests)) if (!B.quests[id]) { res.removed.push(o); touch(zonesOfQuest(o)); }
for (const kind of ['npcs', 'objects']) for (const id of new Set([...Object.keys(A[kind]), ...Object.keys(B[kind])])) {
  const o = A[kind][id], n = B[kind][id]; if (same(o, n)) continue;
  res[kind]++; touch(new Set([...zonesOfEnt(o), ...zonesOfEnt(n)]));
}
const byField = {}; for (const c of res.changed) for (const f of c.fields) byField[f] = (byField[f] || 0) + 1;
const zones = [...touched.entries()].sort((a, b) => b[1] - a[1]);
const lines = [
  `# QuestieDB update: what changed`, '',
  `- quests: ${res.added.length} added, ${res.removed.length} removed, ${res.changed.length} changed (${Object.entries(byField).sort((a, b) => b[1] - a[1]).map(([f, n]) => `${f} ${n}`).join(', ') || '-'})`,
  `- NPCs changed: ${res.npcs}; objects changed: ${res.objects}`,
  `- zones touched: ${zones.length} - their legs are re-planned, and every leg after a changed one in a plan`,
  '', '## Zones', '', ...zones.slice(0, 40).map(([z, n]) => `- ${zoneName[z] || 'zone ' + z}: ${n}`),
  '', '## Quests added', '', ...res.added.slice(0, 60).map((q) => `- ${q.id} ${q.name} [${q.level}]`),
  '', '## Quests removed', '', ...res.removed.slice(0, 60).map((q) => `- ${q.id} ${q.name} [${q.level}]`),
  '', '## Quests changed', '', ...res.changed.slice(0, 120).map((c) => `- ${c.q.id} ${c.q.name} [${c.q.level}]: ${c.fields.join(', ')}${c.xp ? ` (xp ${c.xp[0]} -> ${c.xp[1]})` : ''}`),
];
if (mdOut) fs.writeFileSync(mdOut, lines.join('\n') + '\n');
console.log(lines.slice(2, 5).join('\n'));
