const { raceOk } = require('./world'); // race masks above bit 32 (Skyborne)
// Audit a path in an installed Route.lua for mistakes a player would spot: quests or mobs too far above your level at
// that point, hand-ins before pick-ups, zone changes with no travel, repeated steps.
// usage: node lint-route.js <Route.lua> <db.json> [pathId] [class,race]   e.g. warlock,gnome - then every quest on the
// path must be one that character can take
const fs = require('fs');
// [doneFile]: a JSON list of quests the character had completed when the plan was made - then every pick-up must have
// its prerequisites done before it (before the route, or handed in earlier on it)
const [routeFile, dbFile, wantId, who, doneFile] = process.argv.slice(2);
const { RACE_BIT, CLASS_BIT, LEVEL_ABOVE, DUNGEON_ABOVE } = require('./world'); // the game's rules, shared by every stage

const [whoClass, whoRace] = String(who || '').toLowerCase().replace(/[^a-z,]/g, '').split(',');
const text = fs.readFileSync(routeFile, 'utf8');
const db = JSON.parse(fs.readFileSync(dbFile, 'utf8'));
const at = wantId ? text.indexOf('    id = ' + JSON.stringify(wantId) + ',') : text.indexOf('    id = "path:');
if (at < 0) { console.log('path not found'); process.exit(1); }
const st = text.indexOf('    steps = {', at); // (the choice-point check below reads the route's header)
const steps = require('./routefile').steps(text, wantId); // the shared plan-file reader
const issues = [];
const accepted = new Set(), seen = new Set();
let lastLvl = 0, lastMap = null;
const mobLevelOf = (label) => { const n = Object.values(db.npcs).find((x) => x && x.name === label); return n ? n.maxLevel : null; };
// dungeon quests (objectives "... (in The Stockade)") are done in a group: a group handles mobs a few levels higher
const dungeonQ = new Set(steps.filter((s) => s.k === 'obj' && / \(in [^)]+\)$/.test(s.text || '')).map((s) => s.q));
// the character file (doneFile): a list of done quests, or { done: [...], log: [...] } - a quest already in your log
// has no real pick-up (its accept step just ticks), so its level is not held against the pick-up
const who0 = (() => { try { return doneFile && fs.existsSync(doneFile) ? JSON.parse(fs.readFileSync(doneFile, 'utf8')) : null; } catch (e) { return null; } })();
const inLogAtStart = new Set(((who0 && !Array.isArray(who0) && who0.log) || []).map(Number));
steps.forEach((s, i) => {
  const n = i + 1, lvl = s.lvl || lastLvl; if (s.lvl) lastLvl = s.lvl;
  const q = s.q > 0 ? db.quests[s.q] : null, above = dungeonQ.has(s.q) ? DUNGEON_ABOVE : LEVEL_ABOVE; // the same gate the planner uses (world.js)
  // a quest's level only matters if it makes you fight or loot: a delivery or talk quest (The Hermit) is safe at any level you can take it
  const fights = q && (q.objectives || []).some((o) => o.kind === 'kill' || (o.npcDrops || []).length || (o.objectDrops || []).length);
  if (s.k === 'accept' && q && fights && lvl && q.level > lvl + above && !inLogAtStart.has(s.q)) issues.push(`#${n} accept ${s.name} (quest ${q.level}) at level ${lvl}`);
  if (s.k === 'obj' && s.target && lvl) { const ml = mobLevelOf(s.target); if (ml && ml > lvl + above) issues.push(`#${n} kill ${s.target} (mobs up to ${ml}) at level ${lvl}`); }
  if (s.k === 'accept') accepted.add(s.q);
  if (s.k === 'turnin' && s.q > 0 && !accepted.has(s.q) && !s.inserted) { /* may be in log already: fine */ }
  if (s.m && lastMap && s.m !== lastMap && !['fly', 'hearth', 'train'].includes(s.k)) {
    const prev = steps[i - 1];
    if (prev && !['fly', 'hearth', 'train'].includes(prev.k)) issues.push(`#${n} ${s.k} ${s.name || s.text || ''}: zone changes (${lastMap} -> ${s.m}) with no travel step`);
  }
  const pv = steps[i - 1];
  if (pv && !pv.boat && !s.boat && ['fly', 'hearth'].includes(pv.k) && ['fly', 'hearth'].includes(s.k)) issues.push(`#${n} two travel steps in a row: ${pv.k} ${pv.dest || pv.text || ''} then ${s.k} ${s.dest || s.text || ''}`);
  if (s.m) lastMap = s.m;
  const key = s.k + ':' + (s.q || '') + ':' + (s.text || s.npc || '');
  if (s.q > 0 && seen.has(key)) issues.push(`#${n} repeated: ${s.k} ${s.name || s.text}`);
  seen.add(key);
});
// quests the character can't take: another class's quest (a warlock sent to deliver a warrior quest) or race's
if (whoClass || whoRace) {
  const cb = CLASS_BIT[whoClass], rb = RACE_BIT[whoRace], flagged = new Set();
  steps.forEach((s, i) => {
    const q = s.k === 'accept' && s.q > 0 ? db.quests[s.q] : null;
    if (!q || flagged.has(s.q)) return;
    const badClass = cb && q.classes && !(q.classes & cb), badRace = rb && q.races && !raceOk(q.races, whoRace);
    if (badClass || badRace) { flagged.add(s.q); issues.push(`#${i + 1} accept ${s.name}: a ${badClass ? 'class' : 'race'} quest your character can't take`); }
  });
}
// prerequisites: all of preGroup, or any one of preSingle, done before the route or handed in earlier on it
if (doneFile && fs.existsSync(doneFile)) {
  const done = new Set(Array.isArray(who0) ? who0 : ((who0 && who0.done) || []));
  steps.forEach((s, i) => {
    if (s.k === 'turnin' && s.q > 0) { done.add(s.q); return; }
    const q = s.k === 'accept' && s.q > 0 ? db.quests[s.q] : null;
    if (!q || inLogAtStart.has(s.q)) return; // already in your log: its prerequisites were met
    const group = q.preGroup || [], single = q.preSingle || [];
    const missing = group.filter((p) => !done.has(p));
    if (single.length && !single.some((p) => done.has(p))) missing.push(single.length === 1 ? single[0] : 'one of ' + single.join('/'));
    if (missing.length) issues.push(`#${i + 1} accept ${s.name}: needs ${missing.map((p) => (typeof p === 'number' && db.quests[p] ? db.quests[p].name + ' (' + p + ')' : p)).join(', ')} done first`);
  });
}
// the hearthstone has an hour's cooldown: hearth steps carry tm, the planned minutes since the route began
{
  let last = null;
  steps.forEach((s, i) => {
    if (s.k !== 'hearth' || typeof s.tm !== 'number') return;
    if (last && s.tm - last.tm < 60) issues.push(`#${i + 1} hearth only ${s.tm - last.tm} min after the one at #${last.n} (the hearthstone takes an hour)`);
    last = { tm: s.tm, n: i + 1 };
  });
}
// order within a quest: take it (at a level that lets you), then its objectives, then hand it in. Quests already in
// your log have no pick-up on the route, so only quests picked up on the route are held to the first rule.
{
  const firstAccept = new Map(), lastObj = new Map(), firstObj = new Map();
  steps.forEach((s, i) => {
    if (!(s.q > 0)) return;
    if (s.k === 'accept' && !firstAccept.has(s.q)) firstAccept.set(s.q, i);
    if (s.k === 'obj') { lastObj.set(s.q, i); if (!firstObj.has(s.q)) firstObj.set(s.q, i); }
  });
  let lvl = 0;
  steps.forEach((s, i) => {
    if (s.lvl) lvl = s.lvl;
    const n = i + 1;
    if (!(s.q > 0)) return;
    if (s.k === 'accept' && s.minLevel && lvl && s.minLevel > lvl) issues.push(`#${n} accept ${s.name} needs level ${s.minLevel}, you are ${lvl} here`);
    const a = firstAccept.get(s.q);
    if (s.k === 'obj' && a !== undefined && i < a && i === firstObj.get(s.q)) issues.push(`#${n} objective of ${s.name} before it is picked up (#${a + 1})`);
    if (s.k === 'turnin') {
      if (a !== undefined && i < a) issues.push(`#${n} hand-in of ${s.name} before it is picked up (#${a + 1})`);
      const lo = lastObj.get(s.q);
      if (lo !== undefined && i < lo && !steps.slice(i + 1).some((x) => x.k === 'turnin' && x.q === s.q)) issues.push(`#${n} hand-in of ${s.name} before its objectives are done (#${lo + 1})`);
    }
  });
}
// the quest log holds 40 on Forever: quests already in it at the start show up as hand-ins or objectives before any pick-up
// (quests in the log that the route never touches are unknown here, so this can only undercount)
{
  const log = new Set(), picked = new Set();
  for (const s of steps) if (s.q > 0 && (s.k === 'turnin' || s.k === 'obj') && !picked.has(s.q)) log.add(s.q); else if (s.k === 'accept' && s.q > 0) picked.add(s.q);
  let worst = log.size, at = 0;
  steps.forEach((s, i) => {
    if (!(s.q > 0)) return;
    if (s.k === 'accept') log.add(s.q);
    if (s.k === 'turnin') log.delete(s.q);
    if (log.size > worst) { worst = log.size; at = i + 1; }
  });
  if (worst > 40) issues.push(`#${at} ${worst} quests in your log at once (the log holds 40)`);
}
// the hearthstone takes you to the inn you last bound at: every hearth step must go to the latest bind step's map, or
// (before any bind on the route) to where you started bound - known here only as the first hearth's place, so the
// check is that later hearths without a rebind go to that same place. Hearth steps say where they go (bindMap).
{
  let home = null, fromBind = false;
  steps.forEach((s, i) => {
    if (s.k === 'bind' && s.m) { home = s.m; fromBind = true; }
    if (s.k !== 'hearth' || !s.bindMap) return;
    if (home === null) { home = s.bindMap; return; }
    if (s.bindMap !== home) issues.push(`#${i + 1} hearth to ${s.dest || s.text || s.bindMap}, but the stone is set ${fromBind ? 'at the bind step before it' : 'where the first hearth went'} (map ${home})`);
  });
}
// "where next?" choice points: the addon asks on exactly that step, so it must be the travel step that starts the
// zone, or the first step in the zone you would stay on - never a step deep inside it
{
  const head = text.slice(at, st);
  for (const m of head.matchAll(/\{ at = (\d+), level = \d+, options = \{ \{ zone = "([^"]*)"/g)) {
    const n = +m[1], zone = m[2], s = steps[n - 1], pv = steps[n - 2];
    const ok = s && (['fly', 'hearth'].includes(s.k) || (s.zone === zone && !(pv && pv.zone === zone)));
    if (!ok) issues.push(`#${n} choice point (stay in ${zone}) is on ${s ? s.k + ' ' + (s.name || s.text || '') + (s.zone ? ' in ' + s.zone : '') : 'no step'}, not at the zone boundary`);
  }
}
console.log(`${steps.length} steps checked`);
console.log(issues.length ? issues.slice(0, 40).join('\n') : 'no issues found');
