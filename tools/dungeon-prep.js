const { raceOk } = require('./world'); // race masks above bit 32 (Skyborne)
// Dungeon prep route: pick up every quest for one dungeon (and do the chain quests that unlock them), run it, hand in.
//   gather: accepts for the dungeon's quests + full chains of earlier quests that unlock them, ordered by the optimizer
//   run:    the dungeon, with a checklist of every objective inside
//   return: turn-ins from the dungeon entrance, ordered by the optimizer
// usage: node dungeon-prep.js <config.json>   config: { db, conversion, dungeonFile, charDir | (race, class, level, completed),
//          dungeon: areaId | 'auto', atLevel?, out (json) , list? (print candidate dungeons) }
const fs = require('fs');
const path = require('path');
const { optimize } = require('./optimize');
const { loadDungeons } = require('./dungeons');
const { loadCharState } = require('./snapshot');

const cfg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
// relative paths (qdb/db.json...) are the project's, wherever the settings file was written (it used to be "the folder
// above the settings", which only worked for work folders inside the project)
const rel = (p) => (path.isAbsolute(p) ? p : path.resolve(__dirname, '..', p));
const { quests: Q, npcs: N, objects: O } = JSON.parse(fs.readFileSync(rel(cfg.db), 'utf8'));
const conv = JSON.parse(fs.readFileSync(rel(cfg.conversion), 'utf8')).geometry.transforms;
const T = Object.fromEntries(conv.map((t) => [t.area_id, t]));
const zoneName = (z) => (T[z] ? T[z].target_name : 'zone ' + z);
const D = loadDungeons(cfg.dungeonFile);
// Forever's new quests have no XP in QuestieDB: take it from the Forever data the leveling planner uses
const FX = cfg.addonsDir ? require('./bonus').loadForeverXp(cfg.addonsDir) : {};
// quests with no XP figure get the typical XP for their level (same as the leveling planner), not zero
const medianXp = (() => { const by = {}; for (const q of Object.values(Q)) if (q.xp && q.level > 0 && q.level <= 60) (by[q.level] = by[q.level] || []).push(q.xp); const med = {}; for (let L = 1; L <= 60; L++) { const a = (by[L] || []).sort((x, y) => x - y); med[L] = a.length ? a[a.length >> 1] : (med[L - 1] || 100); } return med; })();
// Forever's figure first (it is what Forever pays, also for Classic quests it changed), as in the leveling planner
const qxp = (q) => FX[q.id] || q.xp || medianXp[Math.max(1, Math.min(60, q.level || 1))];
// reward value (XP-equivalent) for this class, from the same scoring the leveling planner uses
let QUAL;
const rewardOf = (q) => { if (QUAL === undefined) QUAL = cfg.itemsJson ? require('./quality').makeQuality({ quests: Q, npcs: N, objects: O, items: JSON.parse(fs.readFileSync(rel(cfg.itemsJson), 'utf8')), cls: klass, verdicts: st.gearVerdicts }) : null; if (!QUAL) return { value: 0, text: null }; const v = QUAL(q, level); return { value: v.rewardValue || 0, text: v.rewardText }; };

const st = (cfg.charDir && loadCharState(cfg.charDir, rel(cfg.conversion))) || {};
const race = st.race || cfg.race, klass = st.class || cfg.class;
const level = st.level || cfg.level || 1, xp0 = st.xp || 0;
const completed = new Set([...(st.completed || []), ...(cfg.completed || [])]);
const log = st.log || cfg.active || {};
const { RACE_BIT, CLASS_BIT } = require('./world'); // the game's rules, shared by every stage

const HORDE = new Set(['orc', 'undead', 'tauren', 'troll']);
const side = cfg.faction ? (cfg.faction === 'horde' ? 'H' : 'A') : (HORDE.has(race) ? 'H' : 'A');
const foe = side === 'A' ? 'H' : 'A';
const XP = [0, 400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600, 8800, 10100, 11400, 12900, 14400, 16000, 17700, 19400, 21300, 23200, 25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400, 44300, 47400, 50800, 54500, 58600, 62800, 67100, 71600, 76100, 80800, 85700, 90700, 95800, 101000, 106300, 111800, 117500, 123200, 129100, 135100, 141200, 147500, 153900, 160400, 167100, 173900, 180800, 187900, 195000, 202300, 209800];
const HOLIDAY = new Set([-22, -284, -366, -364, -369, -370, -1001, -1002, -1003, -1004, -1005, -1006, -1007, -41, -376, -374, -375, -101]);

// ---------- geometry: map % -> world yards; travel seconds (walk, or fly between flight masters) ----------
const world = (p) => { const t = T[p.zone]; if (!t) return null; const B = t.target_bounds; return { x: B.top - (p.y / 100) * (B.top - B.bottom), y: B.left - (p.x / 100) * (B.left - B.right), c: t.map_id }; };
const FM = {}; // zone -> [{zone,x,y,name}]
for (const n of Object.values(N)) if (n && /^(Gryphon Master|Hippogryph Master|Flight Master|Wind Rider Master|Bat Handler)$/i.test(n.sub || '') && (n.friendly === side || n.friendly === 'AH')) for (const s of n.spawns || []) if (s.x >= 0) (FM[s.zone] = FM[s.zone] || []).push({ ...s, name: n.name });
const RUN = 7, WALK_DETOUR = 1.35;
const wd = (a, b) => { const A = world(a), B = world(b); if (!A || !B) return Infinity; return A.c === B.c ? Math.hypot(A.x - B.x, A.y - B.y) : Infinity; };
const nearestFM = (p) => { let best = null, bd = Infinity; for (const f of FM[p.zone] || []) { const d = wd(p, f); if (d < bd) { bd = d; best = f; } } return best ? { f: best, d: bd } : null; };
function travel(a, b) {
  if (a.zone === b.zone) return (wd(a, b) * WALK_DETOUR) / RUN;
  const walk = (wd(a, b) * WALK_DETOUR) / RUN;
  const fa = nearestFM(a), fb = nearestFM(b);
  let fly = Infinity;
  if (fa && fb) fly = (fa.d * WALK_DETOUR) / RUN + 45 + wd(fa.f, fb.f) / 32 + (fb.d * WALK_DETOUR) / RUN;
  const best = Math.min(walk, fly);
  if (isFinite(best)) return best;
  return 900 + ((fb ? fb.d : 600) * WALK_DETOUR) / RUN; // other continent: boat/zeppelin
}

// ---------- quests ----------
const inDungeonArea = (zone, d) => zone === d.id || d.alt.includes(zone);
const nope = new Set([...(st.nope || []), ...(st.notOffered || [])]);
function ok(q) {
  if (!q) return false;
  if (nope.has(q.id)) return false; // you said you are not doing it
  if (q.races && !raceOk(q.races, race)) return false;
  if (q.classes && !(q.classes & CLASS_BIT[klass])) return false;
  if (q.special & 1 || HOLIDAY.has(q.zone) || q.skill || q.reqSpell || q.minRep) return false;
  if ([...q.starters, ...q.finishers].some((s) => s.friendly === foe)) return false;
  if (!q.starters.some((s) => s.type === 'npc' && (s.spawns || []).some((p) => p.x >= 0))) return false;
  if (!q.finishers.some((s) => (s.spawns || []).some((p) => p.x >= 0))) return false;
  return true;
}
// where an objective is done: spawns of the mobs / objects involved
function objSpawns(o) {
  const out = [];
  if (o.kind === 'kill') { if (N[o.npc]) out.push(...N[o.npc].spawns); }
  else if (o.kind === 'killcredit') { for (const id of o.npcs || []) if (N[id]) out.push(...N[id].spawns); }
  else if (o.kind === 'item') { for (const id of o.npcDrops || []) if (N[id]) out.push(...N[id].spawns); for (const id of o.objectDrops || []) if (O[id]) out.push(...O[id].spawns); if (!out.length) for (const id of o.vendors || []) if (N[id]) out.push(...N[id].spawns); }
  else if (o.kind === 'object') { if (O[o.object]) out.push(...O[o.object].spawns); }
  else if (o.kind === 'explore') out.push(...(o.spawns || []));
  return out;
}
const objInDungeon = (o, d) => { const sp = objSpawns(o); return sp.length > 0 && sp.every((p) => inDungeonArea(p.zone, d) || (p.x < 0 && D.byArea[p.zone] === d)); };
const isDungeonQuest = (q, d) => inDungeonArea(q.zone, d) || (q.objectives.length > 0 && q.objectives.some((o) => objInDungeon(o, d)));
const objLabel = (o) => {
  if (o.kind === 'kill') return 'Kill ' + (N[o.npc] ? N[o.npc].name : 'target');
  if (o.kind === 'killcredit') return o.text || 'Kill ' + ((N[(o.npcs || [])[0]] || {}).name || 'target');
  if (o.kind === 'item') return 'Collect ' + o.name;
  if (o.kind === 'object') return o.text || 'Use ' + ((O[o.object] || {}).name || 'object');
  return o.text || 'Explore';
};
const objMatch = (o) => (o.kind === 'item' ? o.name : o.kind === 'kill' ? (N[o.npc] || {}).name : null);
// densest spot of a spawn list (outside instances)
function spot(spawns) {
  const pts = spawns.filter((p) => p.x >= 0 && T[p.zone]);
  if (!pts.length) return null;
  let best = pts[0], bn = -1;
  for (const p of pts) { const n = pts.filter((q) => q.zone === p.zone && Math.abs(q.x - p.x) < 4 && Math.abs(q.y - p.y) < 4).length; if (n > bn) { bn = n; best = p; } }
  const near = pts.filter((q) => q.zone === best.zone && Math.abs(q.x - best.x) < 4 && Math.abs(q.y - best.y) < 4);
  return { zone: best.zone, x: near.reduce((s, q) => s + q.x, 0) / near.length, y: near.reduce((s, q) => s + q.y, 0) / near.length };
}
// an NPC with several spawns: use the one in a town (the most quest NPCs close by), not a phased or event copy
const questNpcPts = [];
for (const q of Object.values(Q)) for (const s of [...q.starters, ...q.finishers]) if (s.type === 'npc' && s.friendly !== foe) for (const p of s.spawns || []) if (p.x >= 0) questNpcPts.push(p);
const townScore = (p) => questNpcPts.filter((o) => o.zone === p.zone && Math.abs(o.x - p.x) < 3 && Math.abs(o.y - p.y) < 3).length;
const bestSpawn = (spawns) => { const c = (spawns || []).filter((p) => p.x >= 0 && T[p.zone]); if (c.length < 2) return c[0]; return c.map((p) => [p, townScore(p)]).sort((a, b) => b[1] - a[1])[0][0]; };
const giverAt = (q) => { const s = q.starters.find((s) => s.type === 'npc' && bestSpawn(s.spawns)); return s && { who: s.name, at: bestSpawn(s.spawns) }; };
const enderAt = (q) => { const s = q.finishers.find((s) => bestSpawn(s.spawns)); return s && { who: s.name, at: bestSpawn(s.spawns) }; };

// the quests to do before a dungeon quest can be accepted; null if the chain can't be done by this character
function chainOf(q, d, seen = new Set()) {
  if (seen.has(q.id)) return [];
  seen.add(q.id);
  const need = [];
  for (const p of q.preGroup) { if (completed.has(p)) continue; const pq = Q[p]; if (!ok(pq)) return null; const c = chainOf(pq, d, seen); if (!c) return null; need.push(...c, pq); }
  if (q.preSingle.length && !q.preSingle.some((p) => completed.has(p))) {
    let picked = null;
    for (const p of q.preSingle) { const pq = Q[p]; if (!ok(pq)) continue; const c = chainOf(pq, d, new Set(seen)); if (c) { picked = [...c, pq]; break; } }
    if (!picked) return null;
    need.push(...picked);
  }
  return need;
}

function planFor(d) {
  const dq = Object.values(Q).filter((q) => isDungeonQuest(q, d) && ok(q) && !completed.has(q.id));
  const atLevel = cfg.atLevel || level;
  const main = [], chains = new Map(), dropped = [];
  for (const q of dq) {
    if ((q.reqLevel || 0) > atLevel + (cfg.levelSlack ?? 3)) { dropped.push([q, 'needs level ' + q.reqLevel]); continue; }
    const c = chainOf(q, d);
    if (!c) { dropped.push([q, 'chain not available to you']); continue; }
    const chainReq = Math.max(0, ...c.map((p) => p.reqLevel || 0));
    if (chainReq > atLevel + (cfg.levelSlack ?? 5)) { dropped.push([q, 'its chain needs level ' + chainReq]); continue; }
    // a chain quest whose own objectives are in a dungeon (another one, or this one) can't be done on the way in
    if (c.some((p) => p.objectives.some((o) => { const sp = objSpawns(o); return sp.length && sp.every((s) => s.x < 0 || D.byArea[s.zone]); }) && !isDungeonQuest(p, d))) { dropped.push([q, 'chain goes through another dungeon']); continue; }
    main.push(q);
    q._chain = [...new Set(c.filter((p) => !isDungeonQuest(p, d)).map((p) => p.id))];
    for (const p of c) if (!isDungeonQuest(p, d)) chains.set(p.id, p);
  }
  // chain quests that are themselves dungeon quests are handled as dungeon quests
  return { d, main, chains: [...chains.values()], dropped };
}

const candidates = () => Object.values(D.list).map((d) => planFor(d)).filter((p) => p.main.length >= 1 && D.byArea[p.d.entrance.zone] === undefined && T[p.d.entrance.zone]);

async function build(plan) {
  const { d, main, chains } = plan;
  const locs = [], key = (p) => p.zone + ':' + p.x.toFixed(1) + ':' + p.y.toFixed(1);
  const locIdx = new Map();
  const L = (p) => { const k = key(p); if (!locIdx.has(k)) { locIdx.set(k, locs.length); locs.push(p); } return locIdx.get(k); };
  const start = st.pos && T[st.pos.zone] ? st.pos : (cfg.start || null);
  const startLoc = start ? L(start) : null;
  const entrance = d.entrance;
  // phase 1: gather (chain quests in full, then accepts of the dungeon quests)
  const ev = [];
  const qinfo = {};
  for (const q of chains) {
    const g = giverAt(q), e = enderAt(q);
    if (!g || !e) continue;
    const inLog = !!log[q.id];
    const pre = [...q.preGroup, ...q.preSingle].filter((p) => !completed.has(p));
    qinfo[q.id] = { q, g, e };
    if (!inLog) ev.push({ kind: 'accept', q: q.id, loc: L(g.at), work: 8, reqLevel: q.reqLevel || 0, pre, who: g.who });
    q.objectives.forEach((o, i) => {
      const done = inLog && (log[q.id].complete || (log[q.id].objectives || [])[i] && log[q.id].objectives[i].done);
      if (done) return;
      const at = spot(objSpawns(o)); if (!at) return;
      ev.push({ kind: 'obj', q: q.id, i, loc: L(at), work: o.kind === 'kill' ? 150 : o.kind === 'item' ? 200 : 30, reqLevel: 0, pre: [], label: objLabel(o), match: objMatch(o), loot: o.kind === 'item' });
    });
    ev.push({ kind: 'turnin', q: q.id, loc: L(e.at), work: 8, xp: qxp(q), qLevel: q.level, reqLevel: 0, pre: [], who: e.who });
  }
  for (const q of main) {
    const g = giverAt(q); if (!g) continue;
    qinfo[q.id] = { q, g, e: enderAt(q) };
    if (log[q.id]) continue;
    ev.push({ kind: 'accept', q: q.id, loc: L(g.at), work: 8, reqLevel: q.reqLevel || 0, pre: [...q.preGroup, ...q.preSingle].filter((p) => !completed.has(p)), who: g.who });
  }
  // end at the dungeon: a final fixed stop
  const entLoc = L(entrance);
  const n = locs.length;
  const Dm = new Float32Array(n * n);
  for (let a = 0; a < n; a++) for (let b = 0; b < n; b++) Dm[a * n + b] = a === b ? 0 : travel(locs[a], locs[b]);
  const order1 = await orderEvents(ev, Dm, n, startLoc ?? (ev[0] ? ev[0].loc : entLoc), entLoc);
  // phase 2: hand in everything from the entrance
  const ev2 = [];
  for (const q of main) { const e = qinfo[q.id] && qinfo[q.id].e; if (e) ev2.push({ kind: 'turnin', q: q.id, loc: L(e.at), work: 8, xp: qxp(q), qLevel: q.level, reqLevel: 0, pre: [], who: e.who }); }
  const n2 = locs.length;
  const D2 = new Float32Array(n2 * n2);
  for (let a = 0; a < n2; a++) for (let b = 0; b < n2; b++) D2[a * n2 + b] = a === b ? 0 : travel(locs[a], locs[b]);
  const order2 = await orderEvents(ev2, D2, n2, entLoc, null);
  // ---------- steps ----------
  const steps = [], sections = [];
  let curZone = start ? start.zone : null, secTitle = null, minutes = 0, here = start;
  const uiMap = (z) => (T[z] ? T[z].ui_map_id : undefined);
  const at = (p) => ({ m: uiMap(p.zone), x: +(p.x / 100).toFixed(4), y: +(p.y / 100).toFixed(4), zone: zoneName(p.zone) });
  const section = (title, zone) => { if (secTitle !== title) { sections.push({ title, zone: zoneName(zone) }); secTitle = title; } return sections.length; };
  const go = (p, phase) => {
    if (here) minutes += travel(here, p) / 60;
    if (curZone !== null && p.zone !== curZone) steps.push({ k: 'fly', dest: zoneName(p.zone), to: uiMap(p.zone), text: zoneName(p.zone), sec: section('Travel', p.zone), note: 'Fly, or ride if there is no flight path yet.' });
    curZone = p.zone; here = p;
    return section(phase + ': ' + zoneName(p.zone), p.zone);
  };
  const emit = (e, phase) => {
    const p = locs[e.loc]; const sec = go(p, phase); const q = Q[e.q];
    minutes += e.work / 60;
    if (e.kind === 'accept') steps.push({ k: 'accept', q: e.q, name: q.name, npc: e.who, r: 6, level: q.level, minLevel: q.reqLevel > level ? q.reqLevel : undefined, note: isDungeonQuest(q, d) ? 'For ' + d.name + '.' : 'Unlocks a ' + d.name + ' quest.', ...at(p), sec });
    else if (e.kind === 'obj') steps.push({ k: 'obj', q: e.q, name: q.name, text: e.label, match: e.match || undefined, loot: e.loot || undefined, r: 40, level: q.level, ...at(p), sec });
    else steps.push({ k: 'turnin', q: e.q, name: q.name, npc: e.who, r: 6, level: q.level, ...at(p), sec });
  };
  for (const k of order1) emit(ev[k], 'Gather');
  // the run
  const sec = go(entrance, 'Run');
  sections[sec - 1].title = 'Run ' + d.name;
  steps.push({ k: 'goto', text: 'Run ' + d.name, note: 'Every quest for it is in your log now. Use the Group Finder or /4 LookingForGroup.', ...at(entrance), r: 25, sec });
  const runMin = cfg.dungeonRunMin || 50;
  minutes += runMin + (cfg.groupWaitMin ?? 10);
  for (const q of main) q.objectives.forEach((o, i) => { if (objInDungeon(o, d) || inDungeonArea(q.zone, d)) steps.push({ k: 'obj', q: q.id, name: q.name, text: objLabel(o) + ' (in ' + d.name + ')', match: objMatch(o) || undefined, loot: o.kind === 'item' || undefined, level: q.level, sec }); });
  // quests that start from loot inside: worth knowing about
  const drops = Object.values(Q).filter((q) => ok({ ...q, starters: [{ type: 'npc', spawns: [{ x: 1 }] }], finishers: q.finishers }) && q.starters.some((s) => s.type === 'item') && inDungeonArea(q.zone, d) && !completed.has(q.id));
  if (drops.length) steps.push({ k: 'note', text: 'Loot inside can start: ' + drops.map((q) => q.name).join(', '), sec });
  for (const k of order2) emit(ev2[k], 'Hand in');
  let gained = 0; for (const s of steps) if (s.k === 'turnin') gained += qxp(Q[s.q]);
  steps.forEach((s, i) => { s.id = i + 1; });
  const lv = main.map((q) => q.level).sort((a, b) => a - b);
  const needs = Math.max(0, ...main.map((q) => q.reqLevel || 0), ...chains.map((q) => q.reqLevel || 0));
  return { dungeon: d.id, name: d.name, questLevel: lv[lv.length >> 1], needsLevel: needs, quests: main.map((q) => q.name), chainQuests: chains.map((q) => q.name), legs: [d.name], startLevel: level, endLevel: level, endXp: xp0, minutes: Math.round(minutes), xp: gained, sections, steps };
}

// precedence-safe initial order, then the annealer; the last stop (if any) is where the next phase starts
async function orderEvents(ev, Dm, n, startLoc, endLoc) {
  if (!ev.length) return [];
  const placed = new Set(), order = [];
  const qDone = new Set();
  for (let guard = 0; order.length < ev.length && guard < ev.length * ev.length; guard++) {
    for (let k = 0; k < ev.length; k++) {
      if (placed.has(k)) continue;
      const e = ev[k];
      const acceptPlaced = !ev.some((x, j) => x.q === e.q && x.kind === 'accept' && !placed.has(j));
      const objsPlaced = !ev.some((x, j) => x.q === e.q && x.kind === 'obj' && !placed.has(j));
      const preOk = (e.pre || []).every((p) => qDone.has(p) || !ev.some((x) => x.q === p && x.kind === 'turnin'));
      if ((e.kind === 'accept' && preOk) || (e.kind === 'obj' && acceptPlaced) || (e.kind === 'turnin' && acceptPlaced && objsPlaced)) { placed.add(k); order.push(k); if (e.kind === 'turnin') qDone.add(e.q); }
    }
  }
  if (order.length < ev.length) for (let k = 0; k < ev.length; k++) if (!placed.has(k)) order.push(k);
  if (ev.length < 3) return order;
  // charge the trip to the end stop (the dungeon) by adding a zero-work event there that must come last
  const evs = ev.map((e) => ({ ...e, pre: e.pre || [] }));
  let initial = order;
  if (endLoc !== null) { evs.push({ kind: 'obj', q: -9999, loc: endLoc, work: 0, reqLevel: 0, pre: [], last: true }); initial = [...order, evs.length - 1]; }
  const planLevel = Math.max(level, ...evs.map((e) => e.reqLevel || 0));
  const r = await optimize(evs, Dm, n, { startLoc, level: planLevel, xp: 0, xpToLevel: XP, xpWeight: 0, initial, budgetMs: cfg.optimizeMs || 3000, workers: cfg.workers || 3 });
  let best = r.order;
  if (endLoc !== null) { const i = best.indexOf(evs.length - 1); if (i !== best.length - 1) best = order; else best = best.slice(0, -1); }
  return best;
}

(async () => {
  const all = candidates();
  if (cfg.list || cfg.dungeon === 'auto' || Array.isArray(cfg.dungeon)) {
    const want = Array.isArray(cfg.dungeon) ? all.filter((p) => cfg.dungeon.includes(p.d.id))
      : all.filter((p) => { const lv = p.main.map((q) => q.level).sort((a, b) => a - b); const med = lv[lv.length >> 1]; return med >= level - 3 && med <= level + (cfg.aheadLevels ?? 8); });
    want.sort((a, b) => a.main.map((q) => q.level).sort()[0] - b.main.map((q) => q.level).sort()[0]);
    if (cfg.list) { for (const p of want) console.log(`${p.d.name}: ${p.main.length} quests (${p.main.map((q) => q.name + ' ' + q.level).join(', ')}), ${p.chains.length} chain quests${p.dropped.length ? ', dropped: ' + p.dropped.map(([q, why]) => q.name + ' (' + why + ')').join('; ') : ''}`); return; }
    const out = [];
    // quick variant: keep a dungeon quest only if it's worth its own extra time (planned with and without it)
    const worthXph = cfg.worthXph ?? 10000;
    for (const p of want) {
      const full = await build(p);
      const worth = [];
      if (p.main.length > 1) for (const q of p.main) {
        const others = p.main.filter((x) => x !== q);
        const need = new Set(others.flatMap((x) => x._chain));
        const saveMs = cfg.optimizeMs; cfg.optimizeMs = 700; // the with/without comparison only needs a rough plan
        const without = await build({ ...p, main: others, chains: p.chains.filter((c) => need.has(c.id)) });
        cfg.optimizeMs = saveMs;
        const minutes = Math.max(0, full.minutes - without.minutes);
        const own = p.chains.filter((c) => q._chain.includes(c.id) && !need.has(c.id));
        const xp = qxp(q) + own.reduce((t, c) => t + qxp(c), 0);
        const rw = rewardOf(q);
        const xph = minutes > 0 ? Math.round(((xp + rw.value) / minutes) * 60) : Infinity;
        const keep = minutes <= 5 || xph >= worthXph || rw.value >= (cfg.keepRewardValue || 1200);
        worth.push({ q, name: q.name, minutes, xp, reward: rw.text, xph, keep, chain: own.length });
      }
      const cut = worth.filter((w) => !w.keep);
      if (cut.length && cut.length < p.main.length) {
        const keepQ = p.main.filter((q) => !cut.some((w) => w.q === q));
        const need = new Set(keepQ.flatMap((q) => q._chain));
        const r = await build({ ...p, main: keepQ, chains: p.chains.filter((c) => need.has(c.id)) });
        r.variant = "quick";
        r.cut = cut.map((w) => `${w.name} (+${w.minutes} min for ${(w.xp / 1000).toFixed(1)}k XP${w.chain ? ", " + w.chain + "-quest chain" : ""})`);
        out.push(r);
        console.log(`  quick ${r.name}: skips ${r.cut.join("; ")}: ${r.steps.length} steps, ~${r.minutes} min`);
      }
      full.worth = worth.map(({ q, ...w }) => w);
      out.push(full);
      console.log(`${full.name}: ${full.quests.length} quests + ${full.chainQuests.length} chain, ${full.steps.length} steps, ~${full.minutes} min, ${full.xp} xp` + (worth.length ? "  [" + worth.map((w) => `${w.name}: +${w.minutes}m ${w.xph === Infinity ? "free" : Math.round(w.xph / 1000) + "k/h"}${w.keep ? "" : " SKIP"}`).join(", ") + "]" : ""));
    }
    fs.writeFileSync(cfg.out, JSON.stringify(out));
    return;

  }
  const p = all.find((x) => x.d.id === +cfg.dungeon);
  if (!p) throw new Error('no doable quests for dungeon ' + cfg.dungeon);
  const r = await build(p);
  fs.writeFileSync(cfg.out, JSON.stringify([r]));
  console.log(`${r.name}: ${r.quests.length} quests + ${r.chainQuests.length} chain, ${r.steps.length} steps, ~${r.minutes} min`);
})();
