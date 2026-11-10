-- Walking trails: where you actually walk, recorded so the planner can fix its paths. In the capitals and indoors every
-- 3 yards (the stairs, ramps and doorways the building data gets wrong); out in the zones every 12 yards (the gaps,
-- slopes and roads the terrain model misses). Not on flights or while dead. Kept in ForeverRouteDB.trailData on your
-- PC; the planner adds them to its walking model as extra ways to go - a trail only gets used where it is shorter than
-- what the model knew, so wandering, detours and suboptimal walking cost nothing. Turn off in options.
local _, ns = ...
local Trails = {}
ns.Trails = Trails

local CITIES = { [1453] = "Stormwind", [1455] = "Ironforge", [1457] = "Darnassus", [1454] = "Orgrimmar", [1458] = "Undercity", [1456] = "Thunder Bluff" }
local MAX_POINTS = 30000 -- per city; oldest trails are dropped first
local MAX_ZONE_POINTS = 8000 -- per outdoor zone (12-yard spacing: plenty of roads, a small save file)
local HBD = LibStub("HereBeDragons-2.0")

local cur -- { map, seg (table of "x,y[,z]" strings), lastX, lastY, lastT }

-- the recorded walking lives in ForeverRouteDB.trailData (ForeverRouteDB.trails is the on/off setting - they once
-- shared a name, which broke recording)
local function store()
  if type(ForeverRouteDB.trailData) ~= "table" then ForeverRouteDB.trailData = {} end
  return ForeverRouteDB.trailData
end
ns.On("FR_LOADED", function()
  if type(ForeverRouteDB.trails) == "table" then ForeverRouteDB.trailData = ForeverRouteDB.trails; ForeverRouteDB.trails = true end
end)

local function flush()
  if not (cur and cur.seg and #cur.seg >= 3) then cur = nil; return end
  local t = store()
  local list = t[cur.map] or {}; t[cur.map] = list
  list[#list + 1] = table.concat(cur.seg, ";")
  -- keep it bounded: drop the oldest trails past the cap
  local total = 0; for _, s in ipairs(list) do total = total + select(2, s:gsub(";", ";")) + 1 end
  local cap = CITIES[cur.map] and MAX_POINTS or MAX_ZONE_POINTS
  while total > cap and #list > 1 do local s = table.remove(list, 1); total = total - (select(2, s:gsub(";", ";")) + 1) end
  cur = nil
end

local function height()
  if not UnitPosition then return nil end
  local ok, _, _, z = pcall(UnitPosition, "player")
  if ok and type(z) == "number" and z ~= 0 then return z end
end

local function tick()
  if ns.db and ns.db.trails == false then if cur then flush() end return end
  local m, x, y = ns.State.Position()
  local onFoot = not ns.Is(UnitOnTaxi, "player") and not ns.Is(IsFlying) and not ns.Is(UnitIsDeadOrGhost, "player")
  -- fine detail in capitals and indoors (inns, caves, towers, mines), coarser out in the zones; going in or out of a
  -- building starts a new trail (the spacing changes)
  local indoors = ns.Is(IsIndoors)
  local fine = CITIES[m] or indoors
  if not (m and x and onFoot) then if cur then flush() end return end
  if cur and cur.fine ~= fine then flush() end
  local wx, wy = HBD:GetPlayerWorldPosition()
  if not wx then return end
  local now = GetTime()
  if cur and cur.map ~= m then flush() end
  if cur then
    local d = math.sqrt((wx - cur.lastX) ^ 2 + (wy - cur.lastY) ^ 2)
    local dt = now - cur.lastT
    if d > 40 or dt > 30 then flush() -- a portal, a teleport, or a long stop: start a new trail
    elseif d < (fine and 3 or 12) then return end
  end
  if not cur then cur = { map = m, seg = {}, fine = fine } end
  local z = height()
  cur.seg[#cur.seg + 1] = string.format(z and "%.4f,%.4f,%.1f" or "%.4f,%.4f", x, y, z)
  cur.lastX, cur.lastY, cur.lastT = wx, wy, now
  if #cur.seg >= 400 then local keep = cur; flush(); cur = { map = keep.map, fine = keep.fine, seg = { keep.seg and keep.seg[#keep.seg] or nil }, lastX = wx, lastY = wy, lastT = now } end
end

function Trails.Count()
  local n, per = 0, {}
  for m, list in pairs(store()) do
    local c = 0; for _, s in ipairs(list) do c = c + select(2, s:gsub(";", ";")) + 1 end
    per[CITIES[m] or m] = c; n = n + c
  end
  return n, per
end
Trails._tick = tick; Trails._flush = flush; Trails.CITIES = CITIES

ns.On("FR_LOADED", function() C_Timer.NewTicker(1, ns.Guard("trails", tick)) end)
ns.On("PLAYER_LOGOUT", function() pcall(flush) end)
ns.On("ZONE_CHANGED_NEW_AREA", function() pcall(flush) end)
