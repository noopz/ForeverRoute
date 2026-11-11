// Flight masters per zone from QuestieDB (by subtitle), keyed by uiMapID, for the addon's travel arrow and the planner
// (tools/travel.js). Both factions: ns.FLIGHT_BY.Alliance / .Horde (neutral ones in both); Core.lua's ns.UseFaction()
// sets ns.FLIGHT to yours.
// usage: node flightmasters.js <db.json> <conversion.json> <out.lua>
const fs = require('fs');
const [dbPath, convPath, out] = process.argv.slice(2);
const db = JSON.parse(fs.readFileSync(dbPath, 'utf8'));
const conv = JSON.parse(fs.readFileSync(convPath, 'utf8')).geometry.transforms;
const ui = Object.fromEntries(conv.map((t) => [t.area_id, t.ui_map_id]));
const L = ['-- Generated from QuestieDB by flightmasters.js. Flight masters by faction, then uiMapID: { x, y, name } (0-1 map coords).', 'local _, ns = ...', 'ns.FLIGHT_BY = {'];
let report = [];
for (const [side, name] of [['A', 'Alliance'], ['H', 'Horde']]) {
  const byMap = {};
  for (const n of Object.values(db.npcs)) {
    if (!n || !/^(Gryphon Master|Hippogryph Master|Flight Master|Wind Rider Master|Bat Handler)$/i.test(n.sub || '')) continue;
    if (!(n.friendly === side || n.friendly === 'AH')) continue;
    for (const s of n.spawns || []) { const m = ui[s.zone]; if (!m || s.x < 0) continue; (byMap[m] = byMap[m] || []).push([s.x / 100, s.y / 100, n.name]); }
  }
  L.push(`  ${name} = {`);
  for (const [m, list] of Object.entries(byMap).sort((a, b) => a[0] - b[0])) L.push(`    [${m}] = { ${list.map(([x, y, nm]) => `{ ${x.toFixed(4)}, ${y.toFixed(4)}, ${JSON.stringify(nm)} }`).join(', ')} },`);
  L.push('  },');
  report.push(`${name}: ${Object.keys(byMap).length} zones, ${Object.values(byMap).flat().length} flight masters`);
}
L.push('}', 'ns.FLIGHT = ns.FLIGHT_BY.Alliance -- until ns.UseFaction (Core.lua) knows yours');
fs.writeFileSync(out, L.join('\n') + '\n');
console.log(report.join('; '));
