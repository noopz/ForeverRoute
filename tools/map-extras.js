// Maps Forever added without world bounds in the conversion (Zephras Isle, the Skyborne start): tools/map-extras.json
// holds them, estimated until the game says otherwise. With account saves given, the bounds the addon recorded at login
// (ForeverRouteDB.mapBounds, Core.lua RecordMapBounds) replace the estimates in map-extras.json. Then every extra map is
// merged into qdb/conversion.json (idempotent: marked extra = true, replaced on each run), so every tool that reads the
// conversion knows the map.
// usage: node tools/map-extras.js [account ForeverRoute.lua ...]
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..');
const EXTRAS = path.join(__dirname, 'map-extras.json');
const CONV = path.join(ROOT, 'qdb', 'conversion.json');
const ex = JSON.parse(fs.readFileSync(EXTRAS, 'utf8'));
let learned = 0;
for (const f of process.argv.slice(2)) {
  if (!fs.existsSync(f)) continue;
  let db; try { db = (require('./luatable').parseSavedVariables(fs.readFileSync(f, 'utf8')).ForeverRouteDB || {}).mapBounds; } catch (e) { continue; }
  for (const [id, b] of Object.entries(db || {})) {
    const m = ex.maps.find((x) => x.ui_map_id === +id);
    if (!m || !['left', 'right', 'top', 'bottom'].every((k) => typeof b[k] === 'number') || b.left === b.right || b.top === b.bottom) continue;
    const nb = { left: b.left, right: b.right, top: b.top, bottom: b.bottom };
    if (!m.estimated && JSON.stringify(m.target_bounds) === JSON.stringify(nb) && m.map_id === b.inst) continue;
    Object.assign(m, { target_bounds: nb, map_id: typeof b.inst === 'number' ? b.inst : m.map_id, estimated: false, measured: 'in game, ' + path.basename(path.dirname(path.dirname(f))) });
    learned++;
  }
}
if (learned) fs.writeFileSync(EXTRAS, JSON.stringify(ex, null, 2) + '\n');
if (!fs.existsSync(CONV)) { console.log('no qdb/conversion.json'); process.exit(0); }
const conv = JSON.parse(fs.readFileSync(CONV, 'utf8'));
const T = conv.geometry.transforms.filter((t) => !t.extra);
for (const m of ex.maps) {
  if (T.some((t) => t.ui_map_id === m.ui_map_id)) continue; // the conversion learned it itself
  T.push({ ui_map_id: m.ui_map_id, source_name: null, target_name: m.target_name, area_id: m.area_id, map_id: m.map_id, extra: true, estimated: !!m.estimated,
    coefficients: { scale_x: 1, offset_x: 0, scale_y: 1, offset_y: 0 }, area_transform_supported: true, source_bounds: m.target_bounds, target_bounds: m.target_bounds });
}
const before = JSON.stringify(conv.geometry.transforms);
conv.geometry.transforms = T;
if (JSON.stringify(T) !== before) fs.writeFileSync(CONV, JSON.stringify(conv, null, 2) + '\n');
console.log(`map extras: ${ex.maps.length} map(s), ${learned} measured in game now, ${ex.maps.filter((m) => m.estimated).length} still estimated`);
