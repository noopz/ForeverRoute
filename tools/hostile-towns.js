// Towns and camps of the other faction, from the quest data: dense clusters of NPCs friendly only to that faction
// (Crossroads, Tarren Mill, Hammerfall, Splintertree, the Warsong Lumber Camp...). Walking through one means guards and
// players who will fight you - possible (fine for PvP) but slower and riskier, so trips through them cost extra
// (travel-facts.json HOSTILE_SEC) in the planner (travel.js) and the addon's trip planner (Travel.lua).
// Writes tools/hostile-towns.json: { alliance: [hostile to an Alliance player], horde: [...] }, each
// { m: uiMapID, x, y (0-1), r: radius in yards, n: NPCs, fm: its flight master if any }.
// usage: node tools/hostile-towns.js   (after rebuilding qdb/db.json; then node tools/gen-travel-data.js)
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..');
const db = JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'db.json'), 'utf8'));
const conv = JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'conversion.json'), 'utf8')).geometry.transforms;
const T = Object.fromEntries(conv.map((t) => [t.area_id, t]));
const BATTLEGROUNDS = new Set(['Alterac Valley', 'Arathi Basin', 'Warsong Gulch']);
const MIN_NPCS = 8, SEED_PCT = 4, MEMBER_PCT = 6;
// the towns by their flight master (the data has no town names; a camp's flight master tells which town it is)
const TOWN_OF_FM = { Devrak: 'the Crossroads', Zarise: 'Tarren Mill', Urda: 'Hammerfall', Vhulgra: 'Splintertree Post', Andruk: "Zoram'gar Outpost",
  Tharm: 'Sun Rock Retreat', Nyse: 'Freewind Post', Thalon: 'Shadowprey Village', Shardi: 'Brackenwall Village', Gorrik: 'Kargath', Breyk: 'Stonard',
  Thysta: "Grom'gol", 'Omusa Thunderhorn': 'Camp Taurajo', Gorkas: 'Revantusk Village', Shyn: 'Camp Mojache', Brakkar: 'Bloodvenom Post', 'Karos Razok': 'the Sepulcher',
  'Michael Garrett': 'the Undercity', Doras: 'Orgrimmar' };
// any other flight master: the town in its flight point's name ('Southshore, Hillsbrad' -> Southshore), from the addon's
// flight masters (tools/flightmasters.js: the client's flight points) - not 'Darla Harris's town'
const TOWN_OF_FP = {};
for (const m of require('fs').readFileSync(require('path').join(__dirname, '..', 'addon', 'ForeverRoute', 'FlightMasters.lua'), 'utf8').matchAll(/\{ [\d.]+, [\d.]+, "([^"]+)", "([^",]+)/g)) TOWN_OF_FP[m[1]] = m[2];
// a zone's size in yards (its map bounds), to turn map percent into yards
const yardsPerPct = (t) => { const b = t && (t.target_bounds || t.source_bounds); return b ? Math.max(Math.abs(b.right - b.left), Math.abs(b.bottom - b.top)) / 100 : 0; };
function towns(side) {
  const byZone = {};
  for (const n of Object.values(db.npcs)) {
    if (!n || n.friendly !== side) continue;
    for (const p of n.spawns || []) if (p.x >= 0 && T[p.zone] && !BATTLEGROUNDS.has(T[p.zone].target_name)) (byZone[p.zone] = byZone[p.zone] || []).push({ x: p.x, y: p.y, sub: n.sub, name: n.name });
  }
  const out = [];
  for (const [z, pts] of Object.entries(byZone)) {
    const used = new Set();
    for (;;) {
      let seed = -1, best = 0;
      pts.forEach((p, i) => { if (used.has(i)) return; let k = 0; pts.forEach((q, j) => { if (!used.has(j) && Math.hypot(p.x - q.x, p.y - q.y) < SEED_PCT) k++; }); if (k > best) { best = k; seed = i; } });
      if (best < MIN_NPCS) break;
      const c = pts[seed];
      const mem = pts.map((q, j) => j).filter((j) => !used.has(j) && Math.hypot(c.x - pts[j].x, c.y - pts[j].y) < MEMBER_PCT);
      mem.forEach((j) => used.add(j));
      const cx = mem.reduce((a, j) => a + pts[j].x, 0) / mem.length, cy = mem.reduce((a, j) => a + pts[j].y, 0) / mem.length;
      // where most of them are (3 in 4), not the farthest stray one on a road
      const ds = mem.map((j) => Math.hypot(pts[j].x - cx, pts[j].y - cy)).sort((p, q) => p - q);
      const rPct = ds[Math.floor(ds.length * 0.75)] || ds[ds.length - 1];
      const t = T[z];
      const fm = mem.map((j) => pts[j]).find((p) => /Wind Rider|Bat Handler|Gryphon Master|Hippogryph Master/i.test(p.sub || ''));
      out.push({ name: fm ? (TOWN_OF_FM[fm.name] || TOWN_OF_FP[fm.name] || fm.name + "'s town") : (side === 'H' ? 'a Horde' : 'an Alliance') + ' camp', m: t.ui_map_id, zone: t.target_name, x: +(cx / 100).toFixed(4), y: +(cy / 100).toFixed(4), r: Math.round(Math.max(40, rPct * yardsPerPct(t))), n: mem.length, fm: fm ? fm.name : undefined });
    }
  }
  return out.sort((a, b) => a.zone.localeCompare(b.zone) || b.n - a.n);
}
const result = { _about: 'tools/hostile-towns.js: the other faction\'s towns and camps (clusters of its NPCs). Regenerate, do not edit.', alliance: towns('H'), horde: towns('A') };
fs.writeFileSync(path.join(__dirname, 'hostile-towns.json'), JSON.stringify(result, null, 1) + '\n');
console.log(`hostile towns: ${result.alliance.length} for an Alliance player, ${result.horde.length} for a Horde player`);
