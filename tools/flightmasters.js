// Flight masters per zone, keyed by uiMapID, for the addon's travel arrow and the planner (tools/travel.js). Both
// factions: ns.FLIGHT_BY.Alliance / .Horde (neutral ones in both); Core.lua's ns.UseFaction() sets ns.FLIGHT to yours.
//
// Sources:
//   - Forever's client tables TaxiNodes and TaxiPath (wago.tools db2 csv, the build in BUILD below): which flight points
//     exist, for which faction (TaxiNodes.Flags: 1 Alliance, 2 Horde), where, and what the flight map calls them
//     ("Sentinel Hill, Westfall" - the name the addon sees when you open a flight map). A flight point is live when it
//     has a faction and a flight there and back (TaxiPath both ways) to another point with a faction: that leaves out
//     the boats and zeppelins, quest and test paths, the druids' one-way Nighthaven flights, the Plaguelands towers and
//     points that are in the table but not switched on (Powderfuse Port, Tidegear Coast: no faction, no flights; their
//     flight masters are "NYI"). Alterac Valley passes that test and is left out by hand (flight-points.json).
//   - QuestieDB (qdb/db.json): the flight master standing at each point (by subtitle), for the name and the exact spot.
//     QuestieDB alone was wrong in three ways: several spawn points for one flight master (Gretchen Mayberry 11, Grakna
//     6: all were written, the first one was used), a subtitle the list did not know (Bluebell, "Flight Mistress",
//     Tainted Foothills), and flight masters filed under one faction that serve both (Mount Hyjal: both points are for
//     both factions, TaxiNodes says).
//   - tools/flight-points.json: our own corrections, each with its source (a point to leave out; the flight master of
//     a point QuestieDB has nobody at). A live point with no flight master from either is an error: nothing is written.
//
// Each entry: { x, y, flight master, flight point name } (0-1 map coords of the flight master).
// usage: node flightmasters.js [--fetch] <db.json> <conversion.json> <out.lua> [clientDir]
//   --fetch   download TaxiNodes.csv and TaxiPath.csv for BUILD into clientDir first (default qdb/client; also done
//             when they are not there yet)
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const BUILD = process.env.FR_CLIENT_BUILD || '1.60.1.70862';
const NEAR = 150; // yards: a flight master stands at their flight point
const argv = process.argv.slice(2);
const [dbPath, convPath, out, clientDir = path.join(__dirname, '..', 'qdb', 'client')] = argv.filter((a) => !a.startsWith('--'));
const TABLES = ['TaxiNodes', 'TaxiPath'];
if (argv.includes('--fetch') || TABLES.some((t) => !fs.existsSync(path.join(clientDir, t + '.csv')))) {
  fs.mkdirSync(clientDir, { recursive: true });
  for (const t of TABLES) execFileSync('curl', ['-sS', '-L', '--fail', '-A', 'db2-fetch', '-o', path.join(clientDir, t + '.csv'), `https://wago.tools/db2/${t}/csv?build=${BUILD}`], { stdio: 'inherit' });
}
// csv with quoted fields ("Sentinel Hill, Westfall")
function csv(file) {
  const t = fs.readFileSync(file, 'utf8');
  const rows = []; let row = [], c = '', q = false;
  for (let i = 0; i < t.length; i++) {
    const ch = t[i];
    if (q) { if (ch === '"') { if (t[i + 1] === '"') { c += '"'; i++; } else q = false; } else c += ch; }
    else if (ch === '"') q = true;
    else if (ch === ',') { row.push(c); c = ''; }
    else if (ch === '\n') { row.push(c); c = ''; if (row.length > 1) rows.push(row); row = []; }
    else if (ch !== '\r') c += ch;
  }
  if (c !== '' || row.length) { row.push(c); if (row.length > 1) rows.push(row); }
  const head = rows.shift();
  return rows.map((r) => Object.fromEntries(head.map((k, i) => [k, r[i]])));
}
const db = JSON.parse(fs.readFileSync(dbPath, 'utf8'));
const conv = JSON.parse(fs.readFileSync(convPath, 'utf8')).geometry.transforms;
const own = JSON.parse(fs.readFileSync(path.join(__dirname, 'flight-points.json'), 'utf8'));
const byArea = Object.fromEntries(conv.map((t) => [t.area_id, t]));
const byUi = Object.fromEntries(conv.map((t) => [t.ui_map_id, t]));
// a zone point (percent) in world yards, and back
const bounds = (t) => t.target_bounds || t.source_bounds;
const toWorld = (t, x, y) => { const b = bounds(t); return [b.top - (y / 100) * (b.top - b.bottom), b.left - (x / 100) * (b.left - b.right)]; };
const toZone = (t, wx, wy) => { const b = bounds(t); return [(100 * (b.left - wy)) / (b.left - b.right), (100 * (b.top - wx)) / (b.top - b.bottom)]; };

// the live flight points
const taxiNodes = csv(path.join(clientDir, 'TaxiNodes.csv'));
const faction = new Set(taxiNodes.filter((n) => +n.Flags & 3).map((n) => +n.ID));
const ways = new Set();
for (const p of csv(path.join(clientDir, 'TaxiPath.csv'))) ways.add(+p.FromTaxiNode + '>' + +p.ToTaxiNode);
const linked = new Set();
for (const w of ways) { const [a, b] = w.split('>').map(Number); if (a !== b && faction.has(a) && faction.has(b) && ways.has(b + '>' + a)) linked.add(a); }
const points = [];
for (const n of taxiNodes) {
  const id = +n.ID, flags = +n.Flags;
  if (!linked.has(id) || (own.skip || {})[id]) continue;
  points.push({ id, name: n.Name_lang, inst: +n.ContinentID, wx: +n.Pos_0, wy: +n.Pos_1, sides: (flags & 1 ? 'A' : '') + (flags & 2 ? 'H' : '') });
}
// QuestieDB's flight masters: every spawn point, in world yards
const SUB = /^(Gryphon Master|Hippogryph Master|Flight Master|Flight Mistress|Wind Rider Master|Bat Handler)$/i;
const spawns = [];
let order = 0;
for (const [id, n] of Object.entries(db.npcs)) {
  if (!n || !SUB.test(n.sub || '')) continue;
  order++;
  for (const s of n.spawns || []) {
    const t = byArea[s.zone]; if (!t || !bounds(t) || s.x < 0) continue;
    const [wx, wy] = toWorld(t, s.x, s.y);
    spawns.push({ id: +id, order, npc: n.name, friendly: n.friendly || '', ui: t.ui_map_id, inst: t.map_id, x: s.x / 100, y: s.y / 100, wx, wy });
  }
}
const notes = [], errors = [];
const used = new Set();
const byMap = { A: {}, H: {} };
for (const p of points) {
  for (const side of p.sides) {
    // the flight master at this point: one of your faction if QuestieDB has one, else whoever stands there (the point's
    // own faction flags are the authority)
    let best = null;
    for (const s of spawns) {
      if (s.inst !== p.inst) continue;
      const dd = Math.hypot(s.wx - p.wx, s.wy - p.wy);
      if (dd > NEAR) continue;
      const mine = s.friendly.includes(side) ? 0 : 1;
      if (!best || mine < best.mine || (mine === best.mine && dd < best.dd)) best = { ...s, mine, dd };
    }
    const fix = (own.npc || {})[p.id];
    if (!best && fix) {
      const z = toZone(byUi[fix.m], p.wx, p.wy);
      best = { npc: fix.name, ui: fix.m, x: fix.x != null ? fix.x : z[0] / 100, y: fix.y != null ? fix.y : z[1] / 100, order: 1e9 + p.id, mine: 0 };
    }
    if (!best) { errors.push(`${p.id} ${p.name} (${side}): no flight master within ${NEAR} yd in QuestieDB - add it to tools/flight-points.json (npc), with its source`); continue; }
    if (best.mine) notes.push(`${p.name} (${side}): ${best.npc} is filed under "${best.friendly}" in QuestieDB; the flight point is for ${p.sides}`);
    if (best.id) used.add(best.id);
    (byMap[side][best.ui] = byMap[side][best.ui] || []).push({ x: best.x, y: best.y, npc: best.npc, taxi: p.name, order: best.order, point: p.id });
  }
}
// what QuestieDB has that the client does not: said, not written
const seen = new Set();
for (const s of spawns) {
  if (used.has(s.id) || seen.has(s.id)) continue;
  seen.add(s.id);
  notes.push(`${s.npc} (map ${s.ui}): a flight master in QuestieDB with no live flight point - left out`);
}
if (errors.length) { console.error(errors.join('\n')); process.exit(1); }

const L = ['-- Generated by flightmasters.js from the client flight points (TaxiNodes, build ' + BUILD + ') and the flight masters in QuestieDB.',
  '-- By faction, then uiMapID: { x, y, flight master, flight point name } (0-1 map coords).', 'local _, ns = ...', 'ns.FLIGHT_BY = {'];
const report = [];
for (const [side, name] of [['A', 'Alliance'], ['H', 'Horde']]) {
  L.push(`  ${name} = {`);
  for (const [m, list] of Object.entries(byMap[side]).sort((a, b) => a[0] - b[0])) {
    list.sort((a, b) => a.order - b.order || a.point - b.point);
    L.push(`    [${m}] = { ${list.map((f) => `{ ${f.x.toFixed(4)}, ${f.y.toFixed(4)}, ${JSON.stringify(f.npc)}, ${JSON.stringify(f.taxi)} }`).join(', ')} },`);
  }
  L.push('  },');
  report.push(`${name}: ${Object.keys(byMap[side]).length} zones, ${Object.values(byMap[side]).flat().length} flight points`);
}
L.push('}', 'ns.FLIGHT = ns.FLIGHT_BY.Alliance -- until ns.UseFaction (Core.lua) knows yours');
fs.writeFileSync(out, L.join('\n') + '\n');
console.log(report.join('; '));
for (const n of notes) console.log('  ' + n);
