const { raceOk } = require('./world'); // race masks above bit 32 (Skyborne)
// Route generator v0: picks quests in a set of zones for one character and orders
// accept / objective / turn-in actions into a route, then prints it as text and JSON.
// usage: node route.js <db.json> <config.json> [out.json]
const fs = require('fs');
const [dbPath, cfgPath, outPath] = process.argv.slice(2);
const { quests: Q, npcs: N, objects: O } = JSON.parse(fs.readFileSync(dbPath, 'utf8'));
const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));

// ---------- character ----------
const RACE_BIT = { human: 1, orc: 2, dwarf: 4, nightelf: 8, undead: 16, tauren: 32, gnome: 64, troll: 128 };
const CLASS_BIT = { warrior: 1, paladin: 2, hunter: 4, rogue: 8, priest: 16, shaman: 64, mage: 128, warlock: 256, druid: 1024 };
const raceBit = RACE_BIT[cfg.race], classBit = CLASS_BIT[cfg.class];
const XP_TO_LEVEL = [0, 400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600, 8800, 10100, 11400, 12900, 14400, 16000, 17700, 19400, 21300, 23200, 25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400, 44300, 47400, 50800, 54500, 58600, 62800, 67100, 71600, 76100, 80800, 85700, 90700, 95800, 101000, 106300, 111800, 117500, 123200, 129100, 135100, 141200, 147500, 153900, 160400, 167100, 173900, 180800, 187900, 195000, 202300, 209800];

// ---------- geometry ----------
// zone sizes in yards (classic); unknown zones fall back to 3000 x 2000
const ZONE_YARDS = { 1: [4925, 3283], 12: [3470, 2314], 38: [2758, 1839], 40: [3500, 2333], 44: [2170, 1447], 10: [2700, 1800], 11: [4135, 2756], 148: [6550, 4366], 1519: [1737, 1158], 1537: [790, 527], 267: [3200, 2133], 33: [6380, 4254], 141: [5091, 3393], 85: [4518, 3012], 130: [4200, 2800], 14: [5287, 3525], 215: [5137, 3425], 17: [10133, 6756] };
const yards = (z) => ZONE_YARDS[z] || [3000, 2000];
const RUN = 7; // yards/sec unmounted
function dist(a, b) {
  if (!a || !b) return 0;
  if (a.zone !== b.zone) return cfg.zoneHopSeconds ? cfg.zoneHopSeconds * RUN : 900; // cross-zone: flat cost
  const [w, h] = yards(a.zone);
  return Math.hypot((a.x - b.x) / 100 * w, (a.y - b.y) / 100 * h);
}
const travelSec = (a, b) => dist(a, b) / RUN;

// ---------- quest XP ----------
const medianXp = (() => {
  const by = {};
  for (const q of Object.values(Q)) if (q.xp && q.level > 0 && q.level <= 60) (by[q.level] = by[q.level] || []).push(q.xp);
  const med = {};
  for (let l = 1; l <= 60; l++) {
    const pool = [];
    for (let d = -2; d <= 2; d++) if (by[l + d]) pool.push(...by[l + d]);
    pool.sort((a, b) => a - b);
    med[l] = pool.length ? pool[pool.length >> 1] : 100 * l;
  }
  return med;
})();
const baseXp = (q) => q.xp || medianXp[Math.max(1, Math.min(60, q.level))];
function questXpAt(q, level) {
  const d = level - q.level, x = baseXp(q);
  if (d <= 5) return x;
  return Math.round(x * Math.max(0.1, 1 - 0.2 * (d - 5)));
}
function killXp(mobLevel, level) {
  const gray = level <= 5 ? 0 : level <= 39 ? level - Math.floor(level / 10) - 5 : level - Math.floor(level / 5) - 1;
  if (mobLevel <= gray) return 0;
  const base = level * 5 + 45;
  return Math.round(mobLevel >= level ? base * (1 + 0.05 * (mobLevel - level)) : base * (1 - (level - mobLevel) / (level - gray + 5)));
}

// ---------- eligibility ----------
const zones = new Set(cfg.zones);
const inZones = (s) => zones.has(s.zone);
function eligible(q) {
  if (q.races && !raceOk(q.races, cfg.race)) return 'race';
  if (q.classes && !(q.classes & classBit)) return 'class';
  if (q.special & 3) return 'repeatable/event';
  if (q.skill) return 'profession';
  if (q.reqSpell) return 'spell';
  if (q.minRep) return 'reputation';
  if (q.level > cfg.maxQuestLevel || q.reqLevel > cfg.maxQuestLevel) return 'level';
  if (q.level < cfg.minQuestLevel) return 'low level';
  if ((cfg.skip || []).includes(q.id)) return 'config skip';
  return null;
}
const nearestSpawn = (spawns, from) => {
  let best = null, bd = Infinity;
  for (const s of spawns) if (inZones(s)) { const d = dist(from || s, s); if (d < bd) { bd = d; best = s; } }
  return best;
};

// objective count from the quest text: "Slay 4 Kobold Diggers ... 6 Riverpaw Miners"
function countFor(q, name) {
  const t = (q.text || []).join(' ');
  if (name) {
    const stem = name.replace(/s$/, '').split(' ').slice(-1)[0].slice(0, 6);
    const re = new RegExp('(\\d+)\\s+(?:[\\w\'-]+\\s){0,4}?' + stem.replace(/[^\w]/g, ''), 'i');
    const m = re.exec(t);
    if (m) return +m[1];
  }
  const any = /(\d+)\s+[A-Za-z]/.exec(t);
  return any ? Math.min(+any[1], 30) : 1;
}

// densest area of a spawn cloud: grid vote, then the centroid of spawns near the best cell
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
  return { zone: z, x: +x.toFixed(1), y: +y.toFixed(1), density: near.length, total: pts.length };
}

// ---------- build tasks ----------
const skipped = [];
const tasks = {}; // qid -> {q, accept, objs[], turnin, flags}
for (const q of Object.values(Q)) {
  const why = eligible(q);
  if (why) continue;
  const starter = q.starters.find((s) => s.type !== 'item' && s.spawns && s.spawns.some(inZones));
  const itemStart = q.starters.find((s) => s.type === 'item');
  const finisher = q.finishers.find((s) => s.spawns && s.spawns.some(inZones));
  if (!finisher || (!starter && !itemStart)) continue; // not in these zones
  if (!starter && itemStart && !cfg.includeItemStarts) continue;
  const t = { q, flags: [], objs: [] };
  if (starter) t.accept = { who: starter.name, id: starter.id, type: starter.type, at: nearestSpawn(starter.spawns) };
  else t.accept = { who: itemStart.name, item: itemStart.id, type: 'item', at: cluster(itemStart.drops.flatMap((d) => (N[d] ? N[d].spawns : []))) };
  t.turnin = { who: finisher.name, id: finisher.id, type: finisher.type, at: null, spawns: finisher.spawns.filter(inZones) };
  let elite = false, dungeon = false, missing = false;
  for (const o of q.objectives) {
    let spawns = [], label = '', work = 0, mobLevel = 0, mobs = [];
    if (o.kind === 'kill' || o.kind === 'killcredit') {
      const ids = o.kind === 'kill' ? [o.npc] : o.npcs;
      for (const id of ids) if (N[id]) { spawns.push(...N[id].spawns); mobs.push(N[id]); }
      const nm = mobs[0] ? mobs[0].name : o.text;
      const n = countFor(q, o.text || nm);
      label = `Kill ${n} ${o.text || nm}`; work = n * cfg.secPerKill; mobLevel = mobs[0] ? mobs[0].maxLevel : q.level;
      t.kills = (t.kills || 0) + n;
    } else if (o.kind === 'item') {
      const drops = o.npcDrops.map((d) => N[d]).filter(Boolean);
      const objs = o.objectDrops.map((d) => O[d]).filter(Boolean);
      for (const d of drops) spawns.push(...d.spawns);
      for (const d of objs) spawns.push(...d.spawns);
      const n = countFor(q, o.name);
      if (!drops.length && !objs.length && o.vendors.length) { label = `Buy ${n} ${o.name}`; work = 30; spawns = o.vendors.flatMap((v) => (N[v] ? N[v].spawns : [])); }
      else if (objs.length && !drops.length) { label = `Loot ${n} ${o.name} (from ${objs[0].name})`; work = n * cfg.secPerObject; }
      else { label = `Collect ${n} ${o.name}` + (drops.length <= 3 ? ` (from ${drops.map((d) => d.name).join(', ')})` : ''); work = n * cfg.secPerKill / cfg.dropRate; t.kills = (t.kills || 0) + n / cfg.dropRate; }
      mobs = drops; mobLevel = drops[0] ? drops[0].maxLevel : q.level;
    } else if (o.kind === 'object') {
      if (O[o.object]) spawns = O[o.object].spawns;
      label = o.text || `Use ${O[o.object] ? O[o.object].name : 'object'}`; work = 20;
    } else if (o.kind === 'explore') {
      spawns = o.spawns; label = o.text || 'Explore'; work = 5;
    } else continue;
    // group-only when every source of the objective is elite (one elite among many droppers doesn't count)
    if (mobs.length && mobs.every((m) => m.rank >= 1)) elite = true;
    const at = cluster(spawns);
    if (!at) { if (spawns.length) dungeon = true; else missing = true; continue; }
    t.objs.push({ label, at, work, mobLevel, mobIds: mobs.map((m) => m.id) });
  }
  if (elite) t.flags.push('elite');
  if (dungeon) t.flags.push('outside-zones');
  if (missing) t.flags.push('no-location');
  tasks[q.id] = t;
}

// drop quests whose objectives aren't in our zones (dungeons etc.) or need a group
for (const [id, t] of Object.entries(tasks)) {
  if (t.flags.includes('outside-zones') && !cfg.includeOutside) { skipped.push([t.q, 'objectives outside these zones (dungeon/other zone)']); delete tasks[id]; continue; }
  if (t.flags.includes('elite') && !cfg.includeElite) { skipped.push([t.q, 'elite objectives (group)']); delete tasks[id]; }
}
// exclusive groups: keep the better XP one
for (const t of Object.values(tasks)) for (const ex of t.q.exclusive) if (tasks[ex] && tasks[t.q.id]) {
  const loser = baseXp(tasks[ex].q) > baseXp(t.q) ? t.q.id : ex;
  skipped.push([tasks[loser].q, 'mutually exclusive with ' + (loser === ex ? t.q.id : ex)]); delete tasks[loser];
}
// prerequisites must be done already or be in the plan; otherwise drop (repeat until stable)
const done = new Set(cfg.completed || []);
for (let changed = true; changed;) {
  changed = false;
  for (const [id, t] of Object.entries(tasks)) {
    const q = t.q;
    const grpOk = q.preGroup.every((p) => done.has(p) || tasks[p]);
    const sglOk = !q.preSingle.length || q.preSingle.some((p) => done.has(p) || tasks[p]);
    if (!grpOk || !sglOk || done.has(+id)) {
      if (!done.has(+id)) skipped.push([q, 'prerequisite not available in this plan']);
      delete tasks[id]; changed = true;
    }
  }
}

// ---------- ordering ----------
// greedy: always do the action with the best value-per-second from where we stand,
// value = quest XP for turn-ins, a share of it for accepts/objectives so nearby work gets batched.
let level = cfg.level, xp = cfg.xp || 0, pos = cfg.start, clock = 0;
const accepted = new Set(), objDone = {}, turned = new Set(done);
const route = [];
const gain = (amount, why) => {
  xp += amount;
  while (level < 60 && xp >= XP_TO_LEVEL[level]) { xp -= XP_TO_LEVEL[level]; level++; route.push({ type: 'level', level, clock }); }
};
const prereqsMet = (q) => q.preGroup.every((p) => turned.has(p)) && (!q.preSingle.length || q.preSingle.some((p) => turned.has(p))) && (!q.parent || accepted.has(q.parent));
function candidates() {
  const c = [];
  for (const t of Object.values(tasks)) {
    const q = t.q, id = q.id;
    if (turned.has(id)) continue;
    if (!accepted.has(id)) {
      if (!prereqsMet(q) || q.reqLevel > level || accepted.size >= 20) continue;
      if (q.level > level + cfg.maxAbove) continue;
      if (t.accept.at) c.push({ kind: 'accept', t, at: t.accept.at, work: 3 });
      continue;
    }
    const left = t.objs.filter((o, i) => !(objDone[id] || new Set()).has(i));
    if (left.length) for (const o of t.objs) { const i = t.objs.indexOf(o); if (!(objDone[id] || new Set()).has(i)) c.push({ kind: 'obj', t, i, at: o.at, work: o.work }); }
    else c.push({ kind: 'turnin', t, at: nearestSpawn(t.turnin.spawns, pos), work: 3 });
  }
  return c;
}
function score(c) {
  const qx = questXpAt(c.t.q, level);
  const sec = travelSec(pos, c.at) + c.work;
  const v = c.kind === 'turnin' ? qx : c.kind === 'accept' ? qx * 0.35 : qx * 0.5 / Math.max(1, c.t.objs.length);
  // bonus: other open objectives / turn-ins / accepts sharing this spot get done "on the way"
  return v / Math.max(sec, 5);
}
for (let guard = 0; guard < 5000; guard++) {
  if (level >= cfg.targetLevel && !cfg.finishOpen) break;
  const cs = candidates();
  if (!cs.length) break;
  cs.sort((a, b) => score(b) - score(a));
  const c = cs[0];
  clock += travelSec(pos, c.at) + c.work; pos = c.at;
  const q = c.t.q;
  // everything else within ~60 yards that is doable right now happens in the same stop
  const here = [c, ...cs.slice(1).filter((o) => dist(c.at, o.at) < 60 && !(o.t === c.t && o.kind !== c.kind))];
  for (const h of here) {
    const hq = h.t.q;
    if (h.kind === 'accept' && !accepted.has(hq.id)) { accepted.add(hq.id); route.push({ type: 'accept', q: hq, who: h.t.accept.who, at: h.at, clock }); }
    else if (h.kind === 'obj' && accepted.has(hq.id)) {
      (objDone[hq.id] = objDone[hq.id] || new Set()).add(h.i);
      const o = h.t.objs[h.i];
      if (h !== c) clock += o.work;
      const kills = o.label.startsWith('Kill') || o.label.startsWith('Collect') ? Math.round(o.work / cfg.secPerKill) : 0;
      gain(kills * killXp(o.mobLevel, level));
      route.push({ type: 'obj', q: hq, label: o.label, at: o.at, clock });
    } else if (h.kind === 'turnin' && accepted.has(hq.id) && !turned.has(hq.id)) {
      const left = h.t.objs.filter((o, i) => !(objDone[hq.id] || new Set()).has(i));
      if (left.length) continue;
      turned.add(hq.id); accepted.delete(hq.id);
      const got = questXpAt(hq, level); gain(got);
      route.push({ type: 'turnin', q: hq, who: h.t.turnin.who, at: h.at, xp: got, clock });
    }
  }
}

// ---------- output ----------
const fmt = (a) => (a ? `${a.x.toFixed(1)},${a.y.toFixed(1)}` : '?');
const zname = (z) => ({ 40: 'Westfall', 38: 'Loch Modan', 44: 'Redridge', 12: 'Elwynn', 1519: 'Stormwind', 10: 'Duskwood' }[z] || 'zone ' + z);
const lines = [];
let lastZone = null;
for (const s of route) {
  if (s.type === 'level') { lines.push(`        ---- level ${s.level} (${Math.round(s.clock / 60)} min) ----`); continue; }
  if (s.at && s.at.zone !== lastZone) { lines.push(`== ${zname(s.at.zone)}`); lastZone = s.at.zone; }
  const tag = `[${s.q.level}] ${s.q.name} (${s.q.id})`;
  if (s.type === 'accept') lines.push(`${fmt(s.at)}  ACCEPT  ${tag} from ${s.who}`);
  if (s.type === 'obj') lines.push(`${fmt(s.at)}  DO      ${s.label} — ${s.q.name}`);
  if (s.type === 'turnin') lines.push(`${fmt(s.at)}  TURN IN ${tag} to ${s.who} (+${s.xp} xp)`);
}
const left = Object.values(tasks).filter((t) => !turned.has(t.q.id));
lines.push('', `End: level ${level} + ${xp} xp after ~${Math.round(clock / 60)} min of play (estimate)`);
if (left.length) lines.push('Not done (still open or never picked up): ' + left.map((t) => `${t.q.name} (${t.q.id})${accepted.has(t.q.id) ? ' [in log]' : ''}`).join('; '));
lines.push('', 'Skipped:');
for (const [q, why] of skipped) lines.push(`  ${q.name} (${q.id}) [${q.level}]: ${why}`);
console.log(lines.join('\n'));
if (outPath) fs.writeFileSync(outPath, JSON.stringify(route.map((s) => ({ ...s, q: s.q && s.q.id })), null, 1));
