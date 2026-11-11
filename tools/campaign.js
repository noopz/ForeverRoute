const { raceOk } = require('./world'); // race masks above bit 32 (Skyborne)
// Campaign planner: chains zone legs from the character's current state toward a target level.
// Each leg: evaluate every candidate zone in parallel (quick plan, no optimizer), score XP per hour including the trip
// there, pick the best, plan it properly (optimizer on), carry the end state (level, completed, quests in log) forward.
// Writes one combined Route.lua for the addon.
// usage: node campaign.js <campaign.json>
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');
const { loadCharState } = require('./snapshot');

const cfg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const ROOT = path.resolve(__dirname, '..');
const work = cfg.workDir ? path.resolve(cfg.workDir) : path.join(ROOT, 'campaign'); fs.mkdirSync(work, { recursive: true });
const db = JSON.parse(fs.readFileSync(cfg.db, 'utf8'));
const conv = JSON.parse(fs.readFileSync(cfg.conversion, 'utf8')).geometry.transforms;
const zoneName = Object.fromEntries(conv.map((t) => [t.area_id, t.target_name]));
const uiMap = Object.fromEntries(conv.map((t) => [t.area_id, t.ui_map_id]));
const continent = Object.fromEntries(conv.map((t) => [t.area_id, t.map_id]));
const CITIES = new Set([1519, 1537, 1657, 1497, 1637, 1638]);
const { XP_TO_LEVEL, RACE_BIT, CLASS_BIT, CAPITAL_MAPS, LEVEL_ABOVE } = require('./world'); // the game's rules, shared by every stage


// starting state
let st = loadCharState(cfg.charDir, cfg.conversion) || {};
// hearthstone cooldown left when the game saved, minus the time since
const cdNow = st.hearthCd > 0 && st.time ? Math.max(0, Math.round(st.hearthCd - (Date.now() / 1000 - st.time))) : 0;
let state = { hearthCd: cdNow, level: st.level || cfg.level, xp: st.xp || 0, completed: st.completed || [], active: st.log || {}, pos: st.pos || null, zone: st.pos ? st.pos.zone : cfg.startZone };
if (cfg.startStateFile) { const b = JSON.parse(fs.readFileSync(cfg.startStateFile, 'utf8')); state = b.state; st = { ...st, level: b.state.level, pos: b.state.pos, branchFrom: b.state.zone }; }
if (cfg.forceLevel) { state.level = cfg.forceLevel; state.xp = 0; } // look-ahead ranking: score zones as if you were this level
const race = st.race || cfg.race, klass = st.class || cfg.class;
// your race's start zone: you finish it before going anywhere else - its first return (Razor Hill after the Valley of
// Trials, Goldshire after Northshire) is not a revisit, and other races' start zones are not yours to level in (an orc was
// sent from Durotar to Tirisfal at 6 and Zephras Isle at 12; a human from Elwynn to Dun Morogh)
const { RACE_HOME, START_ZONES } = require('./world');
const HOME = cfg.homeZone ?? RACE_HOME[race];
const visitsAt = (z, n, level) => (z === HOME && level < 12 ? Math.max(0, n - 1) : n);
console.log(`${st.name || 'character'}: ${race} ${klass}, level ${state.level}, ${state.completed.length} quests done  [${st.source || 'config'}]`);

// zone level bands from quest data (for this race), to shortlist candidates
const band = {};
for (const q of Object.values(db.quests)) {
  if (q.races && !raceOk(q.races, race)) continue;
  if (q.special & 3 || q.level <= 0 || q.level > 60) continue;
  for (const s of q.starters) for (const sp of s.spawns || []) if (zoneName[sp.zone]) (band[sp.zone] = band[sp.zone] || []).push(q.level);
}
const median = (a) => { const b = [...a].sort((x, y) => x - y); return b[b.length >> 1]; };
// battlegrounds are not a questing leg: their quests need a 40-player PvP match won (Alterac Valley's "Defeat Drek'thar"
// ended every built-in plan, timed as if it were a zone)
const BATTLEGROUNDS = new Set([2597, 3277, 3358]); // Alterac Valley, Warsong Gulch, Arathi Basin
function candidates(level) {
  const zones = Object.entries(band).filter(([z, ls]) => !CITIES.has(+z) && !BATTLEGROUNDS.has(+z) && !(START_ZONES.has(+z) && +z !== HOME && !cfg.allowOtherStartZones) && ls.filter((l) => l >= level - 2 && l <= level + 4).length >= 6).map(([z]) => +z);
  // dungeons at your level: their entrance zone is a leg too (its region brings the quests' givers)
  for (const d of (typeof dungeonLegsAt === 'function' ? dungeonLegsAt(level) : [])) if (!zones.includes(d.entrance) && !CITIES.has(d.entrance)) zones.push(d.entrance);
  return zones;
}
// travel overhead to a zone (minutes): same zone 0, same continent ~6, other continent ~18 (boat)
// flight paths you have (snapshot node names like "Lakeshire, Redridge"); a zone without one costs a ride from the
// nearest one you have. Planning a zone gets you its flight path (the arrival tour), so later legs count it as known.
const knownFP = new Set();
const fpName = (z) => (zoneName[z] || '').toLowerCase();
function hasFP(z) {
  if (knownFP.has(z)) return true;
  const n = fpName(z), first = n.split(' ')[0];
  return (st.taxi || []).some((t) => { t = String(t).toLowerCase(); return t.includes(n) || (first.length >= 5 && t.includes(first)); });
}
const hopFlat = (from, to) => (from === to ? 0 : (continent[from] === continent[to] ? (cfg.hopMin ?? 12) : (cfg.boatHopMin ?? 25)) + (hasFP(to) ? 0 : (cfg.rideMin ?? 8)));
// the trip to a zone (minutes) over the same travel graph as the addon's arrow (tools/travel.js): your flight paths,
// boats, the walk-map ride network, and no riding through zones far above your level. A zone you can't reach safely
// costs NO_WAY minutes, so it is never picked.
const travel = require('./travel');
travel.init(cfg.conversion);
const NO_WAY = 600;
function hop(S, to) {
  const from = S.zone; if (from === to) return 0;
  const m2 = travel.uiOfArea(to), p = S.pos, m1 = travel.uiOfArea(p && p.zone ? p.zone : from);
  if (!m1 || !m2) return hopFlat(from, to);
  const knownFP = new Set(Object.keys(zoneName).map(Number).filter((z) => hasFP(z)).map((z) => travel.uiOfArea(z)).filter(Boolean));
  const start = p && p.zone ? { m: m1, x: p.x / 100, y: p.y / 100 } : travel.arrival(m1, cfg.faction);
  const r = travel.plan(start, travel.arrival(m2, cfg.faction), { level: S.level, knownFP, race, class: klass, faction: cfg.faction });
  return r ? 2 + r.sec / 60 : NO_WAY;
}
// a level of grinding where there's nothing to quest: in the best-scored zone (else any candidate), at the densest
// spot of hostile mobs around your level (the quest database's spawns), for the kills a level takes at
// your kill speed. Returns a leg like a planned one: one "grind" step the addon ticks when you reach the level.
function grindLeg(S, evals, cands) {
  const W = require('./world');
  if (LEARNED) W.setLearned(LEARNED);
  const L = S.level;
  for (const z of [...evals.map((e) => e.z), ...cands]) {
    const pts = [];
    for (const n of Object.values(db.npcs)) {
      if (!n || n.friendly === 'A' || n.friendly === 'AH' || n.friendly === 'H' || !(n.minLevel <= L + 1 && n.maxLevel >= L - 1) || n.rank === 1) continue;
      for (const p of n.spawns || []) if (p.zone === z && p.x >= 0) pts.push(p);
    }
    if (pts.length < 15) continue; // not enough to grind on
    let best = null, bestN = -1;
    for (const p of pts) { let k = 0; for (const q of pts) if (Math.abs(p.x - q.x) < 6 && Math.abs(p.y - q.y) < 6) k++; if (k > bestN) { best = p; bestN = k; } }
    const perKill = W.killXp(L, L) || 1;
    const kills = Math.ceil((XP_TO_LEVEL[L] - (S.xp || 0)) / perKill);
    const sec = (LEARNED && LEARNED.secPerKill) || cfg.secPerKill || 22;
    const minutes = Math.round((kills * sec) / 60 + hop(S, z));
    const nm = zoneName[z];
    const step = { k: 'grind', text: 'Grind mobs around your level until ' + (L + 1), level: L + 1, xp: 0, m: uiMap[z], x: +(best.x / 100).toFixed(4), y: +(best.y / 100).toFixed(4), zone: nm, r: 60, sec: 1, lvl: L,
      note: `No quests worth the trip at level ${L}: about ${kills} kills here gets you to ${L + 1}, where more open up. A dungeon run does it too.` };
    const leg = { title: nm + ' ' + L + '+ (grind)', sections: [{ title: 'Grind in ' + nm }], steps: [step] };
    return { zone: z, leg, state: { level: L + 1, xp: 0, minutes, pos: { zone: z, x: best.x, y: best.y }, completed: S.completed, active: S.active }, options: [], levelBefore: L, grind: true, here: true }; // here: not a "where next?" choice
  }
  return null;
}
// ---------- regions ----------
// A leg is a zone plus the neighbours its quests reach into: where a chain goes on or came from, where the objectives
// are, where you hand in (Hillsbrad's quests send you into Alterac and Arathi; Duskwood's chains run through
// Stormwind). Planned one zone at a time, those quests were dropped ("needs an earlier quest that is not in this
// plan", "objectives outside the planned zones") and the 30s looked empty - the plan hopped zones for scraps.
// A neighbour joins when at least REGION_MIN_LINKS quests you can do now reach into it (same continent, at most
// REGION_MAX of them, the most-linked first). Cities count like any zone.
const REGION_MIN_LINKS = cfg.regionMinLinks ?? 2, REGION_MAX = cfg.regionMax ?? 2;
const BYNAME = {}; // quests by name: Forever's per-race copies of one quest
for (const q of Object.values(db.quests)) if (q && q.name) (BYNAME[q.name] = BYNAME[q.name] || []).push(q);
const followersOf = {};
for (const q of Object.values(db.quests)) for (const p of [...(q.preSingle || []), ...(q.preGroup || [])]) (followersOf[p] = followersOf[p] || []).push(q.id);
function mainZone(spawns) {
  const n = {}; for (const p of spawns || []) if (p && p.zone) n[p.zone] = (n[p.zone] || 0) + 1;
  let best = null; for (const z in n) if (best === null || n[z] > n[best]) best = z;
  return best === null ? null : +best;
}
const starterZone = (q) => (q && q.starters && q.starters[0] ? mainZone(q.starters[0].spawns) : null);
// which zones share a border (the travel network's crossings, as quest-data area ids); cities are hubs you fly to
const areaOfUi = Object.fromEntries(conv.map((t) => [t.ui_map_id, t.area_id]));
const neighbours = {};
try {
  for (const n of JSON.parse(fs.readFileSync(path.join(__dirname, 'travel-net.json'), 'utf8')).nodes || []) {
    if (n.kind !== 'cross' || !n.m2) continue;
    const a = areaOfUi[n.m], b = areaOfUi[n.m2]; if (!a || !b) continue;
    (neighbours[a] = neighbours[a] || new Set()).add(b); (neighbours[b] = neighbours[b] || new Set()).add(a);
  }
} catch (e) {}
const nearby = (z, w) => CITIES.has(w) || (neighbours[z] && neighbours[z].has(w));
function questZones(q, done, level) {
  const out = new Set();
  const add = (z) => { if (z) out.add(z); };
  for (const f of q.finishers || []) add(mainZone(f.spawns));
  for (const o of q.objectives || []) {
    const sp = [];
    if (o.kind === 'kill' && db.npcs[o.npc]) sp.push(...db.npcs[o.npc].spawns);
    if (o.kind === 'killcredit') for (const id of o.npcs || []) if (db.npcs[id]) sp.push(...db.npcs[id].spawns);
    if (o.kind === 'item') { for (const n of require('./world').droppers(o, db.npcs)) sp.push(...n.spawns); for (const id of o.objectDrops || []) if (db.objects[id]) sp.push(...db.objects[id].spawns); }
    if (o.kind === 'object' && db.objects[o.object]) sp.push(...db.objects[o.object].spawns);
    if (o.kind === 'explore') sp.push(...(o.spawns || []));
    add(mainZone(sp.filter((p) => !p.instance)));
  }
  // an earlier step of the chain counts only while it's still to do and worth doing (a chain you finished long ago
  // in Elwynn doesn't make Elwynn part of Redridge)
  // (only quests you can take - Forever's Camping 101 has a copy per race, and the tauren one tied Durotar to Mulgore - and
  // a "one of" prerequisite only when none of its alternatives is done or starts in this quest's own zone)
  const tk = (P) => P && (!P.races || raceOk(P.races, race)) && (!P.classes || !CLASS_BIT[klass] || (P.classes & CLASS_BIT[klass]));
  for (const p of q.preGroup || []) { const P = db.quests[p]; if (tk(P) && !done.has(p) && P.level >= level - 6) add(starterZone(P)); }
  const alts = (q.preSingle || []).map((p) => db.quests[p]).filter(tk);
  if (alts.length && !alts.some((P) => done.has(P.id))) { const zs = alts.filter((P) => P.level >= level - 6).map(starterZone); if (!zs.includes(starterZone(q))) zs.forEach(add); }
  for (const f of followersOf[q.id] || []) { const F = db.quests[f]; if (!tk(F) || (BYNAME[F.name] || []).some((o) => o !== F && tk(o) && starterZone(o) === starterZone(q))) continue; add(starterZone(F)); }
  return out;
}
// ---------- dungeon legs ----------
// A dungeon at your level is a leg like a zone: its entrance zone is a candidate, and its region takes in the zones
// where its quests start (Scarlet Monastery's from Southshore and the cities). Planned and scored like any leg (the run,
// the wait for a group, the run's XP), so it wins only when it's worth it; the player can always skip a run in game.
// Level band: the middle of the levels of the mobs inside (wings included). Its quests: the same rule as the dungeon
// routes (dungeon-prep.js isDungeonQuest). Raids and other-expansion instances are left out.
const DUNGEON_LEGS = (() => {
  // a dungeon is never part of your path unless you asked (cfg.dungeonsInPath): it needs a group, and that can be hard to
  // find - its quests are a side trip you choose (paths.js dungeon routes, the Side trips window)
  if (cfg.dungeons === 'none' || cfg.dungeonsInPath !== true || !cfg.dungeonFile || !fs.existsSync(cfg.dungeonFile)) return [];
  let D; try { D = require('./dungeons').loadDungeons(cfg.dungeonFile); } catch (e) { return []; }
  const RAID = /Molten Core|Onyxia|Blackwing|Zul'Gurub|Ahn'Qiraj|Naxxramas|Utgarde|Black Morass|Old Hillsbrad|Deeprun|Hall of Legends|Champions' Hall/;
  const areaOf = (d) => new Set([d.id, ...(d.alt || [])]);
  const spawnsOf = (o) => {
    const out = [];
    if (o.kind === 'kill' && db.npcs[o.npc]) out.push(...db.npcs[o.npc].spawns);
    if (o.kind === 'killcredit') for (const id of o.npcs || []) if (db.npcs[id]) out.push(...db.npcs[id].spawns);
    if (o.kind === 'item') { for (const n of require('./world').droppers(o, db.npcs)) out.push(...n.spawns); for (const id of o.objectDrops || []) if (db.objects[id]) out.push(...db.objects[id].spawns); }
    if (o.kind === 'object' && db.objects[o.object]) out.push(...db.objects[o.object].spawns);
    return out;
  };
  const mobLevels = {};
  // hostile mobs only, above level 5 (critters and friendly NPCs inside made Dire Maul read '1-60')
  for (const n of Object.values(db.npcs)) if (n && n.minLevel > 5 && n.minLevel <= 63 && !n.friendly) for (const p of n.spawns || []) (mobLevels[p.zone] = mobLevels[p.zone] || []).push(n.minLevel);
  const out = [];
  for (const d of Object.values(D.list)) {
    if (RAID.test(d.name) || !zoneName[d.entrance.zone]) continue;
    const A = areaOf(d);
    const ls = [...A].flatMap((z) => mobLevels[z] || []).sort((a, b) => a - b);
    if (ls.length < 10) continue;
    const lo = ls[Math.floor(ls.length * 0.2)], hi = ls[Math.floor(ls.length * 0.8)];
    const quests = Object.values(db.quests).filter((q) => !(q.special & 3) && (!q.races || raceOk(q.races, race)) && (!q.classes || (q.classes & CLASS_BIT[klass]))
      && (A.has(q.zone) || (q.objectives || []).some((o) => { const sp = spawnsOf(o); return sp.length > 0 && sp.every((p) => A.has(p.zone)); })));
    if (quests.length < 3) continue;
    out.push({ id: d.id, name: d.name, entrance: d.entrance.zone, lo, hi, quests });
  }
  return out;
})();
const dungeonLegsAt = (level) => DUNGEON_LEGS.filter((d) => level >= d.lo - 1 && level <= d.hi);
// is zone z on the other continent from where you are?
function otherContinent(S, z) {
  const here = (S.pos && S.pos.zone) || S.zone;
  return here != null && continent[here] != null && continent[z] != null && continent[here] !== continent[z];
}
// a dungeon run for its XP alone (no quests inside): the dungeon at your level nearest by travel, its run as a leg
// a run's length by dungeon (tools/campaign-defaults.json dungeonMinutes: Gnomeregan two hours, the Stockade half of one) -
// a character made before the table was added still gets it
const DUNGEON_MINUTES = (() => { try { return JSON.parse(fs.readFileSync(path.join(__dirname, 'campaign-defaults.json'), 'utf8')).dungeonMinutes || {}; } catch (e) { return {}; } })();
function xpRunLeg(S, legs = []) {
  const W = require('./world');
  const L = S.level;
  let best = null;
  // at most XP_RUNS_IN_A_ROW runs of the same dungeon in a row (the player runs one 2-3 times, not six)
  const recent = legs.slice(-(cfg.xpRunsInARow ?? 3)).map((l) => l.xpRun);
  for (const dg of dungeonLegsAt(L)) {
    if (!uiMap[dg.entrance]) continue;
    if (recent.length >= (cfg.xpRunsInARow ?? 3) && recent.every((r) => r === dg.id)) continue;
    const runMin = (cfg.dungeonMinutes && cfg.dungeonMinutes[dg.id]) || DUNGEON_MINUTES[dg.id] || cfg.dungeonRunMin || 50;
    // no safe way there (hop costs NO_WAY): not an option - a gnome mage at 33 was sent on a "655 min" Scarlet Monastery run
    const there = hop(S, dg.entrance);
    if (there >= NO_WAY) continue;
    const minutes = runMin + (cfg.groupWaitMin ?? 10) + there;
    const gain = Math.round(XP_TO_LEVEL[L] * (cfg.dungeonLevelFraction ?? 0.35));
    const score = (gain / minutes) * (otherContinent(S, dg.entrance) ? (cfg.otherContinentFactor ?? 1) : 1);
    if (!best || score > best.score) best = { dg, minutes, gain, score };
  }
  if (!best) return null;
  const dg = best.dg;
  const D = (() => { try { return require('./dungeons').loadDungeons(cfg.dungeonFile).list[dg.id]; } catch (e) { return null; } })();
  const ent = (D && D.entrance) || { zone: dg.entrance, x: 50, y: 50 };
  const after = W.addXp(L, S.xp || 0, best.gain);
  const step = { k: 'goto', text: 'Run ' + dg.name + ' with a group', dungeon: dg.name, xpRun: true, m: uiMap[dg.entrance], x: +(ent.x / 100).toFixed(4), y: +(ent.y / 100).toFixed(4), zone: zoneName[dg.entrance], r: 25, sec: 1, lvl: L,
    note: 'For the XP: few quests at your level just now, and dungeon kills pay +50% since Nov 8. Skip it if you would rather not - the route goes on, you will just be a little lower.' };
  const leg = { title: dg.name + ' (XP run)', sections: [{ title: dg.name }], steps: [step] };
  return { z: dg.entrance, id: dg.id, name: dg.name, score: best.score, leg: { zone: dg.entrance, leg, state: { level: after.level, xp: after.xp, minutes: best.minutes, pos: { zone: dg.entrance, x: ent.x, y: ent.y }, completed: S.completed, active: S.active }, options: [], levelBefore: L, here: true, xpRun: dg.id } };
}
const regionCache = {};
function regionOf(z, level, completed) {
  const key = z + ':' + level;
  if (regionCache[key]) return regionCache[key];
  const done = new Set(completed || []);
  const links = {};
  for (const q of Object.values(db.quests)) {
    if (done.has(q.id) || q.level < level - 2 || q.level > level + 4 || (q.special & 3)) continue;
    if (q.races && !raceOk(q.races, race)) continue;
    if (q.classes && !(q.classes & CLASS_BIT[klass])) continue;
    if (starterZone(q) !== z) continue;
    for (const w of questZones(q, done, level)) if (w !== z && continent[w] === continent[z] && zoneName[w] && nearby(z, w)) links[w] = (links[w] || 0) + 1;
  }
  let region = Object.entries(links).filter(([w, n]) => n >= REGION_MIN_LINKS && !BATTLEGROUNDS.has(+w)).sort((a, b) => b[1] - a[1]).slice(0, REGION_MAX).map(([w]) => +w);
  // a dungeon whose entrance is here, at your level: the zones its quests start in (any distance, same continent)
  for (const d of dungeonLegsAt(level)) {
    if (d.entrance !== z) continue;
    const giv = {};
    for (const q of d.quests) { if (done.has(q.id)) continue; const w = starterZone(q); if (w && w !== z && continent[w] === continent[z] && zoneName[w]) giv[w] = (giv[w] || 0) + 1; }
    for (const [w] of Object.entries(giv).sort((a, b) => b[1] - a[1]).slice(0, 3)) if (!region.includes(+w)) region.push(+w);
  }
  return (regionCache[key] = region);
}
const regionName = (z, region) => zoneName[z] + (region.length ? ' (+' + region.map((w) => zoneName[w]).join(', ') + ')' : '');

const visits = {};
if (cfg.startStateFile) Object.assign(visits, JSON.parse(fs.readFileSync(cfg.startStateFile, 'utf8')).visits || {});

// ---------- run cache ----------
const LEG_CACHE = path.join(ROOT, 'leg-cache');
fs.mkdirSync(LEG_CACHE, { recursive: true });
// anything that changes planning results without being in the run config: the planner code and the data it reads
// the quest data each leg can see (tools/datasig.js): a QuestieDB update re-plans only the legs it touched
const legSig = require('./datasig').make(db, (() => { try { return JSON.parse(fs.readFileSync(cfg.itemsJson, 'utf8')); } catch (e) { return null; } })(), cfg.dungeonFile);
const codeSig = (() => {
  const h = require('crypto').createHash('sha1');
  for (const f of ['route2.js', 'optimize.js', 'quality.js', 'voxnav.js', 'waypoints.js', 'world.js', 'travel.js', 'travel-facts.json', 'travel-net.json']) { try { h.update(fs.readFileSync(path.join(__dirname, f))); } catch (e) {} }
  try { h.update(fs.readFileSync(cfg.conversion)); } catch (e) {} // map geometry: every leg
  // (the quest data isn't here any more: each leg's key carries a fingerprint of the data it can see, legSig below -
  // a QuestieDB update used to throw away every cached leg; now it re-plans only the legs whose data changed)
  // the walking trails by what they say (their timestamps changed on every replan and threw the whole cache away)
  try { for (const f of fs.readdirSync(cfg.terrainDir).sort()) if (/[.]trails[.]json$/.test(f)) { h.update(f); h.update(fs.readFileSync(path.join(cfg.terrainDir, f))); } } catch (e) {}
  return h.digest('hex');
})();
// old entries go after three days
try { const cut = Date.now() - 3 * 864e5; for (const d of fs.readdirSync(LEG_CACHE)) { const f = path.join(LEG_CACHE, d); if (fs.statSync(f).mtimeMs < cut) fs.rmSync(f, { recursive: true, force: true }); } } catch (e) {}
// and at most LEG_CACHE_MAX entries (about 180 KB each): every planner change makes the old ones useless, so a busy
// day of changes once filled 6 GB. The least recently used go first (a hit touches its entry)
const LEG_CACHE_MAX = cfg.legCacheMax || 8000;
try {
  const all = fs.readdirSync(LEG_CACHE);
  if (all.length > LEG_CACHE_MAX) {
    const byAge = all.map((d) => { const f = path.join(LEG_CACHE, d); try { return [f, fs.statSync(f).mtimeMs]; } catch (e) { return [f, 0]; } }).sort((a, b) => a[1] - b[1]);
    for (const [f] of byAge.slice(0, all.length - LEG_CACHE_MAX)) fs.rmSync(f, { recursive: true, force: true });
  }
} catch (e) {}
let cacheHits = 0, cacheMisses = 0;
// quests touching a set of zones (giver, hand-in, objective mobs/objects), for the loose key
const qZoneCache = {};
function questTouches(id, zones) {
  let z = qZoneCache[id];
  if (!z) {
    z = new Set(); const q = db.quests[id];
    if (q) {
      for (const x of [...q.starters, ...q.finishers]) for (const sp of x.spawns || []) z.add(sp.zone);
      for (const o of q.objectives || []) { const n = o.npc && db.npcs[o.npc]; if (n) for (const sp of n.spawns || []) z.add(sp.zone); }
    }
    qZoneCache[id] = z;
  }
  return zones.some((x) => z.has(x));
}
function looseView(c) {
  const zs = c.zones || [];
  const step = Math.max(1, Math.round((XP_TO_LEVEL[c.level] || 1000) * 0.25));
  return {
    ...c, start: undefined, arriveFrom: c.arriveFrom ? { zone: c.arriveFrom.zone } : undefined, xp: Math.floor((c.xp || 0) / step) * step,
    completed: (c.completed || []).filter((id) => questTouches(id, zs)).sort((a, b) => a - b),
    active: Object.fromEntries(Object.entries(c.active || {}).filter(([id]) => questTouches(+id, zs)).map(([id, q]) => [id, { complete: !!(q && q.complete), done: ((q && q.objectives) || []).map((o) => (o.done ? 1 : 0)).join('') }])),
  };
}
function runKey(cfgObj) {
  const { stateOut, legOut, routeOut, workers, ...rest0 } = cfgObj;
  // cfg.exactCache: no loose matches (tools/test-delta.js: a loose match reuses a run planned from a slightly different
  // state, so what a plan gets depends on what the cache held before - fine for speed, not for an exact comparison)
  const rest = rest0.loose && !cfg.exactCache ? looseView(rest0) : rest0;
  // canonical JSON: the same state with keys in another order is the same state
  const canon = (v) => Array.isArray(v) ? v.map(canon) : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, canon(v[k])])) : v;
  return require('crypto').createHash('sha1').update(codeSig + legSig(rest.zones || []) + JSON.stringify(canon(rest))).digest('hex');
}
const STAGE = {}, T_START = Date.now();
async function run(cfgObj, tag, timeoutSec) {
  const outs = { state: cfgObj.stateOut, leg: cfgObj.legOut, route: cfgObj.routeOut, out: path.join(work, tag + '.out.json') };
  const key = runKey(cfgObj), dir = path.join(LEG_CACHE, key);
  // cfg.noCache: plan every leg fresh (the determinism check: the same save must give the same plan)
  if (!cfg.noCache && fs.existsSync(path.join(dir, 'ok'))) {
    try {
      for (const [k, f] of Object.entries(outs)) if (f && fs.existsSync(path.join(dir, k))) fs.copyFileSync(path.join(dir, k), f);
      // a loose match was planned from a slightly different state: keep every quest you have really done
      if (cfgObj.loose && outs.state && fs.existsSync(outs.state)) { try { const sj = JSON.parse(fs.readFileSync(outs.state, 'utf8')); sj.completed = [...new Set([...(cfgObj.completed || []), ...(sj.completed || [])])]; fs.writeFileSync(outs.state, JSON.stringify(sj)); } catch (e) {} }
      cacheHits++; const now = new Date(); fs.utimesSync(dir, now, now);
      return { code: 0, out: fs.readFileSync(path.join(dir, 'stdout'), 'utf8'), err: '', cached: true };
    } catch (e) { /* fall through and plan it */ }
  }
  cacheMisses++;
  const tRun = Date.now();
  const r = await runFresh(cfgObj, tag, timeoutSec);
  // time per kind of run (eval-, leg-, look-, ...): where a plan's minutes go (printed at the end)
  { const kind = String(tag).split('-')[0]; const s = STAGE[kind] = STAGE[kind] || { n: 0, ms: 0, max: 0 }; const ms = Date.now() - tRun; s.n++; s.ms += ms; s.max = Math.max(s.max, ms); }
  if (!r.code) {
    try {
      fs.mkdirSync(dir, { recursive: true });
      for (const [k, f] of Object.entries(outs)) if (f && fs.existsSync(f)) fs.copyFileSync(f, path.join(dir, k));
      fs.writeFileSync(path.join(dir, 'stdout'), r.out); fs.writeFileSync(path.join(dir, 'ok'), '');
    } catch (e) {}
  }
  return r;
}
// long-lived route2 hosts (tools/route2-host.js): one node process per concurrent run, reused run after run - starting
// node and parsing the quest database was ~150 ms of a ~250 ms zone evaluation, over a thousand times a plan.
// FR_NO_HOSTS=1: a process per run, as before (the same plan comes out either way)
const HOSTS = { idle: [], seq: 0 };
function hostRun(cfgPath, outPath, timeoutSec) {
  return new Promise((res) => {
    const start = (h) => {
      const id = ++HOSTS.seq;
      let done = false;
      const finish = (r, keep) => { if (done) return; done = true; clearTimeout(timer); h.removeListener('message', onMsg); h.removeListener('exit', onExit); if (keep) { HOSTS.idle.push(h); h.unref(); if (h.channel) h.channel.unref(); } else { try { h.kill(); } catch (e) {} } res(r); };
      const onMsg = (m) => { if (m && m.id === id) finish({ code: m.code, out: m.out, err: m.err }, true); };
      const onExit = (code) => finish({ code: code || 1, out: '', err: 'the route2 host stopped (exit ' + code + ')' }, false);
      const timer = timeoutSec ? setTimeout(() => finish({ code: 1, out: '', err: ' timed out after ' + timeoutSec + 's' }, false), timeoutSec * 1000) : null;
      h.ref(); if (h.channel) h.channel.ref(); // a host at work keeps the planner alive; an idle one doesn't
      h.on('message', onMsg); h.on('exit', onExit);
      h.send({ id, db: cfg.db, cfg: cfgPath, out: outPath });
    };
    const h = HOSTS.idle.pop();
    if (h && h.connected) return start(h);
    const nh = require('child_process').fork(path.join(__dirname, 'route2-host.js'), [], { execArgv: ['--max-old-space-size=8000'], stdio: ['ignore', 'ignore', 'ignore', 'ipc'] });
    try { require('os').setPriority(nh.pid, 19); } catch (e) {} // low priority: keep the game and desktop responsive
    nh.once('message', (m) => { if (m && m.ready) start(nh); });
    nh.once('exit', (code) => res({ code: code || 1, out: '', err: 'the route2 host did not start (exit ' + code + ')' }));
  });
}
// the hosts end with the planner (they also exit on their own when it is gone)
process.on('exit', () => { for (const h of HOSTS.idle) { try { h.kill(); } catch (e) {} } });
function runFresh(cfgObj, tag, timeoutSec) {
  const cfgPath = path.join(work, tag + '.json');
  fs.writeFileSync(cfgPath, JSON.stringify(cfgObj));
  if (!process.env.FR_NO_HOSTS) return hostRun(cfgPath, path.join(work, tag + '.out.json'), timeoutSec);
  return new Promise((res) => {
    const p = spawn(process.execPath, ['--max-old-space-size=8000', path.join(__dirname, 'route2.js'), cfg.db, cfgPath, path.join(work, tag + '.out.json')], { stdio: ['ignore', 'pipe', 'pipe'] });
    try { require("os").setPriority(p.pid, 19); } catch (e) {} // low priority: keep the game and desktop responsive
    let out = '', err = ''; p.stdout.on('data', (d) => (out += d)); p.stderr.on('data', (d) => (err += d));
    const timer = timeoutSec ? setTimeout(() => { err += ' timed out after ' + timeoutSec + 's'; p.kill(); }, timeoutSec * 1000) : null;
    p.on('close', (code) => { if (timer) clearTimeout(timer); res({ code: code ?? 1, out, err }); });
  });
}
async function pool(items, n, fn) { const r = []; let i = 0; await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => { while (i < items.length) { const k = i++; r[k] = await fn(items[k]); } })); return r; }

const CITY_MAPS = CAPITAL_MAPS; // the six capitals
const areaOfMap = Object.fromEntries(conv.map((t) => [t.ui_map_id, t.area_id]));
function carryDeliveries(steps, legs) {
  if (cfg.carry === false || !legs.length) return;
  const N = db.npcs, Q = db.quests;
  const onRoute = new Set(steps.filter((x) => x.q > 0).map((x) => x.q));
  const done0 = new Set(st.completed || []), inLog = new Set(Object.keys(st.log || {}).map(Number));
  const legAt = (i) => { let k = 0; for (let j = 0; j < legs.length; j++) if (legs[j].from <= i) k = j; return k; };
  const turnedBefore = (i) => new Set(steps.slice(0, i).filter((x) => x.k === 'turnin' && x.q > 0).map((x) => x.q));
  const sq = (a, b) => (a.x - b.x) ** 2 + (a.y - b.y) ** 2;
  // the end of each run of steps in a city
  const stops = [];
  for (let i = 0; i < steps.length; i++) if (CITY_MAPS.has(steps[i].m) && !(steps[i + 1] && steps[i + 1].m === steps[i].m)) stops.push(i);
  const added = [];
  for (const stop of stops.reverse()) { // from the end, so earlier indexes stay valid while inserting
    const city = steps[stop].m, cityArea = areaOfMap[city], k = legAt(stop);
    const level = legs[k].levelBefore || state.level;
    const before = turnedBefore(stop);
    for (const [id, q] of Object.entries(Q)) {
      const qid = +id;
      if (onRoute.has(qid) || done0.has(qid) || inLog.has(qid) || q.objectives.length || q.special & 3) continue;
      if (q.races && !raceOk(q.races, race)) continue;
      // class quests only for your class (a warlock was sent to deliver the warrior quest Yorus Barleybrew)
      if (q.classes && !(q.classes & CLASS_BIT[klass])) continue;
      if ((q.reqLevel || 1) > level || !(q.xp > 0)) continue;
      const pre = [...(q.preGroup || []), ...((q.preSingle || []).length === 1 ? q.preSingle : [])];
      if (!pre.every((x) => done0.has(x) || before.has(x))) continue;
      const giver = q.starters.find((g) => g.type === 'npc' && (g.spawns || []).some((sp) => sp.zone === cityArea && sp.x >= 0));
      if (!giver) continue;
      const gn = N[giver.id]; if (gn && gn.friendly && gn.friendly !== 'AH' && gn.friendly !== (cfg.faction === 'horde' ? 'H' : 'A')) continue;
      const fin = q.finishers.find((f) => (f.spawns || []).some((sp) => sp.x >= 0 && uiMap[sp.zone]));
      if (!fin) continue;
      const fsp = fin.spawns.find((sp) => sp.x >= 0 && uiMap[sp.zone]);
      // a later leg of this path in the hand-in zone, while the quest still gives real XP (not gray)
      const j = legs.findIndex((L, jj) => jj > k && L.zone === fsp.zone && (L.levelBefore || 0) <= q.level + 5);
      if (j < 0) continue;
      const gsp = giver.spawns.find((sp) => sp.zone === cityArea && sp.x >= 0);
      // hand-in: cheapest spot among that leg's steps on the same map
      const from = legs[j].from, to = j + 1 < legs.length ? legs[j + 1].from : steps.length;
      const tm = uiMap[fsp.zone], T = { x: fsp.x / 100, y: fsp.y / 100 };
      let at = -1, best = Infinity;
      for (let i = from; i < to; i++) {
        const a = steps[i], b = steps[i + 1];
        if (a.m !== tm || !a.x) continue;
        const c = b && b.m === tm && b.x ? Math.sqrt(sq(a, T)) + Math.sqrt(sq(T, b)) - Math.sqrt(sq(a, b)) : Math.sqrt(sq(a, T));
        if (c < best) { best = c; at = i + 1; }
      }
      if (at < 0) continue;
      steps.splice(at, 0, { k: 'turnin', npc: fin.name, r: 6, q: qid, name: q.name, level: q.level, m: tm, x: +T.x.toFixed(4), y: +T.y.toFixed(4), zone: zoneName[fsp.zone], sec: steps[Math.min(at, steps.length - 1)].sec, note: 'Carried from ' + zoneName[cityArea] + '.' });
      steps.splice(stop + 1, 0, { k: 'accept', npc: giver.name, r: 6, minLevel: q.reqLevel > 1 ? q.reqLevel : undefined, q: qid, name: q.name, level: q.level, m: city, x: +(gsp.x / 100).toFixed(4), y: +(gsp.y / 100).toFixed(4), zone: zoneName[cityArea], sec: steps[stop].sec, note: 'Delivery - handed in later in ' + zoneName[fsp.zone] + ' (' + q.xp + ' xp).' });
      for (const L of legs) if (L.from > stop) L.from += 1;
      for (const L of legs) if (L.from > at) L.from += 1;
      onRoute.add(qid); added.push(q.name + ' (' + zoneName[cityArea] + ' -> ' + zoneName[fsp.zone] + ')');
    }
  }
  if (added.length) console.log('carried deliveries: ' + added.join(', '));
}

// drop rates you measured in game (account SavedVariables, ForeverRouteDB.drops)
const OBSERVED_DROPS = (() => { try { const f = path.join(cfg.charDir, '..', '..', '..', 'SavedVariables', 'ForeverRoute.lua'); const sv = require('./luatable').parseSavedVariables(fs.readFileSync(f, 'utf8')); return (sv.ForeverRouteDB && sv.ForeverRouteDB.drops) || {}; } catch (e) { return {}; } })();
// what your play taught us (tools/learn.js, run by the companion): kill XP corrections and minutes per kill
const LEARNED = (() => { if (cfg.learnedFile === false) return null; try { return JSON.parse(fs.readFileSync(cfg.learnedFile || path.join(ROOT, 'paths-auto', 'learned.json'), 'utf8')); } catch (e) { return null; } })();
// quests with a fun reward (a toy, a transform...: tools/learn.js asked the game) are worth a detour: must-do, with a note
const FUN_NOTES = (LEARNED && LEARNED.funQuests) || {};
const MUST_DO = [...new Set([...(cfg.mustDo || []), ...Object.keys(FUN_NOTES).map(Number)])];
function legConfig(zone, level, extra, S = state) {
  const zones = [zone, ...(cfg.regions === false ? [] : regionOf(zone, level, S.completed))];
  // your faction's hub rides along with every leg on its continent (hand-ins, books, training there): Stormwind for the
  // Alliance in the Eastern Kingdoms; Undercity there and Orgrimmar in Kalimdor for the Horde
  const hub = (cfg.faction === 'horde' ? { 0: 1497, 1: 1637 } : { 0: 1519 })[continent[zone]];
  if (hub && !zones.includes(hub)) zones.push(hub);
  return {
    // rounded up to 10 min so the leg cache still hits
    hearthCdLeft: S.hearthCd > 0 ? Math.ceil(S.hearthCd / 600) * 600 : undefined,
    trainedAt: S.trainedAt, // ranks reached but not trained yet (training is batched) carry over
    race, class: klass, faction: cfg.faction || 'alliance', level, xp: S.xp, zones,
    start: S.pos && zones.includes(S.pos.zone) ? S.pos : null,
    // rounded to a 4% grid: only roughly where you come from matters, and exact spots would defeat the leg cache
    arriveFrom: S.pos && !zones.includes(S.pos.zone) ? { zone: S.pos.zone, x: Math.round(S.pos.x / 4) * 4, y: Math.round(S.pos.y / 4) * 4 } : undefined, arriveKnowsFP: hasFP(zone),
    minQuestLevel: level - 6, maxQuestLevel: level + 5, maxAbove: cfg.maxAbove ?? LEVEL_ABOVE + 1, targetLevel: cfg.targetLevel, finishOpen: true,
    flightSec: 120, completed: S.completed, active: S.active, arrivalTour: true, terrainDir: cfg.terrainDir, conversion: cfg.conversion,
    flightPaths: Object.keys(zoneName).map(Number).filter((z) => hasFP(z)), observedDrops: OBSERVED_DROPS, mustDo: MUST_DO, keep: [...(cfg.keep || []), ...MUST_DO], funNotes: FUN_NOTES, trainLevels: cfg.trainLevels, trainer: cfg.trainer, trainers: cfg.trainers, learned: LEARNED && Object.keys(LEARNED.killXpByDiff || {}).length ? { killXpByDiff: LEARNED.killXpByDiff } : undefined, ...(LEARNED && LEARNED.secPerKill ? { secPerKill: LEARNED.secPerKill } : {}), hearth: S.hearth || undefined, bindName: S.hearth ? undefined : st.bind, trainerNote: cfg.trainerNote, hubNames: cfg.hubNames, skip: [...(cfg.skip || []), ...(st.nope || []), ...(st.notOffered || [])],
    title: `${zoneName[zone]} ${level}+`, character: st.name, charDir: undefined, addonsDir: cfg.addonsDir, bonusQuests: cfg.bonusQuests, bonusNotes: cfg.bonusNotes, booksCharDir: cfg.charDir, itemsJson: cfg.itemsJson, maxFrustration: cfg.maxFrustration, awayHubShare: cfg.awayHubShare, lonelyYards: cfg.lonelyYards, lonelyXpShare: cfg.lonelyXpShare, keepRewardValue: cfg.keepRewardValue, frustrating: cfg.frustrating, // dungeons run earlier on this path: not run again for a quest or two (route2.js)
    dungeonsRun: S.dungeonsRun && S.dungeonsRun.length ? S.dungeonsRun : undefined,
    gearVerdicts: st.gearVerdicts && Object.keys(st.gearVerdicts).length ? st.gearVerdicts : undefined,
    dungeonFile: cfg.dungeonFile, dungeons: cfg.dungeonsInPath === true ? cfg.dungeons : 'none', dungeonRunMin: cfg.dungeonRunMin, groupWaitMin: cfg.groupWaitMin, ...extra,
  };
}

async function evalZone(z, S, n, tag) {
  const c = legConfig(z, S.level, { loose: true, optimize: false, workers: cfg.evalWorkers || 2, start: null, stateOut: path.join(work, tag + '.state.json') }, S);
  const r = await run(c, tag, cfg.evalTimeoutSec || 150);
  if (r.code) return null;
  const s2 = JSON.parse(fs.readFileSync(c.stateOut, 'utf8'));
  const gained = (() => { let x = 0, L = S.level, xp = S.xp; while (L < s2.level) { x += XP_TO_LEVEL[L] - xp; xp = 0; L++; } return x + s2.xp - xp; })();
  // value: what a zone is worth, the same measure the main choice ranks by (XP plus rewards; must-do quests count via
  // the reward value) - look-ahead and the beam used raw XP, which favoured grindy zones the main choice would skip
  return { z, gained, value: zoneValue(gained, s2), minutes: s2.minutes + hop(S, z), turnins: s2.turnins, s: s2 };
}
function zoneValue(gained, s) { return gained + (s.rewardValue || 0) * (cfg.rewardWeight ?? 1); }
// pick among the top candidates by simulating one more leg after each
async function lookaheadPick(top, n) {
  const PARL = Math.max(1, Math.min(cfg.parallel || 6, os.cpus().length - 1));
  for (const e of top) {
    const xpStep = Math.max(1, Math.round((XP_TO_LEVEL[e.s.level] || 1000) * 0.05));
    const S1 = { hearth: state.hearth, level: e.s.level, xp: Math.floor((e.s.xp || 0) / xpStep) * xpStep, completed: [...e.s.completed].sort((a, b) => a - b), active: e.s.active, pos: e.s.pos, zone: e.z, dungeonsRun: e.s.dungeonsRun };
    const next = candidates(S1.level).filter((z) => z !== e.z);
    const ev2 = (await pool(next, PARL, (z) => evalZone(z, S1, n + 1, `look-${n}-${e.z}-${z}`))).filter((x) => x && x.minutes > 0 && x.turnins >= (cfg.minTurnins || 5));
    // the second zone: a return to the first one counts less (the same revisit rule as the main choice)
    const v2 = (x) => x.value * (x.z in visits || x.z === e.z ? 1 / (1 + (cfg.revisitPenalty ?? 0.8) * visitsAt(x.z, (visits[x.z] || 0) + (x.z === e.z ? 1 : 0), S1.level)) : 1);
    ev2.sort((a, b) => v2(b) / b.minutes - v2(a) / a.minutes);
    const b2 = ev2[0];
    const v1 = e.score * e.minutes; // the main choice's value for the first zone (revisit included)
    e.look = b2 ? (v1 + v2(b2)) / (e.minutes + b2.minutes) : v1 / Math.max(1, e.minutes);
    e.lookNext = b2 ? b2.z : null;
  }
  return [...top].sort((a, b) => b.look - a.look)[0];
}

async function beamSearch() {
  await new Promise((r) => setImmediate(r)); // let the rest of the file (the level table) load first
  const B = cfg.beam || 4, PARB = Math.max(1, Math.min(cfg.parallel || 6, os.cpus().length - 1));
  const xpTotal = (L, xp) => { let t = xp; for (let l = 1; l < L; l++) t += XP_TO_LEVEL[l] || 0; return t; };
  const start = { ...state };
  let beam = [{ S: start, seq: [], minutes: 0, gained: 0, visits: {} }];
  const done = [];
  for (let depth = 0; depth < (cfg.maxLegs || 12) && beam.length; depth++) {
    const next = [];
    await pool(beam, Math.max(1, Math.floor(PARB / 2)), async (node) => {
      const last = node.seq[node.seq.length - 1];
      const cands = candidates(node.S.level).filter((z) => z !== last);
      const evs = await pool(cands, 2, (z) => evalZone(z, node.S, depth, `beam-${depth}-${node.seq.join('_')}-${z}`));
      for (const e of evs) {
        if (!e || e.minutes <= 0 || e.turnins < (cfg.minTurnins || 5)) continue;
        const revisit = 1 / (1 + (cfg.revisitPenalty ?? 0.8) * visitsAt(e.z, node.visits[e.z] || 0, node.S.level));
        const xpStep = Math.max(1, Math.round((XP_TO_LEVEL[e.s.level] || 1000) * 0.05));
        const S2 = { hearth: node.S.hearth, level: e.s.level, xp: Math.floor((e.s.xp || 0) / xpStep) * xpStep, completed: [...e.s.completed].sort((a, b) => a - b), active: e.s.active, pos: e.s.pos, zone: e.z, dungeonsRun: e.s.dungeonsRun };
        const n2 = { S: S2, seq: [...node.seq, e.z], minutes: node.minutes + e.minutes, gained: node.gained + e.gained, value: (node.value || 0) + e.value * revisit, visits: { ...node.visits, [e.z]: (node.visits[e.z] || 0) + 1 } };
        n2.rate = n2.value / Math.max(1, n2.minutes); // ranked by value, like the main choice
        n2.xpRate = n2.gained / Math.max(1, n2.minutes); // reported as XP per hour
        (S2.level >= cfg.targetLevel ? done : next).push(n2);
      }
    });
    // keep the best B, but not B copies of the same first two zones (we want genuinely different routes)
    next.sort((a, b) => b.rate - a.rate);
    const seen = new Map(); beam = [];
    for (const n of next) { const k = n.seq.slice(0, 2).join('>'); const c = seen.get(k) || 0; if (c >= 2) continue; seen.set(k, c + 1); beam.push(n); if (beam.length >= B) break; }
    console.log(`beam depth ${depth + 1}: ` + beam.map((n) => n.seq.map((z) => zoneName[z]).join(' > ') + ` (${Math.round(n.xpRate * 60)} xp/h)`).join(' | '));
  }
  const all = [...done, ...beam].sort((a, b) => b.rate - a.rate);
  const out = []; const keys = new Set();
  for (const n of all) { const k = n.seq.slice(0, 3).join('>'); if (keys.has(k)) continue; keys.add(k); out.push({ legs: n.seq, names: n.seq.map((z) => zoneName[z]), hours: +(n.minutes / 60).toFixed(1), xph: Math.round(n.xpRate * 60), endLevel: n.S.level }); if (out.length >= (cfg.beamKeep || 3)) break; }
  fs.writeFileSync(cfg.beamOut, JSON.stringify(out, null, 1));
  console.log('beam routes: ' + out.map((r) => r.names.join(' > ') + ` ${r.xph} xp/h`).join(' || '));
}

(async () => {
  if (cfg.beamOut) { await beamSearch(); return; }
  const legs = [];
  const forceQueue = (cfg.forceLegs || []).slice(), dropped = []; // your path's zone order (see the leg loop)
  const PAR = Math.max(1, Math.min(cfg.parallel || 6, os.cpus().length - 1));
  // standing in a city with quests there (books to loot, hand-ins, pick-ups): every path finishes those first,
  // before leaving - not only the paths whose first zone happens to sit next to that city
  const hereLeg = !cfg.startStateFile && !cfg.forceLevel && !cfg.rankOnly && state.pos && CITIES.has(state.pos.zone) ? state.pos.zone : null;
  if (hereLeg) {
    const tag = 'leg-0-' + hereLeg;
    const c = legConfig(hereLeg, state.level, { zones: [hereLeg], start: state.pos, optimize: true, optimizeSeconds: Math.min(5, cfg.optimizeSeconds || 5), title: zoneName[hereLeg] + ' first', routeOut: path.join(work, tag + '.lua'), legOut: path.join(work, tag + '.leg.json'), stateOut: path.join(work, tag + '.state.json') });
    const r = await run(c, tag, 120);
    if (r.code) console.log('  (no ' + zoneName[hereLeg] + ' errands planned: ' + r.err.split(/\r?\n/).slice(-2).join(' ') + ')');
    else {
      const leg = JSON.parse(fs.readFileSync(c.legOut, 'utf8')), s = JSON.parse(fs.readFileSync(c.stateOut, 'utf8'));
      const work_ = leg.steps.filter((x) => x.k === 'turnin' || x.k === 'obj').length;
      if (work_ > 0) {
        legs.push({ zone: hereLeg, leg, state: s, options: [], beforeFile: null, levelBefore: state.level, here: true });
        console.log(`first, here in ${zoneName[hereLeg]}: ${leg.steps.length} steps, ~${s.minutes} min`);
        state = { trainedAt: s.trainedAt, hearthCd: s.hearthCdLeft || 0, hearth: s.hearth || state.hearth || null, level: s.level, xp: s.xp, completed: s.completed, active: s.active, pos: s.pos, zone: hereLeg, dungeonsRun: s.dungeonsRun };
      } else console.log('  nothing to finish here in ' + zoneName[hereLeg]);
    }
  }
  // zones whose real leg came up empty from this very state: the quick (loosely cached) evaluation promised quests the
  // real plan couldn't do, so the same pick would repeat forever (a dwarf hunter at 58 chose an empty Searing Gorge 100
  // times). Cleared as soon as a leg makes progress.
  let emptyAt = new Set();
  for (let n = 0; n < (cfg.maxLegs || 12) && state.level < cfg.targetLevel; n++) {
    const cands = candidates(state.level).filter((z) => !emptyAt.has(z));
    const t0 = Date.now();
    const evals = await pool(cands, PAR, async (z) => {
      const c = legConfig(z, state.level, { loose: n >= 2, optimize: false, workers: cfg.evalWorkers || 2, start: null, stateOut: path.join(work, `eval-${n}-${z}.state.json`) });
      const r = await run(c, `eval-${n}-${z}`, cfg.evalTimeoutSec || 150);
      if (r.code) return { z, score: -1, err: r.err.split('\n').slice(-3).join(' ') };
      const s = JSON.parse(fs.readFileSync(c.stateOut, 'utf8'));
      const gained = (() => { let x = 0, L = state.level, xp = state.xp; while (L < s.level) { x += XP_TO_LEVEL[L] - xp; xp = 0; L++; } return x + s.xp - xp; })();
      // cfg.switchMin: minutes a zone change costs on top of the travel (settling in, a new map to learn) - more makes
      // fewer, longer stays beat a short hop for a few quests. 15 by default: on four 1-60 plans it never did worse and
      // at best took 14 fewer stops, 9 fewer zone returns and 2.4 h less (dwarf hunter); 30 gave the same paladin plan,
      // 60 went back to more stops
      const minutes = s.minutes + hop(state, z) + (z !== state.zone ? cfg.switchMin ?? 15 : 0);
      const value = gained + (s.rewardValue || 0) * (cfg.rewardWeight ?? 1);
      const revisit = 1 / (1 + (cfg.revisitPenalty ?? 0.8) * visitsAt(z, visits[z] || 0, state.level)); // fresh zones beat returning for a few stragglers (0.8: a 1-60 plan came back to wild areas 17% less, for 1.5% more time)
      // cfg.otherContinentFactor < 1 makes the other continent beat staying by a margin (off: at 0.8 a 1-60 plan took 5
      // fewer boats but 16% longer, and one path stalled at 34 - the quests are where they are)
      const stay = otherContinent(state, z) ? (cfg.otherContinentFactor ?? 1) : 1;
      return { z, gained, minutes, turnins: s.turnins, score: minutes > 0 ? (value / minutes) * revisit * stay : 0, s };
    });
    evals.sort((a, b) => b.score - a.score);
    // a zone you have no safe way to reach (Zephras Isle for a level-1 human: the portal is Skyborne-only) is no option
    if (cfg.rankOnly) { fs.writeFileSync(cfg.rankOut, JSON.stringify(evals.filter((e) => e.score > 0 && e.turnins >= (cfg.minTurnins || 5) && hop(state, e.z) < NO_WAY).map((e) => ({ z: e.z, name: zoneName[e.z], xph: Math.round(e.score * 60), turnins: e.turnins })))); return; }
    console.log(`\nleg ${n + 1} at level ${state.level}: evaluated ${cands.length} zones in ${((Date.now() - t0) / 1000).toFixed(0)}s`);
    for (const e of evals.slice(0, 5)) console.log(`  ${zoneName[e.z].padEnd(22)} ${e.score < 0 ? 'failed ' + e.err : `${Math.round(e.score * 60)} xp/h  (${e.turnins} turn-ins, ${e.minutes} min)`}`);
    const options = evals.filter((e) => e.score > 0 && e.turnins >= (cfg.minTurnins || 5)).slice(0, 4).map((e) => ({ z: e.z, name: zoneName[e.z], xph: Math.round(e.score * 60), turnins: e.turnins, minutes: e.minutes }));
    const beforeFile = path.join(work, 'before-' + (n + 1) + '.json');
    fs.writeFileSync(beforeFile, JSON.stringify({ state, visits }));
    // your path's zone order is kept (the player wants a stable plan): the next zone in it that is still worth doing.
    // One that isn't any more (finished, or outlevelled) is a real turning point: it is dropped, and said why
    let forced = null;
    while (forceQueue.length && !forced) {
      const z = forceQueue.shift();
      forced = evals.find((e) => e.z === z && e.score > 0 && e.turnins >= 1) || null;
      if (!forced) { console.log(`  your path's next zone ${zoneName[z]} is no longer worth doing (finished or outlevelled): moving on`); dropped.push(zoneName[z]); }
    }
    let best = forced || ((n === 0 && cfg.firstZone) ? (evals.find((e) => e.z === cfg.firstZone) || { z: cfg.firstZone }) : evals.find((e) => e.score > 0 && e.turnins >= (cfg.minTurnins || 5)));
    if (!forced && !(n === 0 && cfg.firstZone) && (cfg.lookahead || 0) > 1 && n < (cfg.lookaheadLegs ?? 3)) {
      const top = evals.filter((e) => e.score > 0 && e.turnins >= (cfg.minTurnins || 5)).slice(0, cfg.lookahead);
      if (top.length > 1) {
        const pick = await lookaheadPick(top, n);
        if (pick && pick !== best) console.log(`  look-ahead: ${zoneName[pick.z]} then ${zoneName[pick.lookNext] || '?'} beats ${zoneName[best.z]} on its own (${Math.round(pick.look * 60)} vs ${Math.round((best.look || 0) * 60)} xp/h over two zones)`);
        if (pick) best = pick;
      }
    }
    // nothing with enough hand-ins: a short leg that's still worth the trip beats stopping (the level-30 gap: few
    // quests at your level everywhere, the rest a few levels up)
    if (!best) { best = evals.find((e) => e.score > 0 && e.turnins >= 1) || null; if (best) console.log(`  no zone has ${cfg.minTurnins || 5}+ hand-ins at this level: a short leg in ${zoneName[best.z]}`); }
    // where quests run thin (the 30s), a dungeon run for its XP can beat a short leg - dungeon kills pay +50% since
    // Blizzard's Nov 8 2026 hotfix "so it feels better to go back in for more runs". Scored on XP per minute like a leg;
    // in game it is a Run step you can skip (the route goes on, you're just lower)
    // (only when you asked for them - cfg.xpRuns: a dungeon is a group and an hour or two, not a step to be routed into;
    // a level-29 warlock was sent to Gnomeregan, a two-hour run, for its XP)
    if (cfg.dungeons !== 'none' && cfg.xpRuns === true && (!best || best.turnins < (cfg.minTurnins || 5))) {
      const run = xpRunLeg(state, legs);
      if (run && (!best || run.score > best.score)) {
        legs.push(run.leg);
        console.log(`  -> a run of ${run.name} for its XP: level ${state.level} -> ${run.leg.state.level} (${Math.round(100 * run.leg.state.xp / XP_TO_LEVEL[run.leg.state.level])}%), ~${run.leg.state.minutes} min (beats ${best ? 'a short leg in ' + zoneName[best.z] : 'stopping'})`);
        visits[run.z] = (visits[run.z] || 0) + 1;
        state = { ...state, level: run.leg.state.level, xp: run.leg.state.xp, pos: run.leg.state.pos, zone: run.z, dungeonsRun: [...(state.dungeonsRun || []), run.id] };
        continue;
      }
    }
    if (!best) {
      // no quests anywhere: grind a level where the mobs fit, then look again
      // grinding is a last resort, off unless asked for (cfg.grind): a plan that needs it is a planner gap to fix
      const g = cfg.grind ? grindLeg(state, evals, cands) : null;
      if (!g) { console.log('  no zone worth doing at this level - stopping' + (cfg.grind ? ' (nowhere to grind)' : ' (grinding is off)')); break; }
      legs.push(g);
      console.log(`  -> grind in ${zoneName[g.zone]}: level ${state.level} -> ${g.state.level}, ~${g.state.minutes} min (no quests worth doing at this level)`);
      visits[g.zone] = (visits[g.zone] || 0) + 1;
      state = { ...state, level: g.state.level, xp: 0, pos: g.state.pos, zone: g.zone };
      continue;
    }
    // plan the chosen leg properly
    const tag = `leg-${n + 1}-${best.z}`;
    const c = legConfig(best.z, state.level, { loose: false, optimize: true, optimizeSeconds: cfg.optimizeSeconds || 12, routeOut: path.join(work, tag + '.lua'), legOut: path.join(work, tag + '.leg.json'), stateOut: path.join(work, tag + '.state.json') });
    let r = await run(c, tag);
    // a one-off failure (a shared file busy, a host that died) shouldn't end the whole plan: once more, then give up
    if (r.code) { console.log('leg failed, trying it once more: ' + r.err.slice(-200)); r = await run(c, tag); }
    if (r.code) { console.log('leg failed: ' + r.err.slice(-500)); break; }
    fs.writeFileSync(path.join(work, tag + '.txt'), r.out);
    const leg = JSON.parse(fs.readFileSync(c.legOut, 'utf8'));
    const s = JSON.parse(fs.readFileSync(c.stateOut, 'utf8'));
    if (!leg.steps.length) { console.log(`  -> ${zoneName[best.z]} came up empty when planned for real: ruled out until something changes`); emptyAt.add(best.z); continue; }
    emptyAt = new Set();
    legs.push({ zone: best.z, leg, state: s, options, beforeFile, levelBefore: state.level });
    console.log(`  -> ${regionName(best.z, regionOf(best.z, state.level, state.completed))}: ${leg.steps.length} steps, level ${state.level} -> ${s.level} (${s.level >= 60 ? 100 : Math.round(100 * s.xp / XP_TO_LEVEL[s.level])}%), ~${s.minutes} min`);
    visits[best.z] = (visits[best.z] || 0) + 1;
    knownFP.add(best.z);
    // exact XP: rounding here lost up to 5% of a level on every leg (evaluations still round, for the cache)
    state = { trainedAt: s.trainedAt, hearthCd: s.hearthCdLeft || 0, hearth: s.hearth || state.hearth || null, level: s.level, xp: s.xp || 0, completed: [...s.completed].sort((a, b) => a - b), active: s.active, pos: s.pos, zone: best.z, dungeonsRun: s.dungeonsRun };
  }
  console.log(`planner runs: ${cacheHits} reused from earlier plans, ${cacheMisses} planned fresh`);
  console.log(`planner time: ${Math.round((Date.now() - T_START) / 1000)} s wall; fresh runs by kind (summed process time): ` + Object.entries(STAGE).sort((a, b) => b[1].ms - a[1].ms).map(([k, s]) => `${k} ${s.n}x ${Math.round(s.ms / 1000)} s (avg ${Math.round(s.ms / s.n)} ms, max ${Math.round(s.max / 1000)} s)`).join(', '));
  // merge legs into one route for the addon
  const sections = [], steps = [], choices = [];
  for (const [k, { zone, leg }] of legs.entries()) {
    const fromZone = k > 0 ? legs[k - 1].zone : (st.branchFrom || (st.pos ? st.pos.zone : cfg.startZone));
    const choice = legs[k].here ? null : { leg: k + 1 - (legs[0].here ? 1 : 0), at: steps.length + 1, level: legs[k].levelBefore, chosen: zone, options: legs[k].options, beforeFile: legs[k].beforeFile, remaining: legs.length - k };
    if (choice) choices.push(choice);
    // the trip goes where the leg really starts: a region leg can open in a neighbour or a city ("fly to the Badlands"
    // then straight away "fly to Ironforge" was two travel steps in a row)
    const firstAt = leg.steps.find((s) => s.m && s.k !== 'fly');
    const startM = firstAt ? firstAt.m : uiMap[zone];
    const prevAt = k > 0 ? [...legs[k - 1].leg.steps].reverse().find((s) => s.m) : null;
    const sameMap = prevAt && prevAt.m === startM;
    if (fromZone !== zone && !sameMap && !(leg.steps[0] && leg.steps[0].k === 'fly')) {
      const zone2 = firstAt && firstAt.zone ? firstAt.zone : zoneName[zone];
      const boat = continent[fromZone] !== continent[zone];
      const next = k > 0 ? '  Next leg: ' + leg.title : '';
      sections.push({ title: 'Travel', zone: zone2 });
      // one travel step per zone change, across the sea too: the addon's trip planner (Travel.lua, the same network
      // travel.js costed this leg with) works out the boats, rides, flights and hearth live, leg by leg, from where you
      // really are - a hand-picked harbor here used to disagree with it (and with Forever's Southshore stop)
      steps.push({ k: 'fly', dest: zone2, to: startM, text: zone2, sec: sections.length,
        note: (boat ? 'Across the sea: the card lists the boats and rides.' : 'Fly, or ride if there is no flight path yet.') + next });
    }
    legs[k].from = steps.length;
    const off = sections.length;
    sections.push(...leg.sections);
    // tm (hearth steps): minutes since this leg began -> since the route began (the legs' planned minutes, the same
    // clock the hearth cooldown is carried on), so the audit can see two hearths less than an hour apart
    const clockOff = legs.slice(0, k).reduce((a, l) => a + ((l.state && l.state.minutes) || 0), 0);
    for (const s of leg.steps) steps.push({ ...s, sec: s.sec + off, ...(s.tm !== undefined ? { tm: s.tm + clockOff } : {}) });
    // the choice point is a step, not a number: later passes (carried deliveries, repeated pick-ups below, the safety
    // net in paths.js) insert and remove steps, and a number taken here ended up deep inside the next zone
    if (choice && steps[choice.at - 1]) steps[choice.at - 1]._choice = choice.leg;
  }
  carryDeliveries(steps, legs);
  // a quest picked up earlier on the path and not handed in yet is not picked up again on a later visit
  // (a choice mark on the removed step moves to the step after it)
  { const open = new Set(); for (let i = 0; i < steps.length; i++) { const x = steps[i]; if (x.k === 'accept' && x.q > 0) { if (open.has(x.q)) { steps.splice(i, 1); if (x._choice && steps[i] && !steps[i]._choice) steps[i]._choice = x._choice; for (const L of legs) if (L.from > i) L.from--; i--; continue; } open.add(x.q); } if (x.k === 'turnin' && x.q > 0) open.delete(x.q); } }
  // a travel step straight into another one leads nowhere (the leg it opened was emptied by the passes above): the
  // second one is the trip (a choice mark moves to it)
  for (let i = steps.length - 2; i >= 0; i--) if (steps[i].k === 'fly' && !steps[i].boat && steps[i + 1].k === 'fly') { if (steps[i]._choice && !steps[i + 1]._choice) steps[i + 1]._choice = steps[i]._choice; steps.splice(i, 1); }
  steps.forEach((s, i) => { s.id = i + 1; });
  for (const c of choices) { const i = steps.findIndex((s) => s._choice === c.leg); if (i >= 0) c.at = i + 1; }
  const lua = (v) => (typeof v === 'string' ? JSON.stringify(v) : String(v));
  const ser = (o) => '{ ' + Object.entries(o).filter(([, v]) => v !== undefined && v !== null).map(([k, v]) => k + ' = ' + lua(v)).join(', ') + ' }';
  const last = legs.length ? legs[legs.length - 1].state : state;
  const L = ['-- Generated by the Forever Route campaign planner on ' + new Date().toISOString() + '. Regenerate rather than edit.', 'ForeverRouteData = {'];
  L.push('  id = ' + lua('campaign@' + Date.now()) + ',');
  L.push('  title = ' + lua(`${st.name || ''} ${legs.length ? 'lvl ' + (legs[0] && st.level) + '→' + last.level : ''}`.trim()) + ',');
  L.push('  meta = { character = ' + lua(st.name || '') + ', startLevel = ' + (st.level || cfg.level) + ', endLevel = ' + lua(last.level + ' (' + (XP_TO_LEVEL[last.level] ? Math.round(100 * last.xp / XP_TO_LEVEL[last.level]) : 100) + '%)') + ', legs = ' + lua(legs.filter((l) => !l.here).map((l) => zoneName[l.zone]).join(' > ')) + ' },');
  L.push('  sections = {'); for (const s of sections) L.push('    ' + ser(s) + ','); L.push('  },');
  L.push('  steps = {'); for (const s of steps) L.push('    ' + ser({ ...s, _choice: undefined }) + ','); L.push('  },', '}');
  fs.writeFileSync(cfg.routeOut, L.join('\n') + '\n');
  if (cfg.pathOut) fs.writeFileSync(cfg.pathOut, JSON.stringify({ dropped, legs: legs.filter((l) => !l.here).map((l) => zoneName[l.zone]), startLevel: st.level || cfg.level, endLevel: last.level, endXp: last.xp, choices, minutes: legs.reduce((a, l) => a + (l.state.minutes || 0), 0), sections, steps }));
  console.log(`\nroute: ${legs.filter((l) => !l.here).map((l) => zoneName[l.zone]).join(' > ')}; ${steps.length} steps -> ${cfg.routeOut}`);
})();

