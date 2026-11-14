// Data for the README hero animations (drawn by tools/readme-render.js with a scene in tools/readme-scenes/).
// usage: node tools/readme-hero.js journey <plan key, e.g. human-paladin> <out.json>
//   the plan's route on both continents, stop by stop, with the level and every zone hop (flight, hearth, boat)
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..');
const RF = require('./routefile');
const world = require('./readme-world');

const [mode, key, outFile] = process.argv.slice(2);
const toUrl = (p) => 'file:///' + p.replace(/\\/g, '/');

function routeSteps(k) {
  const t = fs.readFileSync(path.join(ROOT, 'paths-starter', k, 'Route.lua'), 'utf8');
  return RF.steps(t, RF.routeIds(t).find((x) => /^path:/.test(x)));
}

if (mode === 'journey') {
  const steps = routeSteps(key);
  const P = JSON.parse(fs.readFileSync(path.join(ROOT, 'paths-starter', key, 'path-0.json'), 'utf8'));
  const pts = []; let how = null, quests = 0, lvl = 1;
  // the plan's class quests (tools/reviewed-<faction>.json) and weapon upgrades: called out on the way
  const [race, cls] = key.split('-');
  let reviewed = { special: [] }; try { reviewed = JSON.parse(fs.readFileSync(path.join(__dirname, 'reviewed-alliance.json'), 'utf8')); } catch (e) {}
  const classQ = new Map();
  for (const sp of reviewed.special || []) if (sp.class === cls && (!sp.races || sp.races.includes(race))) for (const q of sp.quests) classQ.set(q, sp.name.replace(/ \(.*\)$/, ''));
  const called = new Set(); let pending = null;
  for (const s of steps) {
    if (s.q && classQ.has(s.q) && !called.has(classQ.get(s.q))) { called.add(classQ.get(s.q)); pending = { kind: 'class', text: 'Class quest: ' + classQ.get(s.q) }; }
    else if (s.k === 'turnin' && /weapon upgrade/.test(s.note || '') && !pending) pending = { kind: 'item', text: 'New weapon: ' + s.note.replace(/^Reward: /, '').replace(/ \(.*$/, '') };
    if (s.k === 'hearth') how = 'hearth';
    if (s.k === 'fly') { how = how || (s.boat ? 'boat' : 'fly'); continue; }
    if (s.k === 'turnin') quests++;
    if (s.lvl) lvl = Math.max(lvl, s.lvl);
    if (!s.m || s.x == null) continue;
    const p = world.px(s.m, s.x, s.y); if (!p) continue;
    const last = pts[pts.length - 1];
    const hop = last && (last.zone !== s.zone || Math.hypot(last.x - p.x, last.y - p.y) > 40);
    if (last && !hop && Math.hypot(last.x - p.x, last.y - p.y) < 1.5) { last.lvl = lvl; last.q = quests; if (pending && !last.call) { last.call = pending; pending = null; } continue; }
    pts.push({ x: p.x, y: p.y, inst: p.inst, zone: s.zone || '', lvl, q: quests, hop: hop ? (last.inst !== p.inst ? 'boat' : how || 'fly') : undefined, call: pending || undefined });
    pending = null;
    how = null;
  }
  const zones = new Set(pts.map((p) => p.zone));
  const out = {
    W: 1000, H: 560, map: { W: world.W, H: world.H }, panels: world.panels,
    zones: world.zones.map((z) => ({ ...z, png: toUrl(z.png) })),
    pts, title: key.replace('-', ' '), hours: Math.round(P.minutes / 6) / 10, steps: steps.length, quests, zoneCount: zones.size,
    flights: steps.filter((s) => s.k === 'fly').length,
  };
  fs.writeFileSync(outFile, JSON.stringify(out));
  console.log(`${pts.length} stops, ${pts.filter((p) => p.hop).length} hops, ${zones.size} zones, ${quests} quests, ${out.hours} h`);
}

// node tools/readme-hero.js card <plan key> <out.json> [first step] [last step]
//   the start of a plan as the addon's card shows it, step by step: the steps (wording as UI/Card.lua words them), the
//   walk between them (the planner's waypoints), the zone image, and the addon's own icons and colours
if (mode === 'card') {
  const [from = 1, to = 34] = process.argv.slice(5).map(Number);
  const all = routeSteps(key);
  const steps = all.filter((s) => s.id >= from && s.id <= to);
  const m = steps.find((s) => s.m).m;
  const conv = JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'conversion.json'), 'utf8')).geometry.transforms;
  const T = conv.find((t) => t.ui_map_id === m), b = T.target_bounds || T.source_bounds;
  // Style.KIND (addon/ForeverRoute/UI/Style.lua): the colours and verbs the card uses
  const style = fs.readFileSync(path.join(ROOT, 'addon', 'ForeverRoute', 'UI', 'Style.lua'), 'utf8');
  const KIND = {};
  for (const mm of style.matchAll(/^\s+(\w+) = \{ icon = "([\w-]+)", color = \{ ([\d., ]+) \}, verb = "([^"]*)" \}/gm)) KIND[mm[1]] = { icon: mm[2], color: mm[3].split(',').map((v) => Math.round(+v * 255)), verb: mm[4] };
  // the addon's icons (32-bit TGA, top-left origin) as RGBA for the page
  const icons = {};
  for (const k of new Set(Object.values(KIND).map((x) => x.icon).concat(['icon-check']))) {
    const buf = fs.readFileSync(path.join(ROOT, 'addon', 'ForeverRoute', 'Media', k + '.tga'));
    const w = buf.readUInt16LE(12), h = buf.readUInt16LE(14), px = Buffer.from(buf.subarray(18 + buf[0], 18 + buf[0] + w * h * 4));
    for (let i = 0; i < px.length; i += 4) { const t = px[i]; px[i] = px[i + 2]; px[i + 2] = t; } // BGRA -> RGBA
    icons[k] = { w, h, rgba: px.toString('base64') };
  }
  const zone = world.zones.find((z) => z.ui === m);
  const out = {
    W: 1000, H: 560, zone: T.target_name, png: toUrl(zone.png), yards: [b.left - b.right, b.top - b.bottom], KIND, icons, total: all.length,
    steps: steps.map((s) => ({
      id: s.id, k: s.k, loot: s.loot, q: s.q, name: s.name, text: s.text, npc: s.npc, target: s.target, level: s.level, lvl: s.lvl,
      x: s.x, y: s.y, note: s.note && !/^Reward:/.test(s.note) ? s.note : undefined, reward: s.note && /^Reward:/.test(s.note) ? s.note.replace(/^Reward: /, '') : undefined,
      wp: (s.wp || '').split(';').filter(Boolean).map((p) => p.split(',').slice(0, 2).map(Number)),
    })),
  };
  fs.writeFileSync(outFile, JSON.stringify(out));
  console.log(`${out.steps.length} steps in ${out.zone}, kinds ${Object.keys(KIND).length}, icons ${Object.keys(icons).length}`);
}

// node tools/readme-hero.js grid <out.json> [gate.json ...]: every built-in plan as it ships
// (addon/ForeverRoute_Starter_<race>_<class>/Plan.lua): its hours to 60 with travel (the plan's meta.hours), its
// grinding (tools/score-plan.js), its audit run again now (tools/lint-route.js), and the simulated player's verdict
// from the tree gates that shipped it (tools/tree-gate.js --sim writes <tree dir>/gate.json; no gate: no playthrough)
if (mode === 'grid') {
  const out2 = key; // (the output file; the gate files follow)
  const { execFileSync } = require('child_process');
  const sims = {};
  for (const gf of process.argv.slice(4)) for (const r of JSON.parse(fs.readFileSync(gf, 'utf8'))) if (r.sim) sims[r.race + '-' + r.cls] = r.sim;
  const rows = {};
  for (const d of fs.readdirSync(path.join(ROOT, 'addon'))) {
    const mm = d.match(/^ForeverRoute_Starter_([a-z]+)_([a-z]+)$/); if (!mm) continue;
    const [, race, cls] = mm, k = race + '-' + cls, f = path.join(ROOT, 'addon', d, 'Plan.lua');
    const t = fs.readFileSync(f, 'utf8'), id = RF.routeIds(t).find((x) => /^path:/.test(x));
    const sc = JSON.parse(execFileSync(process.execPath, [path.join(__dirname, 'score-plan.js'), f], { encoding: 'utf8' }).trim().split('\n').pop());
    const a = execFileSync(process.execPath, [path.join(__dirname, 'lint-route.js'), f, path.join(ROOT, 'qdb', 'db.json'), id, cls + ',' + race], { encoding: 'utf8' });
    // a built-in plan is stitched from the tree's parts (tools/tree-assemble.js) and the step clock (tm) restarts at
    // the start -> trunk seam: a hearth "-500 min after" the last one is that restart, not a cooldown a player hits
    const issues = a.split('\n').slice(1).filter((l) => l.trim() && !/no issues found/.test(l) && !/hearth only -\d+ min after/.test(l));
    const meta = (t.match(/^\s+meta = \{.*$/m) || [''])[0], sim = sims[k];
    rows[k] = {
      level: +((meta.match(/endLevel = "(\d+)/) || [])[1] || 60), hours: +(meta.match(/\bhours = ([\d.]+)/) || [])[1], grind: sc.grindH,
      steps: RF.steps(t, id).length, audit: issues.length, personas: sim ? 1 : 0, broke: sim ? sim.broke + (sim.exit ? 1 : 0) : 0,
    };
  }
  const factions = [
    { name: 'Alliance', races: ['human', 'dwarf', 'nightelf', 'gnome', 'skyborne'] },
    { name: 'Horde', races: ['orc', 'undead', 'tauren', 'troll', 'skybornehorde'] },
  ];
  const races = factions.flatMap((f) => f.races), classes = ['warrior', 'paladin', 'hunter', 'rogue', 'priest', 'shaman', 'mage', 'warlock', 'druid'];
  const out = { W: 1000, H: 856, races, classes, factions, plans: rows };
  fs.writeFileSync(out2, JSON.stringify(out));
  const sum = (f) => Object.values(rows).reduce((n, r) => n + f(r), 0);
  console.log(`${Object.keys(rows).length} plans, ${sum((r) => r.audit)} audit issues, ${sum((r) => r.personas)} played, ${sum((r) => r.broke)} broke, ${sum((r) => r.grind)} h grinding`);
}

// node tools/readme-hero.js think <plan key> <out.json> [how many decisions=12]: the planner's zone choices
// (path-0.json choices: every zone it weighed at each leg, xp/h, hand-ins, minutes), a spread from 1 to 60
if (mode === 'think') {
  const n = +(process.argv[5] || 12);
  const P = JSON.parse(fs.readFileSync(path.join(ROOT, 'paths-starter', key, 'path-0.json'), 'utf8'));
  const ch = (P.choices || []).filter((c) => c.options && c.options.filter((o) => o.xph > 0).length >= 3);
  const pick = []; for (let k = 0; k < n; k++) pick.push(ch[Math.round((k * (ch.length - 1)) / (n - 1))]);
  const zoneByName = {}; for (const z of world.zones) zoneByName[z.name] = z;
  const levels = (P.choices || []).map((c) => c.level);
  const out = {
    W: 1000, H: 560, map: { W: world.W, H: world.H }, panels: world.panels, zones: world.zones.map((z) => ({ ...z, png: toUrl(z.png) })),
    title: key.replace('-', ' '), legs: (P.choices || []).length,
    picks: [...new Set(pick)].map((c) => {
      const next = levels[(P.choices || []).indexOf(c) + 1];
      const opts = c.options.filter((o) => o.xph > 0).slice(0, 5).map((o) => ({ name: o.name, xph: o.xph, turnins: o.turnins, minutes: Math.round(o.minutes), chosen: o.z === c.chosen }));
      return { leg: c.leg, level: c.level, to: next || 60, opts, chosenName: (opts.find((o) => o.chosen) || opts[0]).name };
    }),
  };
  fs.writeFileSync(outFile, JSON.stringify(out));
  console.log(out.picks.map((p) => `L${p.level} ${p.chosenName} (${p.opts.length} options)`).join(' | '));
}
