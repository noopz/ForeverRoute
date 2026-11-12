-- Route logic from a level 31's feedback in Duskwood (2026-11-11):
--   a hearth step is only offered when the game says your hearthstone is set there and ready (Engine.HearthUsable);
--   a quest giver next to you whose quest no plan can hold is offered as a side stop (Engine.SideOffer, QuestData.lua);
--   quest items nothing needs any more are listed as safe to delete, and nothing is ever deleted (LogCheck.Leftovers).
local ns = ForeverRoute
local withState, withWorld = ForeverRouteTest.withState, ForeverRouteTest.withWorld

----------------------------------------------------------------------------------------------------------------
-- the hearthstone
----------------------------------------------------------------------------------------------------------------
-- Duskwood as the plan had it: bind at Darkshire's inn, quest out west, hearth back, hand in
local function hearthRoute(dest, noMap)
  return { id = "hearth", title = "hearth", sections = { { title = "Darkshire" } }, steps = {
    { id = 1, k = "bind", npc = "Innkeeper Trelayne", m = 1431, x = 0.7387, y = 0.4441, zone = "Duskwood", sec = 1 },
    { id = 2, k = "obj", q = 601, text = "Kill 5 Wolf", match = "Wolf", m = 1431, x = 0.20, y = 0.50, sec = 1 },
    { id = 3, k = "hearth", text = dest or "Darkshire", dest = dest or "Darkshire", note = "Hearth back to Darkshire - saves about 5 min of travel.", bindMap = not noMap and 1431 or nil, sec = 1 },
    { id = 4, k = "turnin", q = 601, name = "Wolves", npc = "Lars", m = 1431, x = 0.75, y = 0.48, sec = 1 },
  } }
end
local function withBind(fn)
  local sv = { bind = GetBindLocation, cd = ns.HearthCooldown, sub = GetSubZoneText, zone = GetRealZoneText, pos = ns.State.Position }
  local ok, err = pcall(withState, { [601] = { on = true, objectives = { { text = "Wolf slain: 5/5", finished = true, have = 5, need = 5 } }, complete = true } }, fn)
  GetBindLocation, ns.HearthCooldown, GetSubZoneText, GetRealZoneText, ns.State.Position = sv.bind, sv.cd, sv.sub, sv.zone, sv.pos
  if not ok then error(err, 0) end
end

test("hearth step: bound in Stormwind, 'Hearth to Darkshire' is not offered - the plan only assumed you set it there", function()
  withBind(function()
    ForeverRouteData = hearthRoute()
    ns.HearthCooldown = function() return 0 end
    -- the tester: the bind stop ticked by hand, the hearthstone still set in Stormwind (the save said so)
    ns.char.manualDone[ns.Engine.Key(1)] = true
    ns.char.boundAt = { m = 1453, name = "Stormwind City" }
    GetBindLocation = function() return "Stormwind City" end
    ns.Engine.Refresh()
    local can, why = ns.Engine.HearthUsable(3)
    assertTrue(not can, "a hearth to an inn you are not bound at"); assertTrue(why:find("Stormwind City", 1, true) ~= nil, why)
    assertEquals("done", ns.Engine.Status(3), "the hearth step is passed")
    assertEquals(4, ns.Engine.Shown(), "the card goes on to the hand-in (its trip is planned like any other)")
    -- bound somewhere the addon never saw you bind: still not Darkshire
    ns.char.boundAt = nil
    GetBindLocation = function() return "Menethil Harbor" end
    assertEquals("done", ns.Engine.Status(3))
    -- the game says nothing: not offered
    GetBindLocation = function() return nil end
    assertEquals("done", ns.Engine.Status(3))
  end)
end)

test("hearth step: offered when the game says you are bound there - by the inn's town, the zone, a capital's name, or where you set it", function()
  withBind(function()
    ns.HearthCooldown = function() return 0 end
    -- the town the game names ("Darkshire"), never seen binding: the step's own name for it
    ForeverRouteData = hearthRoute()
    ns.char.boundAt = nil
    GetBindLocation = function() return "Darkshire" end
    assertEquals("todo", ns.Engine.Status(3))
    -- a step named after its hub ("Duskwood: Madame Eva, Clerk Daltry"): the flight point's town says Darkshire is in Duskwood
    ForeverRouteData = hearthRoute("Duskwood: Madame Eva, Clerk Daltry")
    assertTrue(ns.FLIGHT_BY.Alliance[1431][1][4]:find("^Darkshire,") ~= nil, "the flight point data names the town")
    assertEquals("todo", ns.Engine.Status(3))
    -- where you set it while the addon watched: that map, whatever the game calls the place - and no other map
    ns.char.boundAt = { m = 1431, name = "Scarlet Raven Tavern" }
    GetBindLocation = function() return "Scarlet Raven Tavern" end
    assertEquals("todo", ns.Engine.Status(3))
    ns.char.boundAt = { m = 1433, name = "Darkshire" } -- (the record wins over a name that happens to match)
    GetBindLocation = function() return "Darkshire" end
    ForeverRouteData = hearthRoute()
    assertEquals("done", ns.Engine.Status(3))
    -- a plan from before hearth steps said where they go: the bind stop before it does
    ns.char.boundAt = { m = 1431, name = "Darkshire" }
    ForeverRouteData = hearthRoute("Duskwood: Madame Eva, Clerk Daltry", true)
    assertEquals("todo", ns.Engine.Status(3))
    ns.char.boundAt = { m = 1453, name = "Stormwind City" }
    GetBindLocation = function() return "Stormwind City" end
    assertEquals("done", ns.Engine.Status(3))
    -- a capital: "Stormwind City" for a step that goes to Stormwind's map
    ns.char.boundAt = nil
    ForeverRouteData = { id = "cap", title = "cap", sections = { { title = "x" } }, steps = {
      { id = 1, k = "hearth", text = "Stormwind: Garion Wendell", dest = "Stormwind: Garion Wendell", bindMap = 1453, sec = 1 },
      { id = 2, k = "bind", npc = "Innkeeper Allison", m = 1453, zone = "Stormwind", sec = 1 },
      { id = 3, k = "accept", q = 602, name = "A", m = 1453, x = 0.5, y = 0.5, sec = 1 },
    } }
    assertEquals("todo", ns.Engine.Status(1))
    GetBindLocation = function() return "Ironforge" end
    assertEquals("done", ns.Engine.Status(1))
  end)
end)

test("hearth step: on cooldown it is passed, ready it is back; standing in the place the game names teaches where your stone is set", function()
  withBind(function()
    ForeverRouteData = hearthRoute()
    ns.char.boundAt = { m = 1431, name = "Darkshire" }
    GetBindLocation = function() return "Darkshire" end
    local cd = 1500
    ns.HearthCooldown = function() return cd end
    local can, why = ns.Engine.HearthUsable(3)
    assertTrue(not can); assertTrue(why:find("cooldown", 1, true) ~= nil, why)
    assertEquals("done", ns.Engine.Status(3))
    cd = 0; assertEquals("todo", ns.Engine.Status(3))
    cd = nil; assertEquals("todo", ns.Engine.Status(3), "the game won't say (a hidden value): bound there is enough")
    -- bound before the addon, under a name no data has: standing there, the name of the place is the bind's name
    ns.char.boundAt = { m = 1453, name = "Stormwind City" }
    GetBindLocation = function() return "The Scarlet Raven" end
    ns.HearthCooldown = function() return 0 end
    assertEquals("done", ns.Engine.Status(3))
    GetSubZoneText = function() return "The Scarlet Raven" end; GetRealZoneText = function() return "Duskwood" end
    ns.State.Position = function() return 1431, 0.74, 0.44 end
    ns.Engine.LearnBind()
    assertEquals(1431, ns.char.boundAt.m); assertEquals("The Scarlet Raven", ns.char.boundAt.name)
    assertEquals("todo", ns.Engine.Status(3))
    -- somewhere else nothing is learned
    ns.char.boundAt = nil
    GetSubZoneText = function() return "Raven Hill" end
    ns.Engine.LearnBind()
    assertNil(ns.char.boundAt)
  end)
end)

----------------------------------------------------------------------------------------------------------------
-- a quest giver next to you (A Noble Brew)
----------------------------------------------------------------------------------------------------------------
-- a level 31's route: a stop in Stormwind, Duskwood (Darkshire), the Wetlands (near Thelgen Rock), Stormwind again
local function brewRoute(noWetlands)
  local s = {
    { k = "accept", q = 701, name = "Errand", npc = "Someone", m = 1453, x = 0.60, y = 0.75, r = 6, sec = 1, lvl = 31 },
    { k = "fly", dest = "Duskwood", to = 1431, text = "Duskwood", sec = 1 },
    { k = "accept", q = 702, name = "Wolves", npc = "Lars", m = 1431, x = 0.7387, y = 0.4441, r = 6, sec = 1, lvl = 31 },
    { k = "turnin", q = 702, name = "Wolves", npc = "Clerk Daltry", m = 1431, x = 0.72, y = 0.47, r = 6, sec = 1, lvl = 31 },
    { k = "fly", dest = "Wetlands", to = 1437, text = "Wetlands", sec = 1 },
    { k = "accept", q = 703, name = "Roots", npc = "Rethiel", m = 1437, x = 0.62, y = 0.72, r = 6, sec = 1, lvl = 32 },
    { k = "turnin", q = 703, name = "Roots", npc = "Kixxle", m = 1437, x = 0.60, y = 0.74, r = 6, sec = 1, lvl = 32 },
    { k = "fly", dest = "Stormwind City", to = 1453, text = "Stormwind City", sec = 1 },
    { k = "accept", q = 704, name = "Back in Town", npc = "Someone Else", m = 1453, x = 0.50, y = 0.70, r = 6, sec = 1, lvl = 32 },
  }
  if noWetlands then table.remove(s, 7); table.remove(s, 6); table.remove(s, 5) end
  for i, t in ipairs(s) do t.id = i end
  return { id = "brew", title = "brew", sections = { { title = "Route" } }, steps = s }
end
local function sideCount() local n = 0; for _, s in ipairs(ForeverRouteData.steps) do if s.side and s.k == "accept" then n = n + 1 end end return n end
local function inBrewWorld(route, fn, at)
  local sv = { side = UnitFactionGroup, class = UnitClass, race = UnitRace, why = ForeverRouteDB.why, avail = ns.Avail and ns.Avail.Unavailable }
  UnitFactionGroup = function() return "Alliance" end
  UnitClass = function() return "Warlock", "WARLOCK", 9 end
  UnitRace = function() return "Gnome", "Gnome", 7 end
  ForeverRouteDB.why = {}
  if ns.Avail then ns.Avail.Unavailable = function() return false end end
  local ok, err = pcall(withWorld, route, fn, { at = at or { m = 1453, x = 0.60, y = 0.75, level = 31 } })
  UnitFactionGroup, UnitClass, UnitRace, ForeverRouteDB.why = sv.side, sv.class, sv.race, sv.why
  if ns.Avail then ns.Avail.Unavailable = sv.avail end
  if not ok then error(err, 0) end
end
local function look() local HBD = LibStub("HereBeDragons-2.0"); local px, py, inst = HBD:GetPlayerWorldPosition(); return ns.Engine.SideOffer(px, py, inst, true) end

test("side quest data: A Noble Brew is one a plan cannot hold, with its giver and where its objectives lie", function()
  local d = ns.SIDE_QUESTS and ns.SIDE_QUESTS[335]
  assertNotNil(d, "A Noble Brew (335) is not in the side quest data")
  assertEquals("A Noble Brew", d.n); assertEquals(30, d.l); assertEquals("Zardeth of the Black Claw", d.g[1]); assertEquals(1453, d.g[2])
  assertEquals("Tear of Tilloa", d.o[1][2]); assertEquals(1431, d.o[1][3][1])
  assertEquals("Musquash Root", d.o[2][2]); assertEquals(1437, d.o[2][3][1])
  -- every entry has what the engine reads
  for q, e in pairs(ns.SIDE_QUESTS) do
    assertTrue(type(e.n) == "string" and type(e.l) == "number" and type(e.r) == "number" and type(e.xp) == "number", "side quest " .. q)
    assertTrue(type(e.g[1]) == "string" and type(e.g[2]) == "number" and type(e.e[2]) == "number", "side quest " .. q .. ": giver / hand-in")
    for _, o in ipairs(e.o or {}) do assertTrue(type(o[2]) == "string" and type(o[3]) == "table" and type(o[3][1]) == "number", "side quest " .. q .. ": objective") end
  end
end)

test("side quest: standing next to Zardeth, A Noble Brew is offered as the next step - once, with the reason; walk on and it is passed", function()
  inBrewWorld(brewRoute(), function(w)
    assertTrue(not look(), "nothing is offered across town"); assertEquals(0, sideCount())
    w:go(1453, 0.405, 0.85) -- the Slaughtered Lamb: Zardeth is a few yards away
    local HBD = LibStub("HereBeDragons-2.0")
    ns.Engine.UpdateFocus(HBD:GetPlayerWorldPosition()) -- (the arrow's once-a-second tick is what looks around)
    assertEquals(1, sideCount(), "A Noble Brew was not offered")
    local i = ns.Engine.Shown()
    local s = ForeverRouteData.steps[i]
    assertEquals(335, s.q, "the card does not show it"); assertEquals("accept", s.k); assertEquals("Zardeth of the Black Claw", s.npc)
    assertTrue(s.note:find("on your route", 1, true) ~= nil, s.note)
    -- the why log says why
    local said
    for _, e in ipairs(ForeverRouteDB.why) do if e.k == "insert" and e.x:find("A Noble Brew", 1, true) and e.x:find("Zardeth", 1, true) then said = e.x end end
    assertNotNil(said, "no reason in the why log")
    -- no second offer while this one stands, and its follow-up (needs it handed in) is not offered
    look(); look()
    assertEquals(1, sideCount())
    -- the plan's steps are all still there
    assertEquals(10, #ForeverRouteData.steps)
    -- you walk on: passed; back at the giver: there again (the same step)
    w:go(1453, 0.60, 0.75); look()
    assertTrue(ns.Engine.Shown() ~= i and ForeverRouteData.steps[ns.Engine.Shown()].q ~= 335, "the offer followed you across town")
    assertEquals("done", ns.Engine.Status(i))
    w:go(1453, 0.405, 0.85); look()
    assertEquals(1, sideCount()); assertEquals(335, ForeverRouteData.steps[ns.Engine.Shown()].q)
  end)
end)

test("side quest: not offered when you won't do it, it is far from your level, its objectives are off your route, or the giver had nothing", function()
  inBrewWorld(brewRoute(), function(w)
    w:go(1453, 0.405, 0.85)
    local ok, why = ns.Engine.SideFits(335)
    if not ok then error("A Noble Brew does not fit: " .. tostring(why), 0) end
    ns.char.nope = { [335] = true }
    ok, why = ns.Engine.SideFits(335); assertTrue(not ok); assertTrue(not look()); assertEquals(0, sideCount())
    ns.char.nope = nil
    w:ding(36); ok, why = ns.Engine.SideFits(335); assertTrue(not ok, "a level 30 quest at 36"); assertTrue(not look())
    w.level = 24; ok, why = ns.Engine.SideFits(335); assertTrue(not ok, "below the level it needs")
    w.level = 31
    ns.Avail.Unavailable = function(q) return q == 335 end
    ok = ns.Engine.SideFits(335); assertTrue(not ok, "the giver had nothing for you")
    ns.Avail.Unavailable = function() return false end
    -- done, or in your log: yours already
    w.quests[335] = { done = true }; ok = ns.Engine.SideFits(335); assertTrue(not ok); w.quests[335] = nil
    -- the other side, another class
    UnitFactionGroup = function() return "Horde" end; ok = ns.Engine.SideFits(335); assertTrue(not ok); UnitFactionGroup = function() return "Alliance" end
    assertEquals(0, sideCount())
  end)
  -- a route that never goes to the Wetlands: the Musquash Root is nowhere near it
  inBrewWorld(brewRoute(true), function(w)
    w:go(1453, 0.405, 0.85)
    local ok, why = ns.Engine.SideFits(335)
    assertTrue(not ok); assertTrue(why:find("Musquash Root", 1, true) ~= nil, why)
    assertTrue(not look()); assertEquals(0, sideCount())
  end)
end)

test("side quest: once it is in your log its objectives become stops in the zones the route visits, each once", function()
  inBrewWorld(brewRoute(), function(w)
    w:go(1453, 0.405, 0.85); look()
    assertEquals(335, ForeverRouteData.steps[ns.Engine.Shown()].q)
    ns.Fire("QUEST_ACCEPTED", 335)
    assertTrue(ns.char.side and ns.char.side[335], "the quest you took is not remembered")
    w:quest(335, { on = true, objectives = { { text = "Tear of Tilloa: 0/1", finished = false, have = 0, need = 1 }, { text = "Musquash Root: 0/1", finished = false, have = 0, need = 1 } } })
    assertTrue(ns.Engine.SideStops(), "no stops were added for its objectives")
    ns.Engine.Refresh()
    local list, at = ForeverRouteData.steps, {}
    for i, s in ipairs(list) do
      if s.k == "fly" then at[s.to] = i end
      if s.q == 335 and s.k == "obj" then at[s.match] = i; assertTrue(s.side and s.inserted) end
    end
    assertNotNil(at["Tear of Tilloa"], "no stop for the Tear of Tilloa"); assertNotNil(at["Musquash Root"], "no stop for the Musquash Root")
    assertEquals(1431, list[at["Tear of Tilloa"]].m); assertEquals(1437, list[at["Musquash Root"]].m)
    assertTrue(at["Tear of Tilloa"] > at[1431] and at["Tear of Tilloa"] < at[1437], "the Tear of Tilloa is not in the Duskwood stretch")
    assertTrue(at["Musquash Root"] > at[1437] and at["Musquash Root"] < at[1453], "the Musquash Root is not in the Wetlands stretch")
    -- asked again: nothing more
    assertTrue(not ns.Engine.SideStops())
    -- the quest log check has it on your route
    assertEquals("todo", ns.Engine.Status(at["Tear of Tilloa"]))
    -- the Tear is in your bags: its stop is done, the root's is not
    w:quest(335, { on = true, objectives = { { text = "Tear of Tilloa: 1/1", finished = true, have = 1, need = 1 }, { text = "Musquash Root: 0/1", finished = false, have = 0, need = 1 } } })
    assertEquals("done", ns.Engine.Status(at["Tear of Tilloa"])); assertEquals("todo", ns.Engine.Status(at["Musquash Root"]))
  end)
end)

-- work the quest data lists none of, in no chain (Brewer's Trade: Brewmeister Bilger in Southshore gives it and takes
-- it back; "Deliver the bottles ... to Dun Garok"): no plan holds it, so it is offered at its giver - saying so
test("side quest: Brewer's Trade (its work not in the quest data) is offered at Brewmeister Bilger, and the offer says where its work is isn't known", function()
  local d = ns.SIDE_QUESTS and ns.SIDE_QUESTS[98071]
  assertNotNil(d, "Brewer's Trade (98071) is not in the side quest data")
  assertTrue(d.u, "Brewer's Trade is not flagged as work the quest data lists none of"); assertNil(d.o)
  local route = { id = "bt", title = "bt", sections = { { title = "Route" } }, steps = {
    { id = 1, k = "accept", q = 711, name = "Errand", npc = "Someone", m = 1424, x = 0.45, y = 0.45, r = 6, sec = 1, lvl = 27 },
    { id = 2, k = "turnin", q = 711, name = "Errand", npc = "Someone", m = 1424, x = 0.45, y = 0.45, r = 6, sec = 1, lvl = 27 },
  } }
  inBrewWorld(route, function(w)
    w:go(1424, 0.5205, 0.5870) -- beside Brewmeister Bilger
    look()
    assertEquals(1, sideCount(), "Brewer's Trade was not offered")
    local s = ForeverRouteData.steps[ns.Engine.Shown()]
    assertEquals(98071, s.q); assertEquals("accept", s.k)
    assertTrue(s.note:find("Brewer's Trade is offered here; where its work is isn't in the quest data (follow your quest log).", 1, true) ~= nil, s.note)
  end, { m = 1424, x = 0.45, y = 0.45, level = 27 })
end)

----------------------------------------------------------------------------------------------------------------
-- quest items nothing needs any more
----------------------------------------------------------------------------------------------------------------
local TEAR, STOUT = 2779, 2788 -- Tear of Tilloa (A Noble Brew, 335), Black Claw Stout (handed to you for 336)
local function leftovers(fake, fn)
  local sv = { side = UnitFactionGroup, class = UnitClass, info = ns.GetItemInfo, data = ForeverRouteData, dr = ns.DungeonRoutes }
  UnitFactionGroup = function() return "Alliance" end
  UnitClass = function() return "Warlock", "WARLOCK", 9 end
  ns.GetItemInfo = function() return nil end
  ns.DungeonRoutes = function() return {} end
  local ok, err = pcall(withState, fake, function()
    ForeverRouteData = { id = "left", title = "left", sections = { { title = "x" } }, steps = { { id = 1, k = "accept", q = 801, name = "Something", sec = 1 } } }
    fn()
  end)
  UnitFactionGroup, UnitClass, ns.GetItemInfo, ns.DungeonRoutes = sv.side, sv.class, sv.info, sv.dr
  if not ok then error(err, 0) end
end
local function has(list, id) for _, x in ipairs(list) do if x.id == id then return x end end end

test("quest item data: quest items by the quests that use them; cloth, potions and the hearthstone are not in it", function()
  assertNotNil(ns.QUEST_ITEMS, "no quest item data")
  assertEquals("Tear of Tilloa", ns.QUEST_ITEMS[TEAR][1]); assertEquals(335, ns.QUEST_ITEMS[TEAR][2])
  assertEquals(336, ns.QUEST_ITEMS[STOUT][2], "an item the giver hands you counts for its quest")
  assertNil(ns.QUEST_ITEMS[2589], "Linen Cloth is not a quest item"); assertNil(ns.QUEST_ITEMS[6948], "the hearthstone"); assertNil(ns.QUEST_ITEMS[118], "a potion")
  for id, e in pairs(ns.QUEST_ITEMS) do assertTrue(type(e[1]) == "string" and type(e[2]) == "number", "quest item " .. id) end
end)

test("leftover quest items: listed only when every quest that uses them is handed in, 'not doing', or abandoned and off your route", function()
  leftovers({}, function()
    local bags = { [TEAR] = 1, [2589] = 20, [6948] = 1 }
    -- a quest you never had and may still take keeps its items
    assertCount(0, ns.LogCheck.Leftovers(bags))
    -- you said you won't do it: its item is left over - and only that item
    ns.char.nope = { [335] = true }
    local list = ns.LogCheck.Leftovers(bags)
    assertCount(1, list); assertEquals(TEAR, list[1].id); assertEquals("Tear of Tilloa", list[1].name); assertEquals(1, list[1].count)
    assertTrue(list[1].why:find("not doing", 1, true) ~= nil, list[1].why)
    -- the game files the item as something else (it has uses): never listed
    ns.GetItemInfo = function() return "Tear of Tilloa", nil, 1, 1, 0, "Trade Goods", "Herb", 20, "", 1, 0, 7, 9 end
    assertCount(0, ns.LogCheck.Leftovers(bags))
    ns.GetItemInfo = function() return "Tear of Tilloa", nil, 1, 1, 0, "Quest", "Quest", 1, "", 1, 0, 12, 0 end
    assertCount(1, ns.LogCheck.Leftovers(bags))
    ns.GetItemInfo = function() return nil end
    ns.char.nope = nil
    -- abandoned (seen in your log once, gone, not done) and your route does not send you back for it
    ns.char.hadQuest = { [335] = true }
    list = ns.LogCheck.Leftovers(bags)
    assertCount(1, list); assertTrue(list[1].why:find("abandoned", 1, true) ~= nil, list[1].why)
    -- ... but the route still plans it (a failed escort is taken again): kept
    ForeverRouteData.steps[2] = { id = 2, k = "accept", q = 335, name = "A Noble Brew", sec = 1 }
    assertCount(0, ns.LogCheck.Leftovers(bags))
    ForeverRouteData.steps[2] = nil
    ns.char.hadQuest = nil
  end)
  -- handed in with a spare in your bags
  leftovers({ [335] = { done = true } }, function()
    local list = ns.LogCheck.Leftovers({ [TEAR] = 2 })
    assertCount(1, list); assertEquals(2, list[1].count); assertTrue(list[1].why:find("handed in", 1, true) ~= nil, list[1].why)
  end)
  -- in your log: its items are needed, whatever else you said about it
  leftovers({ [335] = { on = true, objectives = {} } }, function()
    ns.char.nope = { [335] = "ready" }; ns.char.hadQuest = { [335] = true }
    assertCount(0, ns.LogCheck.Leftovers({ [TEAR] = 1 }))
  end)
end)

test("leftover quest items: an item another quest of yours still needs is never listed; the other side's quests don't count", function()
  -- an item two quests anyone can take use, and one only Horde quests use (from the data, whatever it holds)
  local shared, horde
  for id, e in pairs(ns.QUEST_ITEMS) do
    if not shared and #e == 3 and not ns.QUEST_FOR[e[2]] and not ns.QUEST_FOR[e[3]] then shared = id end
    if not horde and #e == 2 and ns.QUEST_FOR[e[2]] == "H" then horde = id end
  end
  assertNotNil(shared, "no quest item used by two quests in the data"); assertNotNil(horde, "no Horde-only quest item in the data")
  local a, b = ns.QUEST_ITEMS[shared][2], ns.QUEST_ITEMS[shared][3]
  leftovers({ [a] = { done = true } }, function()
    assertCount(0, ns.LogCheck.Leftovers({ [shared] = 1 }), "one quest done, the other may still be taken")
    ns.char.nope = { [b] = true }
    local list = ns.LogCheck.Leftovers({ [shared] = 1 })
    assertCount(1, list); assertCount(2, list[1].quests)
    ns.char.nope = nil
  end)
  leftovers({ [a] = { done = true }, [b] = { on = true, objectives = {} } }, function()
    assertCount(0, ns.LogCheck.Leftovers({ [shared] = 1 }), "the other quest is in your log")
  end)
  leftovers({}, function()
    -- no quest of yours uses it: nothing to say about it either way
    ns.char.nope = { [ns.QUEST_ITEMS[horde][2]] = true }
    assertCount(0, ns.LogCheck.Leftovers({ [horde] = 1 }))
    UnitFactionGroup = function() return "Horde" end
    assertCount(1, ns.LogCheck.Leftovers({ [horde] = 1 }))
    ns.char.nope = nil
  end)
end)

test("leftover quest items: the quest log check lists them and tells you once; nothing is ever deleted or picked up", function()
  local sv = { bags = ns.State.BagItems, print = ns.Print, del = DeleteCursorItem, pick = C_Container and C_Container.PickupContainerItem,
    n = C_QuestLog.GetNumQuestLogEntries }
  local deleted, said = 0, {}
  DeleteCursorItem = function() deleted = deleted + 1 end
  if C_Container then C_Container.PickupContainerItem = function() deleted = deleted + 1 end end
  ns.Print = function(t) said[#said + 1] = t end
  ns.State.BagItems = function() return { [TEAR] = 1, [2589] = 20 } end
  C_QuestLog.GetNumQuestLogEntries = function() return 0 end
  local ok, err = pcall(leftovers, {}, function()
    ns.char.nope = { [335] = true }
    ns.LogCheck.TellLeftovers(); ns.LogCheck.TellLeftovers()
    assertCount(1, said, "said once, not every time")
    assertTrue(said[1]:find("Tear of Tilloa", 1, true) ~= nil and said[1]:find("safe to delete", 1, true) ~= nil, said[1])
    assertTrue(not said[1]:find("Linen", 1, true), "an item that is not a quest item was named")
    -- the window draws the list (and nothing else happens)
    ns.LogCheck.Toggle(); ns.LogCheck.Draw()
    assertTrue(ForeverRouteLogCheck:IsShown())
    ns.LogCheck.Toggle()
    -- gone from your bags, then back: said again
    ns.State.BagItems = function() return {} end
    ns.LogCheck.TellLeftovers()
    ns.State.BagItems = function() return { [TEAR] = 1 } end
    ns.LogCheck.TellLeftovers()
    assertCount(2, said)
    assertEquals(0, deleted, "the addon deleted or picked up an item")
    ns.char.nope = nil; ns.char.leftTold = nil
  end)
  ns.State.BagItems, ns.Print, DeleteCursorItem, C_QuestLog.GetNumQuestLogEntries = sv.bags, sv.print, sv.del, sv.n
  if C_Container then C_Container.PickupContainerItem = sv.pick end
  if not ok then error(err, 0) end
end)

test("your bags are read slot by slot, stacks counted", function()
  local sv = { c = C_Container }
  local slots = { [0] = { { 2779, 1 }, false, { 2589, 20 } }, [1] = { { 2589, 7 } } }
  C_Container = {
    GetContainerNumSlots = function(bag) return slots[bag] and #slots[bag] or 0 end,
    GetContainerItemID = function(bag, slot) local s = slots[bag] and slots[bag][slot]; return s and s[1] or nil end,
    GetContainerItemInfo = function(bag, slot) local s = slots[bag] and slots[bag][slot]; return s and { stackCount = s[2] } or nil end,
  }
  local ok, err = pcall(function()
    local bags = ns.State.BagItems()
    assertEquals(1, bags[2779]); assertEquals(27, bags[2589])
  end)
  C_Container = sv.c
  if not ok then error(err, 0) end
end)
