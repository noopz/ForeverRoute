// Replay real situations through the real login sequence, many at once, and say what the card shows in each.
//
// The simulated players all start fresh at level 1 and follow the plan, so nothing ever checked what the card shows a
// character the plan did not expect: one who joins at 30, whose plan is hours old, who just hearthed to a capital, who
// stands in another zone than the step, whose log is full. Each scenario here is such a situation: a character (a real
// save, or a made-up one: level, position, quests done, quest log, flight paths), a plan (your own Route.lua or a
// built-in ForeverRoute_Starter_<race>_<class> folder) and what happens next (walk / fly / hearth somewhere).
//
// What is replayed, in the order the game does it (keep in step with the FR_LOADED / PLAYER_ENTERING_WORLD handlers in
// Core.lua, State.lua and Engine.lua):
//   ADDON_LOADED   ns.LoadMyPlan(), ns.char = the saved variables (ticks, skips, "not doing", flight paths, bind,
//                  quests not offered), ns.SelectRoute(saved path, quiet)
//   +0 s           PLAYER_ENTERING_WORLD (the engine's own handlers run: refreshes at +1 s and +3 s, travelDone at +4 s)
//   +3 s           Engine.ApplyInserts (finished quests with no hand-in on the route get one)
//   +3.5 s         Engine.MergeSideTrips (side-trip stops and flight paths you don't have, "on the way")
//   every second   Engine.UpdateFocus(your position) as the arrow does, and a quest-log update (FR_STATE)
//   then           each move of the scenario: walk / fly (control lost, zone change, control gained) / hearth
// It runs on tests/_harness.lua's world (virtual clock, position, level), so arrow and pins are checked against the card
// at every change, and one simulator run covers all scenarios (~6 s).
//
// usage:
//   node tools/replay.js --save <ForeverRoute.lua | SavedVariables dir> --plan <Route.lua | starter folder> [options]
//   node tools/replay.js --char race=Gnome,class=Warlock --plan <starter folder> [options]
// options:
//   --matrix              the built-in scenario matrix for this kind of plan (default when no --scenarios)
//   --scenarios <file>    your own: a JSON list of scenarios (fields below)
//   --only <text>         only scenarios whose id contains this
//   --engine <Engine.lua> another Engine.lua in place of the addon's (compare a shipped engine with the repo's)
//   --addon <dir>         the addon source (default addon/ForeverRoute)
//   --name <Name>         the character name to log in as (default: the save's; any name works on a built-in plan)
//   --next <n>            how many coming steps to list (default 10)
//   --json <file>         also write everything as JSON      --quiet   only scenarios with something wrong
//   --strict              exit 3 when any scenario has something wrong (for a gate)
// a scenario: { id, note, level, at: [map, x, y], history: "save" | "none" | [ids], log: "save" | "none" | {id: {complete}},
//   addLog: [{ id, complete, level }], logPad: n (other quests filling the log), taxi: "save" | "none" | [names],
//   ticks: "save" | "none", bind: "Stormwind City", dead: true, instance: "Gnomeregan",
//   then: [{ how: "walk" | "fly" | "hearth", at: [map, x, y] }] }
// exit code: 0 = ran (flags are findings to read, not failures; --strict: 3 if any "!!"), 1 = the simulator gave no result
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { readChar } = require('./save-fixture');

const ROOT = path.join(__dirname, '..');
const SIM = path.join(ROOT, 'sim', 'pkg', 'wow-ui-sim-v0.1.40-forever-windows-x86_64');

// ---------------------------------------------------------------- arguments
const args = {};
for (let a = process.argv.slice(2), i = 0; i < a.length; i++) {
  if (!a[i].startsWith('--')) continue;
  const k = a[i].slice(2);
  args[k] = (a[i + 1] && !a[i + 1].startsWith('--')) ? a[++i] : true;
}
if (!args.plan || !(args.save || args.char)) {
  console.log(fs.readFileSync(__filename, 'utf8').split('\n').filter((l) => l.startsWith('//')).map((l) => l.slice(3)).join('\n'));
  process.exit(2);
}
const src = path.resolve(args.addon || path.join(ROOT, 'addon', 'ForeverRoute'));
const planPath = path.resolve(args.plan);
const starter = fs.statSync(planPath).isDirectory();
const planText = fs.readFileSync(starter ? path.join(planPath, 'Plan.lua') : planPath, 'utf8');
const save = args.save ? readChar(path.resolve(args.save)) : {};
const snap = save.snapshot || {};
const synth = {};
for (const kv of String(args.char === true ? '' : args.char || '').split(',')) { const [k, v] = kv.split('='); if (k && v) synth[k] = v; }
const cap = (s) => String(s || '').toLowerCase().replace(/^./, (c) => c.toUpperCase());
const who = { name: args.name || synth.name || snap.name || 'Replay', race: cap(synth.race || snap.race || 'Gnome'), class: cap(synth.class || snap.class || 'Warlock') };
const NEXT = +(args.next || 10);

// ---------------------------------------------------------------- data: zone names, quest levels
const conv = JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'conversion.json'), 'utf8'));
const ZONES = {};
for (const t of (conv.geometry && conv.geometry.transforms) || []) if (t.ui_map_id && t.target_name) ZONES[t.ui_map_id] = t.target_name;
let QDB = null;
const quest = (id) => { if (!QDB) QDB = JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'db.json'), 'utf8')).quests; return QDB[id] || {}; };
// the plan's quests: hand-in spots it knows (ForeverRouteEnders) and quests with something to kill or collect on a route
const enderIds = new Set(); { const at = planText.indexOf('ForeverRouteEnders = {'); const end = planText.indexOf('\n}', at); for (const m of planText.slice(at, end).matchAll(/^\s*\[(\d+)\] = \{/gm)) enderIds.add(+m[1]); }
const routeQuestLevel = {}; for (const m of planText.matchAll(/k = "obj"[^\n]*?\bq = (\d+)[^\n]*?\blevel = (\d+)/g)) routeQuestLevel[+m[1]] = +m[2];

// ---------------------------------------------------------------- the built-in matrices
const SPOT = { // plausible places for a character of that level
  10: [1426, 0.47, 0.52, 'Kharanos'], 20: [1433, 0.30, 0.45, 'Lakeshire'], 30: [1431, 0.74, 0.46, 'Darkshire'], 40: [1434, 0.27, 0.77, 'Booty Bay'],
};
const SW = [1453, 0.6, 0.7], IF = [1455, 0.3, 0.6];
const TAXI = { // flight paths a character of that level plausibly has
  10: ['Ironforge, Dun Morogh'],
  20: ['Ironforge, Dun Morogh', 'Stormwind, Elwynn', 'Sentinel Hill, Westfall', 'Lakeshire, Redridge', 'Thelsamar, Loch Modan', 'Menethil Harbor, Wetlands'],
  30: ['Ironforge, Dun Morogh', 'Stormwind, Elwynn', 'Sentinel Hill, Westfall', 'Lakeshire, Redridge', 'Thelsamar, Loch Modan', 'Menethil Harbor, Wetlands', 'Darkshire, Duskwood', 'Southshore, Hillsbrad', 'Auberdine, Darkshore', 'Astranaar, Ashenvale'],
};
TAXI[40] = TAXI[30].concat(['Booty Bay, Stranglethorn', 'Refuge Pointe, Arathi', 'Theramore, Dustwallow Marsh', 'Ratchet, The Barrens', 'Gadgetzan, Tanaris']);
// a quest far below this level that the plan knows a hand-in for (and, if it can, has steps for), not done yet
function grayQuest(level, done) {
  let best = null;
  for (const id of enderIds) {
    const ql = routeQuestLevel[id] || quest(id).level;
    if (!ql || ql > level - 10 || ql < level - 16 || done.has(id)) continue;
    const score = (routeQuestLevel[id] ? 100 : 0) + ql;
    if (!best || score > best.score) best = { id, level: ql, score };
  }
  return best;
}
function matrix() {
  const L = snap.level, here = snap.pos && [snap.pos.map, snap.pos.x, snap.pos.y];
  const done = new Set(snap.completed || []); for (const id of Object.keys(snap.log || {})) done.add(+id);
  const out = [];
  const add = (s) => out.push(s);
  if (args.save && here) {
    const base = starter ? { ticks: 'none' } : {};
    const tag = starter ? 'join' : 'own';
    add({ ...base, id: tag + '-saved-spot', note: `the save as it is: level ${L}, where it was saved` + (starter ? ', first login on the built-in plan' : ', plan hours old') });
    add({ ...base, id: tag + '-hearth-stormwind', note: 'saved spot, then hearth to Stormwind', then: [{ how: 'hearth', at: SW }] });
    add({ ...base, id: tag + '-login-stormwind', note: 'logs in in Stormwind', at: SW });
    add({ ...base, id: tag + '-fly-ironforge', note: 'saved spot, then a flight to Ironforge', then: [{ how: 'fly', at: IF }] });
    add({ ...base, id: tag + '-login-ironforge', note: 'logs in in Ironforge', at: IF });
    add({ ...base, id: tag + '-other-zone', note: 'logs in in Darkshire (not where the save was)', at: SPOT[30].slice(0, 3) });
    add({ ...base, id: tag + '-other-continent', note: 'logs in in Auberdine (another continent)', at: [1439, 0.37, 0.44] });
    add({ ...base, id: tag + '-log-full', note: 'quest log full', logPad: 60 });
    const g = grayQuest(L, done);
    if (g) {
      add({ ...base, id: tag + '-gray-open', note: `a level ${g.level} quest in the log, not finished (${g.id} ${quest(g.id).name || ''})`, addLog: [{ id: g.id, complete: false, level: g.level }] });
      add({ ...base, id: tag + '-gray-ready', note: `a level ${g.level} quest in the log, finished (${g.id} ${quest(g.id).name || ''})`, addLog: [{ id: g.id, complete: true, level: g.level }] });
    }
    add({ ...base, id: tag + '-ghost', note: 'dead: a ghost at a graveyard in the next zone (Raven Hill)', dead: true, at: [1431, 0.20, 0.49] });
    add({ ...base, id: tag + '-in-dungeon', note: 'logs in inside a dungeon (The Stockade)', instance: 'The Stockade' });
    if (!starter) {
      add({ id: 'own-no-ticks', note: 'the same save without its ticks / skips / "not doing" (what the live check does today)', ticks: 'none' });
      add({ id: 'own-no-flights', note: 'the same save, no flight paths known yet (flight map never opened)', taxi: 'none' });
      add({ id: 'own-level-up-3', note: `the plan is older still: you are ${L + 3} now`, level: L + 3 });
    }
  }
  if (starter) {
    for (const lv of [10, 20, 30, 40]) {
      const spot = SPOT[lv].slice(0, 3), n = SPOT[lv][3];
      const b = { level: lv, history: 'none', log: 'none', ticks: 'none', taxi: TAXI[lv], bind: lv >= 20 ? 'Stormwind City' : 'Ironforge' };
      add({ ...b, id: `new-${lv}-spot`, note: `level ${lv}, nothing of the plan done, in ${n}`, at: spot });
      add({ ...b, id: `new-${lv}-stormwind`, note: `level ${lv}, nothing done, in Stormwind`, at: SW });
      add({ ...b, id: `new-${lv}-ironforge`, note: `level ${lv}, nothing done, in Ironforge`, at: IF });
      add({ ...b, id: `new-${lv}-hearth`, note: `level ${lv}, in ${n}, then hearth to Stormwind`, at: spot, then: [{ how: 'hearth', at: SW }] });
      add({ ...b, id: `new-${lv}-log-full`, note: `level ${lv}, in ${n}, quest log full of other quests`, at: spot, logPad: 60 });
      const g = grayQuest(lv, new Set());
      if (g) add({ ...b, id: `new-${lv}-gray-open`, note: `level ${lv}, in ${n}, a level ${g.level} quest in the log, not finished (${g.id} ${quest(g.id).name || ''})`, at: spot, addLog: [{ id: g.id, complete: false, level: g.level }] });
      add({ ...b, id: `new-${lv}-no-flights`, note: `level ${lv}, in ${n}, no flight paths known`, at: spot, taxi: 'none' });
    }
    add({ level: 30, history: 'none', log: 'none', ticks: 'none', taxi: TAXI[30], bind: 'Stormwind City', id: 'new-30-kalimdor', note: 'level 30, nothing done, in Astranaar (Kalimdor)', at: [1440, 0.345, 0.48] });
    add({ level: 30, history: 'none', log: 'none', ticks: 'none', taxi: TAXI[30], bind: 'Stormwind City', id: 'new-30-ghost', note: 'level 30, a ghost at Raven Hill', at: [1431, 0.20, 0.49], dead: true });
    add({ level: 30, history: 'none', log: 'none', ticks: 'none', taxi: TAXI[30], bind: 'Stormwind City', id: 'new-30-in-dungeon', note: 'level 30, logs in inside Gnomeregan', at: SPOT[30].slice(0, 3), instance: 'Gnomeregan' });
  }
  return out;
}

// ---------------------------------------------------------------- scenarios -> Lua
const toLua = (v) => {
  if (v === null || v === undefined) return 'nil';
  if (typeof v === 'string') return JSON.stringify(v).replace(/\\u([0-9a-f]{4})/g, (_, h) => '\\' + parseInt(h, 16));
  if (typeof v !== 'object') return String(v);
  if (Array.isArray(v)) return '{' + v.map(toLua).join(',') + '}';
  return '{' + Object.entries(v).map(([k, x]) => '[' + (/^-?\d+$/.test(k) ? k : JSON.stringify(k)) + ']=' + toLua(x)).join(',') + '}';
};
function resolve(s) {
  const pos = s.at || (snap.pos && [snap.pos.map, snap.pos.x, snap.pos.y]) || SW;
  const level = s.level || snap.level || 1;
  const history = Array.isArray(s.history) ? s.history : (s.history === 'none' || !args.save) ? [] : (snap.completed || []);
  const log = {};
  const src = (s.log && typeof s.log === 'object') ? s.log : (s.log === 'none' || !args.save) ? {} : (snap.log || {});
  for (const [id, q] of Object.entries(src)) {
    log[id] = { on: true, complete: !!q.complete, level: q.level || quest(id).level || routeQuestLevel[id] || level, name: quest(id).name || '',
      objectives: (q.objectives || []).map((o) => (Array.isArray(o) ? { have: o[0], need: o[1], finished: !!o[2], text: o[3] || '' } : o)) };
  }
  for (const q of s.addLog || []) {
    log[q.id] = { on: true, complete: !!q.complete, level: q.level || quest(q.id).level || level, name: quest(q.id).name || '',
      objectives: [{ have: q.complete ? 1 : 0, need: 1, finished: !!q.complete, text: (q.complete ? '1/1 ' : '0/1 ') + (quest(q.id).name || 'objective') }] };
  }
  const taxi = Array.isArray(s.taxi) ? s.taxi : (s.taxi === 'none' || !args.save) ? [] : (Array.isArray(snap.taxi) ? snap.taxi : Object.keys(save.knownTaxi || {}));
  // the saved variables the addon reads at login (not the logs and the snapshot)
  const char = {};
  const KEEP = s.ticks !== 'none'
    ? ['progress', 'nope', 'routeTitle', 'routeLegs', 'boundAt', 'ranRun', 'planBlock', 'charKey', 'avail', 'fixFpTicks', 'pinnedPath', 'returnTo', 'hideSpecial', 'requestZone', 'requestHandled']
    : ['routeTitle', 'routeLegs', 'boundAt', 'planBlock', 'charKey', 'fixFpTicks']; // ticks: "none" = the same character and path, nothing ticked
  if (args.save) for (const k of KEEP) { if (save[k] !== undefined) char[k] = save[k]; }
  if (Array.isArray(char.ranRun)) delete char.ranRun; // an empty Lua table reads back as a list
  if (starter) { delete char.routeTitle; delete char.routeLegs; delete char.planBlock; delete char.returnTo; delete char.pinnedPath; if (s.ticks === 'none') delete char.progress; }
  return {
    id: s.id, note: s.note || '', level, m: pos[0], x: pos[1], y: pos[2], history, log, taxi, char,
    bind: s.bind || snap.bind || 'Stormwind City', logPad: s.logPad || 0, dead: !!s.dead, instance: s.instance || null,
    moves: (s.then || []).map((t) => ({ how: t.how || 'walk', m: t.at[0], x: t.at[1], y: t.at[2] })),
  };
}

const RUNTIME = String.raw`
local ns = ForeverRoute
local E = ns.Engine
local HBD = LibStub("HereBeDragons-2.0")
local ZONES = __ZONES__
local STARTER, NAME, NEXT, PLANKEY = __STARTER__, __NAME__, __NEXT__, __PLANKEY__
-- real zone names (the simulator has "Map 1453"): flight-path matching and every travel line go by name
do
  local orig = C_Map.GetMapInfo
  C_Map.GetMapInfo = function(m) local i = orig and orig(m) or {}; if ZONES[m] then i = { mapID = m, name = ZONES[m], mapType = i.mapType, parentMapID = i.parentMapID } end; return i end
end
local function zoneName(m) return m and (ZONES[m] or ("map " .. tostring(m))) or nil end
local function esc(s) return '"' .. tostring(s):gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"' end
local function J(v)
  local t = type(v)
  if t == "boolean" then return tostring(v) end
  if t == "number" then if v ~= v or v == math.huge or v == -math.huge then return "null" end; return v == math.floor(v) and string.format("%d", v) or string.format("%.3f", v) end
  if t == "string" then return esc(v) end
  if t == "table" then
    local o = {}
    if v[1] ~= nil or next(v) == nil then for i = 1, #v do o[i] = J(v[i]) end; return "[" .. table.concat(o, ",") .. "]" end
    for k, x in pairs(v) do o[#o + 1] = esc(k) .. ":" .. J(x) end
    return "{" .. table.concat(o, ",") .. "}"
  end
  return "null"
end
local function L() return ForeverRouteData and ForeverRouteData.steps or {} end
local function keyOf(i) return E.Key and E.Key(i) or i end
-- why a step counts as done (the order Engine's status check asks in)
local function reason(i)
  local s = L()[i]; local id = keyOf(i); local S = ns.State
  if ns.char.manualDone[id] then return "ticked" end
  if ns.char.skipped[id] then return "skipped" end
  if s.q and ns.char.nope and ns.char.nope[s.q] then return "not-doing" end
  local mine = s.q and (S.OnQuest(s.q) or S.IsCompleted(s.q))
  if s.q and ns.Avail and ns.Avail.Unavailable(s.q) and not mine then return "not-offered" end
  if E.Outlevelled and E.Outlevelled(s) then return "outlevelled" end
  if E.GrayHandIn and E.GrayHandIn(s) then return "gray-hand-in" end
  if E.Breadcrumbed and E.Breadcrumbed(s) then return "breadcrumb" end
  if E.BehindYou and E.BehindYou(s) then return "behind-you" end
  if s.q and S.IsCompleted(s.q) then return "quest-done" end
  if s.q and S.OnQuest(s.q) then return s.k == "accept" and "in-log" or "objective-done" end
  return "passed-" .. tostring(s.k)
end
local function spot(i) -- the place a step is at: its own, or (a trip) the first stop after it
  local list = L()
  for j = i, math.min(#list, i + 6) do local t = list[j]; if t.m and t.x then return t end end
end
local function yards(i) -- from you: yards, -1 = another continent, nil = unknown
  local t = spot(i); if not t then return nil end
  local px, py, pinst = HBD:GetPlayerWorldPosition()
  local wx, wy, winst = HBD:GetWorldCoordinatesFromZone(t.x, t.y, t.m)
  if not (px and wx) then return nil end
  if pinst ~= winst then return -1 end
  return math.floor(math.sqrt((px - wx) ^ 2 + (py - wy) ^ 2))
end
-- a step that can never be done as the route stands: a quest step whose pick-up is not on the route any more, or a
-- pick-up whose earlier chain quest (ForeverRouteUnlocks) is neither handed in nor going to be. -> why, or nil
local function deadEnd(i, depth)
  local list, S = L(), ns.State
  local s = list[i]; depth = depth or 0
  if not (s and s.q and s.q > 0) or depth > 6 or E.Status(i) == "done" then return nil end
  local function open(kind, q) for j, t in ipairs(list) do if t.k == kind and t.q == q and E.Status(j) ~= "done" then return j end end end
  if (s.k == "turnin" or s.k == "obj") and not S.OnQuest(s.q) then
    local j = open("accept", s.q)
    if not j then return "its pick-up is not on the route" end
    return deadEnd(j, depth + 1)
  end
  if s.k == "accept" and E.PrereqsOf then
    for _, p in ipairs(E.PrereqsOf(s.q)) do
      if not S.IsCompleted(p) then
        local j = open("turnin", p)
        if not j then return "needs " .. (E.QuestName and E.QuestName(p) or ("quest " .. p)) .. " handed in first, which is not on the route" end
        local why = deadEnd(j, depth + 1); if why then return why end
      end
    end
  end
  return nil
end
local function desc(i)
  local s = L()[i]; if not s then return nil end
  local t = spot(i)
  return { i = i, k = s.k, name = s.name or s.text or s.dest or s.npc or s.zone or "?", text = s.text, npc = s.npc, m = s.m or s.to or (t and t.m), zone = s.zone or s.dest or zoneName(s.m or s.to),
    q = s.q, ql = s.level, lvl = s.lvl, min = s.minLevel or s.until_, st = E.Status(i), ins = s.inserted and true or false, yd = yards(i),
    dead = deadEnd(i) or false }
end
local function card(tag)
  local i = E.Shown(); local s = i and L()[i]
  local m = ns.State.Position()
  local c = { tag = tag, cur = E.current or 0, planned = E.planned or 0, focus = E.focus or 0, at = zoneName(m) or "nowhere", steps = #L() }
  if s then
    c.step = desc(i)
    local ok, tr = pcall(E.TravelFor, s)
    c.travel = (ok and tr and tr.text) or (not ok and ("ERROR " .. tostring(tr))) or nil
    local d, n, z = E.LegProgress(); c.leg = (z or "?") .. " " .. d .. "/" .. n; c.legZone = z
    if s.k == "accept" and ns.State.LogCount() >= ns.State.MaxLog() then c.logFull = ns.State.LogCount() .. "/" .. ns.State.MaxLog() end
  end
  -- the card's "ready nearby" line (a finished quest whose hand-in is close, wherever the plan has it)
  local px, py, pinst = HBD:GetPlayerWorldPosition()
  local okR, rn = pcall(function() return E.ReadyNearby and E.ReadyNearby(px, py, pinst) end)
  if okR and rn then c.ready = "#" .. rn.i .. " " .. tostring(rn.name) .. " (" .. math.floor(rn.d) .. " yd)" end
  return c
end

function ReplayRun(S)
  local out = { id = S.id, cps = {}, issues = {} }
  local char = S.char
  local sv = { un = UnitName, char = ForeverRouteChar, bind = GetBindLocation, time = time, num = C_QuestLog.GetNumQuestLogEntries, info = C_QuestLog.GetInfo,
    dead = UnitIsDeadOrGhost, max = C_QuestLog.GetMaxNumQuestsCanAccept, inst = IsInInstance, iinfo = GetInstanceInfo, mpos = C_Map.GetPlayerMapPosition, nsChar = ns.char, hasPlan = ns.hasPlan, planKey = ns.planKey }
  local function restore()
    UnitName, ForeverRouteChar, GetBindLocation, time, C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo = sv.un, sv.char, sv.bind, sv.time, sv.num, sv.info
    UnitIsDeadOrGhost, IsInInstance, GetInstanceInfo, C_Map.GetPlayerMapPosition, C_QuestLog.GetMaxNumQuestsCanAccept = sv.dead, sv.inst, sv.iinfo, sv.mpos, sv.max
  end
  -- ADDON_LOADED: this character's saved variables, and its plan (a fresh copy for every scenario)
  UnitName = function(u, ...) if u == "player" then return NAME end return sv.un(u, ...) end
  ForeverRouteChar = char
  ForeverRouteRoutes, ForeverRouteData, ForeverRoutePlan, ForeverRouteEnders, ForeverRouteUnlocks = nil, nil, nil, nil, nil
  if STARTER then ForeverRouteByChar = nil end
  -- (a built-in plan of a race the simulator has no such character for - Skyborne, played as another race: the plan
  -- is named outright for the load, as the folder says)
  local svKey = ns.StarterKey
  if PLANKEY then ns.StarterKey = function() return PLANKEY end end
  local okPlan, loaded = pcall(ns.LoadMyPlan)
  ns.StarterKey = svKey
  ns.hasPlan = okPlan and loaded
  UnitName = sv.un
  if not (okPlan and loaded and ns.Routes()[1]) then restore(); error("@@REPLAY" .. J({ id = S.id, fatal = "no plan loaded: " .. tostring(loaded) }) .. "@@END", 0) end
  if STARTER and not (ns.planKey and ns.planKey.starter) then restore(); error("@@REPLAY" .. J({ id = S.id, fatal = "not on the built-in plan" }) .. "@@END", 0) end
  out.plan = (ns.planKey and (ns.planKey.starter and ("built-in " .. ns.planKey.starter) or ns.planKey.found)) or "?"
  -- the world: quests done, quest log, bind, flight paths
  local quests, order = {}, {}
  for _, id in ipairs(S.history) do quests[id] = { on = false, done = true, objectives = {} } end
  for id, q in pairs(S.log) do quests[id] = q; q.noObjectives = #q.objectives == 0; order[#order + 1] = id end
  table.sort(order)
  for k = 1, S.logPad do if #order >= 40 then break end; order[#order + 1] = 900000 + k end
  GetBindLocation = function() return S.bind end
  C_QuestLog.GetMaxNumQuestsCanAccept = function() return 40 end -- Forever: 40 (the simulator says 25)
  C_QuestLog.GetNumQuestLogEntries = function() return #order, #order end
  C_QuestLog.GetInfo = function(i) local id = order[i]; if not id then return nil end; local q = quests[id]; return { questID = id, isHeader = false, level = q and q.level or S.level, title = q and q.name or "Other quest" } end
  if S.dead then UnitIsDeadOrGhost = function() return true end end
  local t0 = (sv.time and sv.time() or 0) + S.n * 100000
  local world
  time = function() return t0 + math.floor(world and world.t or 0) end -- the why log drops a line repeated within 2 minutes
  local okW, err = pcall(ForeverRouteTest.withWorld, ns.MainRoutes()[1] or ns.Routes()[1], function(w)
    world = w
    ForeverRouteDB.why = {} -- (the harness drew the plan once before the login: not part of it)
    local function try(what, f) local ok, e = pcall(f); if not ok then out.issues[#out.issues + 1] = what .. ": " .. tostring(e) end end
    local function tick() -- what the arrow does once a second, and a quest-log update
      try("focus", function() local px, py, pinst = HBD:GetPlayerWorldPosition(); E.UpdateFocus(px, py, pinst); E.Refresh() end)
    end
    local function cp(tag) local ok, c = pcall(card, tag); out.cps[#out.cps + 1] = ok and c or { tag = tag, error = tostring(c) } end
    ns.char = char
    w:knows(S.taxi); ns.char.knownTaxi = ns.State.knownTaxi
    if S.instance then -- inside a dungeon: no position on any map
      HBD.GetPlayerZonePosition = function() return nil end
      HBD.GetPlayerWorldPosition = function() return nil end
      C_Map.GetPlayerMapPosition = function() return nil end
      IsInInstance = function() return true, "party" end
      GetInstanceInfo = function() return S.instance, "party" end
    end
    E.focus, E.focusWhy, E.view, E.lastTrip, E.lastTripStep = nil, nil, nil, nil, nil
    ns.SelectRoute(ns.char.routeTitle, true)
    out.route = ForeverRouteData and (ForeverRouteData.title or ForeverRouteData.id)
    -- FR_LOADED's timers (registered first, so they run before PLAYER_ENTERING_WORLD's at the same second)
    C_Timer.After(3, function() if E.ApplyInserts() then E.Refresh() end end)
    C_Timer.After(3.5, function() if E.MergeSideTrips() then E.Refresh() end end)
    ns.Fire("PLAYER_ENTERING_WORLD")
    try("login +1 s", function() w:wait(1) end); tick(); cp("+1 s")
    try("login +3 s", function() w:wait(2) end); tick(); cp("+3 s hand-ins added")
    try("login +3.5 s", function() w:wait(0.5) end); cp("+3.5 s side trips, flight paths")
    try("login +5 s", function() w:wait(1.5) end); try("quest log update", function() ns.Fire("FR_STATE") end); tick(); cp("settled")
    for _, mv in ipairs(S.moves) do
      local what = mv.how .. " to " .. zoneName(mv.m)
      try(what, function()
        if mv.how == "fly" then w:taxi(true); w:go(mv.m, mv.x, mv.y); w:taxi(false)
        elseif mv.how == "hearth" then ns.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 8690); w:go(mv.m, mv.x, mv.y)
        else w:go(mv.m, mv.x, mv.y) end
      end)
      try("after " .. what, function() w:wait(2) end); tick(); try("quest log update", function() ns.Fire("FR_STATE") end); tick(); cp("after " .. what)
    end
    -- the verdict: the step shown, what is before it, what was added, what comes next
    local list, i = L(), E.Shown()
    local why, last, open = {}, {}, {}
    if i then
      for j = 1, i - 1 do
        local st = E.Status(j)
        local r = st == "done" and reason(j) or st
        why[r] = (why[r] or 0) + 1
        if st ~= "done" then if #open < 8 then local d = desc(j); open[#open + 1] = d end
        else last[#last + 1] = { i = j, k = list[j].k, name = list[j].name or list[j].text or list[j].dest or "?", why = r, lvl = list[j].lvl, ql = list[j].level }; if #last > 4 then table.remove(last, 1) end end
      end
    end
    out.before, out.lastDone, out.passedOver = why, last, open
    out.next = {}
    for _, j in ipairs(E.Upcoming(i or 0, NEXT)) do out.next[#out.next + 1] = desc(j) end
    out.inserted = {}
    for j, s in ipairs(list) do
      if s.inserted then
        local d = desc(j); local a, b = list[j - 1], list[j + 1]
        d.after = a and ((a.k or "") .. " " .. tostring(a.name or a.text or a.dest or "") .. " @" .. tostring(a.zone or a.dest or zoneName(a.m))) or "-"
        d.before = b and ((b.k or "") .. " " .. tostring(b.name or b.text or b.dest or "") .. " @" .. tostring(b.zone or b.dest or zoneName(b.m))) or "-"
        out.inserted[#out.inserted + 1] = d
      end
    end
    -- work nearer than the step shown: the nearest step you could do now among the next 60 not done
    local m = ns.State.Position()
    local near, here = nil, 0
    for _, j in ipairs(E.Upcoming(i or 0, 60)) do
      local s = list[j]
      if E.Status(j) == "todo" and s.m and s.x and (s.k == "accept" or s.k == "turnin" or s.k == "obj") and (not E.Available or E.Available(j)) then
        if s.m == m then here = here + 1 end
        local d = yards(j)
        if d and d >= 0 and (not near or d < near.yd) then near = desc(j) end
      end
    end
    out.nearer, out.inYourZone = near, here
    -- quests where you stand that were passed as "behind you" though they still give XP at your level
    local cut = { n = 0 }
    for j = 1, (i or 1) - 1 do
      local s = list[j]
      -- (by the value rule: all of its work in this zone, and worth its XP at your rate after that work - the same
      -- formula the live pick uses, ns.Next.BehindPrize; a quest whose objectives are elsewhere is not work left here)
      local allHere = true
      for _, t in ipairs(list) do if t.q == s.q and t.m and t.m ~= m then allHere = false; break end end
      -- (worth more than the way there: the value rule - its XP at your rate after its work, less the walk or ride)
      local spd = (ns.Travel and ns.Travel.Speed and ns.Travel.Speed()) or 7
      local yd0 = yards(j)
      local worth = not (ns.Next and ns.Next.BehindPrize) or ns.Next.BehindPrize(list, s, S.level) - ((yd0 and yd0 >= 0) and yd0 * 1.25 / spd or 0) > 0
      -- (and one you could take: a pick-up whose earlier chain quest isn't handed in isn't work left here)
      -- (and room in your log to take it: with the log full, nothing here is work you could take now)
      local room = ns.State.LogCount() < ns.State.MaxLog()
      if room and s.k == "accept" and s.m == m and allHere and worth and (not E.Available or E.Available(j)) and (s.level or 0) >= S.level - 5 and E.Status(j) == "done" and reason(j) == "behind-you" then
        cut.n = cut.n + 1
        local d = yards(j); if d and d >= 0 and (not cut.yd or d < cut.yd) then cut.yd, cut.name, cut.i, cut.ql, cut.lvl = d, s.name, j, s.level, s.lvl end
      end
    end
    out.cutHere = cut
    out.level, out.logCount, out.maxLog, out.total = UnitLevel("player"), ns.State.LogCount(), ns.State.MaxLog(), #list
    out.whys = {}
    for _, e in ipairs(ForeverRouteDB.why or {}) do out.whys[#out.whys + 1] = e.k .. ": " .. e.x end
  end, { anyTarget = true, at = { m = S.m, x = S.x, y = S.y, level = S.level, quests = quests } })
  restore()
  if not okW then out.issues[#out.issues + 1] = tostring(err) end
  error("@@REPLAY" .. J(out) .. "@@END", 0)
end
`;

function testFile(scns) {
  const head = RUNTIME.replace('__ZONES__', '{' + Object.entries(ZONES).map(([k, v]) => `[${k}]=${JSON.stringify(v)}`).join(',') + '}')
    .replace('__STARTER__', String(starter)).replace('__NAME__', JSON.stringify(who.name)).replace('__NEXT__', String(NEXT))
    .replace('__PLANKEY__', starter ? JSON.stringify(path.basename(planPath).replace(/^ForeverRoute_Starter_/, '').replace('_', '-')) : 'nil');
  const tests = scns.map((s, n) => `test(${JSON.stringify('replay ' + s.id)}, function() ReplayRun(${toLua({ ...s, n: n + 1 })}) end)`);
  return head + '\n' + tests.join('\n') + '\n';
}

// ---------------------------------------------------------------- run
function run(scns) {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'fr-replay-'));
  try {
    const dest = path.join(work, 'ForeverRoute');
    fs.cpSync(src, dest, { recursive: true, filter: (p) => !/[\\/]tests([\\/]|$)/.test(path.relative(src, p) ? '/' + path.relative(src, p) : '') });
    if (starter) {
      fs.writeFileSync(path.join(dest, 'Route.lua'), '-- no plan of your own\n');
      fs.cpSync(planPath, path.join(work, path.basename(planPath)), { recursive: true });
    } else fs.copyFileSync(planPath, path.join(dest, 'Route.lua'));
    if (args.engine) fs.copyFileSync(path.resolve(args.engine), path.join(dest, 'Engine.lua'));
    fs.mkdirSync(path.join(dest, 'tests'), { recursive: true });
    const harness = [path.join(src, 'tests', '_harness.lua'), path.join(ROOT, 'addon', 'ForeverRoute', 'tests', '_harness.lua')].find((f) => fs.existsSync(f));
    fs.copyFileSync(harness, path.join(dest, 'tests', '_harness.lua'));
    fs.writeFileSync(path.join(dest, 'tests', 'replay_test.lua'), testFile(scns));
    fs.mkdirSync(path.join(work, 'wtf'), { recursive: true });
    const r = spawnSync(path.join(SIM, 'wow-sim.exe'), ['--allow-ui-version-mismatch', '--addons-path', work, '--session-wtf-path', path.join(work, 'wtf'),
      '--class', who.class, '--race', who.race, 'run-tests', 'ForeverRoute'],
    { cwd: SIM, env: { ...process.env, WOW_INSTALL_PATH: require('./game-dir').WOW }, encoding: 'utf8', timeout: 600000, maxBuffer: 1 << 28, stdio: ['ignore', 'pipe', 'pipe'] });
    const out = (String(r.stdout || '') + '\n' + String(r.stderr || '') + (r.error ? '\n' + r.error.message : '')).replace(/\x1b\[[0-9;]*m/g, '');
    if (process.env.FR_KEEP) { fs.writeFileSync(path.join(work, 'out.txt'), out); console.log('kept ' + work); }
    const res = [];
    for (const m of out.matchAll(/@@REPLAY(.*?)@@END/gs)) { try { res.push(JSON.parse(m[1].replace(/\r?\n\s*/g, ''))); } catch (e) { res.push({ id: '?', fatal: 'unreadable result: ' + e.message }); } }
    if (!res.length) { console.log(out.split('\n').filter((l) => /✗|replay_test|rror|tests,/.test(l)).slice(0, 30).join('\n')); }
    return res;
  } finally { if (!process.env.FR_KEEP) fs.rmSync(work, { recursive: true, force: true }); }
}

// ---------------------------------------------------------------- verdicts
// flags: "!!" is what a player would call wrong (the card asks for something you can't or shouldn't do); "~" is worth
// a look but can be right (a long trip the plan really wants). Each carries the numbers it came from.
function flags(r, s) {
  const f = [];
  const hard = (x) => f.push('!! ' + x), note = (x) => f.push('~ ' + x);
  const c = r.cps[r.cps.length - 1] || {};
  const st = c.step;
  if (!st) { hard('NO-STEP: the card shows nothing'); return f; }
  const lv = r.level;
  const q = st.q && (s.log[st.q] ? 'log' : s.history.includes(st.q) ? 'done' : null);
  if (st.k === 'accept' && q) hard('ALREADY: pick up a quest you ' + (q === 'log' ? 'have' : 'did'));
  if ((st.k === 'turnin' || st.k === 'obj') && q === 'done') hard('ALREADY: a step of a quest you handed in');
  // (a hand-in not finished yet is shown with what it still needs - "Not finished" and its objective bars: a note)
  if (st.st === 'notready') note('NOT-READY: a hand-in not finished yet (the card shows what it still needs)');
  else if (st.st !== 'todo') hard('CANT-DO: the step shown is "' + st.st + '"');
  if (st.dead) hard('DEAD-END: the step shown can never be done - ' + st.dead);
  const gray = lv - (lv < 6 ? lv : lv < 40 ? Math.floor(lv / 10) + 5 : Math.floor(lv / 5) + 1); // the game's gray line
  if (st.ql && st.ql > 0 && st.ql <= gray) hard(`GRAY: a level ${st.ql} quest at level ${lv} (no XP)`);
  else if (st.ql && st.ql > 0 && st.ql < lv - 5) note(`LOW: a level ${st.ql} quest at level ${lv}`);
  if (st.ql && st.ql > lv + 4) hard(`TOO-HIGH: a level ${st.ql} quest at level ${lv}`);
  if (st.min && st.min > lv) hard(`TOO-HIGH: needs level ${st.min}`);
  if (st.lvl && Math.abs(st.lvl - lv) > 3) note(`PLAN-LEVEL: the plan does this step at level ${st.lvl}, you are ${lv}`);
  const far = st.yd === -1 || st.yd > 1500;
  if (st.ins && far) hard('ADDED-FIRST: the step shown is a stop added at login, far away (' + st.k + ' ' + st.name + ' @' + st.zone + ')');
  else if (st.ins) note('ADDED-FIRST: the step shown is a stop added at login (' + st.k + ' ' + st.name + ')');
  if (st.yd === -1) note('OTHER-CONTINENT: the step is on another continent');
  else if (st.yd > 4000) note(`FAR: the step is ${st.yd} yd away`);
  if (far && r.cutHere && r.cutHere.n > 0) hard(`LEAVES-WORK: sends you away while ${r.cutHere.n} quests in your zone were passed as "behind you" though still worth XP (nearest: ${r.cutHere.name}, level ${r.cutHere.ql}, ${r.cutHere.yd} yd; the plan does it at ${r.cutHere.lvl})`);
  if (far && r.nearer && r.nearer.i !== st.i && r.nearer.yd < 600) note(`NEARER-WORK: step ${r.nearer.i} (${r.nearer.k} ${r.nearer.name}) is ${r.nearer.yd} yd away, ${r.inYourZone} doable steps in your zone among the next 60`);
  if (st.zone && c.at && st.m && ZONES[st.m] && ZONES[st.m] !== c.at && !c.travel && st.k !== 'hearth') note('NO-TRAVEL-LINE: another zone and no way there on the card');
  if (c.travel && /^ERROR/.test(c.travel)) hard('TRAVEL-ERROR: ' + c.travel);
  if (c.logFull) hard(`LOG-FULL: a pick-up is shown with the log full (${c.logFull})`);
  if (c.legZone && st.zone && st.k !== 'fly' && c.legZone !== st.zone) note(`LEG-HEADER: says ${c.legZone}, the step is in ${st.zone}`);
  const dead = (r.next || []).filter((d) => d.dead);
  if (dead.length >= 3) hard(`DEAD-ENDS: ${dead.length} of the next ${(r.next || []).length} steps can never be done as the route stands (e.g. #${dead[0].i} ${dead[0].k} ${dead[0].name}: ${dead[0].dead})`);
  const shown = r.cps.map((x) => x.step && x.step.i + ':' + x.step.name);
  const login = shown.slice(0, 4).filter((x, i, a) => i === 0 || x !== a[i - 1]);
  if (login.length > 1) note('FLICKER: the card changed during login: ' + login.join(' -> '));
  if (r.passedOver && r.passedOver.some((p) => p.st === 'todo')) note('JUMPED: shows a later step while step ' + r.passedOver.find((p) => p.st === 'todo').i + ' is still to do (live reordering)');
  for (const x of r.issues || []) hard('ERROR: ' + x.replace(/\s+/g, ' ').slice(0, 220));
  return f;
}
const stepLine = (d) => d ? `#${d.i} ${d.k} ${d.name}${d.npc && d.npc !== d.name ? ' (' + d.npc + ')' : ''} @${d.zone || '?'}` +
  ` [${d.st}${d.ql ? ', quest lvl ' + d.ql : ''}${d.lvl ? ', plan lvl ' + d.lvl : ''}${d.min ? ', needs ' + d.min : ''}${d.ins ? ', ADDED' : ''}${d.dead ? ', DEAD END' : ''}${d.yd === -1 ? ', other continent' : d.yd != null ? ', ' + d.yd + ' yd' : ''}]` : '(nothing)';

const picked = (args.scenarios ? JSON.parse(fs.readFileSync(path.resolve(args.scenarios), 'utf8')) : matrix())
  .filter((s) => !args.only || s.id.includes(args.only));
if (!picked.length) { console.log('no scenarios'); process.exit(2); }
const scns = picked.map(resolve);
const t0 = Date.now();
const results = run(scns);
console.log(`replay: ${who.name} (${who.race} ${who.class}) on ${starter ? 'built-in ' + path.basename(planPath) : path.basename(planPath)}, engine ${args.engine ? path.basename(args.engine) : 'as in the addon'}: ${results.length}/${scns.length} scenarios in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
let flagged = 0;
const all = [];
for (const s of scns) {
  const r = results.find((x) => x.id === s.id);
  if (!r || r.fatal) { console.log(`\n== ${s.id}: ${s.note}\n   NO RESULT${r ? ': ' + r.fatal : ''}`); flagged++; all.push({ id: s.id, note: s.note, flags: ['NO-RESULT'] }); continue; }
  const fl = flags(r, s);
  all.push({ id: s.id, note: s.note, flags: fl, result: r });
  if (fl.some((x) => x.startsWith('!!'))) flagged++; else if (args.quiet) continue;
  const c = r.cps[r.cps.length - 1] || {};
  console.log(`\n== ${s.id}: ${s.note}`);
  console.log(`   you: level ${r.level} in ${c.at}, ${r.logCount}/${r.maxLog} quests in the log, ${s.history.length} done, ${s.taxi.length} flight paths; ${r.plan}, ${r.total} steps`);
  for (const x of r.cps) console.log(`   ${(x.tag + ':').padEnd(34)} ${x.error ? 'ERROR ' + x.error : stepLine(x.step)}`);
  console.log(`   travel line: ${c.travel || '-'}`);
  console.log(`   leg header:  ${c.leg || '-'}`);
  if (c.ready) console.log(`   ready nearby line: ${c.ready}`);
  console.log(`   before it:   ${Object.entries(r.before || {}).sort((a, b) => b[1] - a[1]).map(([k, v]) => v + ' ' + k).join(', ') || '-'}`);
  if ((r.lastDone || []).length) console.log(`   just before: ${r.lastDone.map((d) => `#${d.i} ${d.k} ${d.name} (${d.why})`).join('; ')}`);
  for (const d of r.passedOver || []) console.log(`   passed over: ${stepLine(d)}`);
  console.log(`   added stops: ${(r.inserted || []).length ? '' : '-'}`);
  for (const d of r.inserted || []) console.log(`      ${stepLine(d)}  between [${d.after}] and [${d.before}]`);
  console.log(`   next ${NEXT}:`);
  for (const d of r.next || []) console.log(`      ${stepLine(d)}`);
  if (r.nearer) console.log(`   nearest doable step: ${stepLine(r.nearer)}; ${r.inYourZone} in your zone among the next 60`);
  for (const w of (r.whys || []).slice(0, 12)) console.log(`   why: ${w.slice(0, 230)}`);
  console.log(fl.length ? fl.map((x) => '   ' + x).join('\n') : '   ok: nothing flagged');
}
console.log(`\n${flagged} of ${scns.length} scenarios with something wrong (!!)`);
if (args.json) fs.writeFileSync(path.resolve(args.json), JSON.stringify({ who, plan: planPath, engine: args.engine || null, scenarios: all }, null, 1));
process.exitCode = !results.length ? 1 : (args.strict && flagged) ? 3 : 0;
