// Checks the walking paths (waypoints.js) keep out of the other faction's towns: an Alliance walk from Booty Bay to
// Nesingwary's camp went along the road through Grom'gol (a player's screenshot); it should go round, a Horde one need not.
// usage: node tools/test-waypoints.js   (needs qdb/ and terrain/)
const path = require('path');
const ROOT = path.join(__dirname, '..');
const { addWaypoints } = require('./waypoints');
const conv = require(path.join(ROOT, 'qdb', 'conversion.json')).geometry.transforms;
const db = require(path.join(ROOT, 'qdb', 'db.json'));
const H = require('./hostile-towns.json');
let fails = 0;
const check = (name, ok, info) => { console.log((ok ? 'ok   ' : 'FAIL ') + name + (ok ? '' : '  ' + JSON.stringify(info))); if (!ok) fails++; };
const gromgol = H.alliance.find((t) => t.name === "Grom'gol");
const stv = conv.find((t) => t.area_id === 33), b = stv.target_bounds || stv.source_bounds;
const W = Math.abs(b.left - b.right), Hh = Math.abs(b.top - b.bottom);
async function walk(faction) {
  const r = [{ steps: [{ k: 'goto', m: 1434, x: 0.278, y: 0.768 }, { k: 'accept', m: 1434, x: 0.356, y: 0.108 }] }];
  await addWaypoints(r, { faction, terrainDir: path.join(ROOT, 'terrain'), conv, db, workers: 1 });
  const s = r[0].steps[1];
  const pts = (s.wp || '').split(';').filter(Boolean).map((p) => p.split(',').map(Number));
  return { yards: s.walk, closest: Math.min(...pts.map(([x, y]) => Math.hypot((x - gromgol.x) * W, (y - gromgol.y) * Hh))) };
}
(async () => {
  check("Grom'gol is listed as hostile to the Alliance", !!gromgol, null);
  const a = await walk('alliance'), h = await walk('horde');
  check("an Alliance walk from Booty Bay to Nesingwary keeps out of Grom'gol (its guards' reach)", a.closest > gromgol.r + 150, a);
  check('...for a short detour, not a long one (under 20% longer than the Horde walk)', a.yards < h.yards * 1.2, { alliance: a.yards, horde: h.yards });
  check("a Horde walk may go by Grom'gol (its own town)", h.closest < a.closest, { alliance: a.closest, horde: h.closest });
  console.log(fails ? `${fails} failed` : 'all passed');
  process.exit(fails ? 1 : 0);
})();
