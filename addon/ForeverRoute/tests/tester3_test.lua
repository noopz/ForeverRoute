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
