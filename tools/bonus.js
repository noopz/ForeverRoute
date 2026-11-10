// Bonus pickups for the planner:
//  - Forever quest XP from ForeverDungeonJournal's fallback table (fills Questie's gaps for Forever-only quests)
//  - lore books from HandyNotes_ForeverBooks (locations, item IDs) minus the ones this character already collected
const fs = require('fs');
const path = require('path');
const { parseSavedVariables } = require('./luatable');

function loadForeverXp(addonsDir) {
  const xp = {};
  const f1 = path.join(addonsDir, 'ForeverDungeonJournal', 'Data', 'QuestRewards.lua');
  if (fs.existsSync(f1)) for (const m of fs.readFileSync(f1, 'utf8').matchAll(/\[(\d+)\]\s*=\s*(\d+),/g)) xp[m[1]] = +m[2];
  const f2 = path.join(addonsDir, 'ForeverDungeonJournal', 'Data', 'QuestUpdates.lua');
  if (fs.existsSync(f2)) {
    const src = fs.readFileSync(f2, 'utf8');
    // XP[79007], XP[79008], XP[79192], XP[79980] = 1750, 1750, 1950, 200
    for (const m of src.matchAll(/((?:XP\[\d+\],?\s*)+)=\s*([\d,\s]+)/g)) {
      const ids = [...m[1].matchAll(/XP\[(\d+)\]/g)].map((x) => x[1]), vals = m[2].split(',').map((v) => +v.trim()).filter((v) => !isNaN(v));
      ids.forEach((id, i) => { if (vals[i]) xp[id] = vals[i]; });
    }
  }
  return xp;
}

function loadBooks(addonsDir, charSvDir, conversionPath, faction) {
  const dir = path.join(addonsDir, 'HandyNotes_ForeverBooks');
  if (!fs.existsSync(dir)) return [];
  const conv = JSON.parse(fs.readFileSync(conversionPath, 'utf8')).geometry.transforms;
  const areaOf = {}; for (const t of conv) areaOf[t.ui_map_id] = t.area_id;
  const itemOf = {};
  for (const m of fs.readFileSync(path.join(dir, 'items.lua'), 'utf8').matchAll(/\[(\d+)\]\s*=\s*"([^"]+)"/g)) itemOf[m[2]] = +m[1];
  let collected = {};
  const sv = charSvDir && path.join(charSvDir, 'HandyNotes_ForeverBooks.lua');
  if (sv && fs.existsSync(sv)) { const t = parseSavedVariables(fs.readFileSync(sv, 'utf8')); collected = (t.HandyNotes_ForeverBooksCharDB && t.HandyNotes_ForeverBooksCharDB.collected) || {}; }
  const out = [];
  const re = /^book\("([^"]+)",\s*"([^"]+)",\s*(\d+),\s*([\d.]+),\s*([\d.]+),\s*"((?:[^"\\]|\\.)*)"(?:,\s*(nil|"(\w+)"))?(?:,\s*"(\w+)")?\)/gm;
  for (const m of fs.readFileSync(path.join(dir, 'nodes.lua'), 'utf8').matchAll(re)) {
    const [, id, title, map, x, y, desc, , fac, kind] = m;
    if (kind === 'reference') continue;
    if (collected[id]) continue;
    if (fac && faction && fac.toLowerCase() !== faction.toLowerCase()) continue;
    const zone = areaOf[+map];
    if (!zone) continue;
    out.push({ id, title, zone, x: +x, y: +y, where: desc.replace(/\\n/g, ' ').slice(0, 160), item: itemOf[id] });
  }
  return out;
}
module.exports = { loadForeverXp, loadBooks };
if (require.main === module) {
  const a = path.join(require('fs').realpathSync(path.join(__dirname, '..')), '..', 'Interface', 'AddOns'); // the game's AddOns folder, next to this repo
  const xp = loadForeverXp(a); console.log('forever xp entries', Object.keys(xp).length, 'sleeping bag', xp[79008], xp[79976]);
  const b = loadBooks(a, process.argv[2], process.argv[3], 'Alliance'); console.log('books left', b.length); console.log(b.slice(0, 6).map((x) => `${x.title} @ ${x.zone} ${x.x},${x.y} item ${x.item}`).join('\n'));
}
