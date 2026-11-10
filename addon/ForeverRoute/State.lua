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

function State.Position()
  local HBD = LibStub("HereBeDragons-2.0", true)
  if HBD then local x, y, mapID = HBD:GetPlayerZonePosition(); if x then return mapID, x, y end end
  local mapID = C_Map.GetBestMapForUnit("player")
  local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
  if pos then return mapID, pos.x, pos.y end
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
  local skills = {}
  if GetNumSkillLines then
    for i = 1, (call(GetNumSkillLines) or 0) do
      local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
      if name and not isHeader then skills[name] = { rank, maxRank } end
    end
  end
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

local pending
local function refreshSoon()
  wipe(cache)
  if pending then return end
  pending = true
  C_Timer.After(0.15, function() pending = false; wipe(cache); ns.Fire("FR_STATE") end)
end
State.Invalidate = refreshSoon

ns.On("FR_LOADED", function() State.knownTaxi = ns.char.knownTaxi or {} end)
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
ns.On("PLAYER_LOGOUT", function() pcall(ns.Perf); State.Snapshot("logout") end)
