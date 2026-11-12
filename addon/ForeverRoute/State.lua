-- Live character state: completed quests, quests in the log (queried by ID, so collapsed log headers don't hide them),
-- objective progress, position, flight paths. Writes a snapshot for the PC planner on logout / reload / turn-ins.
local _, ns = ...
local State = {}
ns.State = State

State.completed = {}   -- [questID] = true
State.knownTaxi = {}   -- [nodeName] = true
local cache = {}       -- [questID] = { on, complete, objectives } until the next log change

local function call(fn, ...) if type(fn) == "function" then local ok, a, b, c, d = pcall(fn, ...); if ok then return a, b, c, d end end end

function State.IsCompleted(id)
  if not id then return false end
  if State.completed[id] then return true end
  local done = C_QuestLog and call(C_QuestLog.IsQuestFlaggedCompleted, id)
  if done == nil and IsQuestFlaggedCompleted then done = call(IsQuestFlaggedCompleted, id) end
  if done then State.completed[id] = true end
  return done and true or false
end

-- per-quest live info, by quest ID
function State.Quest(id)
  if not id then return nil end
  local c = cache[id]
  if c then return c end
  local on = C_QuestLog and C_QuestLog.IsOnQuest and call(C_QuestLog.IsOnQuest, id)
  if on == nil and C_QuestLog and C_QuestLog.GetLogIndexForQuestID then on = call(C_QuestLog.GetLogIndexForQuestID, id) ~= nil end
  c = { on = on and true or false, objectives = {} }
  if c.on then
    local objs = C_QuestLog and call(C_QuestLog.GetQuestObjectives, id)
    if type(objs) == "table" then
      for i, o in ipairs(objs) do c.objectives[i] = { text = o.text or "", finished = o.finished, have = o.numFulfilled or 0, need = o.numRequired or 0 } end
    end
    local complete = C_QuestLog and C_QuestLog.IsComplete and call(C_QuestLog.IsComplete, id)
    if complete == nil then complete = #c.objectives > 0; for _, o in ipairs(c.objectives) do if not o.finished then complete = false end end end
    c.complete = complete and true or false
    c.noObjectives = #c.objectives == 0
  end
  cache[id] = c
  return c
end
function State.OnQuest(id) local q = State.Quest(id); return q and q.on end
function State.QuestReady(id) local q = State.Quest(id); return q and q.on and (q.complete or q.noObjectives) end

function State.LogCount()
  local n = 0
  local fn = (C_QuestLog and C_QuestLog.GetNumQuestLogEntries) or GetNumQuestLogEntries
  local entries, quests = call(fn)
  if quests then return quests end
  entries = entries or 0
  for i = 1, entries do
    local info = C_QuestLog and C_QuestLog.GetInfo and call(C_QuestLog.GetInfo, i)
    if info and not info.isHeader then n = n + 1 end
  end
  return n
end
-- is the quest log full? Asked for every pick-up on every refresh: read at most once a second, and again as soon as
-- the log changes (QUEST_LOG_UPDATE)
local fullAt, fullWas = -100, false
function State.LogFull()
  local now = GetTime and GetTime() or 0
  if now - fullAt < 1 then return fullWas end
  fullAt, fullWas = now, State.LogCount() >= State.MaxLog()
  return fullWas
end
ns.On("QUEST_LOG_UPDATE", function() fullAt = -100 end)
function State.MaxLog() return C_QuestLog and C_QuestLog.GetMaxNumQuestsCanAccept and call(C_QuestLog.GetMaxNumQuestsCanAccept) or MAX_QUESTLOG_QUESTS or 40 end -- Forever: 40

function State.RefreshCompleted()
  local list = C_QuestLog and call(C_QuestLog.GetAllCompletedQuestIDs)
  if type(list) == "table" then
    for _, id in ipairs(list) do State.completed[id] = true end
  elseif GetQuestsCompleted then
    local t = {}; call(GetQuestsCompleted, t)
    for id in pairs(t) do State.completed[id] = true end
  end
end

-- visible quest log rows (for the snapshot); route quests are added by ID
local function logIDs()
  local ids = {}
  local n = C_QuestLog and C_QuestLog.GetNumQuestLogEntries and call(C_QuestLog.GetNumQuestLogEntries) or (GetNumQuestLogEntries and call(GetNumQuestLogEntries)) or 0
  for i = 1, n do
    local id, hdr
    if C_QuestLog and C_QuestLog.GetInfo then local info = call(C_QuestLog.GetInfo, i); if info then id, hdr = info.questID, info.isHeader end
    elseif GetQuestLogTitle then local _, _, _, h, _, _, _, q = GetQuestLogTitle(i); id, hdr = q, h end
    if id and id > 0 and not hdr then ids[id] = true end
  end
  for _, s in ipairs(ForeverRouteData and ForeverRouteData.steps or {}) do if s.q and State.OnQuest(s.q) then ids[s.q] = true end end
  return ids
end
State.LogIDs = logIDs
-- every quest seen in your log, kept (ns.char.hadQuest): one that is gone from it and not completed was abandoned.
-- The quest log check needs that to say whose items are left over (UI/LogCheck.lua)
function State.NoteLog()
  if not ns.char then return end
  ns.char.hadQuest = ns.char.hadQuest or {}
  for id in pairs(logIDs()) do ns.char.hadQuest[id] = true end
end
ns.On("FR_STATE", function() pcall(State.NoteLog) end)
-- what is in your bags: [itemID] = how many (the backpack and your bags, not the bank). nil when the game won't say
function State.BagItems()
  local C = type(C_Container) == "table" and C_Container or nil
  local slots = (C and C.GetContainerNumSlots) or GetContainerNumSlots
  local idAt = (C and C.GetContainerItemID) or GetContainerItemID
  if not (slots and idAt) then return nil end
  local out = {}
  for bag = 0, NUM_BAG_SLOTS or 4 do
    local n = call(slots, bag)
    for slot = 1, type(n) == "number" and n or 0 do
      local id = call(idAt, bag, slot)
      if type(id) == "number" and id > 0 then
        local count = 1
        local info = C and C.GetContainerItemInfo and call(C.GetContainerItemInfo, bag, slot)
        if type(info) == "table" and type(info.stackCount) == "number" and info.stackCount > 0 then count = info.stackCount end
        out[id] = (out[id] or 0) + count
      end
    end
  end
  return out
end

function State.Position()
  local HBD = LibStub("HereBeDragons-2.0", true)
  if HBD then local x, y, mapID = HBD:GetPlayerZonePosition(); if x then return mapID, x, y end end
  local mapID = C_Map.GetBestMapForUnit("player")
  local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
  if pos then return mapID, pos.x, pos.y end
end

-- your skills: name -> { rank, maxRank } (Skinning 127 of 150). Forever's client has them in C_SkillInfo, each line a
-- table (name, rank, maxRank, isHeader); the old GetSkillLineInfo returned a list of values instead. Without this the
-- save's skills were always empty on Forever.
function State.Skills()
  local skills = {}
  local C = type(C_SkillInfo) == "table" and C_SkillInfo
  if C and type(C.GetNumSkillLines) == "function" and type(C.GetSkillLineInfo) == "function" then
    for i = 1, (call(C.GetNumSkillLines) or 0) do
      local s = call(C.GetSkillLineInfo, i)
      if type(s) == "table" and s.name and not s.isHeader then skills[s.name] = { s.rank or 0, s.maxRank or 0 } end
    end
  elseif GetNumSkillLines and GetSkillLineInfo then
    for i = 1, (call(GetNumSkillLines) or 0) do
      local ok, name, isHeader, _, rank, _, _, maxRank = pcall(GetSkillLineInfo, i) -- 7 values: not call() (keeps 4)
      if ok and name and not isHeader then skills[name] = { rank, maxRank } end
    end
  end
  return skills
end

-- "Ride to" only once you can ride: before that, every trip on foot reads "Run to" ("ride to xxx when we don't have a
-- mount"). A riding skill of any kind (Riding, Horse Riding, the warlock's and paladin's mounts teach one) counts.
-- Read at most every 10 s: the card asks on every refresh.
local rideAt, rideCan = -100, false
function State.CanRide()
  local now = GetTime and GetTime() or 0
  if now - rideAt < 10 then return rideCan end
  rideAt, rideCan = now, false
  for name in pairs(State.Skills()) do if type(name) == "string" and name:find("Riding", 1, true) then rideCan = true; break end end
  return rideCan
end
-- "Ride" or "Run", and the card's travel kind follows
function ns.RideWord()
  local w = State.CanRide() and "Ride" or "Run"
  if ns.Style and ns.Style.KIND and ns.Style.KIND.ride then ns.Style.KIND.ride.verb = w .. " to" end
  return w
end

function State.Snapshot(reason)
  -- At logout the game may already have unloaded quest progress, gear, skills and money while the quest log still
  -- lists its rows. Such a read would tell the planner every finished quest is untouched; where a value reads empty
  -- but the previous snapshot had it, the previous value is kept (quests don't lose their objectives, you don't
  -- take off every item at once).
  local prev = ns.char.snapshot or {}
  local kept = {}
  local ids = {}
  for id in pairs(State.completed) do ids[#ids + 1] = id end
  table.sort(ids)
  local log = {}
  for id in pairs(logIDs()) do
    local q = State.Quest(id)
    local was = type(prev.log) == "table" and prev.log[id]
    -- listed in the log but "not on it", or no objectives where it had some: a torn-down read
    if was and (not q.on or (#q.objectives == 0 and type(was.objectives) == "table" and #was.objectives > 0)) then
      log[id] = was; kept.quests = (kept.quests or 0) + 1
    else
      local objs = {}
      for i, o in ipairs(q.objectives) do objs[i] = { o.have, o.need, o.finished and true or false, o.text } end
      log[id] = { complete = q.complete, objectives = objs }
    end
  end
  local mapID, x, y = State.Position()
  local skills = State.Skills()
  local gear = {}
  for slot = 1, 19 do local link = GetInventoryItemLink("player", slot); if link then gear[slot] = tonumber(link:match("item:(%d+)")) end end
  local taxi = {}
  for name in pairs(State.knownTaxi) do taxi[#taxi + 1] = name end
  table.sort(taxi)
  local function filled(t) return type(t) == "table" and next(t) ~= nil end
  if not filled(gear) and filled(prev.gear) then gear = prev.gear; kept.gear = true end
  if not filled(skills) and filled(prev.skills) then skills = prev.skills; kept.skills = true end
  -- money and position only when the read is clearly torn down (an empty purse alone can be real)
  local money, pos = GetMoney(), mapID and { map = mapID, x = x, y = y } or nil
  if kept.gear or kept.skills then
    if money == 0 and (prev.money or 0) > 0 then money = prev.money; kept.money = true end
    if not pos and prev.pos then pos = prev.pos; kept.pos = true end
  end
  if next(kept) and ns.Why then
    local what = {}
    if kept.quests then what[#what + 1] = kept.quests .. " quest" .. (kept.quests == 1 and "" or "s") end
    for _, k in ipairs({ "gear", "skills", "money", "pos" }) do if kept[k] then what[#what + 1] = k end end
    ns.Why("snapshot", reason .. ": the game returned nothing for " .. table.concat(what, ", ") .. "; kept the last good values")
  end
  local _, class = UnitClass("player")
  local _, race = UnitRace("player")
  ns.char.snapshot = {
    reason = reason, time = time(), version = 1,
    name = UnitName("player"), realm = GetRealmName(), faction = UnitFactionGroup("player"),
    class = class, race = race,
    level = (UnitXPMax("player") or 0) > 0 and UnitLevel("player") or (ns.char.snapshot and ns.char.snapshot.level) or UnitLevel("player"),
    xp = (UnitXPMax("player") or 0) > 0 and UnitXP("player") or (ns.char.snapshot and ns.char.snapshot.xp) or 0,
    xpMax = (UnitXPMax("player") or 0) > 0 and UnitXPMax("player") or (ns.char.snapshot and ns.char.snapshot.xpMax) or 0,
    money = money, bind = GetBindLocation and GetBindLocation() or nil,
    pos = pos,
    completed = ids, log = log, taxi = taxi, skills = skills, gear = gear,
    routeId = ForeverRouteData and ForeverRouteData.id, routeStep = ns.Engine and ns.Engine.current or nil,
    hearthCd = ns.HearthCooldown(),
  }
end

-- seconds left on the hearthstone (6948); nil if the game won't say (secret values make the maths error)
function ns.HearthCooldown()
  local get = (C_Container and C_Container.GetItemCooldown) or GetItemCooldown
  if not get then return nil end
  local ok, left = pcall(function()
    local start, dur = get(6948)
    if not start or start == 0 or not dur or dur == 0 then return 0 end
    return math.max(0, math.floor(start + dur - GetTime()))
  end)
  return ok and left or nil
end

ns.On("TAXIMAP_OPENED", function()
  if not NumTaxiNodes then return end
  for i = 1, NumTaxiNodes() do
    local name, kind = TaxiNodeName(i), TaxiNodeGetType and TaxiNodeGetType(i)
    if name and (kind == "REACHABLE" or kind == "CURRENT") then State.knownTaxi[name] = true end
  end
  ns.char.knownTaxi = State.knownTaxi
  ns.Fire("FR_TAXI_OPENED")
  ns.Fire("FR_STATE")
end)

-- The flight paths you know without opening a flight master's map: the world map's own flight points
-- (C_TaxiMap.GetTaxiNodesForMap, every node of a map with isUndiscovered) - a level 32 trying the addon for the first
-- time already knows a dozen, and until a flight map was opened the plan walked them everywhere.
-- A client that marks nothing undiscovered among many nodes is not telling: nothing is taken from it then.
State.TAXI_SCAN_MAPS = { 1414, 1415 } -- Kalimdor, the Eastern Kingdoms; the zones of FlightMasters.lua and TravelData join them
function State.ScanTaxi()
  if not (C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap) then return 0 end
  local okF, fac = pcall(UnitFactionGroup, "player")
  local mine = Enum and Enum.FlightPathFaction and (okF and fac == "Horde" and Enum.FlightPathFaction.Horde or Enum.FlightPathFaction.Alliance)
  local neutral = Enum and Enum.FlightPathFaction and Enum.FlightPathFaction.Neutral or 0
  local maps, seen = {}, {}
  local function add(m) if m and not seen[m] then seen[m] = true; maps[#maps + 1] = m end end
  for _, m in ipairs(State.TAXI_SCAN_MAPS) do add(m) end
  for _, side in pairs(ns.FLIGHT_BY or {}) do for m in pairs(side) do add(m) end end
  for m in pairs((ns.TravelData and ns.TravelData.BOUNDS) or {}) do add(m) end
  local found, total, undiscovered = {}, 0, 0
  for _, m in ipairs(maps) do
    local ok, nodes = pcall(C_TaxiMap.GetTaxiNodesForMap, m)
    for _, n in ipairs(ok and type(nodes) == "table" and nodes or {}) do
      if n.name and (n.faction == mine or n.faction == neutral) then
        total = total + 1
        if n.isUndiscovered then undiscovered = undiscovered + 1 else found[n.name] = true end
      end
    end
  end
  if total >= 10 and undiscovered == 0 then
    if ns.Why then ns.Why("taxi", "world map lists " .. total .. " flight points, none undiscovered: not trusted (open a flight master's map)") end
    return 0
  end
  local added = 0
  for name in pairs(found) do if not State.knownTaxi[name] then State.knownTaxi[name] = true; added = added + 1 end end
  ns.char.knownTaxi = State.knownTaxi
  if added > 0 then
    if ns.Why then ns.Why("taxi", added .. " flight path(s) you know, from the world map") end
    ns.Fire("FR_STATE")
  end
  return added
end

local pending
local function refreshSoon()
  wipe(cache)
  if pending then return end
  pending = true
  C_Timer.After(0.15, function() pending = false; wipe(cache); ns.Fire("FR_STATE") end)
end
State.Invalidate = refreshSoon

ns.On("FR_LOADED", function() State.knownTaxi = ns.char.knownTaxi or {}; C_Timer.After(3, ns.Guard("taxi", State.ScanTaxi)) end)
ns.On("TAXI_NODE_STATUS_CHANGED", function() C_Timer.After(0.5, ns.Guard("taxi", State.ScanTaxi)) end)
ns.On("PLAYER_LOGIN", function() State.RefreshCompleted(); refreshSoon(); C_Timer.After(8, function() State.Snapshot("login") end); C_Timer.NewTicker(300, function() State.Snapshot("periodic") end) end)
ns.On("QUEST_LOG_UPDATE", refreshSoon)
ns.On("UNIT_QUEST_LOG_CHANGED", function(unit) if unit == "player" then refreshSoon() end end)
ns.On("QUEST_ACCEPTED", refreshSoon)
ns.On("QUEST_REMOVED", refreshSoon)
ns.On("QUEST_TURNED_IN", function(id)
  if id then State.completed[id] = true end
  refreshSoon()
  C_Timer.After(0.5, function() State.Snapshot("turnin") end)
end)
ns.On("PLAYER_LEVEL_UP", function() refreshSoon(); C_Timer.After(1, function() State.Snapshot("levelup") end) end)
ns.On("PLAYER_XP_UPDATE", function() ns.Fire("FR_XP") end)
ns.On("BAG_UPDATE_DELAYED", function() local i = ns.Engine and ns.Engine.current; local s = i and ForeverRouteData and ForeverRouteData.steps[i]; if s and s.k == "bonus" then ns.Fire("FR_STATE") end end)
-- the cache is kept here: it holds the last live reads, and asking the game again during logout can return nothing
-- (memory only at logout: timing ten route rebuilds there ran past the game's script limit on long plans - "State.lua:25:
-- script ran too long" at PLAYER_LOGOUT in a tester's report - and the snapshot after it never got written)
ns.On("PLAYER_LOGOUT", function() State.Snapshot("logout"); pcall(ns.Perf, true) end)
