// Normalize decoded QuestieDB JSON into one quest-centric file the router can use.
// usage: node build-db.js <qdbJsonDir> <xp.lua[,xp2.lua...]> <out.json> [drops.lua[,drops2.lua...]]
// (several XP or drop files: later ones win - QuestieDB's measured Forever XP, xpDB-traces.lua, over the Classic table)
const fs = require('fs');
const path = require('path');
const [dir, xpPath, outPath, dropPath] = process.argv.slice(2);
// drop rates: item -> npc -> percent (later tables override earlier ones)
const RATES = {};
for (const dp of (dropPath || '').split(',').filter(Boolean)) {
  let cur = null;
  for (const line of fs.readFileSync(dp, 'utf8').split(/\r?\n/)) {
    let m = /^\s{4}\[(\d+)\] = \{/.exec(line);
    if (m) { cur = RATES[m[1]] = RATES[m[1]] || {}; continue; }
    m = /^\s{8}\[(\d+)\] = ([\d.]+),/.exec(line);
    if (m && cur) cur[m[1]] = +m[2];
  }
}
const load = (n) => JSON.parse(fs.readFileSync(path.join(dir, n + '.json'), 'utf8'));
const Q = load('quests'), N = load('npcs'), O = load('objects'), I = load('items');

// quest XP: [id] = {level, xp}
const XP = {};
// [id] = {level, xp} (the Classic table) and QuestXP.db[id] = {level, xp} (Forever's measured traces)
for (const xp of xpPath.split(',').filter(Boolean)) for (const m of fs.readFileSync(xp, 'utf8').matchAll(/\[(\d+)\]\s*=\s*\{(\d+),\s*(\d+)\}/g)) XP[m[1]] = +m[3];

// sparse-array fields arrive either as arrays or as {"3": ...} maps
const at = (v, i) => (v == null ? undefined : Array.isArray(v) ? v[i - 1] : v[i]);
const list = (v) => (v == null ? [] : Array.isArray(v) ? v : Object.values(v));
// a zone -> points map: one keyed only by 1 (or 1..n) arrives as a list, and list position 0 is zone 1 (Dun Morogh's
// whole population was once filed under zone 0 this way)
const zones = (v) => (v == null ? [] : Array.isArray(v) ? v.map((x, i) => [String(i + 1), x]) : Object.entries(v));

function spawnsOf(rec, field) {
  // returns [{zone, x, y}]
  const out = [];
  const s = rec && rec[field];
  if (!s) return out;
  for (const [zone, pts] of zones(s)) for (const p of list(pts)) if (p && p[0] >= 0) out.push({ zone: +zone, x: p[0], y: p[1] }); else if (p) out.push({ zone: +zone, x: -1, y: -1, instance: true });
  return out;
}
const npcInfo = (id) => {
  const n = N[id];
  if (!n) return null;
  return { id: +id, name: n[1], minLevel: n[4], maxLevel: n[5], rank: n[6] || 0, sub: n[14], spawns: spawnsOf(n, 7), friendly: n[13] };
};
const objInfo = (id) => (O[id] ? { id: +id, name: O[id][1], spawns: spawnsOf(O[id], 4) } : null);

const quests = {};
for (const [id, q] of Object.entries(Q)) {
  const start = q[2] || [], end = q[3] || [];
  const starters = [];
  for (const n of list(at(start, 1))) { const i = npcInfo(n); if (i) starters.push({ type: 'npc', ...i }); }
  for (const o of list(at(start, 2))) { const i = objInfo(o); if (i) starters.push({ type: 'object', ...i }); }
  for (const it of list(at(start, 3))) if (I[it]) starters.push({ type: 'item', id: +it, name: I[it][1], drops: list(I[it][2]).map(Number) });
  const finishers = [];
  for (const n of list(at(end, 1))) { const i = npcInfo(n); if (i) finishers.push({ type: 'npc', ...i }); }
  for (const o of list(at(end, 2))) { const i = objInfo(o); if (i) finishers.push({ type: 'object', ...i }); }

  const obj = q[10] || {};
  const objectives = [];
  for (const o of list(at(obj, 1))) if (o) objectives.push({ kind: 'kill', npc: o[0], text: o[1] });
  for (const o of list(at(obj, 2))) if (o) objectives.push({ kind: 'object', object: o[0], text: o[1] });
  for (const o of list(at(obj, 3))) if (o) {
    const it = I[o[0]];
    objectives.push({ kind: 'item', item: o[0], name: it && it[1], npcDrops: it ? list(it[2]).map(Number) : [], rates: RATES[o[0]] || null, objectDrops: it ? list(it[3]).map(Number) : [], vendors: it ? list(it[14]).map(Number) : [] });
  }
  const rep = at(obj, 4); if (rep) objectives.push({ kind: 'rep', faction: rep[0], value: rep[1] });
  for (const o of list(at(obj, 5))) if (o) objectives.push({ kind: 'killcredit', npcs: list(o[0]), base: o[1], text: o[2] });
  for (const o of list(at(obj, 6))) if (o) objectives.push({ kind: 'spell', spell: o[0], text: o[1], item: o[2] });
  const trig = q[9];
  if (trig) {
    const pts = [];
    for (const [zone, ps] of zones(trig[1] || trig['2'])) for (const p of list(ps)) pts.push({ zone: +zone, x: p[0], y: p[1] });
    objectives.push({ kind: 'explore', text: trig[0] || trig['1'], spawns: pts });
  }

  quests[id] = {
    id: +id, name: q[1], reqLevel: q[4] || 1, level: q[5] || q[4] || 1,
    races: q[6] || 0, classes: q[7] || 0, text: q[8] || [],
    starters, finishers, objectives,
    sourceItem: q[11], preGroup: list(q[12]), preSingle: list(q[13]), children: list(q[14]),
    inGroupWith: list(q[15]), exclusive: list(q[16]), zone: q[17] || 0,
    skill: q[18], minRep: q[19], nextInChain: q[22], flags: q[23] || 0, special: q[24] || 0,
    parent: q[25], breadcrumbFor: q[27], breadcrumbs: list(q[28]), reqSpell: q[30],
    xp: XP[id] || 0,
  };
}
// compact npc/object tables for objective lookups
const npcs = {}; for (const id of Object.keys(N)) npcs[id] = npcInfo(id);
const objects = {}; for (const id of Object.keys(O)) objects[id] = objInfo(id);
// Forever's changes the source data doesn't have yet (tools/forever-overrides.json)
// FR_NO_OVERRIDES=1: QuestieDB's data as it is (tools/update-questiedb.js compares our fixes against it)
// (the npcs and objects too: overrides name givers and enders as "npc:ID", filled in from them, and rename NPCs -
// given the quests alone, those givers came out empty and every Mount Hyjal fix was lost on a rebuild)
if (!process.env.FR_NO_OVERRIDES) for (const line of require('./apply-overrides').apply({ quests, npcs, objects })) console.log('forever override: ' + line);
// same-name alternatives the data leaves unmarked (one quest from givers in several towns, all to one place): doing one
// closes the others (tools/exclusive-alternatives.js). After the overrides, which can fix a giver or hand-in, or
// rule a quest out with notAlternative. (Not with FR_NO_OVERRIDES: that is QuestieDB's data as it is.)
if (!process.env.FR_NO_OVERRIDES) {
  const ALT = require('./exclusive-alternatives');
  for (const g of ALT.mark({ quests })) console.log('exclusive alternatives: ' + ALT.describe({ quests }, g));
}
fs.writeFileSync(outPath, JSON.stringify({ quests, npcs, objects }));
console.log('quests', Object.keys(quests).length, 'with xp', Object.values(quests).filter((q) => q.xp).length);
