// Vendors by zone from QuestieDB subtitles, for the addon's errand reminders: where to sell, and where to repair.
// usage: node vendors.js <db.json> <conversion.json> <out.lua> [A|H]
const fs = require('fs');
const [dbPath, convPath, out, side = 'A'] = process.argv.slice(2);
const db = JSON.parse(fs.readFileSync(dbPath, 'utf8'));
const conv = JSON.parse(fs.readFileSync(convPath, 'utf8')).geometry.transforms;
const ui = Object.fromEntries(conv.map((t) => [t.area_id, t.ui_map_id]));
const REPAIR = /^(Armorer|Armorer & Shieldcrafter|Weaponsmith|Blacksmith|Journeyman Blacksmith|Weapon Merchant|Blade Merchant|Shield Merchant|Gunsmith|(Leather|Mail|Cloth|Light|Heavy|Cloth & Leather) Armor Merchant)$/i;
const SELL = /^(General Goods|General Goods Vendor|General Supplies|Trade Supplies|Trade Goods|Food & Drink|Food & Drink Vendor|Food & Drink Merchant|Innkeeper|Reagent Vendor|Tailoring Supplies|Clothier)$/i;
const by = {};
for (const n of Object.values(db.npcs)) {
  if (!n || !n.sub || !(n.friendly === side || n.friendly === 'AH')) continue;
  const repair = REPAIR.test(n.sub), sell = repair || SELL.test(n.sub);
  if (!sell) continue;
  for (const s of n.spawns || []) { const m = ui[s.zone]; if (!m || s.x < 0) continue; (by[m] = by[m] || []).push([s.x / 100, s.y / 100, n.name, n.sub, repair]); }
}
const L = ['-- Generated from QuestieDB by vendors.js. Vendors by uiMapID: { x, y, name, title, canRepair }.', 'local _, ns = ...', 'ns.VENDORS = {'];
for (const [m, list] of Object.entries(by).sort((a, b) => a[0] - b[0])) L.push(`  [${m}] = { ${list.map(([x, y, nm, sub, r]) => `{ ${x.toFixed(4)}, ${y.toFixed(4)}, ${JSON.stringify(nm)}, ${JSON.stringify(sub)}, ${r} }`).join(', ')} },`);
L.push('}');
fs.writeFileSync(out, L.join('\n') + '\n');
console.log(Object.keys(by).length + ' zones, ' + Object.values(by).flat().length + ' vendors (' + Object.values(by).flat().filter((v) => v[4]).length + ' can repair)');
