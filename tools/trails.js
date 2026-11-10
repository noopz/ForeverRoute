// Import city walking trails recorded by the addon (ForeverRouteDB.trails in the account SavedVariables) into
// terrain/area<N>.trails.json for the pathfinder. Points are map % (x, y) plus height when the game gave one.
// usage: node trails.js <account ForeverRoute.lua> <conversion.json> <terrainDir>
const fs = require('fs');
const path = require('path');
const { parseSavedVariables } = require('./luatable');

function importTrails(svFile, convPath, terrainDir) {
  if (!fs.existsSync(svFile)) return {};
  const sv = parseSavedVariables(fs.readFileSync(svFile, 'utf8'));
  const db = sv.ForeverRouteDB || {};
  const trails = (db.trailData && typeof db.trailData === 'object') ? db.trailData : (typeof db.trails === 'object' ? db.trails : {});
  const conv = JSON.parse(fs.readFileSync(convPath, 'utf8')).geometry.transforms;
  const areaOf = Object.fromEntries(conv.map((t) => [t.ui_map_id, t.area_id]));
  const out = {};
  for (const [m, list] of Object.entries(trails)) {
    const area = areaOf[+m]; if (!area) continue;
    const segs = (Array.isArray(list) ? list : Object.values(list)).map((s) => String(s).split(';').map((p) => {
      const [x, y, z] = p.split(',').map(Number);
      return [x * 100, y * 100, Number.isFinite(z) ? z : null];
    }).filter(([x, y]) => Number.isFinite(x) && Number.isFinite(y))).filter((s) => s.length >= 2);
    if (!segs.length) continue;
    // only when they changed: zone distance caches are keyed on these files, and rewriting the same trails on every
    // replan threw the city and Duskwood distances away each time (most of a replan's time)
    const f = path.join(terrainDir, `area${area}.trails.json`), text = JSON.stringify(segs);
    let old = null; try { old = fs.readFileSync(f, 'utf8'); } catch (e) {}
    if (old !== text) fs.writeFileSync(f, text);
    out[area] = segs.reduce((n, s) => n + s.length, 0);
  }
  return out;
}
module.exports = { importTrails };
if (require.main === module) {
  const [sv, conv, dir] = process.argv.slice(2);
  const r = importTrails(sv, conv, dir);
  console.log(Object.keys(r).length ? 'trails imported: ' + Object.entries(r).map(([a, n]) => `area ${a}: ${n} points`).join(', ') : 'no trails recorded yet');
}
