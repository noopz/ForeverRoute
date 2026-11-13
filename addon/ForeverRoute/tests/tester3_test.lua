-- Tester report 2026-11-13: zones ahead from where you are, the card's "why go there", a Target button per mob, the
-- Target button dragged in combat, the arrival pulse, the footer.
local ns = ForeverRoute

local function withRoute(stepsList, fn)
  local sv = { data = ForeverRouteData, cur = ns.Engine.current, view = ns.Engine.view, status = ns.Engine.Status }
  ForeverRouteData = { id = "test:zones", title = "test", steps = stepsList, sections = { { title = "t", zone = "Hillsbrad Foothills" } } }
  ns.Engine.current, ns.Engine.view = 1, nil
  local done = {}
  ns.Engine.Status = function(i) return done[i] and "done" or "todo" end
  local ok, err = pcall(fn, done)
  ForeverRouteData, ns.Engine.current, ns.Engine.view, ns.Engine.Status = sv.data, sv.cur, sv.view, sv.status
  if not ok then error(err, 0) end
end

local ROUTE = {
  { k = "accept", q = 1, name = "Turtles", zone = "Hillsbrad Foothills", npc = "Chef", sec = 1 },
  { k = "fly", dest = "x", zone = "Hillsbrad Foothills", sec = 1 },
  { k = "obj", q = 1, name = "Turtles", zone = "Alterac Mountains", target = "Snapjaw", text = "Collect 10 Turtle Meat (Snapjaw, Cranky Benj)", sec = 1 },
  { k = "obj", q = 2, name = "Granite", zone = "Alterac Mountains", target = "Elemental", sec = 1 },
  { k = "fp", zone = "Alterac Mountains", sec = 1 },
  { k = "turnin", q = 1, name = "Turtles", zone = "Hillsbrad Foothills", sec = 1 },
  { k = "turnin", q = 2, name = "Granite", zone = "Hillsbrad Foothills", sec = 1 },
  { k = "fp", zone = "Stormwind City", sec = 1 },
  { k = "accept", q = 3, name = "Wetlands one", zone = "Wetlands", sec = 1 },
}

test("zones ahead: from where you are, quests worked (not only handed in) count, travel and pass-through stops don't", function()
  withRoute(ROUTE, function(done)
    done[1], done[2] = true, true
    ns.Engine.current = 3
    local z = ns.Engine.ZonesAhead()
    assertEquals(#z, 3, "three visits: Alterac, Hillsbrad, Wetlands (Stormwind is only a flight path)")
    assertEquals(z[1].zone, "Alterac Mountains"); assertEquals(z[1].quests, 2, "turtles worked there, granite")
    assertEquals(z[2].zone, "Hillsbrad Foothills"); assertEquals(z[2].quests, 2)
    assertEquals(z[3].zone, "Wetlands")
    assertEquals(z[1].first, 3)
  end)
end)

test("the card says why it sends you to another zone: what there is to do there and where next", function()
  withRoute(ROUTE, function(done)
    done[1], done[2] = true, true
    ns.Engine.current = 3
    local w = ns.Card.WhyGo(3)
    assertTrue(w and w:find("Going to Alterac Mountains for 2 quests %(Turtles, Granite%), then Hillsbrad Foothills"), "why-go line: " .. tostring(w))
  end)
end)

test("a Target button for each mob the step names, not the first one twice", function()
  local s = { k = "obj", target = "Snapjaw", text = "Collect 10 Turtle Meat (Snapjaw, Cranky Benj)" }
  local o = ns.Card.OtherTargets(s, "Snapjaw")
  assertEquals(#o, 1); assertEquals(o[1], "Cranky Benj")
  assertEquals(#ns.Card.OtherTargets({ k = "turnin", npc = "Chef", text = "Turn in (x, y)" }, "Chef"), 0, "only objectives")
end)

test("the Target button dragged in combat (never started): no protected call", function()
  local b = _G.ForeverRouteTargetButton
  assertTrue(b, "target button exists")
  local sv = { combat = InCombatLockdown, stop = b.StopMovingOrSizing }
  local called = false
  b.StopMovingOrSizing = function() called = true end
  InCombatLockdown = function() return true end
  local ok, err = pcall(function() b:GetScript("OnDragStop")(b) end)
  InCombatLockdown, b.StopMovingOrSizing = sv.combat, sv.stop
  if not ok then error(err, 0) end
  assertTrue(not called, "StopMovingOrSizing must not run for a drag we didn't start")
end)

test("dead and released: the arrow points at your corpse (with a walking line), and back at the step once you're alive", function()
  local A = ns.Arrow
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { ghost = UnitIsGhost, di = C_DeathInfo, best = C_Map.GetBestMapForUnit, want = ns.Nav and ns.Nav.Want, conv = HBD.GetWorldCoordinatesFromZone }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) return 1000 * x, 1000 * y, 0 end -- (the sim has no map data)
  local wanted
  if ns.Nav then ns.Nav.Want = function(t) wanted = t end end
  local ok, err = pcall(function()
    local i = ns.Engine.Shown()
    assertNotNil(i, "a step is shown")
    UnitIsGhost = function() return true end
    C_Map.GetBestMapForUnit = function() return 1429 end
    C_DeathInfo = { GetCorpseMapPosition = function(m) return m == 1429 and { x = 0.4, y = 0.6 } or nil end }
    A.SetTarget(i, true)
    local t = A.Current()
    assertTrue(t and t.corpse, "the arrow's target is the corpse")
    assertEquals(t.m, 1429); assertEquals(t.x, 0.4)
    assertTrue(wanted and wanted.key == t.key, "a walking line is asked for the corpse")
    UnitIsGhost = function() return false end
    A.SetTarget(i, true)
    assertTrue(not (A.Current() and A.Current().corpse), "alive: back to the step")
  end)
  UnitIsGhost, C_DeathInfo, C_Map.GetBestMapForUnit, HBD.GetWorldCoordinatesFromZone = sv.ghost, sv.di, sv.best, sv.conv
  if ns.Nav then ns.Nav.Want = sv.want end
  if not ok then error(err, 0) end
end)

test("a plan file with no leveling path never puts you on a dungeon route; a dungeon route you didn't choose goes back to a path", function()
  local sv = { routes = ForeverRouteRoutes, data = ForeverRouteData, ret = ns.char.returnTo, title = ns.char.routeTitle }
  local ok, err = pcall(function()
    local dung = { id = "dungeon:Gnomeregan:quick", title = "Dungeon: Gnomeregan", dungeon = true, sections = { { title = "x" } }, steps = { { k = "accept", q = 1, name = "x", sec = 1 } } }
    local path = { id = "path:Wetlands", title = "Wetlands", meta = { legs = "Wetlands" }, sections = { { title = "x" } }, steps = { { k = "accept", q = 2, name = "y", sec = 1 } } }
    ns.char.returnTo = nil
    ForeverRouteRoutes = { dung }
    ns.SelectRoute(nil, true)
    assertTrue(ForeverRouteData ~= dung, "no path in the file: not the dungeon route")
    ForeverRouteRoutes = { dung, path }
    -- (with a path you came from days ago still remembered - the tester's save had one)
    ns.char.returnTo = "path:SomeOldPath-FromLastWeek"; ns.char.chosenTrip = nil
    ns.char.routeTitle = "dungeon:Gnomeregan:quick"
    ns.SelectRoute(ns.SavedRoute(), true)
    assertEquals("path:Wetlands", ForeverRouteData and ForeverRouteData.id, "saved on a dungeon route it never chose: back on the path")
    -- one you picked (Route me) stays yours across a login
    ns.char.chosenTrip = "dungeon:Gnomeregan:quick"
    ns.char.routeTitle = "dungeon:Gnomeregan:quick"
    ns.SelectRoute(ns.SavedRoute(), true)
    assertEquals("dungeon:Gnomeregan:quick", ForeverRouteData and ForeverRouteData.id, "a dungeon route you picked")
  end)
  ForeverRouteRoutes, ns.char.returnTo, ns.char.chosenTrip = sv.routes, sv.ret, nil
  ns.SelectRoute(sv.title, true)
  if not ok then error(err, 0) end
end)

test("a pick-up whose earlier chain quest isn't handed in is never offered, even when the plan leaves that quest out (For Further Study)", function()
  local sv = { data = ForeverRouteData, comp = ns.State.IsCompleted, unl = ForeverRouteUnlocks }
  local ok, err = pcall(function()
    ForeverRouteUnlocks = {} -- (the plan knew nothing of the chain)
    ForeverRouteData = { id = "t:pre", steps = { { k = "accept", q = 98313, name = "For Further Study", sec = 1 } }, sections = { { title = "x" } } }
    local done = {}
    ns.State.IsCompleted = function(id) return done[id] or false end
    assertTrue(not ns.Engine.Available(1), "Gleaning Our Future (98310) not handed in: not offered")
    done[98310] = true
    assertTrue(ns.Engine.Available(1), "after Gleaning Our Future: offered")
  end)
  ForeverRouteData, ns.State.IsCompleted, ForeverRouteUnlocks = sv.data, sv.comp, sv.unl
  if not ok then error(err, 0) end
end)

local function navLine(pts)
  local rem = {}; rem[#pts] = 0
  for k = #pts - 1, 1, -1 do rem[k] = rem[k + 1] + math.sqrt((pts[k + 1][1] - pts[k][1]) ^ 2 + (pts[k + 1][2] - pts[k][2]) ^ 2) end
  return { pts = pts, rem = rem, cursor = 1 }
end

test("arrow: a line that loops back past you can't pull the arrow onto its later stretch (Ironforge's ring, tester)", function()
  -- east 100 yd, up 8, back west 100 yd (8 yd from the first stretch), then up and away
  local P = navLine({ { 0, 0 }, { 100, 0 }, { 100, 8 }, { 0, 8 }, { 0, 100 } })
  -- walking along the first stretch, a little toward the return stretch (5 yd off it, 3 yd from the return)
  local aim = ns.Nav.Aim(P, 50, 5, 10, false)
  assertTrue(aim[1] > 50, "the arrow points on along the dots (east), not back west along the return: aims at x=" .. aim[1])
  assertEquals(1, P.cursor, "still on the first stretch")
end)


test("arrow: on the Deeprun Tram (no position in its instance) it says to ride it, not a grey 'in Ironforge'", function()
  local sv = { gii = GetInstanceInfo }
  local ok, err = pcall(function()
    GetInstanceInfo = function() return "Deeprun Tram", "none", 0, "", 0, 0, false, 369 end
    assertTrue(ns.Arrow.InTram(), "the tram's instance")
    GetInstanceInfo = function() return "Eastern Kingdoms", "none", 0, "", 0, 0, false, 0 end
    assertTrue(not ns.Arrow.InTram() or C_Map.GetBestMapForUnit("player") == 499, "not on the tram")
  end)
  GetInstanceInfo = sv.gii
  if not ok then error(err, 0) end
end)

test("an objective farmed in another zone than its giver's says the nearer few exist (Turtle Meat: Alterac, a few in Hillsbrad)", function()
  local note = ns.Card.AlsoNote({ k = "obj", zone = "Alterac Mountains", also = "Hillsbrad Foothills:16" })
  assertTrue(note and note:find("Hillsbrad Foothills too", 1, true) and note:find("in Alterac Mountains", 1, true), tostring(note))
  assertEquals(nil, ns.Card.AlsoNote({ k = "obj", zone = "Alterac Mountains" }))
  assertEquals(nil, ns.Card.AlsoNote({ k = "turnin", also = "X:5" }))
end)

test("flight path step in a zone with two points: having the other one doesn't tick it (Feralas: Thalanaar and Feathermoon)", function()
  local sv = { known = ns.State.knownTaxi }
  local ok, err = pcall(function()
    ns.State.knownTaxi = { ["Thalanaar, Feralas"] = true }
    assertTrue(not ns.Engine.KnowsThisFlightPoint({ k = "fp", m = 1444, npc = "Fyldren Moonfeather", zone = "Feralas" }), "Feathermoon is not yours")
    assertTrue(ns.Engine.KnowsThisFlightPoint({ k = "fp", m = 1444, npc = "Thyssiana", zone = "Feralas" }), "Thalanaar is")
  end)
  ns.State.knownTaxi = sv.known
  if not ok then error(err, 0) end
end)

test("automatic ticks (arrived, landed, trained) go around MarkDone - the entry Learn.lua wraps to log 'ticked by hand'", function()
  local sv = ns.Engine.MarkDone
  local calls = 0
  ns.Engine.MarkDone = function(...) calls = calls + 1 end
  local ok, err = pcall(function() ns.Engine.AutoDone(1) end)
  ns.Engine.MarkDone = sv
  if not ok then error(err, 0) end
  assertEquals(0, calls, "an automatic tick must not pass through the hand-tick entry")
end)

test("warlock grimoire errand in the Horde capitals too, and a demon known by its spell (Horde quests differ)", function()
  local E = ns.Errands
  assertTrue(E.DEMON_TRAINERS[1454] and E.DEMON_TRAINERS[1458], "Orgrimmar and the Undercity have demon trainers")
  local sv = { cls = UnitClass, lvl = UnitLevel, pos = ns.State.Position, isk = IsSpellKnown, comp = ns.State.IsCompleted, gr = ns.char.grimoires }
  local ok, err = pcall(function()
    UnitClass = function() return "Warlock", "WARLOCK" end
    UnitLevel = function() return 31 end
    ns.State.Position = function() return 1454, 0.47, 0.46 end
    ns.State.IsCompleted = function() return false end -- (no Alliance quest done)
    ns.char.grimoires = { Sacrifice = true, ["Consume Shadows"] = true, Seduction = true }
    IsSpellKnown = function(id) return id == 691 end -- Summon Felhunter
    local text = E.Grimoire()
    assertTrue(text and text:find("Kurgul", 1, true) and text:find("Devour Magic", 1, true), tostring(text))
  end)
  UnitClass, UnitLevel, ns.State.Position, IsSpellKnown, ns.State.IsCompleted, ns.char.grimoires = sv.cls, sv.lvl, sv.pos, sv.isk, sv.comp, sv.gr
  if not ok then error(err, 0) end
end)
