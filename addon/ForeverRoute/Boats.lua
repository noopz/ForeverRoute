-- Boat crossings: the planner points a "Boat to X" step at the harbor town (it has no pier coordinates). Once you've
-- taken a boat, this remembers where you actually boarded - the last spot in the harbor zone where you stood still
-- for 15+ seconds before arriving across the sea, if that is close to the boat's known dock - and points future
-- boat steps at that pier.
-- Learned piers live in ForeverRouteDB.docks (shared by your characters).
local _, ns = ...
local Boats = {}
ns.Boats = Boats

local STILL_SEC, MOVE_YD, FRESH_SEC = 15, 1.5, 900
local HBD = LibStub("HereBeDragons-2.0")
local last, still -- last sample { wx, wy }, and where you've been standing { m, x, y, since, at }
local waited = {} -- [map] = { x, y, t }: the latest spot on that map where you stood still long enough

local function docks()
  if type(ForeverRouteDB.docks) ~= "table" then ForeverRouteDB.docks = {} end
  return ForeverRouteDB.docks
end

-- put learned piers on the route's boat steps (the planner's own spot is kept, to tell which pier the step means)
function Boats.Apply()
  local list = ForeverRouteData and ForeverRouteData.steps
  if not list then return end
  local d = docks()
  for _, s in ipairs(list) do
    local p = s.boat and d[s.boat]
    if p and p.m == s.m then
      if not s.learned then s.planX, s.planY = s.x, s.y end
      s.x, s.y, s.r, s.learned, s.wp = p.x, p.y, 25, true, nil
    end
  end
end

-- The spot you last stood still at is only a guess at the pier: the ship is often in when you get there and you
-- walk straight on, so the last wait may have been at the inn or the flight master. Only a spot close to a known
-- dock (Travel.DOCKS) counts - and to the right one: the same dock as the boat's own (want = keys that are it).
local NEAR_DOCK_YD = 150
local function nearestDock(m, x, y)
  local D = ns.Travel and ns.Travel.DOCKS
  local wx, wy, wi = HBD:GetWorldCoordinatesFromZone(x, y, m)
  if not (D and wx) then return nil end
  local best, bd
  for key, k in pairs(D) do
    if k.m == m then
      local dx, dy, di = HBD:GetWorldCoordinatesFromZone(k.x, k.y, k.m)
      if dx and di == wi then
        local dd = math.sqrt((dx - wx) ^ 2 + (dy - wy) ^ 2)
        if not bd or dd < bd then best, bd = key, dd end
      end
    end
  end
  return best, bd
end
local function plausible(m, w, want, what)
  local key, yd = nearestDock(m, w.x, w.y)
  if key and yd <= NEAR_DOCK_YD and want(key) then return true end
  if ns.Why then
    ns.Why("dock", "ignored " .. what .. " pier guess at " .. string.format("%.1f, %.1f", w.x * 100, w.y * 100) .. " (where you last stood still): "
      .. (key and string.format("%d yd from the %s dock%s", math.floor(yd + 0.5), key, want(key) and "" or ", not this boat's") or "no known dock on that map")
      .. " - keeping the planned pier")
  end
  return false
end
Boats._plausible = plausible

local function tick()
  local m, x, y = ns.State.Position()
  local wx, wy = HBD:GetPlayerWorldPosition()
  if not (m and x and wx) then last, still = nil, nil; return end
  local now = GetTime()
  if last and math.sqrt((wx - last[1]) ^ 2 + (wy - last[2]) ^ 2) <= MOVE_YD and still and still.m == m then
    if now - still.since >= STILL_SEC then waited[m] = { x = still.x, y = still.y, t = now } end
  else
    still = { m = m, x = x, y = y, since = now }
  end
  last = { wx, wy }
end

-- arriving across the sea while a boat step is current: the spot you waited at is the pier
local function arrived()
  local i = ns.Engine and ns.Engine.current
  local s = i and ForeverRouteData and ForeverRouteData.steps and ForeverRouteData.steps[i]
  if not (s and s.boat and s.to and s.m and ns.Engine.InZone and ns.Engine.InZone(s.to)) then return end
  local w = waited[s.m]
  if not w or GetTime() - w.t > FRESH_SEC then return end
  -- the boat's own dock: the one the step names (its key, or the pier name it learns under), else the one nearest
  -- the planner's spot for this step (Menethil has two piers)
  local D, named = ns.Travel and ns.Travel.DOCKS or {}, {}
  for k, v in pairs(D) do if v.m == s.m and (k == s.boat or v.learned == s.boat) then named[k] = true end end
  local own = not next(named) and nearestDock(s.m, s.planX or s.x, s.planY or s.y)
  if not plausible(s.m, w, function(k) return named[k] or k == own end, "the " .. s.boat) then return end
  local d = docks()
  local had = d[s.boat]
  d[s.boat] = { m = s.m, x = tonumber(string.format("%.4f", w.x)), y = tonumber(string.format("%.4f", w.y)) }
  Boats.Apply()
  if not had then ns.Print("Learned where the boat leaves from - next time the arrow points right at the pier.") end
end

-- a boat leg of a planned trip: when you board, the spot you waited at becomes that pier
function Boats.LearnDock(key, m)
  local w = waited[m]
  if not (key and w) or GetTime() - w.t > FRESH_SEC then return end
  -- key is the trip's learned-pier name (Travel.DOCKS[k].learned, or the dock key itself)
  local D = ns.Travel and ns.Travel.DOCKS or {}
  if not plausible(m, w, function(k) return ((D[k] and D[k].learned) or k) == key end, "the " .. key) then return end
  local d = docks()
  local had = d[key]
  d[key] = { m = m, x = tonumber(string.format("%.4f", w.x)), y = tonumber(string.format("%.4f", w.y)) }
  if ns.Why then ns.Why("dock", "learned the " .. key .. " pier at " .. string.format("%.1f, %.1f", w.x * 100, w.y * 100) .. " (where you waited before boarding)") end
  if not had then ns.Print("Learned where this boat leaves from - next time the arrow points right at the pier.") end
end
Boats._tick, Boats._arrived, Boats._waited = tick, arrived, waited

ns.On("FR_LOADED", function() C_Timer.NewTicker(1, ns.Guard("boats", tick)); Boats.Apply() end)
ns.On("FR_ROUTE_CHANGED", function() Boats.Apply() end)
ns.On("ZONE_CHANGED_NEW_AREA", function() pcall(arrived) end)
