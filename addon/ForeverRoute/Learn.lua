-- Learning from your play, so the planner gets better without anyone having to report anything. Three records, kept in
-- ForeverRouteDB.learn (account SavedVariables; the companion reads them on every replan - tools/learn.js):
--   killxp    the XP each kill really gave (rested bonus taken out), by your level and the mob's level - the planner
--             corrects its Classic formula with it (Forever gives less for low-level mobs, by how much is what we learn)
--   pace      how long kill and collect steps really took you (only steady work: no long breaks, no flights) - the
--             planner's minutes-per-kill follow it
--   incidents moments that suggest the route was wrong: a step you ticked or skipped by hand, the card landing on
--             another step after a reload, the arrow pointing at a different step than the card. Each with the context
--             to replay it; the companion turns new ones into tests and a report
-- Everything is pcall-guarded and skips Forever's secret values: learning must never break the game.
local _, ns = ...
local Learn = {}
ns.Learn = Learn

Learn.MAX_PACE, Learn.MAX_INCIDENTS = 300, 100

local function store()
  ForeverRouteDB.learn = type(ForeverRouteDB.learn) == "table" and ForeverRouteDB.learn or {}
  local L = ForeverRouteDB.learn
  L.killxp = type(L.killxp) == "table" and L.killxp or {}
  L.pace = type(L.pace) == "table" and L.pace or {}
  L.incidents = type(L.incidents) == "table" and L.incidents or {}
  return L
end
local function plain(v) return v ~= nil and not (issecretvalue and issecretvalue(v)) end
-- (only with the companion: it is the only reader - ns.HasCompanion)
local function guard(fn) return function(...) if not ns.HasCompanion() then return end; local ok, err = pcall(fn, ...); if not ok and ns.LogError then pcall(ns.LogError, "learn", err) end end end

-- ---------- XP per kill ----------
-- mob levels by name, from what you target, mouse over or see on nameplates (the XP message only names the mob)
local levelOf = {}
local function noteUnit(unit)
  local okN, name = pcall(UnitName, unit)
  local okL, lvl = pcall(UnitLevel, unit)
  if okN and okL and plain(name) and plain(lvl) and type(name) == "string" and type(lvl) == "number" and lvl > 0 then levelOf[name] = lvl end
end
-- "Wolf dies, you gain 120 experience. (+60 exp Rested bonus)" in this client's language
local function patterns()
  local function toPattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)"):gsub("%%%%d", "(%%d+)")
    return "^" .. p
  end
  return toPattern(COMBATLOG_XPGAIN_FIRSTPERSON or "%s dies, you gain %d experience."),
    toPattern(COMBATLOG_XPGAIN_EXHAUSTION1 or "%s dies, you gain %d experience. (%s exp %s bonus)")
end
function Learn.ParseXp(msg)
  if not (plain(msg) and type(msg) == "string") then return nil end
  local plainP, restedP = patterns()
  local name, xp = msg:match(plainP or "^(.+) dies, you gain (%d+) experience")
  if not name then return nil end
  local bonus = tonumber(msg:match("%(%+(%d+) exp") or "0") or 0 -- the rested part is not the kill's own XP
  return name, (tonumber(xp) or 0) - bonus
end
function Learn.RecordKill(name, xp, playerLevel)
  local ml = levelOf[name]
  if not (ml and xp and xp > 0 and playerLevel) then return false end
  local K = store().killxp
  local row = K[playerLevel] or {}; K[playerLevel] = row
  local c = row[ml] or { n = 0, xp = 0 }; row[ml] = c
  c.n, c.xp = c.n + 1, c.xp + xp
  return true
end

-- ---------- pace ----------
local started -- { key, t, k } for the step on the card
local function stepAt(i) local d = ForeverRouteData; return d and d.steps and d.steps[i] end
function Learn.StepShown(i)
  local s = stepAt(i)
  started = s and { key = ns.Engine.Key and ns.Engine.Key(i), t = GetTime(), k = s.k, text = s.text, q = s.q } or nil
end
function Learn.StepDone(i)
  local s = stepAt(i)
  if not (s and started and s.k == "obj" and started.key == (ns.Engine.Key and ns.Engine.Key(i))) then return false end
  local sec = GetTime() - started.t
  local need = tonumber((s.text or ""):match("^%a+ (%d+)")) -- "Kill 10 Wolf", "Collect 8 Fang"
  -- steady work only: a step that took over 45 min had a break in it; under 20 s it was done before it was shown
  if not need or sec < 20 or sec > 45 * 60 then return false end
  local P = store().pace
  P[#P + 1] = { k = s.text:match("^(%a+)"), need = need, sec = math.floor(sec), lvl = UnitLevel("player"), q = s.q, rate = s.rate }
  while #P > Learn.MAX_PACE do table.remove(P, 1) end
  return true
end

-- pace from the quest log itself, not the card: every time an objective's count goes up ("Wolf slain: 3/8"), the time
-- since its last increase is a sample (breaks over PACE_GAP seconds, flights and AFK left out). The card's step changes
-- too often (live reordering, nearby steps) to time kills by it - that recorded 2 samples in many hours of play.
-- Samples go in the pace list as { k = "Kill" | "Collect", need = how many came, sec } (tools/learn.js reads them).
Learn.PACE_GAP = 300
local lastHave, lastAt = {}, {}
function Learn.ProgressTick(now)
  now = now or GetTime()
  if ns.Is(UnitIsAFK, "player") or ns.Is(UnitOnTaxi, "player") then return end
  local ids = ns.State.LogIDs and ns.State.LogIDs() or {}
  local P = store().pace
  for id in pairs(ids) do
    local q = ns.State.Quest(id)
    for i, o in ipairs((q and q.objectives) or {}) do
      local k = id .. ":" .. i
      local have = tonumber(o.have) or 0
      local before = lastHave[k]
      if before and have > before and lastAt[k] then
        local sec = now - lastAt[k]
        if sec > 0 and sec <= Learn.PACE_GAP then
          P[#P + 1] = { k = tostring(o.text):find("slain") and "Kill" or "Collect", need = have - before, sec = math.floor(sec + 0.5), lvl = UnitLevel("player"), q = id, src = "log" }
          while #P > Learn.MAX_PACE do table.remove(P, 1) end
        end
      end
      if before == nil or have ~= before then lastAt[k] = now end
      lastHave[k] = have
    end
  end
end
ns.On("FR_STATE", guard(function() Learn.ProgressTick() end))

-- ---------- time per zone ----------
-- how long you really spend in each zone (not on flights, not away) and how many steps you finish there: the report
-- compares it with the plan's estimate for that zone
Learn.TICK = 30
local zoneAcc = { t = nil, m = nil }
function Learn.ZoneTick(now)
  now = now or GetTime()
  local Z = store()
  Z.zones = type(Z.zones) == "table" and Z.zones or {}
  local m = ns.State.Position()
  local away = ns.Is(UnitIsAFK, "player") or ns.Is(UnitOnTaxi, "player")
  if zoneAcc.t and zoneAcc.m and m == zoneAcc.m and not away then
    local dt = now - zoneAcc.t
    if dt > 0 and dt <= Learn.TICK * 3 then -- a longer gap was a loading screen or a pause
      local z = Z.zones[m] or { sec = 0, steps = 0, lvlFrom = UnitLevel("player") }
      Z.zones[m] = z
      z.sec = z.sec + math.floor(dt); z.lvlTo = UnitLevel("player")
    end
  end
  zoneAcc.t, zoneAcc.m = now, m
end
function Learn.ZoneStepDone()
  local m = ns.State.Position()
  local Z = store()
  Z.zones = type(Z.zones) == "table" and Z.zones or {}
  if not m then return end
  local z = Z.zones[m] or { sec = 0, steps = 0, lvlFrom = UnitLevel("player") }
  Z.zones[m] = z
  z.steps = (z.steps or 0) + 1
end

-- ---------- fun quest rewards ----------
-- which quest rewards are fun (toys, transforms...): the quest data only says which quests give an item, the game knows
-- what it does. A few candidates (FunCandidates.lua) a second, in the background, once each: is it a toy, what does its
-- "Use:" line say. Kept in ForeverRouteDB.learn.items[itemID] = { name, toy, use }; the companion makes the fun ones worth
-- a detour.
Learn.ITEMS_PER_TICK = 4
function Learn.ScanItem(id)
  local L = store(); L.items = type(L.items) == "table" and L.items or {}
  if L.items[id] then return true end
  local Cit = C_Item or {}
  if Cit.RequestLoadItemDataByID then pcall(Cit.RequestLoadItemDataByID, id) end
  local tip = C_TooltipInfo and C_TooltipInfo.GetItemByID and select(2, pcall(C_TooltipInfo.GetItemByID, id))
  if type(tip) ~= "table" or not tip.lines or not tip.lines[1] then return false end -- not loaded yet: next round
  local name = tip.lines[1].leftText
  local use
  for _, line in ipairs(tip.lines) do
    local t = line.leftText
    if plain(t) and type(t) == "string" and t:find("^Use:") then use = t; break end
  end
  local toy = false
  if C_ToyBox and C_ToyBox.GetToyInfo then local ok, tid = pcall(C_ToyBox.GetToyInfo, id); toy = ok and tid ~= nil end
  L.items[id] = { name = plain(name) and name or nil, toy = toy or nil, use = use }
  return true
end
local scanQueue
function Learn.ScanTick()
  if not ns.FUN_CANDIDATES then return end
  if not scanQueue then
    scanQueue = {}
    local L = store(); L.items = type(L.items) == "table" and L.items or {}
    for id in pairs(ns.FUN_CANDIDATES) do if not L.items[id] then scanQueue[#scanQueue + 1] = { id = id, tries = 0 } end end
  end
  for _ = 1, Learn.ITEMS_PER_TICK do
    local e = table.remove(scanQueue, 1)
    if not e then return end
    if not Learn.ScanItem(e.id) then e.tries = e.tries + 1; if e.tries < 5 then scanQueue[#scanQueue + 1] = e end end
  end
end
ns.On("FR_LOADED", guard(function() C_Timer.After(20, function() C_Timer.NewTicker(1, guard(function() Learn.ScanTick() end)) end) end))

-- ---------- incidents ----------
function Learn.Incident(kind, i, extra)
  local s = i and stepAt(i)
  local m, x, y = ns.State.Position()
  local I = store().incidents
  local e = { kind = kind, t = time(), route = ForeverRouteData and ForeverRouteData.id, step = i, key = i and ns.Engine.Key and ns.Engine.Key(i),
    what = s and ((s.k or "") .. " " .. (s.name or s.text or s.dest or "")), lvl = UnitLevel("player"), m = m, x = x and math.floor(x * 1000) / 1000, y = y and math.floor(y * 1000) / 1000 }
  for k, v in pairs(extra or {}) do e[k] = v end
  -- the same thing again within a few seconds is one incident (the game can fire PLAYER_DEAD twice for one death)
  local p = I[#I]
  if p and p.kind == e.kind and p.step == e.step and math.abs((p.t or 0) - e.t) <= 5 then return p end
  I[#I + 1] = e
  while #I > Learn.MAX_INCIDENTS do table.remove(I, 1) end
  if ns.Why then ns.Why("incident", kind .. ": " .. tostring(e.what)) end
  return e
end

-- ---------- wiring ----------
local function hook()
  -- manual ticks and skips: the route thought otherwise
  local markDone, skip = ns.Engine.MarkDone, ns.Engine.Skip
  ns.Engine.MarkDone = function(i, ...) pcall(Learn.Incident, "ticked by hand", i or ns.Engine.Shown()); return markDone(i, ...) end
  ns.Engine.Skip = function(i, ...) pcall(Learn.Incident, "skipped", i or ns.Engine.Shown()); return skip(i, ...) end
end
ns.On("FR_LOADED", guard(function()
  store()
  hook()
  -- after a reload the card should land where you left it (unless that step got done meanwhile)
  C_Timer.After(6, guard(function()
    local was, i = ns.char.lastShown, ns.Engine.Shown()
    local now = i and ns.Engine.Key(i)
    if was and now and was.key ~= now and was.route == (ForeverRouteData and ForeverRouteData.id) then
      local wasI
      for j = 1, #(ForeverRouteData.steps or {}) do if ns.Engine.Key(j) == was.key then wasI = j; break end end
      if wasI and ns.Engine.Status(wasI) ~= "done" then Learn.Incident("moved after reload", i, { from = was.key }) end
    end
  end))
end))
ns.On("FR_STEP", guard(function(i)
  Learn.StepShown(i)
  if i and ForeverRouteData then ns.char.lastShown = { key = ns.Engine.Key(i), route = ForeverRouteData.id } end
  -- the arrow follows the card (checked a moment later, once it has re-targeted)
  C_Timer.After(1, guard(function()
    local t, shown = ns.Arrow and ns.Arrow.Current and ns.Arrow.Current(), ns.Engine.Shown()
    if t and shown and t.index ~= shown and not ns.Is(UnitOnTaxi, "player") then Learn.Incident("arrow on another step", shown, { arrow = t.index }) end
  end))
end))
ns.On("FR_STEP_DONE", guard(function(i) Learn.StepDone(i); Learn.ZoneStepDone() end))
-- a death on the route usually means a zone, mob or road too far above you: where, and on which step
-- (in a dungeon the death is the dungeon's, not the step on the card's: it's kept with the dungeon's name instead)
function Learn.Died()
  if ns.Is(IsInInstance) then
    local name = GetInstanceInfo and GetInstanceInfo()
    return Learn.Incident("died", nil, { dungeon = type(name) == "string" and not (issecretvalue and issecretvalue(name)) and name or "a dungeon" })
  end
  return Learn.Incident("died", ns.Engine.Shown())
end
ns.On("PLAYER_DEAD", guard(function() Learn.Died() end))
-- a step on the card for over STUCK minutes of play (a rare drop, an objective that is hard to find, a confusing step)
Learn.STUCK = 25 * 60
function Learn.CheckStuck(now)
  now = now or GetTime()
  if not started or started.reported or ns.Is(UnitIsAFK, "player") or ns.Is(UnitOnTaxi, "player") then return false end
  if now - started.t < Learn.STUCK then return false end
  started.reported = true
  local i = ns.Engine.Shown()
  Learn.Incident("stuck on a step", i, { minutes = math.floor((now - started.t) / 60) })
  return true
end
ns.On("FR_LOADED", guard(function() C_Timer.NewTicker(60, guard(function() Learn.CheckStuck() end)) end))
ns.On("FR_LOADED", guard(function() C_Timer.NewTicker(Learn.TICK, guard(function() Learn.ZoneTick() end)) end))
ns.On("PLAYER_TARGET_CHANGED", guard(function() noteUnit("target") end))
ns.On("UPDATE_MOUSEOVER_UNIT", guard(function() noteUnit("mouseover") end))
ns.On("NAME_PLATE_UNIT_ADDED", guard(function(unit) if unit then noteUnit(unit) end end))
ns.On("CHAT_MSG_COMBAT_XP_GAIN", guard(function(msg)
  local name, xp = Learn.ParseXp(msg)
  if name then Learn.RecordKill(name, xp, UnitLevel("player")) end
end))
Learn._levelOf = levelOf -- tests
