-- Real drop rates, learned from your play: while you're on a "collect" step, every corpse of the step's mob you loot
-- counts as a kill, and the step's item in that corpse's loot counts as a drop. The quest data has the original Classic
-- rates; Forever changed some (the Battleworn Axe is far rarer). With enough kills, the card warns when drops are much
-- rarer than planned, and the planner on your PC uses your measured rate instead of the old one.
-- Kept per item in ForeverRouteDB.drops (shared by your characters): { kills, drops, from = { [npc id] = name } }.
--
-- We count corpses, not loot windows: a loot window also opens for a chest, a herb or a tree (the Heartswood), for
-- skinning a corpse you already looted, and again when you reopen a corpse you left items in. So each loot slot's
-- sources (GetLootSourceInfo) are read, only creature sources count, and each corpse counts once.
local _, ns = ...
local Drops = {}
ns.Drops = Drops

Drops.MIN_KILLS = 15      -- enough to say something
Drops.RARE = 0.5          -- warn when the measured rate is under half the planned one

local function store()
  if type(ForeverRouteDB.drops) ~= "table" then ForeverRouteDB.drops = {} end
  return ForeverRouteDB.drops
end
local function entry(item)
  local d = store(); local e = d[item]
  if type(e) ~= "table" then e = { kills = 0, drops = 0 }; d[item] = e end
  if type(e.from) ~= "table" then e.from = {} end
  return e
end
-- only the step you're actually on: a step you're just looking at in the list is not what you're killing for
local function currentCollect()
  local i = ns.Engine and ns.Engine.current
  local s = i and ForeverRouteData and ForeverRouteData.steps and ForeverRouteData.steps[i]
  if s and s.k == "obj" and s.loot and s.match and s.q then return s end
end
-- some values are hidden from addons on Forever ("secret values"); treat those as unknown
local function plain(v)
  if v == nil or (issecretvalue and issecretvalue(v)) then return nil end
  return v
end
local function call(fn, ...)
  if type(fn) ~= "function" then return nil end
  local r = { n = 0 }
  local function grab(ok, ...)
    if not ok then return false end
    r.n = select("#", ...)
    for k = 1, r.n do r[k] = plain((select(k, ...))) end
    return true
  end
  if not grab(pcall(fn, ...)) then return nil end
  return unpack(r, 1, r.n)
end

-- the mobs the step names: its target, or the planner's "Collect 10 Razormaw Incisor (Highland Razormaw, Elder
-- Razormaw)" list (the first bracket after the item; "(in The Stockade)" is a place, not a mob). nil when it names none.
function Drops.Targets(s)
  local names
  local function add(n) n = n and n:match("^%s*(.-)%s*$"); if n and n ~= "" then names = names or {}; names[n] = true end end
  if s.target then add(s.target) end
  local text = type(s.text) == "string" and s.text or ""
  local at = text:find(s.match, 1, true)
  local group = at and text:sub(at + #s.match):match("^%s*%((.-)%)")
  if group and not group:find("^in ") then for n in group:gmatch("[^,]+") do add(n) end end
  return names
end

-- "Creature-0-1-2-3-<npc id>-<spawn>": the kind of thing and which npc
local function guidInfo(guid)
  if type(guid) ~= "string" then return nil end
  local kind, npc = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)")
  return kind, npc
end

local counted, countedOrder = {}, {}   -- corpses already counted (by item): looting, skinning, reopening count once
local function seen(item, guid)
  local key = item .. "|" .. guid
  if counted[key] then return true end
  counted[key] = true; countedOrder[#countedOrder + 1] = key
  if #countedOrder > 300 then counted[table.remove(countedOrder, 1)] = nil end
  return false
end

-- the loot window: corpse GUID -> how many of the step's item it holds (0 when none)
local function corpses(s)
  local out = {}
  local tguid = call(UnitExists, "target") and call(UnitIsDead, "target") and call(UnitGUID, "target") or nil
  local n = call(GetNumLootItems) or 0
  for slot = 1, n do
    local _, name, qty = call(GetLootSlotInfo, slot)
    if not name then
      local link = call(GetLootSlotLink, slot)
      name = type(link) == "string" and link:match("%[(.-)%]") or nil
    end
    local isItem = name == s.match
    local src = { call(GetLootSourceInfo, slot) }
    if #src == 0 and tguid then src = { tguid, qty or 1 } end   -- no source info: the dead target is the corpse
    for k = 1, #src, 2 do
      local guid = src[k]
      local kind = guidInfo(guid)
      if kind == "Creature" or kind == "Vehicle" then
        out[guid] = (out[guid] or 0) + (isItem and (tonumber(src[k + 1]) or 1) or 0)
      end
    end
  end
  return out, tguid
end

-- corpses of the step's mob looted while collecting
function Drops.OnLoot()
  local s = currentCollect(); if not s then return end
  local list, tguid = corpses(s)
  if not next(list) then return end
  local tname = tguid and call(UnitName, "target")
  local names = Drops.Targets(s)
  local e
  for guid, got in pairs(list) do
    if not seen(s.match, guid) then
      e = e or entry(s.match)
      local _, npc = guidInfo(guid)
      local name = (guid == tguid and type(tname) == "string") and tname or nil
      local known = npc and e.from[npc]
      local counts
      if got > 0 then counts = true                          -- it dropped the item: it is a source, whatever its name
      elseif names then counts = (name and names[name]) or (known and names[known]) or false
      else counts = known ~= nil end                         -- the step names no mob: only mobs seen dropping it
      if counts then
        e.kills = e.kills + 1
        e.drops = e.drops + got
        if npc and (got > 0 or name) then e.from[npc] = name or known or true end
      end
    end
  end
end

-- what to tell you about the step you're on: nil, or text when drops are much rarer than planned.
-- Steps the planner gave a drop rate are judged against it. Side-trip and dungeon steps carry none, and there is no
-- honest rate to compare with, so they only warn when drops are plainly dreadful (under 8% after 25 corpses).
Drops.ABS_RARE, Drops.ABS_KILLS = 0.08, 25
local told = {}
function Drops.Note(s)
  if not (s and s.k == "obj" and s.loot and s.match) then return nil end
  local e = store()[s.match]
  if not e or e.kills < Drops.MIN_KILLS then return nil end
  local rate = e.drops / e.kills
  local planned = tonumber(s.rate)
  local msg
  if planned then
    planned = planned / 100
    if rate >= planned * Drops.RARE then return nil end
    msg = string.format("%s drops look rare: %d from %d kills (%.0f%%, the plan assumed %.0f%%). Consider \"not doing this quest\".", s.match, e.drops, e.kills, rate * 100, planned * 100)
  else
    if e.kills < Drops.ABS_KILLS or rate >= Drops.ABS_RARE then return nil end
    msg = string.format("%s drops look rare here: %d from %d kills (%.0f%%).", s.match, e.drops, e.kills, rate * 100)
  end
  -- the decision log gets one line per item per session, not one per kill (the card asks for this note on every redraw)
  if ns.Why and not told[s.match] then
    told[s.match] = true
    ns.Why("drops", s.match .. (planned and " drops rarer than planned: the card suggests not doing the quest" or " drops look rare: the card says so"))
  end
  return msg
end

ns.On("LOOT_OPENED", function() pcall(Drops.OnLoot) end)
