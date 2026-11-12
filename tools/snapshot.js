// Character state for the planner, from saved variables:
//   1. ForeverRoute's own snapshot (completed quests, quest log + objectives, level/xp, position, hearth, flight paths)
//   2. otherwise Journey Tracker's record (turned-in quests, level from its ding history)
// loadCharState(charSavedVariablesDir, conversionJsonPath) -> state | null
const fs = require('fs');
const path = require('path');
const { parseSavedVariables } = require('./luatable');

// Quest progress the game left blank. A snapshot taken while logging out can list every quest in the log with no
// objectives and no "complete" flag (the game has already let go of quest progress while the log still lists the rows).
// That save is the last one written each session, so on its own it would make the planner redo finished quests and
// drop finished ones it would otherwise hand in. Progress is never lost in game, so the last snapshot that did carry
// it is kept here (outside the game folder) and fills in the blank entries; quests it never saw stay marked unknown.
const MEMORY_DIR = process.env.FR_PROGRESS_MEMORY || path.join(__dirname, '..', 'campaign');
const known = (q) => q && typeof q.complete === 'boolean';
function rememberProgress(snap, log, dir) {
  try {
    const key = String(snap.name || 'char').replace(/[^\w-]/g, '') + '-' + require('crypto').createHash('sha1').update(path.resolve(dir).toLowerCase()).digest('hex').slice(0, 8);
    const file = path.join(MEMORY_DIR, 'quest-progress-' + key + '.json');
    let mem = null; try { mem = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) {}
    const raw = snap.log || {};
    let restored = 0, unknown = 0;
    for (const [id, q] of Object.entries(raw)) {
      if (known(q)) continue;
      const m = mem && mem.log && mem.log[id];
      if (known(m)) { log[id] = { complete: m.complete, objectives: (m.objectives || []).map((o) => ({ have: o[0], need: o[1], done: !!o[2], text: o[3] })), remembered: true }; restored++; }
      else { log[id].unknown = true; unknown++; }
    }
    // remember this save's progress (blank entries keep what was remembered for them; quests no longer in the log go)
    if (Object.values(raw).some(known) && !(mem && mem.time > (snap.time || 0))) {
      const keep = {};
      for (const [id, q] of Object.entries(raw)) if (known(q)) keep[id] = q; else if (mem && mem.log && known(mem.log[id])) keep[id] = mem.log[id];
      const next = JSON.stringify({ time: snap.time || 0, log: keep });
      if (!mem || JSON.stringify(mem) !== next) {
        fs.mkdirSync(MEMORY_DIR, { recursive: true });
        const tmp = file + '.' + process.pid + '.tmp';
        fs.writeFileSync(tmp, next); fs.renameSync(tmp, file);
      }
    }
    const say = [];
    if (restored) say.push(`progress of ${restored} quests from the save of ${new Date(mem.time * 1000).toLocaleString()} (this one left them blank)`);
    if (unknown) say.push(`progress unknown for ${unknown} quests (the save left them blank)`);
    return say.join(', ') || null;
  } catch (e) { return null; }
}

function loadCharState(dir, convPath) {
  if (!dir) return null; // a character planned from its settings alone (a new character, a test): no save to read
  const conv = convPath ? JSON.parse(fs.readFileSync(convPath, 'utf8')).geometry.transforms : [];
  const areaOfMap = {}; for (const t of conv) areaOfMap[t.ui_map_id] = t.area_id;
  const read = (f) => { const p = path.join(dir, f); return fs.existsSync(p) ? parseSavedVariables(fs.readFileSync(p, 'utf8')) : null; };
  const fr = read('ForeverRoute.lua');
  const snap = fr && fr.ForeverRouteChar && fr.ForeverRouteChar.snapshot;
  // level/xp written during logout can be zeroed: prefer Journey Tracker's level history then
  const jtLevel = (() => { const jt = read('JourneyTracker.lua'); const db = jt && jt.JourneyTrackerDB; const d = db && Object.keys(db.dings || {}).map(Number).filter((n) => !isNaN(n)); return d && d.length ? Math.max(...d) : null; })();
  if (snap && !(snap.xpMax > 0)) { snap.level = Math.max(snap.level || 0, jtLevel || 0); snap.xp = 0; }
  if (snap) {
    const log = {};
    for (const [id, q] of Object.entries(snap.log || {})) log[id] = { complete: !!q.complete, objectives: (q.objectives || []).map((o) => ({ have: o[0], need: o[1], done: !!o[2], text: o[3] })) };
    const memo = rememberProgress(snap, log, dir);
    return {
      source: 'ForeverRoute snapshot (' + new Date(snap.time * 1000).toLocaleString() + ', ' + snap.reason + ')' + (memo ? ', ' + memo : ''),
      name: snap.name, race: (snap.race || '').toLowerCase().replace(/\s/g, ''), class: (snap.class || '').toLowerCase(), faction: (snap.faction || '').toLowerCase(),
      level: snap.level, xp: snap.xp, completed: (snap.completed || []).map(Number), log,
      pos: snap.pos && areaOfMap[snap.pos.map] ? { zone: areaOfMap[snap.pos.map], x: snap.pos.x * 100, y: snap.pos.y * 100 } : null,
      bind: snap.bind, taxi: snap.taxi || [], skills: snap.skills || {}, gear: snap.gear || null,
      // the game's word on gear rewards (the addon's Gear.lua): itemID -> how much better than what you wear (<= 0: not)
      gearVerdicts: Object.fromEntries(Object.entries((fr.ForeverRouteChar && fr.ForeverRouteChar.gearVerdict) || {}).filter(([, v]) => v && typeof v.d === 'number').map(([k, v]) => [k, v.d])),
      // quests you said you are not doing (the Not doing this quest button): left out of every plan
      nope: Object.keys((fr.ForeverRouteChar && fr.ForeverRouteChar.nope) || {}).map(Number),
      // quests the game didn't offer you when you talked to their giver (the addon's Availability.lua), at your level
      // or above: left out until you level past it - the database lists some Forever doesn't give you
      notOffered: Object.entries((fr.ForeverRouteChar && fr.ForeverRouteChar.avail && fr.ForeverRouteChar.avail.no) || {})
        // (stay: refused where a level is not the reason - out until the game offers it, however high you are)
        .filter(([, n]) => n && (n.stay || (n.lvl || 0) >= (snap.level || 0))).map(([q]) => Number(q)),
    };
  }
  const jt = read('JourneyTracker.lua');
  const db = jt && jt.JourneyTrackerDB;
  if (db) {
    const completed = Object.keys((db.wrapped && db.wrapped.questsTurnedIn) || {}).map(Number);
    const dings = Object.keys(db.dings || {}).map(Number).filter((n) => !isNaN(n));
    const level = dings.length ? Math.max(...dings) : null;
    const ch = db.char || {};
    return {
      source: 'Journey Tracker record', name: ch.name, race: (ch.race || '').toLowerCase().replace(/\s/g, ''), class: (ch.class || '').toLowerCase(),
      faction: null, level, xp: 0, completed, log: {}, pos: null, bind: null, taxi: [], skills: {},
    };
  }
  return null;
}
module.exports = { loadCharState };

if (require.main === module) {
  const s = loadCharState(process.argv[2], process.argv[3]);
  console.log(s && { ...s, completed: s.completed.length + ' quests', log: Object.keys(s.log).length + ' in log' });
}
