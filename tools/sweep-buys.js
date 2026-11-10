// Sweep: every "Buy N <item>" step in a plan, against the vendor nearest the quest (its giver, else its hand-in). A
// plan once hearthed to Stormwind for a Flagon of Mead that the Menethil innkeeper sells (route2 put buy steps at the
// densest cluster of sellers). usage: node tools/sweep-buys.js <Route.lua or Plan.lua> [...]  -> one line per bad step
const fs = require('fs');
const path = require('path');
const RF = require('./routefile');
const ROOT = path.join(__dirname, '..');
const db = JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'db.json'), 'utf8'));
const conv = JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'conversion.json'), 'utf8')).geometry.transforms;
const uiOf = Object.fromEntries(conv.map((t) => [t.area_id, t.ui_map_id]));
const B = {}; for (const t of conv) { const b = t.target_bounds || t.source_bounds; if (b) B[t.ui_map_id] = { ...b, inst: t.map_id }; }
const world = (m, x, y) => { const b = B[m]; return b ? [b.left + x * (b.right - b.left), b.top + y * (b.bottom - b.top), b.inst] : null; };
const yd = (a, b) => (a && b && a[2] === b[2] ? Math.hypot(a[0] - b[0], a[1] - b[1]) : Infinity);
let bad = 0, total = 0;
for (const file of process.argv.slice(2)) {
  const text = fs.readFileSync(file, 'utf8');
  for (const id of RF.routeIds(text)) {
    const steps = RF.steps(text, id);
    steps.forEach((s, i) => {
      const m = /^Buy \d+ (.+)$/.exec(s.text || '');
      if (s.k !== 'obj' || !m || !s.q) return;
      total++;
      const q = db.quests[s.q]; if (!q) return;
      const o = (q.objectives || []).find((x) => x.kind === 'item' && x.name === m[1]); if (!o) return;
      const vendors = (o.vendors || []).flatMap((v) => ((db.npcs[v] || {}).spawns || []).filter((sp) => sp.x >= 0).map((sp) => ({ ...sp, name: db.npcs[v].name })));
      const giver = (q.starters[0] && q.starters[0].spawns && q.starters[0].spawns[0]) || (q.finishers[0] && q.finishers[0].spawns && q.finishers[0].spawns[0]);
      if (!giver || !vendors.length || !s.m) return;
      const gw = world(uiOf[giver.zone], giver.x / 100, giver.y / 100);
      const near = vendors.map((v) => ({ v, d: yd(gw, world(uiOf[v.zone], v.x / 100, v.y / 100)) })).sort((a, b) => a.d - b.d)[0];
      const here = yd(gw, world(s.m, s.x, s.y));
      // planned more than 500 yd (or a continent) further from the quest than the nearest seller
      if (here - near.d > 500) {
        bad++;
        console.log(`${path.basename(path.dirname(file))} ${id.slice(0, 28)} #${i + 1} ${s.text} (${q.name}): planned in ${s.zone || s.m}, ${isFinite(here) ? Math.round(here) + ' yd' : 'another continent'} from the giver; ${near.v.name} is ${Math.round(near.d)} yd`);
      }
    });
  }
}
console.log(`${total} buy steps, ${bad} far from the nearest seller`);
