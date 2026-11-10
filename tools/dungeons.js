// Dungeon list from QuestieDB's Forever support data: areaId -> { name, alt: [areaIds], parent, entrance: {zone,x,y} }
const fs = require('fs');
function loadDungeons(path) {
  const src = fs.readFileSync(path, 'utf8');
  const out = {};
  const re = /\[(\d+)\] = \{"([^"]+)",(\{[\d,]+\}|nil),(\d+),\{\{(\d+), ([\d.]+), ([\d.]+)\}/g;
  for (const m of src.matchAll(re)) {
    out[m[1]] = { id: +m[1], name: m[2], alt: m[3] === 'nil' ? [] : m[3].slice(1, -1).split(',').map(Number), parent: +m[4], entrance: { zone: +m[5], x: +m[6], y: +m[7] } };
  }
  // later overrides: dungeons[1581][4] = {{40, 42.6, 71.8}}
  for (const m of src.matchAll(/dungeons\[(\d+)\]\[4\] = \{\{(\d+), ([\d.]+), ([\d.]+)\}/g)) if (out[m[1]]) out[m[1]].entrance = { zone: +m[2], x: +m[3], y: +m[4] };
  const byArea = {};
  for (const d of Object.values(out)) { byArea[d.id] = d; for (const a of d.alt) byArea[a] = d; }
  return { list: out, byArea };
}
module.exports = { loadDungeons };
if (require.main === module) { const d = loadDungeons(process.argv[2]); console.log(Object.values(d.list).map((x) => `${x.id} ${x.name} @ ${x.entrance.zone} ${x.entrance.x},${x.entrance.y}`).join('\n')); }
