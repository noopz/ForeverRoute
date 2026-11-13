-- Trips on the real network (the zone bounds the planner uses: the sim has no map data), from tester reports.
local ns = ForeverRoute

local function onRealMaps(level, taxi, fn)
  local HBD = LibStub("HereBeDragons-2.0")
  local B = ns.TravelData.BOUNDS
  local sv = { conv = HBD.GetWorldCoordinatesFromZone, info = C_Map.GetMapInfo, taxi = ns.State.knownTaxi, pos = ns.State.Position, lvl = UnitLevel, docks = ForeverRouteDB.docks }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) local b = B[m]; if not b then return nil end return b[1] + x * (b[2] - b[1]), b[3] + y * (b[4] - b[3]), b[5] end
  local names = { [1453] = "Stormwind City", [1455] = "Ironforge", [1426] = "Dun Morogh", [1417] = "Arathi Highlands", [1437] = "Wetlands", [1432] = "Loch Modan" }
  C_Map.GetMapInfo = function(m) return { name = names[m] or ("map " .. m) } end
  UnitLevel = function() return level end
  ns.State.knownTaxi = taxi
  ForeverRouteDB.docks = {}
  local ok, err = pcall(fn)
  HBD.GetWorldCoordinatesFromZone, C_Map.GetMapInfo, ns.State.knownTaxi, ns.State.Position, UnitLevel, ForeverRouteDB.docks = sv.conv, sv.info, sv.taxi, sv.pos, sv.lvl, sv.docks
  if not ok then error(err, 0) end
end

local function allAlliance()
  local known = {}
  for _, list in pairs(ns.FLIGHT_BY.Alliance) do for _, f in ipairs(list) do if f[4] then known[f[4]] = true end end end
  return known
end

local SW_INN = { m = 1453, x = 0.6039, y = 0.7527, name = "Stormwind" }

test("trips: Refuge Pointe to Stormwind with its flight path known is the flight to Stormwind, not Ironforge and the tram for 3 s less", function()
  onRealMaps(32, allAlliance(), function()
    ns.State.Position = function() return 1417, 0.45, 0.46 end
    local legs = ns.Travel.Plan({ m = 1417, x = 0.45, y = 0.46 }, SW_INN)
    assertNotNil(legs)
    local text = ns.Travel.Describe(legs)
    for _, l in ipairs(legs) do assertTrue(l.how ~= "boat", "took the tram: " .. text) end
    assertTrue(text:find("Fly to Stormwind", 1, true) ~= nil, text)
  end)
end)

test("trips: off the tram in Stormwind the walk never reads \"from Stormwind to Stormwind\"", function()
  local taxi = allAlliance(); taxi["Stormwind, Elwynn"] = nil
  onRealMaps(32, taxi, function()
    ns.State.Position = function() return 1455, 0.55, 0.48 end
    local legs = ns.Travel.Plan({ m = 1455, x = 0.55, y = 0.48 }, SW_INN)
    assertNotNil(legs)
    local text = ns.Travel.Describe(legs)
    assertTrue(text:find("Deeprun Tram", 1, true) ~= nil, text)
    assertTrue(text:find("from Stormwind to Stormwind", 1, true) == nil, text)
  end)
end)

test("trips: Dun Morogh to the Wetlands on foot goes through Loch Modan, never over the mountains", function()
  onRealMaps(22, {}, function()
    ns.State.Position = function() return 1426, 0.86, 0.40 end
    local legs = ns.Travel.Plan({ m = 1426, x = 0.86, y = 0.40 }, { m = 1437, x = 0.50, y = 0.75, name = "the Wetlands" })
    assertNotNil(legs)
    local text = ns.Travel.Describe(legs)
    assertTrue(text:find("Dun Morogh - Wetlands", 1, true) == nil, text)
    assertTrue(text:find("Loch Modan", 1, true) ~= nil, text)
  end)
end)

test("trips: riding from Southshore to Alterac Mountains, the arrow aims at the border, not Southshore's flight master on the way (tester)", function()
  onRealMaps(33, allAlliance(), function()
    ns.State.Position = function() return 1424, 0.495, 0.557 end
    local legs = ns.Travel.Plan({ m = 1424, x = 0.495, y = 0.557 }, { m = 1416, x = 0.184, y = 0.497, name = "Alterac Mountains" })
    assertNotNil(legs)
    local l1 = legs[1]
    assertEquals("ride", l1.how, ns.Travel.Describe(legs))
    local atFM = l1.m == 1424 and math.abs(l1.x - 0.4934) < 0.02 and math.abs(l1.y - 0.5227) < 0.02
    assertTrue(not atFM, "the ride points at the flight master: " .. l1.m .. " " .. l1.x .. "," .. l1.y)
  end)
end)
