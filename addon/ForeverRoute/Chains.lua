-- Quests priced and chains named without a plan (the design for zones and chains, stage 2): ns.QUEST_XP and
-- ns.CHAINS come from QuestData.lua (tools/gen-quest-data.js, tools/chains.js); both are unpacked the first time
-- they are asked for.
--   ns.QuestXp(q, level)  the XP quest q pays at that level (the planner's world.js questXp: full up to 5 levels
--                         below the quest, then 20% less a level, never under 10%); nil for a quest it doesn't know
--   ns.ChainOf(q)         the chain q is part of: { id, name, q = { ids in level order }, z = { area per part }, at = q's part }
local _, ns = ...

local xp -- id -> { base, level }
local function unpackXp()
  xp = {}
  for id, base, lvl in string.gmatch(ns.QUEST_XP or "", "(%d+):(%d+):(%d+)") do xp[tonumber(id)] = { tonumber(base), tonumber(lvl) } end
end

function ns.QuestXp(q, level)
  if not xp then unpackXp() end
  local e = q and xp[q]
  if not e then return nil end
  local base, ql = e[1], e[2]
  level = level or (UnitLevel and UnitLevel("player")) or ql
  local d = level - ql
  if d <= 5 then return base end
  return math.floor(base * math.max(0.1, 1 - 0.2 * (d - 5)) + 0.5)
end

local chainOf -- quest id -> chain
local function unpackChains()
  chainOf = {}
  for head, c in pairs(ns.CHAINS or {}) do
    local ch = { id = head, name = c.name, q = {}, z = {} }
    for id in string.gmatch(c.q or "", "%d+") do ch.q[#ch.q + 1] = tonumber(id) end
    for z in string.gmatch(c.z or "", "%d+") do ch.z[#ch.z + 1] = tonumber(z) end
    for n, id in ipairs(ch.q) do chainOf[id] = { chain = ch, at = n } end
  end
end

function ns.ChainOf(q)
  if not chainOf then unpackChains() end
  local e = q and chainOf[q]
  if not e then return nil end
  local ch = e.chain
  return { id = ch.id, name = ch.name, q = ch.q, z = ch.z, at = e.at }
end
