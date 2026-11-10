const { raceOk } = require('./world'); // race masks above bit 32 (Skyborne)
// Route generator v1: hub-and-loop planner.
//  - finds quest hubs (clusters of quest NPCs), loads up at each hub (all turn-ins, then all accepts)
//  - plans a field loop over open objectives (nearest-neighbour + 2-opt), merging objectives that share a spot
//    and passing field quest givers on the way; broad "kill anywhere" objectives become background work
//  - returns to a hub by walking or hearthstone (bound at the main hub), learns flight paths on arrival
//  - trains at even levels (configurable) and times a short grind so a turn-in batch lands on a training level
//  - quests whose turn-in is outside the planned zones are carried and listed for the next leg
// usage: node route2.js <db.json> <config.json> [out.json]
const fs = require('fs');
const { XP_TO_LEVEL, RACE_BIT, CLASS_BIT, CAPITAL_AREAS, QUEST_LOG_MAX, LEVEL_ABOVE, DUNGEON_ABOVE, trainNow, setLearned } = require('./world'); // the game's rules, shared by every stage
const [dbPath, cfgPath, outPath] = process.argv.slice(2);
// a long-lived host (tools/route2-host.js) keeps the big files parsed between runs (by path and modification time)
const readJsonCached = (p) => { const C = global.__FR_JSON; if (!C) return JSON.parse(fs.readFileSync(p, 'utf8')); const k = p + ':' + fs.statSync(p).mtimeMs; return C[k] || (C[k] = JSON.parse(fs.readFileSync(p, 'utf8'))); };
const { quests: Q, npcs: N, objects: O } = readJsonCached(dbPath);
const cfg = Object.assign({
  maxAbove: LEVEL_ABOVE + 1, maxLog: QUEST_LOG_MAX, // the shared level gate (world.js): quests up to LEVEL_ABOVE above you
  maxMobAbove: LEVEL_ABOVE + 1, secPerKill: 22, secPerObject: 12, dropRate: 0.5, mergeYards: 60,
  hubYards: 160, detourYards: 250, maxKills: 45, faction: 'alliance', minHubNpcs: 2, maxTripMin: 30, hearthCooldownMin: 60, minXpPerMin: 0,
  trainLevels: [], trainerTripMin: 7, backgroundMinStops: 3, finishOpen: true,
}, JSON.parse(fs.readFileSync(cfgPath, 'utf8')));
// what your play taught us (tools/learn.js): kill XP corrections; minutes per kill comes in as cfg.secPerKill
setLearned(cfg.learned);
// real character state from saved variables (our snapshot, else Journey Tracker)
if (cfg.charDir) {
  const st = require('./snapshot').loadCharState(cfg.charDir, cfg.conversion);
  if (st) {
    console.error('character: ' + st.name + ' ' + st.race + ' ' + st.class + ' level ' + st.level + ', ' + st.completed.length + ' quests done, ' + Object.keys(st.log).length + ' in log  [' + st.source + ']');
    if (st.level) { cfg.level = st.level; cfg.xp = st.xp || 0; }
    if (st.race) cfg.race = st.race; if (st.class) cfg.class = st.class;
    cfg.completed = [...new Set([...(cfg.completed || []), ...st.completed])];
    cfg.active = st.log;
    if (st.pos && cfg.zones.includes(st.pos.zone)) cfg.start = st.pos;
  }
}



const raceBit = RACE_BIT[cfg.race], classBit = CLASS_BIT[cfg.class];
const petClass = ['warlock', 'hunter'].includes(cfg.class);
const ZONE_NAME = { 1: 'Dun Morogh', 12: 'Elwynn Forest', 38: 'Loch Modan', 40: 'Westfall', 44: 'Redridge Mountains', 10: 'Duskwood', 11: 'Wetlands', 148: 'Darkshore', 1519: 'Stormwind', 1537: 'Ironforge' };
// every other zone by its name from the map conversion (steps showed "zone 331" for Ashenvale)
try { for (const t of JSON.parse(fs.readFileSync(cfg.conversion, 'utf8')).geometry.transforms) if (!ZONE_NAME[t.area_id] && t.target_name) ZONE_NAME[t.area_id] = t.target_name; } catch (e) {}
const zname = (z) => ZONE_NAME[z] || 'zone ' + z;

// ---------- geometry ----------
const ZONE_YARDS = { 1: [4925, 3283], 12: [3470, 2314], 38: [2758, 1839], 40: [3500, 2333], 44: [2170, 1447], 10: [2700, 1800], 11: [4135, 2756], 148: [6550, 4366], 1519: [1737, 1158], 1537: [790, 527] };
// zone size from the small metadata file (loading the whole walk grid just for this cost hundreds of ms and 100+ MB)
const __yd = {}; const yards = (z) => { if (__yd[z]) return __yd[z]; let r = ZONE_YARDS[z] || [3000, 2000]; if (cfg.terrainDir) { for (const f of [`${cfg.terrainDir}/area${z}.vox.json`, `${cfg.terrainDir}/area${z}.json`]) if (fs.existsSync(f)) { const B = JSON.parse(fs.readFileSync(f, 'utf8')).bounds; r = [B.left - B.right, B.top - B.bottom]; break; } } return (__yd[z] = r); };
// running speed, mounted from level 40 (tools/travel-facts.json MOUNT); a leg is planned at the level it starts at
const FACTS = require('./travel-facts.json');
const RUN = FACTS.MOUNT && cfg.level >= FACTS.MOUNT.level ? FACTS.MOUNT.speed : FACTS.RIDE;
// terrain-aware distances when a zone grid exists (terrain.js output); straight lines otherwise
const ZoneNav = require('./nav');
const navs = {};
const { VoxNav } = require('./voxnav');
const NAV = (z) => {
  if (!cfg.terrainDir) return null;
  if (navs[z] === undefined) {
    // layered walk map (buildings, caves) if built, else the plain terrain grid
    try { navs[z] = fs.existsSync(`${cfg.terrainDir}/area${z}.vox.json`) ? new VoxNav(cfg.terrainDir, z) : new ZoneNav(cfg.terrainDir, z); } catch (e) { navs[z] = null; }
  }
  return navs[z];
};
const zones = new Set(cfg.zones);
const inZones = (s) => s && zones.has(s.zone);
function straightDist(a, b) { if (!a || !b || a.zone !== b.zone) return 1e5; const [zw, zh] = yards(a.zone); return Math.hypot((a.x - b.x) / 100 * zw, (a.y - b.y) / 100 * zh); }
const MATRIX = {}; // zone -> { pts: [], lookup }
// nearest precomputed point for a location, remembered per location object (it was rescanned on every lookup)
const __snap = new Map();
function snapPoi(p) {
  const M = MATRIX[p.zone]; if (!M) return null;
  const c = __snap.get(p); if (c !== undefined && c.M === M) return c.r;
  let best = null, bd = Infinity, bi = -1;
  M.pts.forEach((q, i) => { const d = straightDist(p, q); if (d < bd) { bd = d; best = q; bi = i; } });
  const r = bd < 200 ? { q: best, off: bd, i: bi } : null;
  __snap.set(p, { M, r });
  return r;
}
function dist(a, b) {
  if (a && b && a.zone === b.zone && MATRIX[a.zone]) {
    const sa = snapPoi(a), sb = snapPoi(b);
    if (sa && sb) { const d = MATRIX[a.zone].D[sa.i * MATRIX[a.zone].pts.length + sb.i]; if (!Number.isNaN(d)) return isFinite(d) ? Math.max(straightDist(a, b), d + sa.off + sb.off - (sa.q === sb.q ? sa.off + sb.off : 0)) : straightDist(a, b) * 3; }
  }
  if (!a || !b) return 0;
  if (a.zone !== b.zone) return 1e5; // never walk between zones; travel() handles flights
  const [zw, zh] = yards(a.zone), straight = Math.hypot((a.x - b.x) / 100 * zw, (a.y - b.y) / 100 * zh);
  if (straight < 120) return straight; // town scale: buildings/towers aren't in the terrain data
  if (cfg.noLivePaths) return straight * 1.1;
  const nav = NAV(a.zone);
  if (nav) { const d = nav.dist(a, b); if (isFinite(d)) return Math.max(d, straight); }
  return straight;
  const [w, h] = yards(a.zone);
  return Math.hypot((a.x - b.x) / 100 * w, (a.y - b.y) / 100 * h);
}
// flight masters in the planned zones (and trainer cities)
const FLIGHT = {};
for (const n of Object.values(N)) if (n && /Gryphon Master|Hippogryph Master|Flight Master/.test(n.sub || '') && n.friendly !== 'H')
  for (const s of n.spawns) if (!FLIGHT[s.zone]) FLIGHT[s.zone] = { ...s, name: n.name };
// no start given (flying in from another zone): start at the first zone's flight master
if (!cfg.start) cfg.start = FLIGHT[cfg.zones[0]] ? { zone: cfg.zones[0], x: FLIGHT[cfg.zones[0]].x, y: FLIGHT[cfg.zones[0]].y } : null;
// a zone without a flight master (Zephras Isle): you arrive at its dock (tools/travel-facts.json)
if (!cfg.start && cfg.conversion) {
  try {
    const ui = (JSON.parse(fs.readFileSync(cfg.conversion, 'utf8')).geometry.transforms.find((t) => t.area_id === cfg.zones[0]) || {}).ui_map_id;
    const dock = Object.values(JSON.parse(fs.readFileSync(__dirname + '/travel-facts.json', 'utf8')).DOCKS).find((d) => d.m === ui);
    if (dock) cfg.start = { zone: cfg.zones[0], x: dock.x * 100, y: dock.y * 100 };
  } catch (e) {}
}
function travelSec(a, b) {
  if (!a || !b) return 0;
  if (a.zone === b.zone) return dist(a, b) / RUN;
  const fa = FLIGHT[a.zone], fb = FLIGHT[b.zone];
  if (fa && fb) return dist(a, fa) / RUN + cfg.flightSec + dist(fb, b) / RUN;
  return 600;
}

// ---------- xp ----------
const medianXp = (() => {
  const by = {};
  for (const q of Object.values(Q)) if (q.xp && q.level > 0 && q.level <= 60) (by[q.level] = by[q.level] || []).push(q.xp);
  const med = {};
  for (let l = 1; l <= 60; l++) { const p = []; for (let d = -2; d <= 2; d++) if (by[l + d]) p.push(...by[l + d]); p.sort((a, b) => a - b); med[l] = p.length ? p[p.length >> 1] : 100 * l; }
  return med;
})();
const BONUS = require('./bonus');
const FOREVER_XP = cfg.addonsDir ? BONUS.loadForeverXp(cfg.addonsDir) : {};
// Forever's own figure first: ForeverDungeonJournal's table is what Forever's client pays (Blackfathom Villainy 3300,
// Classic says 1650), the Classic value only when Forever's is not known
const baseXp = (q) => FOREVER_XP[q.id] || q.xp || medianXp[Math.max(1, Math.min(60, q.level))];
// chains expert guides call must-do (Missing Diplomat, Raene's Cleansing...): worth half their XP again, so they anchor the plan
const MUST_DO = new Set(cfg.mustDo || []);
const extraValue = (q) => { const t = tasks && tasks[q.id]; const v = t && t.qual; return (v ? v.rewardValue + v.funValue * baseXp(q) : 0) + (MUST_DO.has(q.id) ? baseXp(q) * (cfg.mustDoBonus ?? 0.5) : 0); };
const questXpAt = (q, L) => require('./world').questXp(baseXp(q), q.level, L); // the shared rule (world.js)
// one copy of the kill XP formula, shared with the optimizer so both count the levels you gain the same way
const { killXp } = require('./optimize');
const CAPITALS = CAPITAL_AREAS;

// ---------- helpers ----------
// How many of a thing a quest wants, read from its text: the number right before the thing's name, in the same clause
// ("Kill 12 Starving Dire Wolves and 8 Rabid Dire Wolves", "five Great Goretusk Snouts"). Words are compared in the
// singular (Wolves = Wolf). When objectives share their last word (Starving / Rabid Dire Wolf, Tough Condor / Crisp
// Spider Meat) the word that tells them apart is looked for instead. A thing with no number of its own is one
// (Snellig's Snuffbox, Kurzen's Head, each tablet fragment): the text's other numbers belong to other objectives.
// A quest already in your log knows best: the game says how many it needs.
const WORD_NUM = { one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10, eleven: 11, twelve: 12, thirteen: 13, fourteen: 14, fifteen: 15, sixteen: 16, seventeen: 17, eighteen: 18, nineteen: 19, twenty: 20, thirty: 30 };
function singular(w) {
  w = String(w).toLowerCase().replace(/'s$/, '').replace(/[^a-z0-9'-]/g, '');
  if (/ves$/.test(w)) return w.slice(0, -3) + 'f';
  if (/men$/.test(w)) return w.slice(0, -3) + 'man';
  if (/[^aeiou]ies$/.test(w)) return w.slice(0, -3) + 'y';
  if (/(ss|x|z|ch|sh)es$/.test(w)) return w.slice(0, -2);
  if (/[^s]s$/.test(w)) return w.slice(0, -1);
  return w;
}
// (a final e is ignored: "Oozes" loses its "es" like "Boxes" does)
const sameWord = (a, b) => a === b || a.replace(/e$/, '') === b.replace(/e$/, '') || (a.length >= 6 && b.length >= 6 && a.slice(0, 6) === b.slice(0, 6));
function objNames(q) { return q.objectives.map((o) => (o.kind === 'item' ? o.name : o.kind === 'kill' ? o.text || (N[o.npc] && N[o.npc].name) : o.text)).filter(Boolean); }
function countFor(q, name) {
  if (!name) return 1;
  const have = (cfg.active || {})[q.id];
  const lname = name.toLowerCase();
  const g = have && (have.objectives || []).find((o) => o.need > 0 && (o.text || '').toLowerCase().includes(lname));
  if (g) return g.need;
  const words = name.split(/\s+/).map(singular).filter(Boolean);
  const alpha = words.filter((w) => /[a-z]/.test(w));
  let key = alpha[alpha.length - 1] || words[words.length - 1];
  const rivals = objNames(q).filter((n) => n !== name).map((n) => n.split(/\s+/).map(singular)).filter((ws) => ws.includes(key));
  if (rivals.length) { const own = words.find((w) => !rivals.some((ws) => ws.includes(w))); if (own) key = own; }
  const tok = (q.text || []).join(' ').split(/\s+/);
  let numbers = 0, only = null;
  for (let i = 0; i < tok.length; i++) {
    const n = /^\d+$/.test(tok[i]) ? +tok[i] : WORD_NUM[tok[i].toLowerCase()];
    if (!n || words.includes(tok[i].toLowerCase())) continue; // part of the name itself (Super Reaper 6000)
    numbers++; only = n;
    for (let j = i + 1; j <= i + 6 && j < tok.length; j++) {
      const w = singular(tok[j]);
      if (sameWord(w, key)) return n;
      // the clause ends at punctuation (not at an abbreviation: Venture Co. Loggers), "and", "or" or the next number
      const stop = /[,;:!?]$/.test(tok[j]) || (/\.$/.test(tok[j]) && !/^[A-Z][a-z]{0,2}\.$/.test(tok[j]));
      if (stop || w === 'and' || w === 'or' || /^\d+$/.test(w) || WORD_NUM[w]) break;
    }
  }
  // one objective and one number in the whole text: that number is its count, whatever the text calls the thing
  return q.objectives.length === 1 && numbers === 1 ? Math.min(only, 30) : 1;
}
function cluster(spawns) {
  const pts = spawns.filter(inZones);
  if (!pts.length) return null;
  const cell = 5, vote = new Map();
  for (const p of pts) for (let dx = -1; dx <= 1; dx++) for (let dy = -1; dy <= 1; dy++) {
    const k = p.zone + ':' + (Math.floor(p.x / cell) + dx) + ':' + (Math.floor(p.y / cell) + dy);
    vote.set(k, (vote.get(k) || 0) + 1);
  }
  let bk = null, bv = -1;
  for (const [k, v] of vote) if (v > bv) { bv = v; bk = k; }
  const [z, cx, cy] = bk.split(':').map(Number);
  const near = pts.filter((p) => p.zone === z && Math.abs(p.x / cell - (cx + 0.5)) <= 1.5 && Math.abs(p.y / cell - (cy + 0.5)) <= 1.5);
  const x = near.reduce((s, p) => s + p.x, 0) / near.length, y = near.reduce((s, p) => s + p.y, 0) / near.length;
  // the hunting area: radius (yards) around the centre holding ~80% of those spawns - you're "there" anywhere inside it
  const [zw, zh] = yards(z);
  const ds = near.map((p) => Math.hypot((p.x - x) / 100 * zw, (p.y - y) / 100 * zh)).sort((a, b) => a - b);
  const area = Math.round(ds[Math.min(ds.length - 1, Math.floor(ds.length * 0.8))] || 0);
  return { zone: z, x: +x.toFixed(1), y: +y.toFixed(1), density: near.length, total: pts.length, spread: pts.length / near.length, area };
}
// the level of the mobs an objective has you fight: the ones at the spot the plan sends you to (the middle level of the
// spawns there), not the hardest mob anywhere in the world that drops the item - Murloc Fin also drops from level-29
// murlocs elsewhere while Redridge's are 22, and that gated Murloc Poachers for levels and carried it across legs
function levelAt(mobs, at, dungeon, q) {
  if (!mobs.length) return q.level;
  const lv = (m) => m.maxLevel || q.level;
  if (dungeon || !at) return Math.max(...mobs.map(lv)); // a dungeon run: the group meets the hardest of them
  const r = Math.max(at.area || 0, 60) + 30, here = [];
  for (const m of mobs) for (const s of m.spawns) if (s.zone === at.zone && straightDist(at, s) <= r) here.push(lv(m));
  if (!here.length) { const inz = mobs.filter((m) => m.spawns.some(inZones)); return Math.max(...(inz.length ? inz : mobs).map(lv)); }
  here.sort((a, b) => a - b);
  return here[here.length >> 1];
}
const nearest = (spawns, from) => { let b = null, bd = Infinity; for (const s of spawns) if (inZones(s)) { const d = from ? travelSec(from, s) : 0; if (d < bd) { bd = d; b = s; } } return b; };

// ---------- tasks ----------
const skipped = [];
const QUALITY = cfg.itemsJson ? require('./quality').makeQuality({ quests: Q, npcs: N, objects: O, items: readJsonCached(cfg.itemsJson), cls: cfg.class, verdicts: cfg.gearVerdicts }) : null;
// quests to treat as frustrating, with a reason (cfg.frustrating: { questId: reason }); drop rates and the rest are
// judged from the quest data (quality.js)
const CURATED_FRUSTRATING = Object.assign({}, cfg.frustrating || {});
const BOOKS = cfg.addonsDir && (cfg.booksCharDir || cfg.charDir) ? BONUS.loadBooks(cfg.addonsDir, cfg.booksCharDir || cfg.charDir, cfg.conversion, cfg.faction === 'horde' ? 'Horde' : 'Alliance').filter((b) => zones.has(b.zone)) : [];
const booksDone = new Set();
// dungeons we're willing to run (cfg.dungeons: list of dungeon area ids, or 'all')
const DUNGEONS = cfg.dungeonFile ? require('./dungeons').loadDungeons(cfg.dungeonFile) : { list: {}, byArea: {} };
const dungeonOn = (d) => d && (cfg.dungeons === 'all' || (cfg.dungeons || []).includes(d.id)) && zones.has(d.entrance.zone);
const dungeonOf = (spawns) => { for (const sp of spawns) { const d = DUNGEONS.byArea[sp.zone]; if (d) return d; } return null; };
const HOLIDAY_SORTS = new Set([-22, -284, -366, -364, -369, -370, -1001, -1002, -1003, -1004, -1005, -1006, -1007, -41, -376, -374, -375, -22, -101]);
// quests already finished in your log: always worth handing in, whatever their level or how annoying they were
// quests that open another quest (it lists them as a prerequisite): handing them in leads somewhere
let FOLLOW = null;
const opensFollowUp = (id) => { if (!FOLLOW) { FOLLOW = new Set(); for (const o of Object.values(Q)) for (const p of [...(o.preSingle || []), ...(o.preGroup || [])]) FOLLOW.add(p); } return FOLLOW.has(+id); };
const finishedInLog = (id) => { const a = (cfg.active || {})[id]; return !!(a && a.complete); };
// breadcrumb -> the quests it leads to (the quest data lists each quest's breadcrumbs)
const BREADCRUMB_OF = {};
for (const t of Object.values(Q)) for (const b of t.breadcrumbs || []) (BREADCRUMB_OF[b] = BREADCRUMB_OF[b] || []).push(t.id);
function eligible(q) {
  if (q.races && !raceOk(q.races, cfg.race)) return 'race';
  if (q.classes && !(q.classes & classBit)) return 'class';
  if (q.special & 1) return 'repeatable';
  if (HOLIDAY_SORTS.has(q.zone)) return 'holiday event';
  if (q.skill) return 'profession';
  if (q.reqSpell || q.minRep) return 'requirement';
  const isBonus = (cfg.bonusQuests || []).includes(q.id);
  if (!isBonus && (q.level > cfg.maxQuestLevel || q.reqLevel > cfg.maxQuestLevel)) return 'level';
  if (isBonus && q.reqLevel > cfg.level + 2) return 'level';
  // a must-do chain's low first step opens the good part. A quest already finished in your log is just a hand-in -
  // but one far below you (Messenger to Westfall at 26: 250 XP) isn't worth a trip either, unless it opens a follow-up
  if (q.level < cfg.minQuestLevel && !(cfg.mustDo || []).includes(q.id) && !(finishedInLog(q.id) && opensFollowUp(q.id))) return 'low level';
  // a breadcrumb (The Corruption Abroad) is no longer offered once the quest it leads to is in your log or done: the
  // giver has nothing for you (Argos Nightwhisper, 2026-11-09)
  if (!(cfg.active || {})[q.id] && (BREADCRUMB_OF[q.id] || []).some((t) => (cfg.completed || []).includes(t) || (cfg.active || {})[t])) return 'breadcrumb: its quest is already yours';
  return null;
}
const tasks = {}, TASK_DUMP = {};
for (const q of Object.values(Q)) {
  if (eligible(q)) continue;
  const starter = q.starters.find((s) => s.type !== 'item' && s.spawns && s.spawns.some(inZones));
  const finisherIn = q.finishers.find((s) => s.spawns && s.spawns.some(inZones));
  const finisherAny = q.finishers.find((s) => s.spawns && s.spawns.length);
  // a quest already in your log that you picked up somewhere else (A Scroll from Mauren from Stonetalon): no giver
  // here is needed, only its hand-in - else it was carried past its turn-in NPC leg after leg and never handed in
  const carriedIn = !starter && !!(cfg.active || {})[q.id] && !!finisherIn;
  if (!starter && !carriedIn) continue;  // item-started quests: v1 leaves them out
  if ([starter, ...q.finishers].some((s) => s && s.friendly === (cfg.faction === 'horde' ? 'A' : 'H'))) continue;
  if (!finisherIn && !finisherAny) continue;
  const t = { q, objs: [], flags: [] };
  t.accept = starter ? { who: starter.name, npc: starter.id, at: nearest(starter.spawns, null) } : { who: (q.starters[0] || {}).name, at: null, inLog: true };
  t.turnin = finisherIn ? { who: finisherIn.name, npc: finisherIn.id, spawns: finisherIn.spawns.filter(inZones) }
    : { who: finisherAny.name, npc: finisherAny.id, spawns: [], carry: finisherAny.spawns[0] };
  if (!finisherIn) t.flags.push('carry');
  let elite = false, outside = false;
  for (const o of q.objectives) {
    let spawns = [], label = '', work = 0, mobs = [], kills = 0, buying = false;
    if (o.kind === 'kill' || o.kind === 'killcredit') {
      for (const id of o.kind === 'kill' ? [o.npc] : o.npcs) if (N[id]) { spawns.push(...N[id].spawns); mobs.push(N[id]); }
      const nm = o.text || (mobs[0] && mobs[0].name);
      const n = countFor(q, nm); label = `Kill ${n} ${nm}`; work = n * cfg.secPerKill; kills = n;
      // a "kill" of someone friendly to you is a talk (Forever's "Speak with Illaya Amberwind and Coriella Calmbreeze"
      // is stored as kill credit on a level-20 elder and an innkeeper): no fight, no mob level holding the quest back
      const mine = cfg.faction === 'horde' ? 'H' : 'A';
      if (mobs.length && mobs.every((m) => m.friendly === 'AH' || m.friendly === mine)) { label = `Speak with ${nm}`; work = 15; kills = 0; mobs = []; }
    } else if (o.kind === 'item') {
      // your measured rate for this item (ForeverRouteDB.drops, 15+ kills) beats the Classic data: Forever changed some
      const obs = (cfg.observedDrops || {})[o.name];
      const measured = obs && obs.kills >= 15 ? Math.max(0.005, obs.drops / obs.kills) : null;
      const rate = (d) => (measured != null ? measured : o.rates && o.rates[d] != null ? o.rates[d] / 100 : null);
      const drops = o.npcDrops.filter((d) => rate(d) == null || rate(d) >= 0.02).map((d) => N[d]).filter(Boolean), objs = o.objectDrops.map((d) => O[d]).filter(Boolean);
      drops.forEach((d) => spawns.push(...d.spawns)); objs.forEach((d) => spawns.push(...d.spawns));
      const n = countFor(q, o.name);
      if (!drops.length && !objs.length && o.vendors.length) { label = `Buy ${n} ${o.name}`; work = 20; spawns = o.vendors.flatMap((v) => (N[v] ? N[v].spawns : [])); buying = true; }
      else if (objs.length && !drops.length) { label = `Loot ${n} ${o.name} from ${objs[0].name}`; work = n * cfg.secPerObject; }
      // rates of 80% and up are mostly Questie's flat placeholders - except a sure drop from the one mob that has it
      // (a named mob's head, Snellig's Snuffbox): that is one kill per item, not the 50% fallback
      else { const rs = drops.map((d) => rate(d.id)).filter((r) => r != null && (r < 0.79 || (r >= 0.995 && drops.length === 1))); const r = rs.length ? rs.reduce((a, b) => a + b, 0) / rs.length : cfg.dropRate; if (!rs.length && !(o.rates)) t.flags.push('unknown drop rate'); kills = Math.round(n / r); work = kills * cfg.secPerKill; label = `Collect ${n} ${o.name}` + (drops.length && drops.length <= 3 ? ` (${drops.map((d) => d.name).join(', ')})` : ''); }
      mobs = drops; var dropInfo = { need: n, rates: Object.fromEntries(drops.map((d) => [d.id, rate(d.id) ?? cfg.dropRate])) };
    } else if (o.kind === 'object') { if (O[o.object]) spawns = O[o.object].spawns; label = o.text || `Use ${O[o.object] ? O[o.object].name : 'object'}`; work = 15; }
    else if (o.kind === 'explore') { spawns = o.spawns; label = o.text || 'Explore'; work = /escort|protect|accompany/i.test(label) ? 300 : 5; }
    else continue;
    const allElite = mobs.length && mobs.every((m) => m.rank >= 1);
    // a vendor: the one nearest the quest (Innkeeper Helbrek in Menethil sells the Third Fleet's mead - the densest
    // cluster of sellers was Stormwind, and a plan hearthed there and flew back for one flagon)
    const ref = t.accept.at || (t.turnin.spawns || [])[0];
    const vend = buying && ref ? spawns.filter((sp) => sp.x >= 0).sort((a, b) => (a.zone === ref.zone ? 0 : 1) - (b.zone === ref.zone ? 0 : 1) || straightDist(a, ref) - straightDist(b, ref))[0] : null;
    let at = vend ? { ...vend, density: 1, total: 1, spread: 1 } : cluster(spawns);
    let dungeon = null;
    if (at && allElite) {
      for (const d of Object.values(DUNGEONS.list)) if (dungeonOn(d) && d.entrance.zone === at.zone && straightDist(d.entrance, at) < 450) { at = null; spawns = [{ zone: d.id, x: -1, y: -1, instance: true }]; break; }
    }
    if (!at) {
      const d = dungeonOf(spawns);
      if (dungeonOn(d)) { dungeon = d; at = { ...d.entrance, density: 1, total: 1, spread: 1 }; label = label + ' (in ' + d.name + ')'; work = 0; kills = 0; }
      else { outside = true; continue; }
    }
    if (allElite && !dungeon) elite = true; // dungeon mobs are elite by design: the run is planned as a group
    const mobLevel = levelAt(mobs, at, dungeon, q);
    // the same objective listed twice (The Great Outdoors: "use the campfire" twice, same object): one step does both
    if (t.objs.some((x) => x.label === label && x.at && at && x.at.x === at.x && x.at.y === at.y && x.at.zone === at.zone)) { dropInfo = null; continue; }
    t.objs.push({ dropPct: dropInfo ? Math.round(100 * Object.values(dropInfo.rates).reduce((x, y) => x + y, 0) / Math.max(1, Object.values(dropInfo.rates).length)) : undefined, label, at, work, kills, mobLevel, mobIds: mobs.map((m) => m.id), allSpawns: spawns.filter(inZones), drop: o.kind === 'item' && !dungeon ? dropInfo : null, dungeon: dungeon ? dungeon.id : null, killsFor: o.kind === 'kill' || o.kind === 'killcredit' ? mobs.map((m) => m.id) : null });
    dropInfo = null;
  }
  // several fights in one hunting ground (Tramping Paws: Mosshide Gnolls and Mongrels mixed together): one spot for
  // all of them, the densest part of their combined spawns - each at its own densest patch put the pin at one edge of
  // the area you farm (a player saw it low-left of the gnoll camp, the mongrels up and right)
  {
    const fights = t.objs.filter((o) => !o.dungeon && o.at && (o.kills > 0 || o.drop) && o.allSpawns && o.allSpawns.length);
    if (fights.length > 1) {
      const U = cluster(fights.flatMap((o) => o.allSpawns));
      if (U) for (const o of fights) if (o.at.zone === U.zone && straightDist(o.at, U) < (cfg.sharedHuntYards || 400)) o.at = { ...U, area: Math.max(U.area || 0, o.at.area || 0) };
    }
  }
  // what each objective was read as, before any filtering (cfg.tasksOut: for tools/test-route2-tasks.js)
  if (cfg.tasksOut) TASK_DUMP[q.id] = { name: q.name, objs: t.objs.map((o) => ({ label: o.label, kills: o.kills, mobLevel: o.mobLevel, dropPct: o.dropPct, need: o.drop ? o.drop.need : undefined })) };
  const totalKills = t.objs.reduce((s, o) => s + o.kills, 0);
  if (totalKills > cfg.maxKills && !(cfg.keep || []).includes(q.id) && !finishedInLog(q.id)) { skipped.push([q, `about ${totalKills} kills needed: not worth it`]); continue; }
  if (outside && !finishedInLog(q.id)) { skipped.push([q, 'objectives outside the planned zones (dungeon or other zone)']); continue; }
  if (elite && !(petClass && q.level <= cfg.level + 1) && !cfg.includeElite && !finishedInLog(q.id)) { skipped.push([q, 'elite objectives: group quest']); continue; }
  if (elite) t.flags.push('elite');
  if ((cfg.skip || []).includes(q.id)) { skipped.push([q, 'skipped in config']); continue; }
  // it needs an item brought in that isn't one of its objectives (Wowhead says so: tools/wowhead.js -> needsItems) -
  // the plan has no way to get it; once the quest is finished in your log it's just a hand-in
  // Forever removed it (tools/forever-overrides.json notInForever: the Felsteed chain)
  if (q.notInForever) { skipped.push([q, 'not in Forever']); continue; }
  if ((q.needsItems || []).length && !finishedInLog(q.id)) { skipped.push([q, 'needs an item the plan cannot get (' + q.needsItems.join(', ') + ')']); continue; }
  if (QUALITY) {
    t.qual = QUALITY(q, cfg.level);
    if (CURATED_FRUSTRATING[q.id]) { t.qual.frustration += 0.6; t.qual.reasons.push(CURATED_FRUSTRATING[q.id]); }
    const keepForReward = t.qual.rewardValue >= (cfg.keepRewardValue || 1200);
    if (t.qual.frustration >= (cfg.maxFrustration ?? 0.55) && !keepForReward && !(cfg.bonusQuests || []).includes(q.id) && !(cfg.keep || []).includes(q.id) && !finishedInLog(q.id)) {
      skipped.push([q, 'frustrating: ' + t.qual.reasons.join(', ')]); continue;
    }
  }
  tasks[q.id] = t;
}
if (cfg.tasksOut) { fs.writeFileSync(cfg.tasksOut, JSON.stringify(TASK_DUMP)); if (cfg.tasksOnly) process.exit(0); }
for (const t of Object.values(tasks)) for (const ex of t.q.exclusive) if (tasks[ex] && tasks[t.q.id]) {
  const loser = baseXp(tasks[ex].q) > baseXp(t.q) ? t.q.id : ex;
  skipped.push([tasks[loser].q, 'alternative to ' + (loser === ex ? t.q.name : tasks[ex].q.name)]); delete tasks[loser];
}
const done0 = new Set(cfg.completed || []);
// one of a set of alternatives already done or in your log (Adventurer quests like The Great Outdoors: one per
// character, offered in every start zone): the others are closed. Zones are planned one at a time, so the check
// above, within this zone, can't see the one you did in the last zone.
for (const [id, t] of Object.entries(tasks)) {
  const other = (t.q.exclusive || []).find((e) => done0.has(e) || (cfg.active || {})[e]);
  if (other && !(cfg.active || {})[id] && !done0.has(+id)) { skipped.push([t.q, 'alternative to quest ' + other + ', already done or in your log']); delete tasks[id]; }
}
for (let ch = true; ch;) {
  ch = false;
  for (const [id, t] of Object.entries(tasks)) {
    const q = t.q;
    // (a quest already in your log has had whatever it needed)
    const ok = !!(cfg.active || {})[id] || (q.preGroup.every((p) => done0.has(p) || tasks[p]) && (!q.preSingle.length || q.preSingle.some((p) => done0.has(p) || tasks[p])));
    if (!ok || done0.has(+id)) { if (!done0.has(+id)) skipped.push([q, 'needs an earlier quest that is not in this plan']); delete tasks[id]; ch = true; }
  }
}
module.exports.done = (async () => {
// ---------- distance tables (parallel) ----------
if (cfg.terrainDir) {
  const { matrix } = require('./dmatrix');
  const pois = [];
  for (const t of Object.values(tasks)) { if (t.accept.at) pois.push(t.accept.at); pois.push(...t.turnin.spawns); for (const o of t.objs) pois.push(o.at); }
  for (const z of zones) { if (FLIGHT[z]) pois.push(FLIGHT[z]); }
  if (cfg.start) pois.push(cfg.start);
  for (const z of zones) {
    const zp = pois.filter((p) => p && p.zone === z);
    if (!zp.length) continue;
    // a zone without a walk map (Forever's new Zephras Isle): straight lines, like before walk maps existed
    if (!['vox.json', 'json'].some((x) => fs.existsSync(`${cfg.terrainDir}/area${z}.${x}`))) { console.error(`zone ${z}: no walk map, straight lines`); continue; }
    const lookup = await matrix(cfg.terrainDir, z, zp, { workers: cfg.workers });
    const seen = new Map(); for (const p of zp) seen.set((+p.x).toFixed(1) + ',' + (+p.y).toFixed(1), { zone: z, x: +(+p.x).toFixed(1), y: +(+p.y).toFixed(1) });
    // the whole distance table for this zone up front (a lookup was string keys + object access in the hot loop)
    const pts = [...seen.values()], n = pts.length, D = new Float64Array(n * n);
    for (let i = 0; i < n; i++) for (let j = 0; j < n; j++) { const v = lookup(pts[i], pts[j]); D[i * n + j] = v === undefined ? NaN : v; }
    MATRIX[z] = { pts, lookup, D };
  }
  cfg.noLivePaths = true;
}
// XP-per-minute estimate: work + a round trip from the giver to the objective area
for (const t of Object.values(tasks)) {
  const trip = t.objs.reduce((s, o) => s + travelSec(t.accept.at, o.at), 0);
  const sec = t.objs.reduce((s, o) => s + o.work, 0) + trip * 0.6 + 20;
  t.xpm = baseXp(t.q) / (sec / 60);
}
if (cfg.minXpPerMin) for (const [id, t] of Object.entries(tasks)) if (t.xpm < cfg.minXpPerMin && !t.q.children.length && !Object.values(tasks).some((o) => o.q.preSingle.includes(+id) || o.q.preGroup.includes(+id))) {
  skipped.push([t.q, `low XP for the time (~${Math.round(t.xpm)} xp/min)`]); delete tasks[id];
}
// lonely detours (backtracking, tools/backtrack.js): an objective far (cfg.lonelyYards) from every other quest's places
// in its zone, on a quest worth less than most here - you'd ride out for it alone and straight back. Kept: must-do and
// kept quests, chain links, quests finished in your log, a good reward.
if (cfg.lonelyYards) {
  const all = Object.entries(tasks);
  const ptsOf = (t) => [t.accept.at, ...(t.turnin.spawns || []), ...t.objs.map((o) => o.at)].filter(Boolean);
  const xs = all.map(([, t]) => t.xpm).filter(isFinite).sort((a, b) => a - b), med = xs[xs.length >> 1] || 0;
  const linked = (id) => Object.values(tasks).some((o) => o.q.preSingle.includes(+id) || o.q.preGroup.includes(+id));
  let n = 0;
  for (const [id, t] of all) {
    if (MUST_DO.has(+id) || (cfg.keep || []).includes(+id) || finishedInLog(+id) || t.q.children.length || linked(id)) continue;
    if ((t.qual && t.qual.rewardValue >= (cfg.keepRewardValue || 1200)) || !(t.xpm < med * (cfg.lonelyXpShare ?? 1))) continue;
    const others = all.filter(([o]) => o !== id).flatMap(([, o]) => ptsOf(o));
    const far = t.objs.find((o) => o.at && others.every((p) => p.zone !== o.at.zone || dist(o.at, p) > cfg.lonelyYards));
    if (far) { skipped.push([t.q, `a lonely detour: ${(far.o && far.o.name) || 'its objective'} is far from every other quest here, for ~${Math.round(t.xpm)} xp/min`]); delete tasks[id]; n++; }
  }
  if (n) console.error(`${n} lonely detour(s) left out`);
}

// ---------- hubs ----------
// hubs come from the towns themselves: every friendly quest giver/ender, innkeeper and flight master in these
// zones (not just the quests still left), so a hub keeps its shape as quests get done
const npcPts = [];
{
  const foe = cfg.faction === 'horde' ? 'A' : 'H';
  const seen = new Set();
  const addNpc = (n) => { if (!n || seen.has(n.id) || n.friendly === foe || !n.friendly || n.spawns.length > 6) return; /* skip critters and wandering mobs that happen to give quests */ seen.add(n.id); for (const sp of n.spawns) if (inZones(sp)) npcPts.push({ ...sp, npc: n.id, who: n.name }); };
  for (const q of Object.values(Q)) { if (q.races && !raceOk(q.races, cfg.race)) continue; for (const st of [...q.starters, ...q.finishers]) if (st.type === 'npc') addNpc(N[st.id]); }
  for (const n of Object.values(N)) if (n && /Innkeeper|Gryphon Master|Flight Master/.test(n.sub || '')) addNpc(n);
}
const hubs = [];
for (const p of npcPts) {
  const joined = hubs.filter((h) => h.pts.some((q) => straightDist(q, p) < cfg.hubYards));
  let h = joined[0];
  if (!h) { h = { zone: p.zone, x: p.x, y: p.y, npcs: new Map(), pts: [] }; hubs.push(h); }
  for (const o of joined.slice(1)) { h.pts.push(...o.pts); for (const [k, v] of o.npcs) h.npcs.set(k, v); hubs.splice(hubs.indexOf(o), 1); }
  h.pts.push(p); h.npcs.set(p.npc, p.who);
}
for (const h of hubs) { const ps = h.pts; h.x = ps.reduce((s, p) => s + p.x, 0) / ps.length; h.y = ps.reduce((s, p) => s + p.y, 0) / ps.length; }
const questCount = {}; for (const q of Object.values(Q)) for (const st of [...q.starters, ...q.finishers]) if (st.type === 'npc') questCount[st.name] = (questCount[st.name] || 0) + 1;
const realHubs = hubs.filter((h) => h.npcs.size >= cfg.minHubNpcs || [...h.npcs.values()].some((n) => (questCount[n] || 0) >= 3)).sort((a, b) => b.npcs.size - a.npcs.size);
const inHub = (h, p) => h.pts.some((q) => straightDist(q, p) < cfg.hubYards);
const hubOf = (p) => realHubs.find((h) => inHub(h, p));
for (const h of realHubs) { const names = [...h.npcs.values()].sort((x, y) => (questCount[y] || 0) - (questCount[x] || 0)); const hit = names.find((n) => (cfg.hubNames || {})[n]); h.name = hit ? cfg.hubNames[hit] : `${zname(h.zone)}: ${names.slice(0, 2).join(', ')}`; }

// ---------- simulation ----------
if (cfg.arriveFrom && cfg.arriveFrom.zone !== cfg.zones[0]) {
  const T = Object.fromEntries(JSON.parse(fs.readFileSync(cfg.conversion, 'utf8')).geometry.transforms.map((t) => [t.area_id, t]));
  const world = (p) => { const t = T[p.zone]; if (!t || !t.target_bounds) return null; const b = t.target_bounds; return { c: t.map_id, x: b.top - (p.y / 100) * (b.top - b.bottom), y: b.left - (p.x / 100) * (b.left - b.right) }; };
  const wd = (a, b) => (a && b && a.c === b.c ? Math.hypot(a.x - b.x, a.y - b.y) : Infinity);
  const from = world(cfg.arriveFrom), fm = FLIGHT[cfg.zones[0]];
  let best = null, bd = Infinity;
  for (const h of realHubs) { if (h.zone !== cfg.zones[0]) continue; const d = wd(from, world(h)); if (d < bd) { bd = d; best = h; } }
  if (best) {
    const flyYd = cfg.arriveKnowsFP && fm ? 700 + wd(world(fm), world(best)) : Infinity;
    if (bd < flyYd) { cfg.start = { zone: best.zone, x: best.x, y: best.y }; console.error('arriving on foot from ' + zname(cfg.arriveFrom.zone) + ': starting at ' + (best.name || 'the nearest quest town') + ' (' + Math.round(bd) + ' yd)'); }
  }
}
let level = cfg.level, xp = cfg.xp || 0, pos = cfg.start, clock = 0;
// bound in a town outside this leg's zones (Astranaar while questing in Duskwood): the stone is no use here, so the
// simulation rebinds at the main hub like the step writer does
let hearth = cfg.hearth && zones.has(cfg.hearth.zone) ? cfg.hearth : null, hearthReadyAt = cfg.hearthCdLeft || 0, chosenHearth = null;
const accepted = new Set(), turned = new Set(done0), objDone = {}, fpKnown = new Set(cfg.flightPaths || []);
// quests already in the log: accepted; finished quests have all objectives done
// quests from other zones stay in your log untouched (passed on to the next leg as they came in)
const passActive = {};
for (const [id, q] of Object.entries(cfg.active || {})) {
  const t = tasks[id]; if (!t) { passActive[id] = q; continue; }
  accepted.add(+id);
  if (q.complete) t.objs.forEach((o, i) => (objDone[id] = objDone[id] || new Set()).add(i));
  else q.objectives.forEach((g) => { if (!g.done) return; const nm = (g.text || '').toLowerCase(); t.objs.forEach((o, i) => { if (nm && o.label.toLowerCase().includes(nm.replace(/:.*$/, '').replace(/ slain$/, '').trim())) (objDone[id] = objDone[id] || new Set()).add(i); }); });
}
const out = [];
const odone = (id, i) => objDone[id] && objDone[id].has(i);
const markObj = (id, i) => (objDone[id] = objDone[id] || new Set()).add(i);
const step = (s) => out.push({ ...s, clock: Math.round(clock), lvl: level, curXp: xp });
let gainedTotal = 0; // XP this leg so far (the rate a trip away has to beat: cfg.awayHubShare)
function gain(n) { xp += n; gainedTotal += n; while (level < 60 && xp >= XP_TO_LEVEL[level]) { xp -= XP_TO_LEVEL[level]; level++; step({ type: 'level' }); } }
const ready = (t) => t.objs.every((o, i) => odone(t.q.id, i));
// kill objectives against mobs well above you wait until you are close enough (a level-19 warlock and level-24 skeletons)
const tooHigh = (o) => o.kills > 0 && (o.mobLevel || 0) > level + cfg.maxMobAbove - 1;
// a quest that is all fighting, with every fight still out of reach a level later, is picked up when you get there:
// taking it now only fills a log slot and gets carried from zone to zone
function acceptLevel(t) {
  if (!t.objs.length || !t.objs.every((o) => o.kills > 0) || finishedInLog(t.q.id)) return 0;
  return Math.min(...t.objs.map((o) => (o.mobLevel || 0) - cfg.maxMobAbove));
}
const canAccept = (t) => !accepted.has(t.q.id) && !turned.has(t.q.id) && t.q.reqLevel <= level && acceptLevel(t) <= level && (t.q.level <= level + cfg.maxAbove - 1 || (cfg.bonusQuests || []).includes(t.q.id))
  && t.q.preGroup.every((p) => turned.has(p)) && (!t.q.preSingle.length || t.q.preSingle.some((p) => turned.has(p))) && (!t.q.parent || accepted.has(t.q.parent));
function moveTo(p, why) {
  if (!p) return;
  if (pos && p.zone !== pos.zone) {
    const fa = FLIGHT[pos.zone], fb = FLIGHT[p.zone];
    step({ type: 'fly', from: pos.zone, to: p.zone, at: fa, note: why });
  }
  clock += travelSec(pos, p); pos = p;
  const f = FLIGHT[p.zone];
  if (f && !fpKnown.has(p.zone) && dist(p, f) < 150) { fpKnown.add(p.zone); step({ type: 'fp', at: f, who: f.name }); }
}
// everything doable at a spot: turn-ins first (they unlock follow-ups), then accepts, then objectives
function workHere(spot, radius) {
  let did = 0;
  for (let again = true; again;) {
    again = false;
    for (const t of Object.values(tasks)) {
      const id = t.q.id;
      if (accepted.has(id) && ready(t) && t.turnin.spawns.some((s) => dist(s, spot) < radius)) {
        accepted.delete(id); turned.add(id); const g = questXpAt(t.q, level);
        step({ type: 'turnin', q: t.q, who: t.turnin.who, at: nearest(t.turnin.spawns, spot), xp: g }); gain(g); did++; again = true;
      }
    }
    for (const t of Object.values(tasks)) {
      // the log holds 40 on Forever, shared with the quests you carry for other zones
      if (accepted.size + Object.keys(passActive).length >= cfg.maxLog) break;
      if (canAccept(t) && dist(t.accept.at, spot) < radius) { accepted.add(t.q.id); step({ type: 'accept', q: t.q, who: t.accept.who, at: t.accept.at }); did++; again = true; }
    }
  }
  return did;
}
function workLoners() {
  const spots = [];
  for (const t of Object.values(tasks)) {
    if (accepted.has(t.q.id) && ready(t)) for (const sp of t.turnin.spawns || []) if (inZones(sp) && !realHubs.some((h) => inHub(h, sp))) spots.push(sp);
    if (canAccept(t) && t.accept.at && inZones(t.accept.at) && !realHubs.some((h) => inHub(h, t.accept.at))) spots.push(t.accept.at);
  }
  if (!spots.length) return false;
  spots.sort((a, b) => travelSec(pos, a) - travelSec(pos, b));
  const sp = spots[0];
  moveTo(sp);
  return workHere(sp, 15) > 0;
}
function workHub(h) {
  // walk the hub's NPCs in order; repeat so follow-ups unlocked by turn-ins are picked up
  let total = 0;
  for (let k = 0; k < 4; k++) { let n = 0; for (const p of h.pts) n += workHere(p, 15); total += n; if (!n) break; }
  return total;
}
// a hub that was visited and gave nothing (a giver the visit can't reach, a full log) is not picked again at this level:
// a Dustwallow leg once "visited" Swamp Eye Jarl 400 times doing nothing, and the whole leg came out empty
const deadHubs = new Set();
function doObjectivesAt(spot) {
  const here = [];
  for (const t of Object.values(tasks)) if (accepted.has(t.q.id)) t.objs.forEach((o, i) => { if (!odone(t.q.id, i) && !tooHigh(o) && dist(o.at, spot) < cfg.mergeYards && (!o.dungeon || dungeonReady(o.dungeon))) here.push([t, o, i]); });
  const runs = [...new Set(here.filter(([, o]) => o.dungeon).map(([, o]) => o.dungeon))];
  for (const id of runs) {
    const d = DUNGEONS.list[id];
    const min = (cfg.dungeonMinutes && cfg.dungeonMinutes[id]) || cfg.dungeonRunMin || 50;
    clock += (min + (cfg.groupWaitMin ?? 10)) * 60;
    // the run's own kill XP as a share of a level: Forever pays about half of Classic's in dungeons even after the Nov 8
    // 2026 hotfix (+50% dungeon kill XP, Kaivax; launch was ~70% below Classic - docs/research/world-facts.md), and a
    // group splits it (x1.4/5 each); 0.35 of a level per run is the working figure until your own runs measure it
    const runXp = Math.round(XP_TO_LEVEL[level] * (cfg.dungeonLevelFraction ?? 0.35));
    step({ type: 'dungeon', at: spot, name: d.name, dungeon: id, minutes: min, runXp });
    gain(runXp);
  }
  if (!here.length) return;
  // shared mobs: objectives on the same mobs are worked at the same time, pay the longest one
  const work = Math.max(...here.map(([, o]) => o.work)) + 0.35 * (here.reduce((s, [, o]) => s + o.work, 0) - Math.max(...here.map(([, o]) => o.work)));
  clock += work;
  let kx = 0; for (const [, o] of here) kx += o.kills * killXp(o.mobLevel, level);
  step({ type: 'do', at: spot, items: here.map(([t, o]) => ({ q: t.q, label: o.label, bg: o.bg })) });
  for (const [t, , i] of here) markObj(t.q.id, i);
  gain(kx);
  // drops lining up (Wowhead rates): mobs killed here also drop items for other open quests
  const killed = {}; // mobId -> kills
  for (const [, o] of here) {
    const ids = o.killsFor || (o.drop ? o.mobIds : null);
    if (!ids || !ids.length) continue;
    // the kills go to each mob by how many of it live around the spot (46 Great Goretusks and one Bellygrub: he gets
    // about 2%, not a third). A lone mob (one spawn, or a rare) counts only when it is what you came for - a kill
    // target, or the only mob the item drops from - you do not kill him by chance while farming the others
    const r = Math.max(cfg.mergeYards, (o.at && o.at.area) || 0) + 30;
    const lone = (m) => !N[m] || N[m].spawns.length <= 1 || N[m].rank === 2 || N[m].rank === 4;
    const w = ids.map((m) => (!o.killsFor && ids.length > 1 && lone(m) ? 0 : N[m] ? N[m].spawns.filter((s) => s.zone === spot.zone && straightDist(s, spot) <= r).length : 0));
    let sum = w.reduce((a, b) => a + b, 0);
    // none of them right at the spot (a spread-out objective): share evenly among the ones that are not lone mobs
    if (!sum) { ids.forEach((m, k) => { w[k] = o.killsFor || ids.length === 1 || !lone(m) ? 1 : 0; }); sum = w.reduce((a, b) => a + b, 0); }
    if (sum) ids.forEach((m, k) => { if (w[k]) killed[m] = (killed[m] || 0) + o.kills * w[k] / sum; });
  }
  const extra = [];
  for (const t of Object.values(tasks)) if (accepted.has(t.q.id)) t.objs.forEach((o, i) => {
    // nothing counts as done before you can fight the mobs it drops from (as for every other objective)
    if (odone(t.q.id, i) || !o.drop || tooHigh(o)) return;
    let got = 0; for (const [m, k] of Object.entries(killed)) if (o.drop.rates[m]) got += k * Math.min(0.95, o.drop.rates[m]);
    if (!got) return;
    o.progress = (o.progress || 0) + got / o.drop.need;
    if (o.progress >= 1) { markObj(t.q.id, i); extra.push({ q: t.q, label: o.label, bg: true, shared: true }); }
  });
  if (extra.length) step({ type: 'do', at: spot, items: extra });
}
// background objectives: broad spawns that a loop passes through several times
function markBackground(stops) {
  for (const t of Object.values(tasks)) if (accepted.has(t.q.id)) t.objs.forEach((o, i) => {
    if (odone(t.q.id, i) || !o.kills) return;
    const near = stops.filter((s) => o.allSpawns.some((p) => dist(p, s) < 80)).length;
    o.bg = near >= cfg.backgroundMinStops;
  });
}
// a quest is still coming if its prerequisites are all in the plan (or done) — e.g. VanCleef after the escort
function stillComing(t, seen = new Set()) {
  if (turned.has(t.q.id) || accepted.has(t.q.id)) return false;
  if (seen.has(t.q.id)) return false; seen.add(t.q.id);
  const pre = [...t.q.preGroup, ...t.q.preSingle];
  return pre.every((p) => turned.has(p) || (tasks[p] && (accepted.has(p) || stillComing(tasks[p], seen)))) && t.q.reqLevel <= cfg.maxQuestLevel;
}
let forceDungeons = false;
const hopped = {}; // zone -> times we flew there for leftover objectives (stop after 2) // set when nothing else is left to do
// dungeons already run earlier on this path (campaign.js passes them on from leg to leg): every Eastern Kingdoms leg
// has Stormwind and so the Stockade entrance, and each leg ran it again for whatever Stockade quest it held - four
// 55-minute runs on one path. A second run needs enough of its quests waiting to be worth a group.
const RUN_BEFORE = new Set(cfg.dungeonsRun || []);
const openIn = (id) => Object.values(tasks).filter((t) => accepted.has(t.q.id) && t.objs.some((o, i) => o.dungeon === id && !odone(t.q.id, i))).length;
function dungeonReady(id) {
  if (RUN_BEFORE.has(id) && openIn(id) < (cfg.dungeonRerunMin ?? 3)) return false;
  // not before you can take its bosses: the toughest objective mob in it within the group margin (world.js)
  let top = 0;
  for (const t of Object.values(tasks)) if (accepted.has(t.q.id)) for (const o of t.objs) if (o.dungeon === id && o.mobLevel) top = Math.max(top, o.mobLevel);
  if (top > level + DUNGEON_ABOVE) return false;
  if (forceDungeons) return true;
  // wait until every quest with objectives in this dungeon that this plan can still reach is in the log
  for (const t of Object.values(tasks)) {
    if (turned.has(t.q.id) || accepted.has(t.q.id)) continue;
    if (t.objs.some((o) => o.dungeon === id) && (canAccept(t) || stillComing(t))) return false;
  }
  return true;
}
function planLoop(home) {
  // open objective spots of accepted quests (one per objective; merged later at execution)
  let pts = [];
  for (const t of Object.values(tasks)) if (accepted.has(t.q.id)) t.objs.forEach((o, i) => { if (!odone(t.q.id, i) && !tooHigh(o) && o.at.zone === home.zone && (!o.dungeon || dungeonReady(o.dungeon))) pts.push(o.at); });
  // field quest givers / turn-in NPCs outside hubs are stops too when they have something for us
  const objOnly = [...pts];
  for (const b of BOOKS) if (!booksDone.has(b.id) && b.zone === home.zone && objOnly.some((p) => dist(p, b) < (cfg.bookDetourYards || 350))) pts.push({ zone: b.zone, x: b.x, y: b.y });
  for (const t of Object.values(tasks)) if (canAccept(t) && !hubOf(t.accept.at) && t.accept.at.zone === home.zone && (objOnly.some((p) => dist(p, t.accept.at) < cfg.detourYards) || dist(home, t.accept.at) < cfg.detourYards)) pts.push(t.accept.at);
  // ready turn-ins at field NPCs on the way
  for (const t of Object.values(tasks)) if (accepted.has(t.q.id) && ready(t)) for (const sp of t.turnin.spawns) if (!hubOf(sp) && objOnly.some((p) => dist(p, sp) < cfg.detourYards)) pts.push(sp);
  const objPts = [...pts];
  for (let i = pts.length - 1; i >= 0; i--) if (!objPts.includes(pts[i])) {}
  if (!pts.length) return [];
  // dedupe spots within merge distance
  const uniq = []; for (const p of pts) if (!uniq.some((u) => dist(u, p) < cfg.mergeYards)) uniq.push(p);
  // nearest neighbour from home
  let route = [], cur = home, left = [...uniq];
  while (left.length) { left.sort((a, b) => dist(cur, a) - dist(cur, b)); cur = left.shift(); route.push(cur); }
  // 2-opt on home -> route -> home
  const len = (r) => { let s = dist(home, r[0]); for (let i = 1; i < r.length; i++) s += dist(r[i - 1], r[i]); return s + dist(r[r.length - 1], home); };
  for (let imp = true; imp;) { imp = false; for (let i = 0; i < route.length - 1; i++) for (let j = i + 1; j < route.length; j++) { const r = [...route.slice(0, i), ...route.slice(i, j + 1).reverse(), ...route.slice(j + 1)]; if (len(r) + 1 < len(route)) { route = r; imp = true; } } }
  // cut the loop at maxTripMin of estimated time (rest waits for the next loop)
  let t = 0, cutAt = route.length, prev = home;
  for (let i = 0; i < route.length; i++) { t += dist(prev, route[i]) / RUN + 90; prev = route[i]; if (t > cfg.maxTripMin * 60) { cutAt = Math.max(1, i); break; } }
  return route.slice(0, cutAt);
}
function bestHub() {
  // value of visiting: XP of ready turn-ins + rough value of new accepts, per second of travel
  let best = null, bv = 0, anyBest = null, anyV = 0;
  const logFull = accepted.size + Object.keys(passActive).length >= cfg.maxLog;
  for (const h of realHubs) {
    if (deadHubs.has(h.name + ':' + level)) continue;
    let v = 0;
    for (const t of Object.values(tasks)) {
      if (accepted.has(t.q.id) && ready(t) && t.turnin.spawns.some((s) => inHub(h, s))) v += questXpAt(t.q, level);
      if (!logFull && canAccept(t) && inHub(h, t.accept.at)) v += (questXpAt(t.q, level) + extraValue(t.q)) * 0.5;
    }
    let sec = travelSec(pos, h) + 30;
    if (v / sec > anyV) { anyV = v / sec; anyBest = h; }
    // a hub in another zone (a capital mid-zone, for one pick-up): you fly there and back, and it has to be worth a
    // share of the XP rate you've been making, or it waits until the route passes it (cfg.awayHubShare)
    if (cfg.awayHubShare && pos && h.zone !== pos.zone) {
      sec += travelSec(h, pos);
      // the leg's own rate once it has one; before that, a level per 1.5 h (a trip at the start of a leg counts too)
      const rate = clock > 600 ? gainedTotal / clock : XP_TO_LEVEL[level] / 5400;
      if (v / sec < cfg.awayHubShare * rate) continue;
    }
    if (v / sec > bv) { bv = v / sec; best = h; }
  }
  // mid-leg, no hub worth the trip ends the leg (the route moves on); a leg that has done nothing yet still takes the
  // best hub - never a leg of 0 steps
  return best || (gainedTotal === 0 ? anyBest : null);
}
const trainLevels = new Set(cfg.trainLevels);
// the level you last trained at (carried from the leg before: ranks left waiting there still count)
let trainedAt = cfg.trainedAt ?? cfg.level;
function maybeTrain() {
  const due = [...trainLevels].filter((l) => l > trainedAt && l <= level);
  // batched (world.js): two ranks waiting, or the route is in the trainer's city anyway
  if (!TRAINERS.length || !trainNow(due, pos && TRAINERS.some((tr) => tr.zone === pos.zone))) return;
  const trainer = nearestTrainer(pos);
  const back = pos;
  step({ type: 'train', at: trainer, levels: due, note: trainer.note || cfg.trainerNote });
  // the round trip from where you are, on the travel network the arrow uses (in Stormwind it is a walk; from Kalimdor
  // it is boats); the flat trainerTripMin only when the trip can't be priced
  const there = pos && tripSec(pos, trainer), home = pos && tripSec(trainer, pos);
  clock += there != null && home != null ? there + home + 120 : cfg.trainerTripMin * 60;
  trainedAt = level;
  pos = back; // round trip, ends back where we were
}
// your class trainers (cfg.trainers: Stormwind and Ironforge for an Alliance warlock; cfg.trainer alone still works);
// you train at the one quicker to reach from where you are
const TRAINERS = (cfg.trainers && cfg.trainers.length) ? cfg.trainers : (cfg.trainer ? [cfg.trainer] : []);
function nearestTrainer(p) {
  if (TRAINERS.length < 2 || !p) return TRAINERS[0];
  let best = TRAINERS[0], bs = Infinity;
  for (const tr of TRAINERS) { const s = tripSec(p, tr); if (s != null && s < bs) { bs = s; best = tr; } }
  return best;
}
// seconds from a to b ({ zone: area id, x, y in 0-100 }) by the shared travel network, with your flight paths and level
let travelNet = null;
function tripSec(a, b) {
  try {
    if (!travelNet) { travelNet = require('./travel'); travelNet.init(cfg.conversion); }
    const m1 = travelNet.uiOfArea(a.zone), m2 = travelNet.uiOfArea(b.zone);
    if (!m1 || !m2) return null;
    const known = new Set((cfg.flightPaths || []).map((z) => travelNet.uiOfArea(z)).filter(Boolean));
    const r = travelNet.plan({ m: m1, x: a.x / 100, y: a.y / 100 }, { m: m2, x: b.x / 100, y: b.y / 100 }, { level, knownFP: known, race: cfg.race, class: cfg.class });
    return r ? r.sec : null;
  } catch (e) { return null; }
}
function goHome(h) {
  const walk = travelSec(pos, h);
  if (hearth && inHub(h, hearth) && clock >= hearthReadyAt && walk > 120) {
    step({ type: 'hearth', at: h, saved: Math.round(walk - 10) }); clock += 10; hearthReadyAt = clock + cfg.hearthCooldownMin * 60; pos = h; return;
  }
  moveTo(h);
}

// opening: go to the first hub, bind hearth at the biggest hub when we pass it
const INNS = Object.values(N).filter((n) => n && /Innkeeper/.test(n.sub || '') && n.friendly !== (cfg.faction === 'horde' ? 'A' : 'H')).flatMap((n) => n.spawns.filter(inZones).map((s) => ({ ...s, name: n.name })));
// where to bind: an inn town in the zone you are questing in (Darkshire for Duskwood), not Stormwind just because the
// capital is always in the zone list and has the most NPCs
const mainHub = realHubs.find((h) => h.zone === cfg.zones[0] && INNS.some((i) => inHub(h, i))) || realHubs.find((h) => INNS.some((i) => inHub(h, i))) || realHubs[0];
const innOf = (h) => INNS.find((i) => inHub(h, i));
if (!cfg.hearth && cfg.bindName) {
  const want = String(cfg.bindName).toLowerCase();
  const inn = INNS.find((i) => { const h = hubOf(i); const z = zname(i.zone).toLowerCase(), hn = ((h && h.name) || "").toLowerCase(); return z === want || want.startsWith(z + " ") || z.startsWith(want) || (hn && (hn === want || hn.startsWith(want + ":"))); });
  if (inn) cfg.hearth = { zone: inn.zone, x: inn.x, y: inn.y, name: inn.name };
}
// arrival tour: pick up from every hub first (nearest-first, ending at the main hub) so the
// field loops can work many quests' objectives together, like a hand-written guide's first pass
if (cfg.arrivalTour) {
  let left = realHubs.filter((h) => h.zone === cfg.zones[0] && Object.values(tasks).some((t) => canAccept(t) && inHub(h, t.accept.at)));
  let first = true;
  while (left.length) {
    left.sort((a, b) => (inHub(b, pos) - inHub(a, pos)) || ((a === mainHub) - (b === mainHub)) || travelSec(pos, a) - travelSec(pos, b));
    const h = left.shift();
    if (!inHub(h, pos)) goHome(h);
    pos = { zone: h.zone, x: h.x, y: h.y };
    step({ type: 'hub', at: h, name: h.name + (first ? ' (pick-up run)' : '') }); first = false;
    if (!hearth && h === mainHub) { hearth = { zone: h.zone, x: h.x, y: h.y }; step({ type: 'bind', at: innOf(h) || h, who: (innOf(h) || {}).name }); }
    workHub(h);
    // objectives right next to this hub get done now
    for (const t of Object.values(tasks)) if (accepted.has(t.q.id)) t.objs.forEach((o, i) => { if (!odone(t.q.id, i) && !tooHigh(o) && dist(o.at, h) < cfg.mergeYards * 2) { moveTo(o.at); doObjectivesAt(o.at); } });
  }
}
for (let guard = 0; guard < 400; guard++) {
  if (level >= cfg.targetLevel && !cfg.finishOpen) break;
  const h = bestHub();
  const anyOpen = Object.values(tasks).some((t) => accepted.has(t.q.id) && !t.flags.includes('carry'));
  if (!h && !anyOpen) break;
  if (h) {
    if (!pos || !inHub(h, pos)) goHome(h); else pos = { zone: h.zone, x: h.x, y: h.y };
    step({ type: 'hub', at: h, name: h.name });
    if (!hearth && h === mainHub) { hearth = { zone: h.zone, x: h.x, y: h.y }; step({ type: 'bind', at: innOf(h) || h, who: (innOf(h) || {}).name }); }
    if (!workHub(h)) deadHubs.add(h.name + ':' + level);
    maybeTrain();
  }
  const home = h || pos;
  const loop = planLoop(home);
  if (!loop.length && !forceDungeons && Object.values(tasks).some((t) => accepted.has(t.q.id) && t.objs.some((o, i) => o.dungeon && !odone(t.q.id, i)))) {
    // nothing else to do: run the dungeon with what we have
    const other = Object.values(tasks).some((t) => canAccept(t)) || Object.values(tasks).some((t) => accepted.has(t.q.id) && !t.objs.some((o) => o.dungeon) && ready(t));
    if (!other) { forceDungeons = true; continue; }
  }
  // lone quest NPCs out in the field (Teronis' Corpse): not part of any hub, so hub visits never reach them -
  // when the loop has nothing else, go hand in / pick up there, nearest first
  if (!loop.length && workLoners()) continue;
  if (!loop.length) {
    // nothing left in this zone: go where open objectives are (e.g. back from a city run)
    const elsewhere = [];
    for (const t of Object.values(tasks)) if (accepted.has(t.q.id)) t.objs.forEach((o, i) => { if (!odone(t.q.id, i) && !tooHigh(o) && o.at.zone !== (pos && pos.zone) && (!o.dungeon || dungeonReady(o.dungeon)) && !(hopped[o.at.zone] >= 2)) elsewhere.push(o.at); });
    if (elsewhere.length && guard < 390) {
      hopped[elsewhere[0].zone] = (hopped[elsewhere[0].zone] || 0) + 1;
      const z = elsewhere[0].zone, hz = realHubs.find((h) => h.zone === z);
      moveTo(hz ? { zone: z, x: hz.x, y: hz.y } : elsewhere[0], 'objectives left in ' + zname(z));
      continue;
    }
    const pend = Object.values(tasks).some((t) => accepted.has(t.q.id) && ready(t) && t.turnin.spawns.length) || Object.values(tasks).some((t) => canAccept(t)); if (!h || !pend) break; continue; }
  markBackground(loop);
  step({ type: 'loop', stops: loop.length });
  for (const spot of loop) {
    moveTo(spot);
    for (const b of BOOKS) if (!booksDone.has(b.id) && b.zone === spot.zone && straightDist(b, spot) < 25) { booksDone.add(b.id); clock += 30; step({ type: 'bonus', at: { zone: b.zone, x: b.x, y: b.y }, book: b }); }
    workHere(spot, cfg.mergeYards);
    doObjectivesAt(spot);
    workHere(spot, cfg.mergeYards);
  }
  // grind-to-threshold: if a training level is close and the next hub batch won't reach it, top up here
  const nextTrain = [...trainLevels].find((l) => l > level);
  // never in a capital: there are no mobs to grind there (the step writer leaves such a grind out, so counting its XP
  // here put the simulation a level ahead of the steps and of the optimizer)
  if (nextTrain === level + 1 && !(pos && CAPITALS.has(pos.zone))) {
    const pending = Object.values(tasks).filter((t) => accepted.has(t.q.id) && ready(t)).reduce((s, t) => s + questXpAt(t.q, level), 0);
    const need = XP_TO_LEVEL[level] - xp - pending;
    if (need > 0 && need < XP_TO_LEVEL[level] * 0.15) {
      const mobs = Math.ceil(need / Math.max(1, killXp(level, level)));
      step({ type: 'grind', at: pos, mobs, need, target: nextTrain }); clock += mobs * cfg.secPerKill; gain(need);
    }
  }
}

// ---------- end state (for chaining legs) ----------
if (cfg.stateOut) {
  const active = { ...passActive };
  // carry which objectives are done, so a later visit to the zone does not plan them again
  for (const id of accepted) { const t = tasks[id]; active[id] = t ? { complete: !!ready(t), objectives: t.objs.map((o, i) => ({ done: odone(id, i), text: o.label })) } : ((cfg.active || {})[id] || { complete: false, objectives: [] }); } // a quest from another zone: pass its progress through untouched
  const gained = out.filter((s2) => s2.type === 'turnin').reduce((a, s2) => a + s2.xp, 0);
  const rewardValue = out.filter((s2) => s2.type === 'turnin').reduce((a, s2) => a + extraValue(s2.q), 0);
  const dungeonsRun = [...new Set([...(cfg.dungeonsRun || []), ...out.filter((s2) => s2.type === 'dungeon').map((s2) => s2.dungeon)])].sort((a, b) => a - b);
  fs.writeFileSync(cfg.stateOut, JSON.stringify({ trainedAt, hearthCdLeft: Math.max(0, Math.round(hearthReadyAt - clock)), dungeonsRun, rewardValue, level, xp, completed: [...turned], active, pos, minutes: Math.round(clock / 60), questXp: gained, turnins: out.filter((s2) => s2.type === 'turnin').length }));
}
// ---------- print ----------
const f = (a) => (a ? `${(+a.x).toFixed(1)}, ${(+a.y).toFixed(1)}` : '');
const L = [];
let lastZone = null;
for (const s of out) {
  if (s.at && s.at.zone !== lastZone && s.type !== 'train') { L.push('', `## ${zname(s.at.zone)}`); lastZone = s.at.zone; }
  const tag = (q) => `${q.name} [${q.level}]`;
  switch (s.type) {
    case 'level': L.push(`      -- level ${s.lvl} (~${Math.round(s.clock / 60)} min) --`); break;
    case 'hub': L.push('', `### ${s.name}`); break;
    case 'bind': L.push(`  ${f(s.at)}  Set your hearthstone with ${s.who || 'the innkeeper'}.`); break;
    case 'fp': L.push(`  ${f(s.at)}  Learn the flight path (${s.who}).`); break;
    case 'fly': L.push(`  Fly from ${zname(s.from)} to ${zname(s.to)}.`); break;
    case 'accept': L.push(`  ${f(s.at)}  Accept ${tag(s.q)} from ${s.who}`); break;
    case 'turnin': L.push(`  ${f(s.at)}  Turn in ${tag(s.q)} to ${s.who}  (+${s.xp} xp)`); break;
    case 'loop': L.push(`  -> Field loop (${s.stops} stops):`); break;
    case 'do': for (const it of s.items) L.push(`  ${f(s.at)}  ${it.shared ? '(drops from the mobs here) ' : it.bg ? '(along the way) ' : ''}${it.label} — ${it.q.name}`); break;
    case 'hearth': L.push(`  Hearth back (saves ~${Math.round(s.saved / 60)} min of walking).`); break;
    case 'train': L.push('', `  >> Train level ${s.levels.join('/')} spells${s.note ? ': ' + s.note : ''}`); break;
    case 'dungeon': L.push(`  >> Run ${s.name} with a group (~${s.minutes} min + finding a group; ~${s.runXp} xp from the run itself)`); break;
    case 'bonus': L.push(`  ${f(s.at)}  Bonus: loot the book "${s.book.title}" — ${s.book.where}`); break;
    case 'grind': L.push(`  Grind about ${s.mobs} mobs here (${s.need} xp) so the next turn-ins land you on level ${s.target} for training.`); break;
  }
}
const carry = Object.values(tasks).filter((t) => accepted.has(t.q.id));
L.push('', `End: level ${level} + ${xp}/${XP_TO_LEVEL[level]} xp after ~${Math.round(clock / 60)} min (estimate).`);
if (carry.length) { L.push('', 'Still in your log (carry to the next leg):'); for (const t of carry) L.push(`  ${t.q.name} [${t.q.level}] -> ${t.turnin.who}${t.turnin.carry ? ' in ' + zname(t.turnin.carry.zone) : ''}${ready(t) ? ' (done, hand in)' : ' (objectives left)'}`); }
const never = Object.values(tasks).filter((t) => !accepted.has(t.q.id) && !turned.has(t.q.id));
if (never.length) { L.push('', 'Available but not taken (level/time):'); for (const t of never) L.push(`  ${t.q.name} [${t.q.level}] (needs ${t.q.reqLevel})`); }
L.push('', 'Skipped:'); for (const [q, why] of skipped) L.push(`  ${q.name} [${q.level}] (${q.id}): ${why}`);
console.log(L.join('\n'));
if (outPath) fs.writeFileSync(outPath, JSON.stringify(out.map((s) => ({ ...s, q: s.q && s.q.id, items: s.items && s.items.map((i) => ({ ...i, q: i.q.id })) })), null, 1));
// ---------- optimize the visit order (parallel simulated annealing) ----------
if (cfg.optimize) {
  const { optimize } = require('./optimize');
  const locs = [], locKey = new Map();
  const locOf = (p) => { const k = p.zone + ':' + (+p.x).toFixed(1) + ',' + (+p.y).toFixed(1); if (!locKey.has(k)) { locKey.set(k, locs.length); locs.push(p); } return locKey.get(k); };
  const startLoc = locOf(cfg.start || (out.find((s2) => s2.at) || {}).at || { zone: cfg.zones[0], x: 50, y: 50 });
  const events = [];
  // pick-ups in a side zone (the capital that rides along with every leg) whose hand-in isn't in this leg: a trip
  // for nothing now - the safety net drops them anyway since they're never handed in here
  const turnedHere = new Set(out.filter((s2) => s2.type === "turnin").map((s2) => s2.q.id));
  const sideOnly = (s2) => s2.type === "accept" && s2.at && s2.at.zone !== cfg.zones[0] && !turnedHere.has(s2.q.id) && !(cfg.bonusQuests || []).includes(s2.q.id);
  const dropped = out.filter(sideOnly);
  // their objectives go too (a region leg kept them, and the quest was planned again whole on a later leg: the
  // objective twice, the first time before it was ever picked up)
  const droppedQ = new Set(dropped.map((s2) => s2.q.id));
  if (dropped.length) console.error("left out " + dropped.length + " side-zone pick-ups not handed in on this leg: " + dropped.map((s2) => s2.q.name).join(", "));
  // a dungeon run is one event the quests done in it hang on: their objectives there come after the run, and the run
  // after every one of their pick-ups (it was a free-floating event, and the route read "Run The Stockade, then accept
  // The Stockade Riots, then collect the Head of Bazil Thredd")
  const runEvent = {}; // dungeon id -> index of its run event
  for (const s2 of out) {
    if (sideOnly(s2)) continue;
    if (s2.type === 'accept') events.push({ kind: 'accept', q: s2.q.id, loc: locOf(s2.at), work: 3, reqLevel: Math.max(tasks[s2.q.id] ? acceptLevel(tasks[s2.q.id]) : 0, (cfg.bonusQuests || []).includes(s2.q.id) ? s2.q.reqLevel : Math.max(s2.q.reqLevel || 0, s2.q.level - cfg.maxAbove + 1)), pre: [...s2.q.preGroup, ...(s2.q.preSingle.length === 1 ? s2.q.preSingle : [])], who: s2.who, name: s2.q.name, qLevel: s2.q.level });
    if (s2.type === 'turnin') events.push({ kind: 'turnin', q: s2.q.id, loc: locOf(s2.at), work: 3, xp: baseXp(s2.q), qLevel: s2.q.level, reqLevel: 0, pre: [], who: s2.who, name: s2.q.name });
    if (s2.type === 'dungeon') { runEvent[s2.dungeon] = events.length; events.push({ kind: 'obj', q: -1000 - events.length, loc: locOf(s2.at), work: (s2.minutes + (cfg.groupWaitMin ?? 10)) * 60, killXp: s2.runXp, reqLevel: 0, pre: [], after: [], label: 'Run ' + s2.name + ' with a group', name: s2.name, qLevel: 0, dungeonRun: true }); }
    // (none in a capital: there are no mobs to kill there)
    if (s2.type === 'grind' && !CAPITALS.has(s2.at && s2.at.zone)) events.push({ kind: 'obj', q: -3000 - events.length, loc: locOf(s2.at), work: s2.mobs * cfg.secPerKill, killXp: s2.need, reqLevel: 0, pre: [], label: 'Grind about ' + s2.mobs + ' mobs', name: 'Grind', qLevel: 0, grind: { mobs: s2.mobs, need: s2.need } });
    if (s2.type === 'bonus') events.push({ kind: 'obj', q: -5000 - events.length, loc: locOf(s2.at), work: 30, killXp: 0, reqLevel: 0, pre: [], label: s2.book.title, name: s2.book.title, qLevel: 0, book: s2.book });
    if (s2.type === 'do') for (const it of s2.items) {
      if (droppedQ.has(it.q.id)) continue;
      const t = tasks[it.q.id], o = t && t.objs.find((x) => x.label === it.label);
      events.push({ kind: 'obj', q: it.q.id, loc: locOf(s2.at), shared: it.shared, work: it.shared ? 0 : o ? o.work : 60, killXp: 0, reqLevel: o && o.kills > 0 ? Math.max(0, o.mobLevel - cfg.maxMobAbove + 1) : 0, pre: [], label: it.label, area: o && o.at ? o.at.area : undefined, name: it.q.name, qLevel: it.q.level, kills: it.shared || !o ? 0 : o.kills, mobLevel: o ? o.mobLevel : undefined,
        after: o && o.dungeon && runEvent[o.dungeon] !== undefined ? [runEvent[o.dungeon]] : undefined });
    }
  }
  for (const e of events) if (e.after && e.kind === 'obj' && !e.dungeonRun) {
    const run = events[e.after[0]], acc = events.findIndex((x) => x.kind === 'accept' && x.q === e.q);
    if (acc >= 0 && !run.after.includes(acc)) run.after.push(acc);
  }
  const nL = locs.length, D = new Float32Array(nL * nL);
  for (let i = 0; i < nL; i++) for (let j = 0; j < nL; j++) D[i * nL + j] = i === j ? 0 : travelSec(locs[i], locs[j]);
  // backtracking (the player's biggest complaint, ahead of time): which places are hubs (3+ pick-ups / hand-ins within
  // HUB_YD) and which ~WILD_YD area of the wild each place is in, so the optimizer can charge for going back to a wild
  // area you had already left, and for a trip out from a hub for one thing (tools/optimize.js)
  const HUB_YD = 80, WILD_YD = cfg.wildCellYd || 250;
  const handIns = new Array(nL).fill(0);
  for (const e of events) if (e.kind === 'accept' || e.kind === 'turnin') handIns[e.loc]++;
  const locHub = locs.map((p) => { let n = 0; for (let j = 0; j < nL; j++) if (handIns[j] && locs[j].zone === p.zone && straightDist(p, locs[j]) < HUB_YD) n += handIns[j]; return n >= 3; });
  const locCell = locs.map((p) => { const [zw, zh] = yards(p.zone); return [p.zone, Math.floor((p.x / 100) * zw / WILD_YD), Math.floor((p.y / 100) * zh / WILD_YD)]; });
  // the log cap counts every quest you came in with, as the simulation does (40 on Forever)
  const opts = { locHub, locCell, revisitSec: cfg.revisitSec ?? 240, thinSec: cfg.thinSec ?? 120, learned: cfg.learned, level: cfg.level, xp: cfg.xp || 0, startLoc, xpToLevel: XP_TO_LEVEL, xpWeight: cfg.xpWeight ?? 0.25, maxLog: cfg.maxLog, log0: Object.keys(cfg.active || {}).length, initial: events.map((_, k) => k), budgetMs: (cfg.optimizeSeconds || 15) * 1000, workers: cfg.workers };
  // (cfg.eventsOut: the optimizer's input, for tools/test-optimize.js)
  if (cfg.eventsOut) { fs.writeFileSync(cfg.eventsOut, JSON.stringify({ events, D: Array.from(D), nL, opts })); if (cfg.eventsOnly) process.exit(0); }
  const t0 = Date.now();
  const res = await optimize(events, D, nL, opts);
  // the simulation's own order follows every rule by construction; if the search could not find one that does (or the
  // optimizer's model still disagrees with the simulation), ship the simulation's order on purpose and say so loudly
  const fallback = res.violations > 0 || !isFinite(res.cost);
  if (res.baseViolations > 0) console.error(`OPTIMIZER MODEL MISMATCH: the simulation's own order breaks ${res.baseViolations} optimizer rule(s)`);
  if (fallback) { console.error(`OPTIMIZER FALLBACK: best order found still breaks ${res.violations} rule(s); using the simulation's order`); res.order = opts.initial.slice(); }
  // report: travel+work time of both orders
  const timeOf = (order) => { let t = 0, l = startLoc; for (const k of order) { const e = events[k]; t += D[l * nL + e.loc] + e.work; l = e.loc; } return t; };
  const before = timeOf(opts.initial), after = timeOf(res.order);
  const O = [];
  O.push('', '==================== OPTIMIZED ORDER ====================');
  O.push(`Search: ${opts.workers || require('os').cpus().length - 1} threads x ${opts.budgetMs / 1000}s, ${res.iterations} moves on the best thread. Route time ${Math.round(before / 60)} -> ${Math.round(after / 60)} min (travel + objectives, excludes training/hearth).` + (fallback ? ` OPTIMIZER FALLBACK: no order found that keeps every rule (${res.violations} broken), the simulation's order is used.` : ''));
  let lastLoc = -1, lastHub = null;
  for (const k of res.order) {
    const e = events[k], p = locs[e.loc], h = hubOf(p);
    if (h && h !== lastHub) O.push('', `### ${h.name}`);
    if (!h && lastHub) O.push('  -> field:');
    lastHub = h;
    const c = `${(+p.x).toFixed(1)}, ${(+p.y).toFixed(1)}`;
    if (e.kind === 'accept') O.push(`  ${c}  Accept ${e.name} [${e.qLevel}] from ${e.who}`);
    if (e.kind === 'turnin') O.push(`  ${c}  Turn in ${e.name} to ${e.who}`);
    if (e.kind === 'obj') O.push(`  ${c}  ${e.label} — ${e.name}`);
    lastLoc = e.loc;
  }
  console.log(O.join(String.fromCharCode(10)));
  if (cfg.start) res.order = hereFirst(res.order, events, locs);
  if (cfg.routeOut) writeRoute(res.order.map((k) => events[k]), locs);

  console.error(`optimizer: ${((Date.now() - t0) / 1000).toFixed(1)}s, thread results ${res.all.join(' ')}`);
}
function hereFirst(order, events, locs) {
  const HERE_YARDS = cfg.hereYards ?? 450;
  let hub = null, bd = Infinity;
  for (const h of realHubs) { if (h.zone !== cfg.start.zone) continue; const d = straightDist(cfg.start, h); if (d < bd) { bd = d; hub = h; } }
  if (!hub || bd > HERE_YARDS) return order;
  const done = new Set(cfg.completed || []);
  const now = (e) => {
    if (!inHub(hub, locs[e.loc])) return false;
    if (e.kind === 'accept') return (e.reqLevel || 0) <= cfg.level && (e.pre || []).every((q) => done.has(q));
    if (e.kind === 'turnin') return finishedInLog(e.q);
    return false;
  };
  const front = order.filter((k) => now(events[k]));
  if (!front.length) return order;
  const rest = order.filter((k) => !front.includes(k));
  console.error('starting at ' + (hub.name || 'the nearest hub') + ': ' + front.length + ' pick-ups/hand-ins there first');
  return [...front, ...rest];
}
function writeRoute(seq, locs) {
  // the shared level gate, last word (world.js, the audit uses the same): reordering can bring a pick-up ahead of the
  // level it needs. Such a quest leaves this leg whole (pick-up, objectives, hand-in); dropping one can delay a level, so
  // check again until nothing changes
  const gateDrop = new Set();
  for (let pass = 0; pass < 4; pass++) {
    let L = cfg.level, X = cfg.xp || 0, changed = false;
    const gain = (n) => { const r = require('./world').addXp(L, X, n); L = r.level; X = r.xp; };
    for (const e of seq) {
      if (gateDrop.has(e.q)) continue;
      const q = Q[e.q];
      if (e.kind === 'accept' && q && !(cfg.bonusQuests || []).includes(e.q)) {
        const inDungeon = tasks[e.q] && tasks[e.q].objs.some((o) => o.dungeon);
        if (q.level > L + (inDungeon ? DUNGEON_ABOVE : LEVEL_ABOVE)) { gateDrop.add(e.q); changed = true; continue; }
      }
      // kills against mobs too far above you (a quest already in your log has no pick-up to stop it): the quest waits
      // for a later leg, still in your log
      if (e.kind === 'obj' && e.kills > 0 && e.mobLevel != null && e.q > 0
        && e.mobLevel > L + (tasks[e.q] && tasks[e.q].objs.some((o) => o.dungeon) ? DUNGEON_ABOVE : LEVEL_ABOVE)) { gateDrop.add(e.q); changed = true; continue; }
      if (e.kind === 'turnin' && q) gain(questXpAt(q, L));
      else if (e.kind === 'obj') gain(e.kills > 0 && e.mobLevel != null ? e.kills * killXp(e.mobLevel, L) : e.killXp || 0);
    }
    if (!changed) break;
  }
  if (gateDrop.size) {
    console.error('level gate: left out ' + [...gateDrop].map((id) => (Q[id] ? Q[id].name : id)).join(', ') + ' (picked up too early after reordering)');
    seq = seq.filter((e) => !gateDrop.has(e.q));
  }
  const conv = JSON.parse(fs.readFileSync(cfg.conversion, 'utf8')).geometry.transforms;
  const uiMap = {}; for (const t of conv) uiMap[t.area_id] = t.ui_map_id;
  const lua = (v) => typeof v === 'string' ? JSON.stringify(v) : String(v);
  const sections = [], steps = [];
  let lastSec = null, level = cfg.level, xp = cfg.xp || 0, bound = false, fpDone = new Set(cfg.flightPaths || []), trained = cfg.trainedAt ?? cfg.level;
  const levelUp = (n) => { const r = require('./world').addXp(level, xp, n); level = r.level; xp = r.xp; }; // the shared rule (world.js)
  const sectionFor = (p) => { const h = hubOf(p); const title = h ? h.name : 'Out in ' + zname(p.zone); if (title !== lastSec) { sections.push({ title, zone: zname(p.zone) }); lastSec = title; } return sections.length; };
  const at = (p) => ({ m: uiMap[p.zone], x: +(p.x / 100).toFixed(4), y: +(p.y / 100).toFixed(4), zone: zname(p.zone) });
  // the mob to target: "Kill 15 Defias Trapper" -> Defias Trapper; "Collect 8 X (Mob A, Mob B)" -> Mob A
  // "Collect 5 Snout (Bellygrub, Great Goretusk, Snort)": of the mobs that drop it, the one to hunt is the common one
  // you can take (the most spawns within the level gate) - the first listed was often a one-off named mob far above
  // you (Bellygrub, 24). Else the first
  const npcByName = new Map();
  for (const n of Object.values(N)) if (n && n.name && (n.spawns || []).length && n.maxLevel) { const was = npcByName.get(n.name); if (!was || n.spawns.length > was.spawns.length) npcByName.set(n.name, n); }
  const targetOf = (label, lv) => {
    let m = /^Kill\s+\d+\s+(.+)$/.exec(label || ''); if (m) return m[1];
    m = /\(([^)]+)\)/.exec(label || ''); if (!m) return undefined;
    const names = m[1].split(',').map((s) => s.trim()).filter(Boolean);
    const ok = names.map((nm) => ({ nm, n: npcByName.get(nm) })).filter((x) => x.n && (x.n.maxLevel || 0) <= (lv || 60) + LEVEL_ABOVE && !(x.n.rank > 0));
    ok.sort((a, b) => b.n.spawns.length - a.n.spawns.length);
    return (ok[0] && ok[0].nm) || names[0];
  };
  // a usable quest item: the item the quest gives you, or the item a spell objective needs
  const itemOf = (q) => { if (!q) return undefined; const sp = q.objectives.find((o) => o.kind === 'spell' && o.item); return sp ? sp.item : (q.sourceItem || undefined); };
  const matchOf = (label) => { const m = /^(?:Kill|Collect|Loot|Buy)\s+\d+\s+(.+?)(?:\s+\(.*\))?(?:\s+from\s+.*)?$/.exec(label || ''); return m ? m[1] : null; };
  // where to keep the hearthstone: best saving on this order of stops
  const CITY = CAPITAL_AREAS;
  const homeTest = (at) => (p) => p && at && p.zone === at.zone && (CITY.has(p.zone) || straightDist(at, p) < 200);
  const trainerLoc = cfg.trainer ? { zone: cfg.trainer.zone, x: cfg.trainer.x, y: cfg.trainer.y } : null;
  function hearthValue(c) {
    const isHome = homeTest(c.at);
    let here = cfg.start || (seq[0] && locs[seq[0].loc]), clock = 0, ready = cfg.hearthCdLeft || 0, saved = -c.cost, active = !!c.current, lv = cfg.level, x = cfg.xp || 0, tr = cfg.level;
    const go = (q) => {
      const walk = travelSec(here, q);
      if (active && isHome(q) && !isHome(here) && clock >= ready && walk >= 120) { saved += walk - 10; ready = clock + (cfg.hearthCooldownMin || 60) * 60; clock += 10; }
      else clock += walk;
      here = q; if (isHome(q)) active = true;
    };
    for (const e of seq) {
      go(locs[e.loc]); clock += e.work || 0;
      const q = Q[e.q];
      if (e.kind === 'turnin' && q) { x += questXpAt(q, lv); while (lv < 60 && x >= XP_TO_LEVEL[lv]) { x -= XP_TO_LEVEL[lv]; lv++; } }
      if (e.kind === 'obj' && (e.kills > 0 || e.killXp)) { x += e.kills > 0 ? e.kills * killXp(e.mobLevel, lv) : e.killXp; while (lv < 60 && x >= XP_TO_LEVEL[lv]) { x -= XP_TO_LEVEL[lv]; lv++; } }
      const due = (cfg.trainLevels || []).filter((l) => l > tr && l <= lv);
      if (due.length && trainerLoc) { tr = lv; const back = here; go(trainerLoc); go(back); }
    }
    return saved;
  }
  const cands = [];
  if (cfg.hearth) cands.push({ at: cfg.hearth, cost: 0, current: true, name: zname(cfg.hearth.zone) });
  for (const h of realHubs) {
    const inn = innOf(h);
    if (!inn || (cfg.hearth && homeTest(cfg.hearth)(inn))) continue;
    if (!seq.some((e) => inHub(h, locs[e.loc]))) continue; // only towns this leg actually goes to
    cands.push({ at: inn, hub: h, cost: 40, name: h.name || zname(inn.zone), inn });
  }
  for (const c of cands) c.value = hearthValue(c);
  const bindChoice = cands.sort((a, b) => b.value - a.value)[0] || null;
  if (cands.length) console.error('hearthstone: ' + cands.map((c) => `${c.name}${c.current ? ' (now)' : ''} saves ${Math.round(c.value / 60)} min`).join(', ') + ' -> ' + (bindChoice ? bindChoice.name : 'none'));
  // hearth tracking: where you're bound (once the route binds you) and a rough clock along the route
  let lastZoneW = null; // the leg itself starts with its own travel step (added when legs are joined)
  let hearthAt = bindChoice && bindChoice.current ? cfg.hearth : null, hearthClock = 0, hearthReady = cfg.hearthCdLeft || 0, here = cfg.start || null;
  const atHearth = (q) => hearthAt && homeTest(hearthAt)(q);
  const HEARTH_MIN_WALK = 120, HEARTH_CD = (cfg.hearthCooldownMin || 60) * 60;
  for (const e of seq) {
    const p = locs[e.loc], sec = sectionFor(p), h = hubOf(p);
    if (here && hearthAt && atHearth(p) && !atHearth(here) && hearthClock >= hearthReady) {
      const walk = travelSec(here, p);
      if (walk >= HEARTH_MIN_WALK) {
        const where = (h && h.name) || zname(p.zone);
        steps.push({ k: 'hearth', text: where, dest: where, note: 'Hearth back to ' + where + ' - saves about ' + Math.round(walk / 60) + ' min of travel.', bindMap: uiMap[hearthAt.zone], sec, tm: Math.round(hearthClock / 60) });
        hearthReady = hearthClock + HEARTH_CD; here = hearthAt;
      }
    }
    // a travel step to another zone - unless the hearth just took you there (decided first, above)
    if (lastZoneW !== null && p.zone !== lastZoneW && !(steps.length && steps[steps.length - 1].k === 'hearth')) steps.push({ k: 'fly', dest: zname(p.zone), to: uiMap[p.zone], text: zname(p.zone), sec, note: 'Fly, or ride if it is close.' });
    lastZoneW = p.zone;
    if (here) hearthClock += travelSec(here, p);
    hearthClock += e.work || 0; here = p;
    // inn: bind on the first visit to the town picked above - whenever it is not where you are bound now, also when you
    // came into this leg bound somewhere else (the next leg is told you rebound here, so the step must be on the route)
    if (!bound && bindChoice && !bindChoice.current && inHub(bindChoice.hub, p)) { const inn = bindChoice.inn; steps.push({ k: 'bind', npc: inn.name, ...at(inn), r: 8, sec, note: 'Hearth back here to hand in big batches.' }); bound = true; hearthAt = inn; }
    // flight path when first passing a hub with a flight master
    const fm = FLIGHT[p.zone];
    if (fm && !fpDone.has(p.zone) && straightDist(fm, p) < 250) { steps.push({ k: 'fp', npc: fm.name, ...at(fm), r: 8, sec }); fpDone.add(p.zone); }
    const q = Q[e.q];
    const base = { q: e.q, name: e.name, level: q ? q.level : undefined, ...at(p), sec, lvl: level };
    if (e.kind === 'accept' && (cfg.bonusQuests || []).includes(e.q)) { steps.push({ k: 'accept', npc: e.who, r: 6, note: (cfg.bonusNotes || {})[e.q], q: e.q, name: e.name, level: q ? q.level : undefined, ...at(p), sec, lvl: level }); continue; }
    const tq = tasks[e.q] && tasks[e.q].qual;
    // a fun reward (a toy, a transform: tools/learn.js asked the game) is said first - it is why this quest is on the route
    const fun = (cfg.funNotes || {})[e.q];
    if (e.kind === 'accept') steps.push({ k: 'accept', npc: e.who, r: 6, minLevel: q && q.reqLevel > 1 ? q.reqLevel : undefined, note: [fun && ('Fun reward: ' + fun), tq && tq.rewardText && ('Reward: ' + tq.rewardText), tq && tq.frustration > 0.2 && ('Heads up: ' + tq.reasons.join(', '))].filter(Boolean).join('  ·  ') || undefined, warn: tq && tq.frustration > 0.2 ? true : undefined, reward: (tq && tq.rewardItem) || undefined, ...base });
    if (e.book) { steps.push({ k: 'bonus', text: 'loot the book ' + e.book.title, where: e.book.where, item: e.book.item, book: e.book.id, ...at(p), r: 12, sec, note: 'Lore book on the way (HandyNotes Forever Books).' }); continue; }
    // a grind top-up from the simulation: a real step (done once you reach the level and XP it aims for)
    if (e.grind) {
      levelUp(e.killXp);
      steps.push({ k: 'grind', text: e.label, level, xp: Math.round(xp), note: 'Kill mobs around here until level ' + level + (xp > 0 ? ' and ' + Math.round(100 * xp / XP_TO_LEVEL[level]) + '%' : '') + ' (' + e.grind.need + ' xp) - your next turn-ins then land on training.', ...at(p), r: 60, sec, lvl: level });
      continue;
    }
    if (e.dungeonRun) {
      steps.push({ k: 'goto', text: e.label, dungeon: e.name, note: 'Finishes every dungeon quest in your log. Use the Group Finder or /4 LookingForGroup.', ...at(p), r: 25, sec });
      levelUp(e.killXp || 0); // the run's own XP
      continue;
    }
    const oInfo = e.kind === 'obj' && tasks[e.q] && tasks[e.q].objs.find((x) => x.label === e.label);
    if (e.kind === 'obj') steps.push({ rate: oInfo && oInfo.dropPct, k: 'obj', text: e.label, match: matchOf(e.label), target: targetOf(e.label, level), item: itemOf(q), loot: /^(Collect|Loot)/.test(e.label) || undefined, r: Math.max(40, Math.min(220, (e.area || 0) + 15)), note: e.shared ? 'Drops from the mobs you are already killing here.' : undefined, ...base });
    if (e.kind === 'turnin') {
      steps.push({ k: 'turnin', npc: e.who, r: 6, note: tq && tq.rewardText ? 'Reward: ' + tq.rewardText : undefined, reward: (tq && tq.rewardItem) || undefined, ...base });
      levelUp(questXpAt(q, level));
      let due = (cfg.trainLevels || []).filter((l) => l > trained && l <= level);
      // batched like the simulation (world.js): two ranks waiting, or you are in the trainer's city anyway
      if (!(TRAINERS.length && trainNow(due, here && TRAINERS.some((tr) => tr.zone === here.zone)))) due = [];
      const trainer = due.length ? nearestTrainer(here) : null;
      if (due.length && trainer && hearthAt && hearthAt.zone === trainer.zone && here && here.zone !== trainer.zone && hearthClock >= hearthReady) {
        steps.push({ k: 'hearth', text: zname(trainer.zone), dest: zname(trainer.zone), note: 'Hearth to ' + zname(trainer.zone) + ' for your new spells, then fly back.', bindMap: uiMap[hearthAt.zone], sec, tm: Math.round(hearthClock / 60) });
        hearthReady = hearthClock + HEARTH_CD;
      }
      if (due.length && trainer) lastZoneW = trainer.zone; // training takes you to the trainer's city: the next stop elsewhere gets a travel step
      if (due.length && trainer) { steps.push({ k: 'train', text: 'level ' + due.join('/') + ' spells', note: trainer.note || cfg.trainerNote, sec, m: uiMap[trainer.zone], x: trainer.x / 100, y: trainer.y / 100, zone: zname(trainer.zone), r: 10 }); trained = level; }
    }
    // kill XP at your level at this step (as the simulation counts it), not the leg's starting level
    if (e.kind === 'obj' && (e.kills > 0 || e.killXp)) { levelUp(e.kills > 0 ? e.kills * killXp(e.mobLevel, level) : e.killXp); }
  }
  // the cooldown this leg leaves for the next, from the steps you will actually follow
  // the end state from the steps you will actually follow, not the simulation before optimizing: where you end up,
  // and only quests the steps pick up (or that were in your log already) count as in your log for the next leg
  try {
    if (cfg.stateOut && fs.existsSync(cfg.stateOut)) {
      const st0 = JSON.parse(fs.readFileSync(cfg.stateOut, 'utf8'));
      st0.hearthCdLeft = Math.max(0, Math.round(hearthReady - hearthClock));
      st0.trainedAt = trained; // ranks still waiting are trained in a later leg
      // where the stone is set when the leg ends: the inn the steps bound you at, else where you came in bound
      chosenHearth = bound ? bindChoice.at : (cfg.hearth || null);
      st0.hearth = chosenHearth;
      if (here) st0.pos = { zone: here.zone, x: here.x, y: here.y };
      const picked = new Set(seq.filter((e) => e.kind === 'accept').map((e) => String(e.q)));
      const dropped = Object.keys(st0.active || {}).filter((id) => !(cfg.active || {})[id] && !picked.has(id));
      for (const id of dropped) delete st0.active[id];
      if (dropped.length) console.error('end state: ' + dropped.length + ' quests not picked up on the steps left out of your log');
      // quests the level gate took out of this leg: as they were when the leg began (in your log as you had them, or
      // not at all), never handed in here
      if (gateDrop.size) {
        st0.completed = (st0.completed || []).filter((id) => !gateDrop.has(id));
        for (const id of gateDrop) { if ((cfg.active || {})[id]) st0.active[id] = cfg.active[id]; else delete st0.active[id]; }
      }
      if (st0.level !== level || Math.abs((st0.xp || 0) - xp) > 0.1 * (XP_TO_LEVEL[level] || 1)) console.error(`end state: steps reach level ${level} (${Math.round(xp)} xp), the simulation ${st0.level} (${Math.round(st0.xp || 0)} xp)`);
      fs.writeFileSync(cfg.stateOut, JSON.stringify(st0));
    }
  } catch (e) { console.error('end state: ' + e.message); }
  steps.forEach((st, i) => { st.id = i + 1; });
  const ser = (o) => '{ ' + Object.entries(o).filter(([, v]) => v !== undefined && v !== null).map(([k, v]) => k + ' = ' + lua(v)).join(', ') + ' }';
  const L = [];
  L.push('-- Generated by the Forever Route planner on ' + new Date().toISOString() + '. Regenerate rather than edit.');
  L.push('ForeverRouteData = {');
  L.push('  id = ' + lua((cfg.title || 'route') + '@' + Date.now()) + ',');
  L.push('  title = ' + lua(cfg.title || 'Forever Route') + ',');
  L.push('  meta = { character = ' + lua(cfg.character || '') + ', startLevel = ' + cfg.level + ', endLevel = ' + lua(level + ' (' + Math.round(100 * xp / XP_TO_LEVEL[level]) + '%)') + ' },');
  L.push('  sections = {'); for (const sct of sections) L.push('    ' + ser(sct) + ','); L.push('  },');
  L.push('  steps = {'); for (const st of steps) L.push('    ' + ser(st) + ','); L.push('  },');
  L.push('}');
  // cfg.graphOut: the zone as the planner saw it (tools/readme-graph.js draws it): hubs, every quest kept (giver, hand-in,
  // objective spots, chain links, XP per minute, done here or later) and every one cut with the reason, and the order
  if (cfg.graphOut) {
    const spot = (p) => (p ? { zone: p.zone, x: +(+p.x).toFixed(2), y: +(+p.y).toFixed(2) } : null);
    const giverAt = (q) => { for (const s of q.starters || []) for (const sp of s.spawns || []) if (inZones(sp)) return spot(sp); return null; };
    const objAt = (q) => { const sps = []; for (const o of q.objectives || []) { if (o.npc && N[o.npc]) sps.push(...N[o.npc].spawns); for (const x of o.npcDrops || []) if (N[x]) sps.push(...N[x].spawns); if (o.object && O[o.object]) sps.push(...O[o.object].spawns); for (const x of o.objectDrops || []) if (O[x]) sps.push(...O[x].spawns); } const c = cluster(sps); return c ? spot(c) : null; };
    fs.writeFileSync(cfg.graphOut, JSON.stringify({
      zone: cfg.zones[0], zones: cfg.zones, level: cfg.level,
      hubs: realHubs.filter((h) => inZones(h)).map((h) => ({ name: h.name, ...spot(h), npcs: h.npcs.size })),
      kept: Object.values(tasks).map((t) => ({ id: t.q.id, name: t.q.name, level: t.q.level, xp: questXpAt(t.q, cfg.level), xpm: Math.round(t.xpm || 0), pre: [...(t.q.preSingle || []), ...(t.q.preGroup || [])],
        giver: spot(t.accept.at), hand: spot((t.turnin.spawns || [])[0]), objs: t.objs.filter((o) => o.at).map((o) => ({ ...spot(o.at), label: o.label, kills: o.kills, area: o.at.area || 0 })),
        status: turned.has(t.q.id) ? 'done' : accepted.has(t.q.id) ? 'carried' : 'later' })),
      cut: skipped.map(([q, why]) => ({ id: q.id, name: q.name, level: q.level, xp: q.xp || 0, why, pre: [...(q.preSingle || []), ...(q.preGroup || [])], giver: giverAt(q), obj: objAt(q) })),
      order: steps.filter((s) => ['accept', 'turnin', 'obj'].includes(s.k)).map((s) => ({ k: s.k, q: s.q, m: s.m, x: s.x, y: s.y, text: s.k === 'obj' ? s.text : s.name })),
    }));
  }
  if (cfg.legOut) fs.writeFileSync(cfg.legOut, JSON.stringify({ title: cfg.title, endLevel: level, endXp: xp, sections, steps }));
  if (cfg.routeOut.endsWith('.lua')) fs.writeFileSync(cfg.routeOut, L.join(String.fromCharCode(10)) + String.fromCharCode(10));
  console.error('route written: ' + steps.length + ' steps, ' + sections.length + ' sections -> ' + cfg.routeOut);
}
})();
