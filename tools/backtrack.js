// Backtracking in a plan, measured the way the simulated player does (tests/_player.lua): hubs are places with 3+
// pick-ups / hand-ins within HUB_YD; everything else is the wild. A wild revisit is coming back to a wild area
// (WILD_YD cells, neighbours count as the same area) after having been more than AWAY_YD away; a thin trip is a trip
// out of a hub for one wild thing and straight back. Each revisit is put down to a cause:
//   within a leg   the zone planner's order sent you back (tools/optimize.js)
//   across legs    the campaign came back to the zone later (tools/campaign.js)
// usage: node tools/backtrack.js <Route.lua or Plan.lua> [path id]   -> summary and the worst offenders
const fs = require('fs');
const path = require('path');
const RF = require('./routefile');
const ROOT = path.join(__dirname, '..');
const [file, want] = process.argv.slice(2);
const text = fs.readFileSync(file, 'utf8');
const id = want || RF.routeIds(text).find((x) => /^path:/.test(x));
const steps = RF.steps(text, id);
const conv = JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'conversion.json'), 'utf8')).geometry.transforms;
const B = {}; for (const t of conv) { const b = t.target_bounds || t.source_bounds; if (b) B[t.ui_map_id] = { ...b, inst: t.map_id }; }
const world = (m, x, y) => { const b = B[m]; return b ? [b.left + x * (b.right - b.left), b.top + y * (b.bottom - b.top), b.inst] : null; };
const HUB_YD = 80, WILD_YD = 150, AWAY_YD = 300;
// legs: a new leg starts at each travel step
let leg = 0; const legOf = [];
steps.forEach((s, i) => { if (s.k === 'fly') leg++; legOf[i] = leg; });
const pts = steps.map((s) => (s.m && s.x != null ? world(s.m, s.x, s.y) : null));
const hubs = [];
const handIns = pts.map((p, i) => (p && (steps[i].k === 'accept' || steps[i].k === 'turnin') ? p : null)).filter(Boolean);
for (const a of handIns) { let n = 0; for (const b of handIns) if (a[2] === b[2] && Math.hypot(a[0] - b[0], a[1] - b[1]) < HUB_YD) n++; if (n >= 3) hubs.push(a); }
// a capital is never the wild (a city errand is a walk, not backtracking out in the world)
const CAP = new Set([...require('./world').CAPITAL_MAPS].map(Number));
const atHub = (p, s) => (s && CAP.has(+s.m)) || hubs.some((h) => h[2] === p[2] && Math.hypot(h[0] - p[0], h[1] - p[1]) < HUB_YD);
const cells = new Map();
const out = { within: [], across: [], thin: 0, trips: 0, wild: 0, thinEx: [] };
let trip = null;
steps.forEach((s, i) => {
  const p = pts[i];
  if (!p || !['obj', 'accept', 'turnin'].includes(s.k)) return;
  if (atHub(p, s)) {
    if (trip && trip.n >= 1) { out.trips++; if (trip.n === 1 && trip.far) { out.thin++; out.thinEx.push(trip.what); } }
    trip = { n: 0, far: false, from: i };
  } else {
    out.wild++;
    if (trip) { trip.n++; trip.what = `#${i + 1} ${s.k} ${s.name || s.text} (${s.zone})`; }
    const key = p[2] + ':' + Math.floor(p[0] / WILD_YD) + ':' + Math.floor(p[1] / WILD_YD);
    const c = cells.get(key);
    if (c && c.left) { (legOf[c.first] === legOf[i] ? out.within : out.across).push({ at: i + 1, first: c.first + 1, zone: s.zone, name: s.name || s.text }); c.left = false; c.first = i; }
    else if (!c) cells.set(key, { first: i, at: p, left: false });
    if (trip && hubs.some((h) => h[2] === p[2] && Math.hypot(h[0] - p[0], h[1] - p[1]) > AWAY_YD)) trip.far = true;
  }
  for (const c of cells.values()) if (!c.left && c.at[2] === p[2] && Math.hypot(c.at[0] - p[0], c.at[1] - p[1]) > AWAY_YD) c.left = true;
});
const byZone = (l) => Object.entries(l.reduce((a, r) => ((a[r.zone] = (a[r.zone] || 0) + 1), a), {})).sort((a, b) => b[1] - a[1]).slice(0, 8).map(([z, n]) => z + ' ' + n).join(', ');
console.log(`${id}: ${steps.length} steps, ${leg} legs`);
console.log(`wild revisits: ${out.within.length + out.across.length} (within a leg ${out.within.length}, across legs ${out.across.length}); thin trips ${out.thin} of ${out.trips}; ${out.wild} steps in the wild`);
console.log('  within a leg, by zone: ' + byZone(out.within));
console.log('  across legs, by zone:  ' + byZone(out.across));
console.log('  examples within: ' + out.within.slice(0, 5).map((r) => `#${r.at} ${r.name} (first #${r.first})`).join('; '));
console.log('  examples across: ' + out.across.slice(0, 5).map((r) => `#${r.at} ${r.name} (first #${r.first})`).join('; '));
// why each revisit happened: the quest done on the return was already in your log on the first visit (the order could
// have done it then: "in log") or was picked up after it (a follow-up, or one from a later hub: "opened later")
{
  const acceptAt = {}; steps.forEach((s, i) => { if (s.k === 'accept' && s.q > 0 && acceptAt[s.q] === undefined) acceptAt[s.q] = i; });
  const why = (r) => { const s = steps[r.at - 1]; const q = s.q > 0 ? s.q : null; if (!q || acceptAt[q] === undefined) return 'other'; return acceptAt[q] < r.first - 1 ? 'in log' : 'opened later'; };
  for (const [name, l] of [['within', out.within], ['across', out.across]]) {
    const n = {}; for (const r of l) { r.why = why(r); n[r.why] = (n[r.why] || 0) + 1; }
    console.log(`  ${name} a leg, why: ` + Object.entries(n).map(([k, v]) => k + ' ' + v).join(', '));
  }
  if (process.env.FR_WHY) for (const r of [...out.within, ...out.across].filter((r) => r.why === 'in log').slice(0, +process.env.FR_WHY)) console.log(`    in log: #${r.at} ${r.name} (${r.zone}), first there #${r.first} ${steps[r.first - 1].name || steps[r.first - 1].text}${legOf[r.first - 1] === legOf[r.at - 1] ? '' : ' (an earlier leg)'}`);
}
if (process.env.FR_THIN) console.log('  thin trips: ' + out.thinEx.slice(0, +process.env.FR_THIN).join('; '));
module.exports = {};
