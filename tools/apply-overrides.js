// Apply tools/forever-overrides.json (quest facts Forever changed) to a quest database object, or to qdb/db.json.
// build-db.js calls apply() on every build; run this file directly to patch an existing db.json in place.
// usage: node tools/apply-overrides.js [db.json]
const fs = require('fs');
const path = require('path');
const OVERRIDES = path.join(__dirname, 'forever-overrides.json');

function apply(db) {
  const o = JSON.parse(fs.readFileSync(OVERRIDES, 'utf8'));
  const done = [];
  for (const [id, fields] of Object.entries(o.quests || {})) {
    const q = db.quests[id];
    if (!q) continue;
    for (const [k, v] of Object.entries(fields)) if (!k.startsWith('_') && JSON.stringify(q[k]) !== JSON.stringify(v)) { done.push(`${id} ${q.name}: ${k} ${q[k]} -> ${v}`); q[k] = v; }
  }
  return done;
}
module.exports = { apply };

if (require.main === module) {
  const f = process.argv[2] || path.join(__dirname, '..', 'qdb', 'db.json');
  const db = JSON.parse(fs.readFileSync(f, 'utf8'));
  const done = apply(db);
  if (done.length) { const tmp = f + '.tmp'; fs.writeFileSync(tmp, JSON.stringify(db)); fs.renameSync(tmp, f); }
  console.log(done.length ? done.join('\n') : 'already applied');
}
