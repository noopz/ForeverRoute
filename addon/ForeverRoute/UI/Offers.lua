-- Level-up notice: every time you ding, one line on the card (and one chat line) - new spells to train, the best
-- zones at your new level (the planner scores the next two levels ahead of time), and whether another zone now clearly
-- beats the one you're in. Shown for a while after the ding, or until you hide it. Never switches anything: "See
-- options" opens the paths.
local _, ns = ...
local Offers = {}
ns.Offers = Offers

Offers.SHOW_SECONDS = 15 * 60
Offers.BEATS = 1.25 -- another zone has to be this much better to be called out

-- the zone you're working in: the current step's zone, else where you stand
local function currentZone()
  local i = ns.Engine and ns.Engine.Shown and ns.Engine.Shown()
  local s = i and ForeverRouteData and ForeverRouteData.steps and ForeverRouteData.steps[i]
  if s and s.zone then return s.zone end
  local m = ns.State.Position()
  local info = m and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(m)
  return info and info.name or nil
end
local function same(a, b) return a and b and (a == b or a:find(b, 1, true) or b:find(a, 1, true)) and true or false end

-- the best zones at this level (from the plan's look-ahead, else its current ranking)
function Offers.Zones(level)
  local plan = ForeverRoutePlan
  if not plan then return {} end
  local list = (plan.ahead and plan.ahead[level]) or (level == plan.level and plan.zones) or {}
  local out = {}
  for _, z in ipairs(list) do if (z.xph or 0) > 0 then out[#out + 1] = z end end
  table.sort(out, function(a, b) return (a.xph or 0) > (b.xph or 0) end)
  return out
end

-- -> text, better (a zone that clearly beats yours), or nil
function Offers.Summary(level)
  local zones = Offers.Zones(level)
  local parts = {}
  if level % 2 == 0 then parts[#parts + 1] = "new spells to train" end
  local cur = currentZone()
  local mine, better
  for _, z in ipairs(zones) do if same(z.name, cur) then mine = z end end
  local top = zones[1]
  if top and mine and top ~= mine and (top.xph or 0) >= (mine.xph or 0) * Offers.BEATS then better = top end
  if top then
    local best = {}
    for k = 1, math.min(3, #zones) do
      local z = zones[k]
      best[#best + 1] = ns.Style.ShortZone(z.name) .. string.format(" %.0fk", (z.xph or 0) / 1000) .. (same(z.name, cur) and " (yours)" or "")
    end
    parts[#parts + 1] = "best zones now: " .. table.concat(best, ", ")
  end
  if better then parts[#parts + 1] = ns.Style.ShortZone(better.name) .. " clearly beats " .. ns.Style.ShortZone(mine.name) end
  if #parts == 0 then return nil end
  return string.format("Level %d: %s", level, table.concat(parts, " - ")), better
end

-- the card row: for a while after a ding (a ding we haven't shown yet counts as just now)
function Offers.Current()
  local level = UnitLevel("player")
  if not level then return nil end
  if ns.char.dingLevel ~= level then ns.char.dingLevel = level; ns.char.dingAt = time() end
  if ns.char.offerDismissed == level then return nil end
  if time() - (ns.char.dingAt or 0) > Offers.SHOW_SECONDS then return nil end
  local text, better = Offers.Summary(level)
  if not text then return nil end
  return level, { text = text, better = better }
end

function Offers.Dismiss() ns.char.offerDismissed = UnitLevel("player"); ns.Fire("FR_STEP", ns.Engine.Shown()) end

ns.On("PLAYER_LEVEL_UP", function(newLevel)
  C_Timer.After(1, function()
    ns.char.dingLevel = newLevel; ns.char.dingAt = time()
    local text = Offers.Summary(newLevel)
    if text then ns.Print(text .. ". /fr paths to look - your route stays as it is.") end
    ns.Fire("FR_STEP", ns.Engine.Shown())
  end)
end)
