-- What the game really offers you. The quest database comes from several game versions, so it can list a quest
-- Forever doesn't give you (A Friend of the Family, from Bolvar: the card sent you there and he had nothing). The game
-- knows: the quest givers you talk to list what they offer, and the world map's "!" list shows what's available on a
-- map. Both are recorded per character in ForeverRouteChar.avail:
--   seen[q] = { t, lvl }       the game offered it (a giver listed it, or the map showed it)
--   no[q]   = { t, lvl, npc }  you talked to its giver and it wasn't among the offers, at that level
-- A quest the game didn't offer is left off your route (and every plan, tools/snapshot.js) until you level up - a
-- level can be the reason - or the game offers it after all. The planner reads the same record.
local _, ns = ...
local Avail = {}
ns.Avail = Avail

local function call(fn, ...) if type(fn) == "function" then local ok, a, b, c, d, e = pcall(fn, ...); if ok then return a, b, c, d, e end end end
local function plain(v) return v ~= nil and not (issecretvalue and issecretvalue(v)) end
local function store()
  local c = ForeverRouteChar
  if not c then return { seen = {}, no = {} } end
  c.avail = type(c.avail) == "table" and c.avail or {}
  c.avail.seen = type(c.avail.seen) == "table" and c.avail.seen or {}
  c.avail.no = type(c.avail.no) == "table" and c.avail.no or {}
  return c.avail
end
Avail._store = store
local function level() return (UnitLevel and UnitLevel("player")) or 0 end

function Avail.Seen(q)
  if not q then return end
  local A = store()
  A.seen[q] = { t = time(), lvl = level() }
  if A.no[q] then A.no[q] = nil; if ns.Why then ns.Why("avail", "quest " .. q .. " is offered after all: back on your route") end end
end
-- the game did not offer this quest at its giver (q: quest id, npc: who you talked to)
function Avail.NotOffered(q, npc, name)
  local A = store()
  if A.no[q] and A.no[q].lvl == level() then return end
  A.no[q] = { t = time(), lvl = level(), npc = npc }
  if ns.Why then ns.Why("avail", (name or ("quest " .. q)) .. ": " .. tostring(npc) .. " doesn't offer it to you - left off your route until you level up") end
  ns.Print((name or ("Quest " .. q)) .. ": " .. tostring(npc) .. " doesn't offer it to you, so it's off your route for now.")
end
-- left off the route: the game didn't offer it at this level (and hasn't since). A quest you have or did is never this.
function Avail.Unavailable(q)
  local n = q and ForeverRouteChar and ForeverRouteChar.avail and ForeverRouteChar.avail.no and ForeverRouteChar.avail.no[q]
  if not n then return false end
  if level() > (n.lvl or 0) then return false end
  return true
end

-- the quests a giver you're talking to offers: ids, or nil when the game didn't say
local function offeredHere(event)
  local ids = {}
  if event == "GOSSIP_SHOW" and C_GossipInfo and C_GossipInfo.GetAvailableQuests then
    local list = call(C_GossipInfo.GetAvailableQuests)
    if type(list) ~= "table" then return nil end
    for _, x in ipairs(list) do if type(x) == "table" and plain(x.questID) and x.questID then ids[#ids + 1] = x.questID end end
    return ids
  elseif event == "QUEST_GREETING" and GetNumAvailableQuests and GetAvailableQuestInfo then
    local n = call(GetNumAvailableQuests)
    if type(n) ~= "number" then return nil end
    for i = 1, n do local _, _, _, _, id = call(GetAvailableQuestInfo, i); if plain(id) and id then ids[#ids + 1] = id end end
    return ids
  elseif event == "QUEST_DETAIL" and GetQuestID then
    local id = call(GetQuestID)
    if plain(id) and id and id > 0 then ids[1] = id end
    return ids, true -- one quest straight to its page: says nothing about the others
  end
end
-- the route's pick-ups from this giver that you could take now (not had, not done, level reached)
local function expectedFrom(npc)
  local out = {}
  local list = ForeverRouteData and ForeverRouteData.steps
  if not (list and npc) then return out end
  for _, s in ipairs(list) do
    if s.k == "accept" and s.q and s.npc == npc and not (s.minLevel and level() < s.minLevel)
      and not ns.State.OnQuest(s.q) and not ns.State.IsCompleted(s.q) then out[s.q] = s.name or true end
  end
  return out
end
function Avail.OnGiver(event)
  local ids, partial = offeredHere(event)
  if not ids then return end
  local offered = {}
  for _, id in ipairs(ids) do offered[id] = true; Avail.Seen(id) end
  if partial then return end
  local npc = call(UnitName, "npc")
  if not (plain(npc) and type(npc) == "string") then return end
  for q, name in pairs(expectedFrom(npc)) do
    if not offered[q] then Avail.NotOffered(q, npc, type(name) == "string" and name or nil) end
  end
  if ns.Engine then ns.Engine.Refresh() end
end
for _, ev in ipairs({ "GOSSIP_SHOW", "QUEST_GREETING", "QUEST_DETAIL" }) do
  ns.On(ev, function() C_Timer.After(0.2, ns.Guard("avail", function() Avail.OnGiver(ev) end)) end)
end

-- the world map's available quests on the map you're on (the "!" icons): what the game says you can pick up there
function Avail.ScanMap(m)
  if not (m and C_QuestLine and C_QuestLine.GetAvailableQuestLines) then return 0 end
  if C_QuestLine.RequestQuestLinesForMap then call(C_QuestLine.RequestQuestLinesForMap, m) end
  local list = call(C_QuestLine.GetAvailableQuestLines, m)
  local n = 0
  for _, x in ipairs(type(list) == "table" and list or {}) do
    if type(x) == "table" and plain(x.questID) and x.questID then Avail.Seen(x.questID); n = n + 1 end
  end
  return n
end
local function scanHere() local m = ns.State and ns.State.Position and ns.State.Position(); if m then Avail.ScanMap(m) end end
ns.On("ZONE_CHANGED_NEW_AREA", function() C_Timer.After(3, ns.Guard("avail", scanHere)) end)
ns.On("QUESTLINE_UPDATE", function() C_Timer.After(0.5, ns.Guard("avail", scanHere)) end)
ns.On("FR_LOADED", function() C_Timer.After(8, ns.Guard("avail", scanHere)); C_Timer.NewTicker(120, ns.Guard("avail", scanHere)) end)
