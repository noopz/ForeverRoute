-- Inside a dungeon. The game gives no coordinates in there (no map position, no world position), and the map it names
-- is the zone around the entrance (City of Dalaran reads as Alterac Mountains), so a plan step has nothing to point
-- at. What it does give is the instance's map id - UnitPosition's 4th value, GetInstanceInfo's 8th - and the quest log
-- keeps counting. So: which dungeon this is (ns.DUNGEONS, by that id), and what your quest log has for it
-- (ns.DUNGEON_QUESTS, DungeonQuests.lua - made from QuestieDB by tools/dungeon-quests.js). The card shows that while
-- you're inside (UI/Card.lua); the engine's "Run <dungeon>" steps ask here too (Engine.InDungeon).
local _, ns = ...
local Dungeon = {}
ns.Dungeon = Dungeon

local function plain(v) return v ~= nil and not (issecretvalue and issecretvalue(v)) end
local function norm(x) return (tostring(x or ""):lower():gsub("^the ", "")) end

-- the instance map you are on (0 and 1 are the continents), or nil when the game doesn't say
function Dungeon.InstanceId()
  if UnitPosition then
    local ok, _, _, _, id = pcall(UnitPosition, "player")
    if ok and plain(id) and type(id) == "number" then return id end
  end
  if GetInstanceInfo then
    local ok, _, _, _, _, _, _, _, id = pcall(GetInstanceInfo)
    if ok and plain(id) and type(id) == "number" then return id end
  end
end

-- the dungeon you are in: its name, and its id when it is one of ns.DUNGEONS. nil out in the world.
--   by the instance map id first (a number the game gives in there, whatever it hides);
--   else the game's own word (IsInInstance, through ns.Is: a hidden answer counts as no) and the instance's name -
--   matched to a dungeon we know, or passed on as it is (a dungeon not in the table: name only, no id)
function Dungeon.Here()
  local names = ns.DUNGEONS or {}
  local id = Dungeon.InstanceId()
  if id and names[id] then return names[id], id end
  if not (IsInInstance and GetInstanceInfo and ns.Is(IsInInstance)) then return nil end
  local ok, name = pcall(GetInstanceInfo)
  if not (ok and plain(name) and type(name) == "string" and name ~= "") then return nil end
  local n = norm(name)
  for mid, dn in pairs(names) do if norm(dn) == n then return dn, mid end end
  return name, nil
end
-- inside a dungeon the card has quests for (the card's dungeon state, no arrow, no pins): name, id
function Dungeon.Inside()
  local name, id = Dungeon.Here()
  if id and ns.DUNGEON_QUESTS and ns.DUNGEON_QUESTS[id] then return name, id end
end

-- a dungeon's quest ids, as a list (the data keeps them as one string: nothing to build until you walk in)
local function idsOf(id)
  local d = ns.DUNGEON_QUESTS and ns.DUNGEON_QUESTS[id]
  if not d then return {} end
  if not d.list then
    d.list = {}
    for q in tostring(d.ids or ""):gmatch("%d+") do d.list[#d.list + 1] = tonumber(q) end
  end
  return d.list
end
-- the dungeon (id) a quest is done in, or nil
local questIndex
function Dungeon.OfQuest(q)
  if not questIndex then
    questIndex = {}
    for id in pairs(ns.DUNGEON_QUESTS or {}) do for _, x in ipairs(idsOf(id)) do questIndex[x] = questIndex[x] or id end end
  end
  return q and questIndex[q] or nil
end

local function questName(q, known)
  if known then return known end
  local t = C_QuestLog and C_QuestLog.GetTitleForQuestID
  if t then local ok, name = pcall(t, q); if ok and plain(name) and type(name) == "string" and name ~= "" then return name end end
  for _, s in ipairs(ForeverRouteData and ForeverRouteData.steps or {}) do if s.q == q and s.name then return s.name end end
  return "Quest " .. tostring(q)
end

-- could you simply pick this one up? (e: a row of the dungeon's "open" list)
local function canTake(e, level, side, classBit)
  local State = ns.State
  if State.OnQuest(e[1]) or State.IsCompleted(e[1]) then return false end
  if level < (e[3] or 1) then return false end
  if e[4] and side and e[4] ~= side then return false end
  if e[5] and classBit and bit and bit.band(e[5], classBit) == 0 then return false end
  if ns.char and ns.char.nope and ns.char.nope[e[1]] then return false end -- you said you're not doing it
  if ns.Avail and ns.Avail.Unavailable(e[1]) then return false end         -- its giver didn't offer it
  for _, q in ipairs(e.all or {}) do if not State.IsCompleted(q) then return false end end
  if e.any and #e.any > 0 then
    local one = false
    for _, q in ipairs(e.any) do if State.IsCompleted(q) then one = true; break end end
    if not one then return false end
  end
  return true
end

-- what your quest log has for a dungeon (id):
--   quests   { { q, name, ready, objectives = { { text, have, need, finished } } }, ... }  unfinished ones first
--   missed   { { q, name, from }, ... }   not picked up, though you could have (their givers are out in the world)
--   inside   { { q, name, from }, ... }   picked up in there (a person or a drop inside)
--   done, total   objectives finished / in all (a quest with none counts as one)
function Dungeon.State(id)
  local State = ns.State
  local out = { quests = {}, missed = {}, inside = {}, done = 0, total = 0 }
  local d = ns.DUNGEON_QUESTS and ns.DUNGEON_QUESTS[id]
  if not d then return out end
  local names = {}
  for _, e in ipairs(d.open or {}) do names[e[1]] = e[2] end
  for _, q in ipairs(idsOf(id)) do
    local info = State.Quest(q)
    if info and info.on then
      local ready = State.QuestReady(q) and true or false
      local objs = {}
      for i, o in ipairs(info.objectives or {}) do
        objs[i] = { text = o.text or "", have = o.have or 0, need = o.need or 0, finished = (o.finished or ready) and true or false }
        out.total = out.total + 1
        if objs[i].finished then out.done = out.done + 1 end
      end
      if #objs == 0 then out.total = out.total + 1; if ready then out.done = out.done + 1 end end
      out.quests[#out.quests + 1] = { q = q, name = questName(q, names[q]), ready = ready, objectives = objs }
    end
  end
  table.sort(out.quests, function(a, b) if a.ready ~= b.ready then return not a.ready end return a.q < b.q end)
  local level = (UnitLevel and UnitLevel("player")) or 1
  local side = UnitFactionGroup and UnitFactionGroup("player")
  side = (side == "Alliance" and "A") or (side == "Horde" and "H") or nil
  local _, _, classId = UnitClass("player")
  local classBit = type(classId) == "number" and 2 ^ (classId - 1) or nil
  for _, e in ipairs(d.open or {}) do
    if canTake(e, level, side, classBit) then
      local t = e[7] and out.inside or out.missed
      t[#t + 1] = { q = e[1], name = e[2], from = e[6] }
    end
  end
  return out
end

-- walking in or out: FR_DUNGEON(name, id) - nil, nil on the way out. Both come with a loading screen, so the game's
-- zone events cover it; a slow look every few seconds is there for a client that names the instance late.
local last
function Dungeon.Check()
  local name, id = Dungeon.Here()
  local now = name and (id or name) or nil
  if now == last then return end
  last = now
  if ns.Why then ns.Why("dungeon", name and ("inside " .. name .. (id and (" (instance " .. id .. ")") or " (not a dungeon this addon has quests for)")) or "back out in the world") end
  ns.Fire("FR_DUNGEON", name, id)
end
local function check() pcall(Dungeon.Check) end
ns.On("ZONE_CHANGED_NEW_AREA", check)
ns.On("PLAYER_ENTERING_WORLD", check)
ns.On("FR_LOADED", function() check(); if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(5, check) end end)
