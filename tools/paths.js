// Multi-path planner: rank first zones, plan the top N distinct starts in parallel (each a full campaign), then at every
// later zone boundary plan a branch for each runner-up zone that's close enough to be worth offering. Writes one Route.lua
// holding every path and branch, with the choice points, so the addon can offer "where next?" when a zone is finished.
// usage: node paths.js <campaign.json> [N=3] [branchesPerChoice=2]
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');
const base = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const args = process.argv.slice(3).filter((a, i, all) => !a.startsWith('--') && all[i - 1] !== '--work');
const REUSE = process.argv.includes('--reuse');
const N = +(args[0] || 3);
const ALTS = +(args[1] ?? 2);
const { makeEnsure, commonDrop } = require('./ensure-steps');
const ROOT = path.resolve(__dirname, '..');
const relRoot = (f) => (path.isAbsolute(f) ? f : path.join(ROOT, f));
const ensure = makeEnsure(JSON.parse(fs.readFileSync(relRoot(base.db), 'utf8')), JSON.parse(fs.readFileSync(relRoot(base.conversion), 'utf8')).geometry.transforms);
const wi = process.argv.indexOf('--work');
const work = wi > 0 ? path.resolve(process.argv[wi + 1]) : path.resolve(__dirname, '..', 'paths'); fs.mkdirSync(work, { recursive: true });
const run = (cfg, tag) => new Promise((res) => {
  const f = path.join(work, tag + '.json'); fs.writeFileSync(f, JSON.stringify(cfg));
  const p = spawn(process.execPath, ['--max-old-space-size=4000', path.join(__dirname, 'campaign.js'), f], { stdio: ['ignore', 'pipe', 'pipe'] });
    try { require("os").setPriority(p.pid, 19); } catch (e) {} // low priority: keep the game and desktop responsive
  let out = ''; p.stdout.on('data', (d) => (out += d)); p.stderr.on('data', (d) => (out += d));
  p.on('close', (code) => { fs.writeFileSync(path.join(work, tag + '.log'), out); res(code); });
});
async function pool(items, n, fn) { let i = 0; await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => { while (i < items.length) { const k = i++; await fn(items[k], k); } })); }
const readJson = (f) => (fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, 'utf8')) : null);
const XP = [0, 400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600, 8800, 10100, 11400, 12900, 14400, 16000, 17700, 19400, 21300, 23200, 25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400, 44300, 47400, 50800, 54500, 58600, 62800, 67100, 71600, 76100, 80800, 85700, 90700, 95800, 101000, 106300, 111800, 117500, 123200, 129100, 135100, 141200, 147500, 153900, 160400, 167100, 173900, 180800, 187900, 195000, 202300, 209800];
const uniq = (a) => a.filter((z, i) => a.indexOf(z) === i);
// (no level after 60: a path that reaches it has no fraction of a next level)
const finish = (p) => { p.levels = p.endLevel + (XP[p.endLevel] ? p.endXp / XP[p.endLevel] : 0) - p.startLevel; p.rate = p.levels / Math.max(1, p.minutes / 60); return p; };
const slug = (s) => s.replace(/[^A-Za-z]+/g, '');

// a special chain as a route: each stop is where the last quest is handed in and the next one starts (often the
// same object), with a travel step whenever the zone changes
function specialRoutes() {
  const out = [];
  if (!(base.special || []).length) return out;
  const dbS = JSON.parse(fs.readFileSync(relRoot(base.db), 'utf8'));
  const convS = JSON.parse(fs.readFileSync(relRoot(base.conversion), 'utf8')).geometry.transforms;
  const T = Object.fromEntries(convS.map((t) => [t.area_id, t]));
  let st = null; try { st = require('./snapshot').loadCharState(base.charDir, relRoot(base.conversion)); } catch (e) {}
  const done = new Set((st && st.completed) || []);
  // never a spot in the other faction's capital (the Horde copy of a class-quest summon lives in Undercity)
  const ENEMY_CITY = new Set((base.faction || 'alliance') === 'horde' ? [1519, 1537, 1657] : [1497, 1637, 1638]);
  const spot = (list) => { for (const o of list || []) for (const sp of o.spawns || []) if (sp.x >= 0 && T[sp.zone] && !ENEMY_CITY.has(sp.zone)) return { who: o.name, zone: sp.zone, m: T[sp.zone].ui_map_id, x: +(sp.x / 100).toFixed(4), y: +(sp.y / 100).toFixed(4), zoneName: T[sp.zone].target_name }; return null; };
  for (const c of base.special) {
    const qs = c.quests.map((id) => dbS.quests[id]).filter(Boolean);
    if (!qs.length || qs.every((q) => done.has(q.id))) continue;
    const steps = [], sections = [];
    let zone = null;
    const at = (sp, step) => {
      if (sp.zone !== zone) {
        sections.push({ title: sp.zoneName, zone: sp.zoneName });
        const hint = (c.travel || {})[sp.zoneName];
        if (zone !== null || hint) steps.push({ k: 'fly', dest: sp.zoneName, to: sp.m, text: sp.zoneName, sec: sections.length, note: hint || 'Fly, or ride if there is no flight path yet.' });
        zone = sp.zone;
      }
      steps.push({ ...step, m: sp.m, x: sp.x, y: sp.y, zone: sp.zoneName, r: 8, sec: sections.length });
    };
    // every pick-up, objective and hand-in is an action that waits for what it needs (a quest's prerequisites in this
    // trip, its own pick-up, its objectives); the next action is the one at the same spot, else in the same zone
    // (nearest), else in the zone with the most to do - so two quests from the same giver share every trip
    const inTrip = new Set(qs.map((q) => q.id));
    const acts = [];
    qs.forEach((q, i) => {
      if (done.has(q.id)) return;
      const from = spot(q.starters), to = spot(q.finishers);
      // no prerequisites in the data (the Cozy Sleeping Bag chain): the trip's own order is the chain
      const own = [...(q.preSingle || []), ...(q.preGroup || [])];
      const pre = (own.length ? own : i > 0 ? [qs[i - 1].id] : []).filter((p) => inTrip.has(p) && !done.has(p));
      const acc = { kind: 'accept', q, sp: from, needs: pre.map((p) => 'turnin:' + p), id: 'accept:' + q.id, order: i };
      if (from) acts.push(acc);
      const objIds = [], bring = [], elsewhere = [];
      (q.objectives || []).forEach((o, k) => {
        const src = o.kind === 'kill' ? [dbS.npcs[o.npc]] : [...(o.objectDrops || []).map((id) => dbS.objects[id]), ...(o.npcDrops || []).map((id) => dbS.npcs[id])];
        // a common drop (ensure-steps commonDrop: Linen Cloth) is no place to go; the hand-in says what to bring
        if (commonDrop(o)) { bring.push(o.name || 'the item'); return; }
        const sp = spot(src.filter(Boolean).map((x) => ({ name: x.name, spawns: x.spawns })));
        // an item with no place out in the world: it drops in a dungeon (Jordan's Smithing Hammer, Shadowfang Keep) or
        // the data has no source for it - the hand-in says so, not nothing (it was left out without a word)
        if (!sp && o.kind === 'item') { const who = uniq(src.filter(Boolean).map((x) => x.name)).slice(0, 2).join(' or '); elsewhere.push((o.name || 'an item') + (who ? ' (from ' + who + ', in a dungeon)' : ' (no source in the quest data)')); return; }
        if (!sp) return; // done where you hand in (a summon at the trainer)
        const id = 'obj:' + q.id + ':' + k; objIds.push(id);
        acts.push({ kind: 'obj', q, o, sp, needs: from ? [acc.id] : [], id, order: i });
      });
      if (to) acts.push({ kind: 'turnin', q, sp: to, needs: [...(from ? [acc.id] : []), ...objIds], id: 'turnin:' + q.id, order: i, bring, elsewhere });
    });
    const did = new Set(), dist2 = (a, b) => (a.x - b.x) ** 2 + (a.y - b.y) ** 2;
    let here = null, first = true;
    while (did.size < acts.length) {
      const ready = acts.filter((a) => !did.has(a.id) && a.needs.every((n) => did.has(n) || !acts.some((b) => b.id === n)));
      if (!ready.length) break;
      const zoneCount = {}; for (const a of ready) zoneCount[a.sp.zone] = (zoneCount[a.sp.zone] || 0) + 1;
      const rank = (a) => (here && a.sp.zone === here.zone ? dist2(a.sp, here) : 1e6 - zoneCount[a.sp.zone] * 1000 + a.order);
      const a = ready.sort((x, y) => rank(x) - rank(y))[0];
      const q = a.q;
      if (a.kind === 'accept') at(a.sp, { k: 'accept', q: q.id, name: q.name, npc: a.sp.who, level: q.level, note: first ? 'Click the ' + a.sp.who + ' to start it.' + (c.note ? '  ' + c.note : '') : (here && dist2(a.sp, here) === 0 ? 'The next part starts right here.' : undefined) });
      if (a.kind === 'obj') at(a.sp, { k: 'obj', q: q.id, name: q.name, text: a.o.kind === 'kill' ? 'Kill ' + ((dbS.npcs[a.o.npc] || {}).name || 'target') : 'Collect ' + (a.o.name || 'item'), match: a.o.kind === 'kill' ? (dbS.npcs[a.o.npc] || {}).name : a.o.name, loot: a.o.kind !== 'kill' || undefined, level: q.level });
      if (a.kind === 'turnin') at(a.sp, { k: 'turnin', q: q.id, name: q.name, npc: a.sp.who, level: q.level, note: 'Click the ' + a.sp.who + '.' + (a.bring && a.bring.length ? '  Bring ' + a.bring.join(', ') + ' (found all over: loot or gather it on the way, or buy it at the auction house).' : '') + (a.elsewhere && a.elsewhere.length ? '  Also needs ' + a.elsewhere.join(', ') + ': not on this route.' : ''), warn: a.elsewhere && a.elsewhere.length ? true : undefined });
      did.add(a.id); here = a.sp; first = false;
    }
    steps.forEach((x, i) => { x.id = i + 1; });
    const zones = new Set(steps.filter((x) => x.k === 'fly').map((x) => x.dest)).size;
    // a fixed id (c.id) survives renaming the trip: the player may be following it
    out.push({ id: c.id, name: c.name, tag: c.tag, why: c.why, inPath: !!c.inPath, minLevel: c.minLevel || 0, questNames: qs.map((q) => q.name), questLevel: Math.max(c.minLevel || 0, ...qs.map((q) => q.level)), needsLevel: c.minLevel || Math.max(...qs.map((q) => q.reqLevel || 1)),
      sections, steps, legs: [...new Set(sections.map((x) => x.title))], startLevel: (st && st.level) || base.level, endLevel: (st && st.level) || base.level, endXp: 0, minutes: c.minutes || zones * 12, choices: [] });
  }
  return out;
}

(async () => {
  const t0 = Date.now();
  const cpus = os.cpus().length;
  const rankOut = path.join(work, 'rank.json');
  if (!REUSE) await run({ ...base, workDir: path.join(work, 'work-rank'), rankOnly: true, rankOut, routeOut: path.join(work, 'rank.lua') }, 'rank');
  const ranked = JSON.parse(fs.readFileSync(rankOut, 'utf8'));
  // look ahead: which zones are worth doing one and two levels from now (the addon offers them when you level up)
  const curLevel = (() => { try { return require('./snapshot').loadCharState(base.charDir, relRoot(base.conversion)).level; } catch (e) { return base.level; } })() || base.level;
  const ahead = {};
  await Promise.all([1, 2].map(async (d) => {
    const L = curLevel + d, out = path.join(work, 'rank-' + L + '.json');
    if (!REUSE || !fs.existsSync(out)) await run({ ...base, forceLevel: L, workDir: path.join(work, 'work-rank-' + d), rankOnly: true, rankOut: out, routeOut: path.join(work, 'rank-' + L + '.lua') }, 'rank-' + L);
    try { ahead[L] = JSON.parse(fs.readFileSync(out, 'utf8')); } catch (e) {}
  }));
  const starts = ranked.slice(0, N);
  // a new character starts where its race starts (base.homeZone: Teldrassil for a night elf), not in the zone that ranks
  // best from nowhere - a fresh plan once sent a level-1 night elf to Dun Morogh
  if (base.homeZone) { const home = ranked.find((r) => r.z === base.homeZone) || { z: base.homeZone, name: String(base.homeZone), xph: 0, turnins: 0 }; const rest = starts.filter((r) => r.z !== base.homeZone); starts.length = 0; starts.push(home, ...rest); starts.length = Math.min(starts.length, N); }
  // a zone you asked for in game ("Start next in..."): it gets a path of its own, even if it isn't a top pick
  const convT = JSON.parse(fs.readFileSync(relRoot(base.conversion), 'utf8')).geometry.transforms;
  const reqName = base.requestZone;
  const reqT = reqName && convT.find((t) => t.target_name === reqName || t.target_name.startsWith(reqName));
  if (reqT && !starts.some((r) => r.z === reqT.area_id)) {
    const known = ranked.find((r) => r.z === reqT.area_id);
    starts[Math.min(starts.length, N - 1)] = known || { z: reqT.area_id, name: reqT.target_name, xph: 0, turnins: 0 };
  }
  // the zone the path you're following goes to next keeps a path of its own, so a replan never takes your path
  // away (it only drops out once that zone has nothing left for you)
  // your path's zones from the first one that still has something for you (finished zones drop off the front)
  const areaOfName = (n) => { const t = convT.find((x) => x.target_name === n); return t ? t.area_id : null; };
  let followLegs = (base.followLegs || []).slice();
  while (followLegs.length && !ranked.some((r) => r.z === areaOfName(followLegs[0]))) followLegs.shift();
  const folT = followLegs.length ? convT.find((t) => t.target_name === followLegs[0]) : (base.followZone && convT.find((t) => t.target_name === base.followZone));
  const fol = folT && ranked.find((r) => r.z === folT.area_id);
  if (fol && !starts.some((r) => r.z === fol.z && !r.follow)) {
    const slot = Math.max(0, Math.min(starts.length, N - 1) - (reqT && reqT.area_id !== fol.z ? 1 : 0));
    starts[slot] = fol; console.log('keeping a path that starts in ' + fol.name + ' (the one you are following)');
  }
  // that slot follows your zone order exactly
  if (fol && followLegs.length) {
    const fi = starts.findIndex((r) => r.z === fol.z);
    if (fi >= 0) { starts[fi] = { ...starts[fi], follow: true }; console.log('your path keeps its zone order: ' + followLegs.join(' > ') + ' (a zone is only replaced when it is no longer worth doing: finished, or outlevelled)'); }
  }
  // beam search (background full pass): the best whole zone orders it finds replace the other paths; yours stays locked
  if (base.beam && !REUSE) {
    const beamOut = path.join(work, "beam.json");
    await run({ ...base, beamOut, workDir: path.join(work, "work-beam") }, "beam");
    const routes = (() => { const x = readJson(beamOut); return Array.isArray(x) ? x : []; })();
    let slot = 0;
    for (const r of routes) {
      while (slot < starts.length && starts[slot] && (starts[slot].follow || (reqT && starts[slot].z === reqT.area_id))) slot++;
      if (slot >= N) break;
      if (starts.some((x) => x.forceOrder && x.forceOrder.join() === r.legs.join())) continue;
      // your path keeps its first two zones and re-plans the rest, so a beam route starting the same way would come out
      // as the same path twice - offer a different one
      const folTwo = (fol && followLegs.length ? followLegs.slice(0, 2).map(areaOfName).filter(Boolean) : []).join();
      if (folTwo && r.legs.slice(0, 2).join() === folTwo) continue;
      starts[slot] = { z: r.legs[0], name: r.names[0], xph: r.xph, turnins: 0, forceOrder: r.legs };
      console.log("beam route " + (slot + 1) + ": " + r.names.join(" > ") + " (" + r.xph + " xp/h)");
      slot++;
    }
  }
  const requestedZ = reqT ? reqT.area_id : null;
  console.log('first-zone options: ' + starts.map((r) => `${r.name} (${r.xph} xp/h)`).join(', '));
  // dungeon prep routes: one per dungeon worth doing around this level. They depend only on your state, not on the
  // paths, so they run at the same time as the path planning instead of after it
  const dungeonsP = (async () => {
    // dungeon prep routes: one per dungeon worth doing around this level
    let dungeons = [];
    if (base.reuseDungeons && fs.existsSync(base.reuseDungeons)) { dungeons = readJson(base.reuseDungeons) || []; console.log('dungeon routes reused from the last full plan'); }
    else if (base.dungeonPrep !== false && base.dungeonFile) {
      const dcfg = { addonsDir: base.addonsDir, itemsJson: base.itemsJson, keepRewardValue: base.keepRewardValue, db: base.db, conversion: base.conversion, dungeonFile: base.dungeonFile, charDir: base.charDir, dungeon: base.prepDungeons || 'auto', levelSlack: base.prepLevelSlack ?? 5, aheadLevels: base.prepAheadLevels ?? 12, out: path.join(work, 'dungeons.json') };
      const f = path.join(work, 'dungeon-prep.json'); fs.writeFileSync(f, JSON.stringify(dcfg));
      await new Promise((res) => { const pr = spawn(process.execPath, [path.join(__dirname, 'dungeon-prep.js'), f], { stdio: ['ignore', 'pipe', 'pipe'], cwd: ROOT }); try { os.setPriority(pr.pid, 19); } catch (e) {} let o = ''; pr.stdout.on('data', (d) => (o += d)); pr.stderr.on('data', (d) => (o += d)); pr.on('close', () => { fs.writeFileSync(path.join(work, 'dungeon-prep.log'), o); process.stdout.write(o); res(); }); });
      dungeons = readJson(dcfg.out) || [];
    }
  
      return dungeons;
  })();
  // each path gets its share of the cores (one path got half of them: a built-in plan ran on 2 of 8)
  if (!REUSE) await Promise.all(starts.map((r, k) => run({ ...base, firstZone: r.z, ...(r.follow ? { forceLegs: followLegs.map(areaOfName).filter(Boolean) } : r.forceOrder ? { forceLegs: r.forceOrder } : {}), workDir: path.join(work, 'work-' + k), parallel: Math.max(1, Math.floor((base.parallel || 3) / Math.max(1, starts.length))), routeOut: path.join(work, `path-${k}.lua`), pathOut: path.join(work, `path-${k}.json`) }, `path-${k}`)));
  const paths = starts.map((r, k) => { const j = readJson(path.join(work, `path-${k}.json`)); if (j) j.slot = k; return j; }).filter(Boolean).map(finish);
  // the recommended path is the most enjoyable one, not the quickest: story chains, worthwhile rewards and dungeons
  // count for it; quests with a heads-up (escorts, bad drops...), going back to zones you've done and flight time
  // count against; hours only count lightly
  {
    const db = JSON.parse(fs.readFileSync(relRoot(base.db), 'utf8'));
    const qual = require('./quality').makeQuality({ quests: db.quests, npcs: db.npcs, objects: db.objects, items: JSON.parse(fs.readFileSync(relRoot(base.itemsJson), 'utf8')), cls: base.class });
    for (const p of paths) {
      const ids = [...new Set(p.steps.filter((s) => s.q > 0 && s.k === 'turnin').map((s) => s.q))];
      let frust = 0, heads = 0, story = 0, rewards = 0;
      for (const id of ids) { const q = db.quests[id]; if (!q) continue; const v = qual(q, p.startLevel); frust += v.frustration; if (v.frustration >= 0.3) heads++; if (v.tags.includes('story chain')) story++; if (v.rewardValue) rewards++; }
      const distinct = new Set(p.legs).size, revisits = p.legs.length - distinct;
      const dungeons = p.steps.filter((s) => s.k === 'goto' && /^Run /.test(s.text || '')).length, flights = p.steps.filter((s) => s.k === 'fly').length;
      p.fun = { story, rewards, dungeons, heads, revisits, flights, zones: distinct };
      p.enjoy = story + rewards * 4 + dungeons * 6 + distinct * 2 - frust * 6 - revisits * 3 - flights - (p.minutes / 60) * 2;
    }
  }
  paths.sort((a, b) => b.enjoy - a.enjoy);
  paths.forEach((p) => { p.id = 'path:' + uniq(p.legs).map(slug).join('-'); });
  // the path you follow keeps its id (unless another path happens to end up with exactly that id)
  starts.forEach((r, k) => { const pp = paths.find((x) => x.slot === k); if (r.follow && pp && base.followId && !paths.some((x) => x !== pp && x.id === base.followId)) { pp.id = base.followId; pp.followed = true; } });
  if (requestedZ) for (const p of paths) if (p.legs[0] === convT.find((t) => t.area_id === requestedZ).target_name) p.requested = reqT.target_name;
  console.log(`main paths done in ${Math.round((Date.now() - t0) / 1000)}s`);

  // zone routes: one ready-made route for each of the best zones at your level (the trip there, pick-ups on the way
  // that start the zone, the zone's quests), so in game you can go to any of them at once - a zone too crowded, or just
  // a change - without waiting for a replan. The next replan then builds your whole path from the zone you picked.
  const zoneJobs = ranked.slice(0, base.zoneRoutes ?? 6).map((r) => ({ z: r.z, name: r.name, xph: r.xph, tag: 'zone-' + r.z, pathOut: path.join(work, 'zone-' + r.z + '.json') }));
  await pool(zoneJobs, Math.max(1, Math.floor((cpus - 1) / 2)), async (j) => {
    if (!REUSE || !fs.existsSync(j.pathOut)) await run({ ...base, firstZone: j.z, forceLegs: [j.z], maxLegs: 1, parallel: 2, optimizeSeconds: base.optimizeSeconds || 5,
      workDir: path.join(work, 'work-' + j.tag), routeOut: path.join(work, j.tag + '.lua'), pathOut: j.pathOut }, j.tag);
    j.route = readJson(j.pathOut); if (j.route) finish(j.route);
  });
  console.log('zone routes: ' + zoneJobs.filter((j) => j.route).map((j) => j.name + ' (' + j.route.steps.length + ' steps)').join(', '));

  // branches: at every later zone boundary, each runner-up zone within reach of the pick gets its own plan from there
  const jobs = [];
  for (const [pk, p] of paths.entries()) {
    for (const c of p.choices || []) {
      if (c.leg < 2 || !c.options) continue;
      const chosen = c.options.find((o) => o.z === c.chosen);
      const bar = (chosen ? chosen.xph : 0) * (base.branchMinShare ?? 0.6);
      const alts = c.options.filter((o) => o.z !== c.chosen && o.xph >= bar).slice(0, ALTS);
      c.alts = [];
      for (const o of alts) {
        const tag = `branch-${pk}-${c.leg}-${o.z}`;
        const job = { p, c, o, tag, pathOut: path.join(work, tag + '.json') };
        c.alts.push(job); jobs.push(job);
      }
    }
  }
  const conc = Math.max(1, Math.floor((cpus - 1) / 2));
  console.log(`planning ${jobs.length} branches, ${conc} at a time`);
  let done = 0;
  await pool(jobs, conc, async (j) => {
    if (!REUSE || !fs.existsSync(j.pathOut)) await run({ ...base, startStateFile: j.c.beforeFile, firstZone: j.o.z, maxLegs: base.maxLegs || 12, parallel: 2, optimizeSeconds: base.branchOptimizeSeconds || base.optimizeSeconds || 10,
      workDir: path.join(work, 'work-' + j.tag), routeOut: path.join(work, j.tag + '.lua'), pathOut: j.pathOut }, j.tag);
    j.route = readJson(j.pathOut); if (j.route) finish(j.route);
    done++; console.log(`  [${done}/${jobs.length}] ${j.tag}: ${j.route ? uniq(j.route.legs).join(' > ') + ` -> ${j.route.endLevel}` : 'failed'}`);
  });

  // (dungeon routes were started alongside the path planning; collect them now)
  let dungeons = await dungeonsP;

  // write Route.lua
  const lua = (v) => (typeof v === 'string' ? JSON.stringify(v) : String(v));
  const ser = (o) => '{ ' + Object.entries(o).filter(([, v]) => v !== undefined && v !== null).map(([k, v]) => k + ' = ' + lua(v)).join(', ') + ' }';
  const svTime = process.env.FR_FROM_SAVE ? +process.env.FR_FROM_SAVE : (() => { try { return Math.floor(fs.statSync(path.join(base.charDir, 'ForeverRoute.lua')).mtimeMs / 1000); } catch (e) { return 0; } })();
  const L = ['-- Generated by the Forever Route path planner on ' + new Date().toISOString() + '. Regenerate rather than edit.', 'ForeverRoutePlan = { generated = ' + Math.floor(Date.now() / 1000) + ', fromSave = ' + svTime + (reqName ? ', requested = ' + JSON.stringify(reqName) : '') + ', zones = { ' + ranked.map((r) => '{ name = ' + JSON.stringify(r.name) + ', xph = ' + r.xph + ', turnins = ' + r.turnins + ' }').join(', ') + ' }, ahead = { ' + Object.entries(ahead).map(([L, zs]) => '[' + L + '] = { ' + zs.map((r) => '{ name = ' + JSON.stringify(r.name) + ', xph = ' + r.xph + ' }').join(', ') + ' }').join(', ') + ' }, level = ' + curLevel + ', later = { ' + [...new Set(paths.flatMap((p) => p.legs))].filter((z) => !ranked.some((r) => r.name === z)).map((z) => JSON.stringify(z)).join(', ') + ' } }', 'ForeverRouteRoutes = {'];
  const emit = (r, title, id, extra, choices) => {
    const fixed = ensure(r.steps); ensured += fixed.added; droppedCarry += fixed.dropped || 0;
    // a choice point is the step campaign.js marked at the zone boundary, wherever the safety net moved it; the
    // number from the campaign only counts when no step carries the mark (an older plan)
    for (const ch of choices || []) { const a = fixed.choiceAt(ch.leg); if (a) ch.at = a; else console.log('choice point for leg ' + ch.leg + ' of ' + id + ' has no marked step; keeping step ' + ch.at); }
    L.push('  {');
    L.push('    id = ' + lua(id) + ',');
    L.push('    title = ' + lua(title) + ',');
    for (const [k, v] of Object.entries(extra)) L.push(`    ${k} = ${lua(v)},`);
    // hours to a common level (the plan target), so paths that end at different levels compare fairly
    const lv = (r.endLevel + (XP[r.endLevel] ? r.endXp / XP[r.endLevel] : 0)) - r.startLevel, toT = (base.targetLevel || 30) - r.startLevel;
    const hT = lv > 0 ? (r.minutes / 60) * Math.max(0, toT) / lv : r.minutes / 60;
    L.push('    meta = { character = ' + lua(base.character || 'Testchar') + ', startLevel = ' + r.startLevel + ', endLevel = ' + lua(r.endLevel + ' (' + (XP[r.endLevel] ? Math.round(100 * r.endXp / XP[r.endLevel]) : 100) + '%)') + ', hours = ' + (r.minutes / 60).toFixed(1) + ', hoursTo = ' + hT.toFixed(1) + ', target = ' + (base.targetLevel || 30) + ', legs = ' + lua(r.legs.join(' > ')) + (r.dropped && r.dropped.length ? ', dropped = ' + lua(r.dropped.join(', ')) : '') + ' },');
    if (choices && choices.length) {
      L.push('    choices = {');
      for (const ch of choices) L.push('      { at = ' + ch.at + ', level = ' + ch.level + ', options = { ' + ch.options.map((o) => ser(o)).join(', ') + ' } },');
      L.push('    },');
    }
    L.push('    sections = {'); for (const s of r.sections) L.push('      ' + ser(s) + ','); L.push('    },');
    // branches and dungeon routes are stored packed (one string) and unpacked in game only when picked: most of
    // the plan is routes you never take, and a string is a fraction of the memory of the same steps as tables
    const qids = [...new Set(fixed.filter((x) => x.q > 0).map((x) => x.q))].join(',');
    if (extra.branch || extra.dungeon) {
      L.push('    questIds = ' + lua(qids) + ',', '    stepCount = ' + fixed.length + ',', '    packed = [==['); L.push({ steps: fixed, packed: true }); L.push(']==],');
    } else { L.push('    steps = {'); L.push({ steps: fixed }); L.push('    },'); } // steps written after waypoints are added
    L.push('  },');
    return fixed;
  };
  let nb = 0, ensured = 0, droppedCarry = 0;
  // class quests you can't level without (the Voidwalker, the Succubus: cfg.special with inPath) go into every path as
  // a leg of their own, at the first zone change once you're their level - not left as a side trip that waits until
  // it happens to be on the way (the Succubus chain never is: Stormwind > the Barrens > Ashenvale > Stormwind)
  const SPECIALS = specialRoutes();
  function spliceInPath(p) {
    for (const r of SPECIALS.filter((x) => x.inPath)) {
      // once its hardest quest is within the level gate too (Poisons opens at 20, Klaven's Tower is a level-24 quest)
      const need = Math.max(r.minLevel, (r.questLevel || 0) - require('./world').LEVEL_ABOVE);
      let at = p.steps.findIndex((x, i) => i > 0 && x.k === 'fly' && (x.lvl || p.steps[i - 1].lvl || 0) >= need);
      if (at < 0) { const last = p.steps[p.steps.length - 1]; if (!last || (last.lvl || 0) < need) continue; at = p.steps.length; }
      // only what the path does before this point counts as done: a later pickup of the same quest (Elanaria is also
      // offered in Darkshore, at 16) left the chain's hand-in here without its accept
      const have = new Set(p.steps.slice(0, at).filter((x) => x.q).map((x) => x.k + ':' + x.q));
      const add = r.steps.filter((x) => !(x.q && have.has(x.k + ':' + x.q)));
      if (!add.some((x) => x.q)) continue; // already in the path (or done)
      // the path's own later steps for the same quests would now be done twice: drop them
      const mine = new Set(add.filter((x) => x.q).map((x) => x.k + ':' + x.q));
      for (let i = p.steps.length - 1; i >= at; i--) if (p.steps[i].q && mine.has(p.steps[i].k + ':' + p.steps[i].q)) {
        const [gone] = p.steps.splice(i, 1);
        if (gone._choice !== undefined && p.steps[i] && p.steps[i]._choice === undefined) p.steps[i]._choice = gone._choice; // keep the zone-boundary mark
      }
      const off = p.sections.length;
      p.sections.push(...r.sections.map((x) => ({ ...x, title: x.title + ' (' + r.name + ')' })));
      const lvl = (p.steps[at - 1] && p.steps[at - 1].lvl) || r.minLevel;
      p.steps.splice(at, 0, ...add.map((x) => ({ ...x, sec: x.sec + off, lvl, note: x.note ? x.note : 'Class quest: ' + r.name + '.' })));
      console.log('  in the path: ' + r.name + ' (' + add.length + ' steps) before step ' + (at + 1) + ' of ' + p.id);
    }
  }
  paths.forEach((p) => spliceInPath(p));
  paths.forEach((p, k) => {
    const choices = [];
    for (const c of p.choices || []) {
      const ok = (c.alts || []).filter((j) => j.route);
      if (!ok.length) continue;
      const stay = c.options.find((o) => o.z === c.chosen) || { name: p.legs[c.leg - 1], xph: 0 };
      const after = p.legs.slice(c.leg - 1);
      const opts = [{ zone: stay.name, xph: stay.xph, next: uniq(after).slice(0, 4).join(' > '), endLevel: p.endLevel, main: true }];
      for (const j of ok) {
        j.id = 'branch:' + slug(p.id) + ':' + c.leg + ':' + slug(j.o.name);
        opts.push({ zone: j.o.name, xph: j.o.xph, next: uniq(j.route.legs).slice(0, 4).join(' > '), endLevel: j.route.endLevel, route: j.id });
      }
      choices.push({ at: c.at, leg: c.leg, level: c.level, options: opts });
    }
    emit(p, uniq(p.legs).slice(0, 4).join(' · '), p.id, { best: k === 0, requested: p.requested, story: p.fun.story, rewards: p.fun.rewards, dungeons: p.fun.dungeons, headsUp: p.fun.heads, revisits: p.fun.revisits, flights: p.fun.flights, enjoy: Math.round(p.enjoy) }, choices);
    for (const c of p.choices || []) for (const j of (c.alts || []).filter((x) => x.route)) {
      // a branch hands back the main path's choice once it rejoins; it just carries its own steps from the boundary on
      // (branchAt is the main path's choice step as written above, so the addon finds the choice from the branch)
      const at = (choices.find((x) => x.leg === c.leg) || c).at;
      emit(j.route, `${j.o.name} instead of ${p.legs[c.leg - 1]} (after ${p.legs[c.leg - 2]})`, j.id, { branch: true, parent: p.id, parentTitle: uniq(p.legs).slice(0, 4).join(' · '), branchAt: at }, null);
      nb++;
    }
  });
  for (const d of dungeons) {
    emit({ ...d, endLevel: d.startLevel, endXp: 0 }, 'Dungeon: ' + d.name + (d.variant ? ' (quick)' : ''), 'dungeon:' + slug(d.name) + (d.variant ? ':quick' : ''), { dungeon: true, dungeonName: d.name, variant: d.variant, cut: d.cut ? d.cut.join(', ') : undefined, questLevel: d.questLevel, needsLevel: d.needsLevel, quests: d.quests.join(', '), chainCount: d.chainQuests.length, xp: d.xp }, null);
  }
  for (const j of zoneJobs) if (j.route) emit(j.route, 'Zone: ' + j.name, 'zone:' + slug(j.name), { zoneRoute: true, zoneName: j.name, xph: j.xph }, null);
  for (const r of SPECIALS) emit(r, 'Special: ' + r.name, 'special:' + (r.id || slug(r.name)), { dungeon: true, special: true, dungeonName: r.name, tag: r.tag, why: r.why, questLevel: r.questLevel, needsLevel: r.needsLevel, quests: r.questNames.join(', '), chainCount: 0 }, null);
  L.push('}');
  // where each quest in your log is handed in, so the addon can slot in a hand-in for a quest you finished that the
  // route doesn't cover (no replan needed)
  {
    const dbE = JSON.parse(fs.readFileSync(relRoot(base.db), 'utf8'));
    const convE = JSON.parse(fs.readFileSync(relRoot(base.conversion), 'utf8')).geometry.transforms;
    const uiOf = Object.fromEntries(convE.map((t) => [t.area_id, t.ui_map_id]));
    let st = null; try { st = require('./snapshot').loadCharState(base.charDir, relRoot(base.conversion)); } catch (e) {}
    // every quest you could have in your log before the next replan: the ones there now, and any your character can
    // take up to a few levels past the plan's target (picked up off the plan - a Goldshire errand - still gets its
    // hand-in slotted in live). Done ones are left out.
    const { canTake } = require('./world');
    const done = new Set((st && st.completed) || []);
    const maxLvl = (base.targetLevel || 60) + 5;
    const ids = [...new Set([...Object.keys((st && st.log) || {}).map(Number),
      ...Object.values(dbE.quests).filter((q) => q.level > 0 && q.level <= maxLvl && !done.has(q.id) && canTake(q, base.race, base.class)).map((q) => q.id)])];
    const rows = [];
    for (const id of ids) {
      const q = dbE.quests[id]; if (!q) continue;
      const f = q.finishers.find((x) => (x.spawns || []).some((s) => s.x >= 0 && uiOf[s.zone]));
      if (!f) continue;
      const sp = f.spawns.find((s) => s.x >= 0 && uiOf[s.zone]);
      rows.push('  [' + id + '] = { npc = ' + JSON.stringify(f.name) + ', m = ' + uiOf[sp.zone] + ', x = ' + (sp.x / 100).toFixed(4) + ', y = ' + (sp.y / 100).toFixed(4) + ', name = ' + JSON.stringify(q.name) + ' },');
    }
    L.push('ForeverRouteEnders = {', ...rows, '}');
    // chains: for each quest on a route, the later quests on that route that need it (directly or further down) -
    // the addon warns before you drop a quest that others depend on
    const onRoute = new Set(); for (const x of L) if (typeof x === 'object') for (const st2 of x.steps) if (st2.q > 0) onRoute.add(st2.q);
    const needs = {}; // quest -> quests it directly unlocks
    for (const q of Object.values(dbE.quests)) if (onRoute.has(q.id)) for (const pre of [...(q.preSingle || []), ...(q.preGroup || [])]) (needs[pre] = needs[pre] || []).push(q.id);
    const unl = [];
    for (const qid of onRoute) {
      const seen = new Set(), stack = [...(needs[qid] || [])];
      while (stack.length) { const x = stack.pop(); if (seen.has(x)) continue; seen.add(x); stack.push(...(needs[x] || [])); }
      if (seen.size) unl.push('  [' + qid + '] = { ' + [...seen].join(', ') + ' },');
    }
    L.push('ForeverRouteUnlocks = {', ...unl, '}');
  }
  // walking waypoints (terrain + buildings) for every step, so the arrow can follow the real path
  if (base.terrainDir && base.waypoints !== false) {
    const { addWaypoints } = require('./waypoints');
    const acct = base.accountSV || (base.charDir && path.resolve(base.charDir, '../../../SavedVariables/ForeverRoute.lua'));
    if (acct) { const t = require('./trails').importTrails(acct, relRoot(base.conversion), relRoot(base.terrainDir)); if (Object.keys(t).length) console.log('city walking trails: ' + JSON.stringify(t)); }
    const lists = L.filter((x) => typeof x === 'object');
    const db = JSON.parse(fs.readFileSync(relRoot(base.db), 'utf8'));
    const conv = JSON.parse(fs.readFileSync(relRoot(base.conversion), 'utf8')).geometry.transforms;
    const n = await addWaypoints(lists, { terrainDir: relRoot(base.terrainDir), conv, db, cacheFile: base.waypointsCache ? relRoot(base.waypointsCache) : path.join(work, 'waypoints-cache.json'), workers: Math.max(1, Math.min(base.waypointsCache ? cpus - 1 : 6, cpus - 2)), log: (m) => console.log(m) });
    console.log(`waypoints: ${n} steps have a walking path`);
  }
  const text = L.flatMap((x) => (typeof x === 'string' ? [x] : x.steps.map((s, i) => { const { ensured: _e, _choice: _c, ...rest } = s; return '      ' + ser({ ...rest, id: i + 1 }) + ','; })));
  const out = base.routesOut || path.join(work, 'Route.lua');
  fs.writeFileSync(out, text.join('\n') + '\n');
  for (const p of paths) console.log(`  ${uniq(p.legs).join(' > ')}: ${p.startLevel} -> ${p.endLevel} (${XP[p.endLevel] ? Math.round(100 * p.endXp / XP[p.endLevel]) : 100}%), ~${(p.minutes / 60).toFixed(1)} h, ${p.steps.length} steps, ${(p.choices || []).filter((c) => (c.alts || []).some((j) => j.route)).length} choice points`);
  console.log(`safety net: ${ensured} accept/objective steps added for quests already in your log; ${droppedCarry} quests left out (picked up but never handed in on that route)`);
  console.log(`wrote ${paths.length} paths + ${nb} branches + ${dungeons.length} dungeon routes -> ${out} in ${Math.round((Date.now() - t0) / 1000)}s`);
  process.exit(0); // everything above is written synchronously; don't let a stray handle keep the process alive
})();
