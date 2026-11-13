-- Forever Route test suite (runs in wow-ui-sim: wow-sim run-tests ForeverRoute)
local ns = ForeverRoute

local KINDS = { accept = 1, turnin = 1, obj = 1, ["goto"] = 1, fly = 1, fp = 1, hearth = 1, bind = 1, train = 1, grind = 1, note = 1, bonus = 1 }
local withState, withWorld = ForeverRouteTest.withState, ForeverRouteTest.withWorld
-- the old reordering (the live solver off, Options: "Choose the next step from where I am"): its own tests, run in that
-- mode - the solver's answers for the same places are in next_test.lua
local function planOrderTest(name, fn)
  test(name .. " [plan-order mode]", function()
    local was = ns.db.smartNext
    ns.db.smartNext = false
    local ok, err = pcall(fn)
    ns.db.smartNext = was
    if not ok then error(err, 0) end
  end)
end


local function miniRoute()
  return { id = "test", title = "test", sections = { { title = "Hub" } }, steps = {
    { id = 1, k = "accept", q = 101, name = "A", npc = "Giver", sec = 1 },
    { id = 2, k = "obj", q = 101, text = "Kill 5 Wolf", match = "Wolf", sec = 1 },
    { id = 3, k = "turnin", q = 101, name = "A", npc = "Giver", sec = 1 },
    { id = 4, k = "accept", q = 102, name = "B", npc = "Giver", sec = 1 },
    { id = 5, k = "obj", q = 102, text = "Collect 3 Fang", match = "Fang", sec = 1 },
    { id = 6, k = "turnin", q = 102, name = "B", npc = "Giver", sec = 1 },
    { id = 7, k = "goto", text = "Go somewhere", sec = 1 },
  } }
end


-- a route in Duskwood: one quest (giver at Darkshire, wolves to the west), then a trip to Redridge for the next one
local function worldRoute()
  return { id = "world", title = "world", sections = { { title = "Darkshire" }, { title = "Lakeshire" } }, steps = {
    { id = 1, k = "accept", q = 201, name = "Wolves", npc = "Lars", m = 1431, x = 0.75, y = 0.48, r = 6, sec = 1 },
    { id = 2, k = "obj", q = 201, text = "Kill 5 Wolf", match = "Wolf", m = 1431, x = 0.40, y = 0.40, r = 60, sec = 1 },
    { id = 3, k = "turnin", q = 201, name = "Wolves", npc = "Lars", m = 1431, x = 0.75, y = 0.48, r = 6, sec = 1 },
    { id = 4, k = "fly", dest = "Redridge Mountains", to = 1433, text = "Redridge Mountains", sec = 2 },
    { id = 5, k = "accept", q = 202, name = "Gnolls", npc = "Marshal", m = 1433, x = 0.30, y = 0.45, r = 6, sec = 2 },
  } }
end

test("scenario: a quest done while walking around - card, arrow and pins agree at every step", function()
  withWorld(worldRoute(), function(w)
    assertEquals(1, w:shown())
    w:go(1431, 0.74, 0.48) -- at the giver
    w:quest(201, { on = true, objectives = { { text = "Wolf slain: 0/5", finished = false, have = 0, need = 5 } } })
    assertEquals(2, w:shown())
    w:go(1431, 0.55, 0.44) -- walking out
    w:go(1431, 0.41, 0.40) -- at the wolves
    w:quest(201, { on = true, objectives = { { text = "Wolf slain: 3/5", finished = false, have = 3, need = 5 } } })
    assertEquals(2, w:shown())
    w:quest(201, { on = true, complete = true, objectives = { { text = "Wolf slain: 5/5", finished = true, have = 5, need = 5 } } })
    assertEquals(3, w:shown())
    w:go(1431, 0.60, 0.46) -- walking back
    w:go(1431, 0.75, 0.48)
    w:quest(201, { on = false, done = true, objectives = {} })
    assertEquals(4, w:shown())
  end)
end)

test("scenario: the trip to the next zone ends when you arrive there, and the next step is shown", function()
  withWorld(worldRoute(), function(w)
    w.quests[201] = { on = false, done = true, objectives = {} }
    w:go(1431, 0.75, 0.48)
    assertEquals(4, w:shown())
    w:go(1433, 0.20, 0.60) -- arrived in Redridge
    assertEquals(5, w:shown())
    w:go(1433, 0.30, 0.45)
    w:quest(202, { on = true, objectives = { { text = "Gnoll slain: 0/8", finished = false, have = 0, need = 8 } } })
  end)
end)

test("scenario: on a flight the arrow points nowhere (not back at the flight master), crossing a zone mid-air moves the route on, and landing points at the next step", function()
  withWorld(worldRoute(), function(w)
    w:knows({ "Darkshire, Duskwood", "Lakeshire, Redridge" })
    w.quests[201] = { on = false, done = true, objectives = {} }
    w:go(1431, 0.77, 0.44) -- at the Darkshire flight master
    assertEquals(4, w:shown())
    w:taxi(true)
    assertNil(ns.Arrow.Current(), "the arrow points somewhere while you fly")
    w:go(1433, 0.10, 0.70) -- the flight crosses into Redridge
    assertEquals(5, w:shown())
    assertNil(ns.Arrow.Current(), "the arrow re-planned from the sky")
    w:go(1433, 0.31, 0.43)
    w:taxi(false) -- landed at Lakeshire
    local t = ns.Arrow.Current()
    assertNotNil(t, "no arrow after landing")
    assertEquals(5, t.index)
  end)
end)

test("scenario: the boat to Darkshore - the arrow leads to the pier, points nowhere at sea, and the route moves on in Auberdine", function()
  local route = { id = "boat", title = "boat", sections = { { title = "Travel" }, { title = "Auberdine" } }, steps = {
    { id = 1, k = "fly", dest = "Darkshore", to = 1439, text = "Darkshore", sec = 1 },
    { id = 2, k = "accept", q = 301, name = "Buzzbox", npc = "Gwennyth", m = 1439, x = 0.37, y = 0.41, r = 6, sec = 2 },
  } }
  withWorld(route, function(w)
    w:knows({ "Stormwind, Elwynn", "Auberdine, Darkshore" })
    w:go(1453, 0.30, 0.30) -- Stormwind, near the harbor
    assertEquals(1, w:shown())
    local t = ns.Arrow.Current()
    assertNotNil(t, "no arrow to the pier")
    if t.m ~= 1453 then error("the arrow should lead to the Stormwind pier first, it points at " .. tostring(t.m) .. " " .. tostring(t.x) .. "," .. tostring(t.y) .. " (" .. tostring(t.label) .. "); trip: " .. tostring(ns.Engine.lastTrip and ns.Travel.Describe(ns.Engine.lastTrip)), 0) end
    w:board(true)
    assertNil(ns.Arrow.Current(), "the arrow points somewhere while you sail")
    w:go(1439, 0.33, 0.44) -- docked at Auberdine
    w:board(false)
    assertEquals(2, w:shown())
    t = ns.Arrow.Current()
    assertNotNil(t); assertEquals(2, t.index)
  end)
end)

test("scenario: switching to a side trip and back - card, arrow and pins follow, and your path is the one you come back to", function()
  local main = ns.MainRoutes()[1]
  local side
  for _, r in ipairs(ns.Routes()) do if r.dungeon then side = r; break end end
  if not (main and side) then return end -- the plan in the repo has no side trips: nothing to switch to
  withWorld(main, function(w)
    ns.SelectRoute(main.id, true); ns.Engine.Refresh()
    local mainStep = w:shown()
    assertNotNil(mainStep)
    w:wait(1)
    ns.SelectRoute(side.id, true); ns.Fire("FR_ROUTE_CHANGED"); w:wait(1)
    assertEquals(side, ForeverRouteData)
    local t = ns.Arrow.Current()
    if t then assertTrue(t.index <= #ns.Steps(side), "the arrow kept a step number from the other route") end
    ns.SelectRoute(main.id, true); ns.Fire("FR_ROUTE_CHANGED"); w:wait(1)
    assertEquals(main, ForeverRouteData)
    assertEquals(main.id, ns.char.routeTitle)
    assertEquals(mainStep, w:shown())
  end)
end)

test("scenario: on your leveling path, a side trip's stop right on the way is folded in; a far one waits; nothing twice", function()
  local side = { id = "special:test", title = "Special: test", special = true, dungeon = true, dungeonName = "Test pet", needsLevel = 20, sections = { { title = "x" } }, steps = {
    { id = 1, k = "accept", q = 401, name = "Near", npc = "Someone in Darkshire", m = 1431, x = 0.74, y = 0.47, r = 6, sec = 1 }, -- next to Lars
    { id = 2, k = "turnin", q = 401, name = "Near", npc = "Someone in Darkshire", m = 1431, x = 0.74, y = 0.47, r = 6, sec = 1 },
    { id = 3, k = "accept", q = 201, name = "Wolves", npc = "Lars", m = 1431, x = 0.75, y = 0.48, r = 6, sec = 1 }, -- already on the path
    { id = 4, k = "accept", q = 402, name = "Far", npc = "Takar", m = 1413, x = 0.49, y = 0.57, r = 6, sec = 1 }, -- the Barrens
  } }
  local sv = ns.DungeonRoutes
  ns.DungeonRoutes = function() return { side } end
  local route = worldRoute()
  route.choices = { { at = 4, options = {} } } -- "where next?" on the travel step
  local ok, err = pcall(ForeverRouteTest.withWorld, route, function(w)
    w:go(1431, 0.70, 0.47)
    ForeverRouteData.steps._merged = nil
    assertTrue(ns.Engine.MergeSideTrips(), "nothing was folded in")
    ns.Engine.Refresh(); w:wait(1)
    local n401, n201, n402 = 0, 0, 0
    for _, s in ipairs(ForeverRouteData.steps) do
      if s.q == 401 then n401 = n401 + 1 end
      if s.q == 201 and s.k == "accept" then n201 = n201 + 1 end
      if s.q == 402 then n402 = n402 + 1 end
    end
    assertEquals(2, n401) -- its pick-up and hand-in, on the way
    assertEquals(1, n201) -- not twice
    assertEquals(0, n402) -- the Barrens is not on this path
    -- stops went in before the travel step: its "where next?" choice moved with it, and step numbers are positions
    assertEquals("fly", ForeverRouteData.steps[route.choices[1].at].k)
    for i, s in ipairs(ForeverRouteData.steps) do assertEquals(i, s.id) end
  end)
  ns.DungeonRoutes = sv
  if not ok then error(err, 0) end
end)

test("scenario: a reload mid-quest lands on the same step (it once jumped to an unrelated pick-up)", function()
  withWorld(worldRoute(), function(w)
    w:go(1431, 0.41, 0.40)
    w:quest(201, { on = true, objectives = { { text = "Wolf slain: 3/5", finished = false, have = 3, need = 5 } } })
    assertEquals(2, w:shown())
    -- a reload: the engine forgets where it was and works it out again from the quest log
    ns.Engine.current, ns.Engine.view, ns.Engine.focus = nil, nil, nil
    ns.Fire("PLAYER_ENTERING_WORLD")
    ns.Engine.Refresh()
    assertEquals(2, w:shown())
  end)
end)

test("scenario: abandoning a quest sends you back to its pick-up", function()
  withWorld(worldRoute(), function(w)
    w:go(1431, 0.41, 0.40)
    w:quest(201, { on = true, objectives = { { text = "Wolf slain: 3/5", finished = false, have = 3, need = 5 } } })
    assertEquals(2, w:shown())
    w:quest(201, { on = false, objectives = {} }) -- abandoned
    assertEquals(1, w:shown())
  end)
end)

test("addon loaded with its frames", function()
  assertNotNil(ns)
  assertNotNil(ns.db)
  assertNotNil(ForeverRouteCard)
  assertNotNil(ForeverRouteArrow)
  assertNotNil(ForeverRouteList)
  assertNotNil(ForeverRouteOptions)
end)

test("planned paths are present and well formed", function()
  local routes = ns.Routes()
  assertTrue(#routes >= 1)
  for _, r in ipairs(routes) do
    assertType("string", r.id); assertType("string", r.title); assertType("table", ns.Steps(r))
    assertTrue(#ns.Steps(r) > ((r.branch or r.dungeon) and 3 or 50))
    local seen = {}
    for i, s in ipairs(ns.Steps(r)) do
      assertTrue(KINDS[s.k] ~= nil)
      assertEquals(i, s.id)
      assertNil(seen[s.id]); seen[s.id] = true
      assertNotNil(r.sections[s.sec])
      if s.k == "accept" or s.k == "turnin" or s.k == "obj" then assertType("number", s.q) end
      if s.x then assertType("number", s.m); assertTrue(s.x > 0 and s.x < 1 and s.y > 0 and s.y < 1) end
    end
  end
end)

test("every step of every path renders on the card, arrow and list without errors", function()
  local errors = {}
  for _, r in ipairs(ns.Routes()) do
    ns.SelectRoute(r.id, true)
    for i = 1, #ns.Steps(r) do
      ns.Engine.view = i
      local ok, err = pcall(function()
        ns.Card.Describe(ns.Steps(r)[i])
        ns.Card.Fill(); ns.Card.Layout()
        ns.Arrow.SetTarget(i, true)
      end)
      if not ok then errors[#errors + 1] = r.title .. " #" .. i .. ": " .. tostring(err) end
    end
    ns.Engine.view = nil
    local ok, err = pcall(function() ns.List.Toggle(); ns.List.Scroll(50); ns.List.Toggle() end)
    if not ok then errors[#errors + 1] = "list: " .. tostring(err) end
  end
  ns.SelectRoute(ns.Routes()[1].id, true)
  if #errors > 0 then error(#errors .. " errors, first: " .. errors[1]) end
end)

test("engine: current step follows quest state", function()
  withState({}, function()
    ForeverRouteData = miniRoute()
    assertEquals(1, ns.Engine.Compute())
    -- quest accepted: the objective is next
    ns.State.Quest = function(id) if id == 101 then return { on = true, objectives = { { text = "Wolf slain: 2/5", finished = false, have = 2, need = 5 } } } end return { on = false, objectives = {} } end
    assertEquals(2, ns.Engine.Compute())
    assertEquals(2, ns.Engine.ObjectiveFor(ForeverRouteData.steps[2]).have)
    -- objective finished -> turn-in
    ns.State.Quest = function(id) if id == 101 then return { on = true, complete = true, objectives = { { text = "Wolf slain: 5/5", finished = true, have = 5, need = 5 } } } end return { on = false, objectives = {} } end
    assertEquals(3, ns.Engine.Compute())
    -- handed in -> next quest
    ns.State.IsCompleted = function(id) return id == 101 end
    ns.State.Quest = function() return { on = false, objectives = {} } end
    assertEquals(4, ns.Engine.Compute())
  end)
end)

test("engine: turn-in with objectives left says not ready", function()
  withState({ [101] = { on = true, complete = false, objectives = { { text = "Wolf slain: 1/5", finished = false, have = 1, need = 5 } } } }, function()
    ForeverRouteData = miniRoute()
    assertEquals("notready", ns.Engine.Status(3))
    assertEquals("todo", ns.Engine.Status(2))
  end)
end)

test("engine: skipping an accept skips that quest's later steps, undo restores them", function()
  withState({}, function()
    ForeverRouteData = miniRoute()
    ns.Engine.current = 1
    ns.Engine.Skip(1)
    local K = ns.Engine.Key
    assertTrue(ns.char.skipped[K(1)]); assertTrue(ns.char.skipped[K(2)]); assertTrue(ns.char.skipped[K(3)])
    assertNil(ns.char.skipped[K(4)])
    assertEquals(4, ns.Engine.Compute())
    ns.Engine.Undo()
    assertNil(ns.char.skipped[K(1)]); assertNil(ns.char.skipped[K(3)])
    assertEquals(1, ns.Engine.Compute())
  end)
end)

test("engine: back only looks, jump forward skips and is undoable", function()
  withState({}, function()
    ForeverRouteData = miniRoute()
    ns.Engine.Refresh()
    assertEquals(1, ns.Engine.current)
    ns.Engine.Jump(4)
    assertEquals(4, ns.Engine.current)
    ns.Engine.Back()
    assertEquals(3, ns.Engine.Shown())
    assertEquals(4, ns.Engine.current) -- looking back doesn't change progress
    ns.Engine.Forward()
    assertEquals(4, ns.Engine.Shown())
    ns.Engine.Undo()
    ns.Engine.Refresh()
    assertEquals(1, ns.Engine.current)
  end)
end)

test("engine: grouped objectives at one spot", function()
  withState({ [101] = { on = true, objectives = {} }, [102] = { on = true, objectives = {} } }, function()
    local r = miniRoute()
    r.steps[2].m, r.steps[2].x, r.steps[2].y = 1436, 0.5, 0.5
    r.steps[3] = { id = 3, k = "obj", q = 102, text = "Collect 3 Fang", match = "Fang", m = 1436, x = 0.505, y = 0.5, sec = 1 }
    ForeverRouteData = r
    assertCount(1, ns.Engine.Group(2))
  end)
end)

test("bonus steps check bags and the books addon", function()
  withState({}, function()
    ForeverRouteData = { id = "b", title = "b", sections = { { title = "x" } }, steps = { { id = 1, k = "bonus", text = "loot the book X", item = 209849, book = "anatomy", sec = 1 } } }
    assertEquals("todo", ns.Engine.Status(1))
    HandyNotes_ForeverBooksCharDB = { collected = { anatomy = true } }
    assertEquals("done", ns.Engine.Status(1))
    HandyNotes_ForeverBooksCharDB = nil
  end)
end)

test("reward scoring runs on real items without errors", function()
  local evaluated = 0
  for _, id in ipairs({ 2042, 2041, 6087, 2074, 1561, 2165, 5249, 6948 }) do
    local link = select(2, ns.GetItemInfo(id)) or ("item:" .. id)
    local ok, err = pcall(ns.Quests.Evaluate, link)
    assertTrue(ok)
    evaluated = evaluated + 1
  end
  assertEquals(8, evaluated)
end)

test("snapshot captures character state", function()
  ns.State.Snapshot("test")
  local s = ns.char.snapshot
  assertNotNil(s)
  assertType("table", s.completed); assertType("table", s.log); assertType("table", s.gear)
  assertTrue((s.level or 0) > 0)
end)

test("logout snapshot: a torn-down read (no objectives, gear, skills or money) keeps the last good values", function()
  local saved = { snap = ns.char.snapshot, n = C_QuestLog.GetNumQuestLogEntries, info = C_QuestLog.GetInfo, on = C_QuestLog.IsOnQuest,
    objs = C_QuestLog.GetQuestObjectives, comp = C_QuestLog.IsComplete, link = GetInventoryItemLink, skills = GetNumSkillLines, money = GetMoney }
  local entries = { { isHeader = true, title = "Darkshore" }, { questID = 1738, title = "Heartswood" }, { questID = 143, title = "Messenger" } }
  C_QuestLog.GetNumQuestLogEntries = function() return #entries end
  C_QuestLog.GetInfo = function(i) return entries[i] end
  local ok, err = pcall(function()
    -- earlier, live: half done and finished quests, gear, skills, money
    ns.char.snapshot = { level = 21, money = 25022, gear = { [1] = 1234 }, skills = { Cooking = { 50, 75 } }, pos = { map = 1439, x = 0.4, y = 0.5 },
      log = { [1738] = { objectives = { { 0, 1, false, "0/1 Heartswood" } } }, [143] = { complete = true, objectives = {} } } }
    -- logout: the log still lists the quests, everything else reads empty
    C_QuestLog.IsOnQuest = function() return false end
    C_QuestLog.GetQuestObjectives = function() return nil end
    C_QuestLog.IsComplete = function() return nil end
    GetInventoryItemLink = function() return nil end
    GetNumSkillLines = function() return 0 end
    GetMoney = function() return 0 end
    ns.State.Invalidate()
    ns.State.Snapshot("logout")
    local s = ns.char.snapshot
    assertEquals("0/1 Heartswood", s.log[1738].objectives[1][4])
    assertTrue(s.log[143].complete)
    assertEquals(1234, s.gear[1]); assertNotNil(s.skills.Cooking)
    assertEquals(25022, s.money)
    if not ns.State.Position() then assertEquals(1439, s.pos.map) end
  end)
  ns.char.snapshot = saved.snap
  C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.IsOnQuest, C_QuestLog.GetQuestObjectives, C_QuestLog.IsComplete = saved.n, saved.info, saved.on, saved.objs, saved.comp
  GetInventoryItemLink, GetNumSkillLines, GetMoney = saved.link, saved.skills, saved.money
  ns.State.Invalidate()
  if not ok then error(err, 0) end
end)

test("logging out doesn't rebuild the route (a long plan ran past the game's script limit there)", function()
  local real, n = ns.Engine.Refresh, 0
  ns.Engine.Refresh = function(...) n = n + 1; return real(...) end
  local ok, err = pcall(ns.Fire, "PLAYER_LOGOUT")
  ns.Engine.Refresh = real
  if not ok then error(err, 0) end
  assertEquals(0, n, "route rebuilt at logout")
  assertTrue(ns.char.snapshot ~= nil, "no snapshot at logout")
end)

test("/fr options opens its window on screen", function()
  ns.Options.Open()
  local host = ForeverRouteOptionsWindow
  assertTrue(host and host:IsShown(), "the window didn't open")
  assertTrue(host:GetNumPoints() > 0, "the window has no position (it went nowhere)")
  assertEquals("DIALOG", host:GetFrameStrata())
  host:Hide()
end)

test("finishing a zone isn't announced as a path switch: the same path with that zone dropped off the front is quiet", function()
  local saved = ns.char.routeLegs
  ns.char.routeLegs = "Westfall > Redridge Mountains > Duskwood > Wetlands"
  local function legs(s) return { meta = { legs = s } } end
  local ok, err = pcall(function()
    assertEquals(nil, ns.PathSwitchNote("old", legs("Redridge Mountains > Duskwood > Wetlands > Ashenvale")), "Westfall done: not a switch")
    assertEquals(nil, ns.PathSwitchNote("old", legs("Duskwood > Wetlands > Ashenvale")), "Westfall and Redridge done: not a switch")
    assertTrue(ns.PathSwitchNote("old", legs("Ashenvale > Darkshore > Stonetalon Mountains")) ~= nil, "a different path: said")
  end)
  ns.char.routeLegs = saved
  if not ok then error(err, 0) end
end)

test("auto-fly: at a flight master it takes the flight the card's trip needs - only when on, never with Shift, only a path you have", function()
  local sv = { trip = ns.Engine.lastTrip, step = ns.Engine.lastTripStep, shown = ns.Engine.Shown, data = ForeverRouteData, on = ns.db.autoFly,
    num = NumTaxiNodes, name = TaxiNodeName, typ = TaxiNodeGetType, take = TakeTaxiNode, shift = IsShiftKeyDown, after = C_Timer.After }
  local took
  local ok, err = pcall(function()
    local step = { k = "turnin", q = 1, name = "Q", m = 1424, x = 0.5, y = 0.5 }
    ForeverRouteData = { steps = { step } }
    ns.Engine.Shown = function() return 1 end
    ns.Engine.lastTrip, ns.Engine.lastTripStep = { { how = "ride" }, { how = "fly", toTaxi = "Southshore, Hillsbrad" } }, step
    local nodes = { { "Stormwind, Elwynn", "CURRENT" }, { "Southshore, Hillsbrad", "REACHABLE" }, { "Refuge Pointe, Arathi", "REACHABLE" } }
    NumTaxiNodes = function() return #nodes end
    TaxiNodeName = function(i) return nodes[i][1] end
    TaxiNodeGetType = function(i) return nodes[i][2] end
    TakeTaxiNode = function(i) took = i end
    C_Timer.After = function(_, f) f() end
    IsShiftKeyDown = function() return false end
    ns.db.autoFly = false
    ns.Fire("TAXIMAP_OPENED"); assertEquals(nil, took, "off: it flew")
    ns.db.autoFly = true
    IsShiftKeyDown = function() return true end
    ns.Fire("TAXIMAP_OPENED"); assertEquals(nil, took, "Shift held: it flew")
    IsShiftKeyDown = function() return false end
    ns.Fire("TAXIMAP_OPENED"); assertEquals(2, took, "it didn't take the trip's flight")
    took = nil; nodes[2][2] = "DISTANT"
    ns.Fire("TAXIMAP_OPENED"); assertEquals(nil, took, "a flight path you don't have")
    took = nil; nodes[2][2] = "REACHABLE"; ns.Engine.lastTripStep = {}
    ns.Fire("TAXIMAP_OPENED"); assertEquals(nil, took, "a trip for another step than the card's")
  end)
  ns.Engine.lastTrip, ns.Engine.lastTripStep, ns.Engine.Shown, ForeverRouteData, ns.db.autoFly = sv.trip, sv.step, sv.shown, sv.data, sv.on
  NumTaxiNodes, TaxiNodeName, TaxiNodeGetType, TakeTaxiNode, IsShiftKeyDown, C_Timer.After = sv.num, sv.name, sv.typ, sv.take, sv.shift, sv.after
  if not ok then error(err, 0) end
end)

test("options sliders don't fire settings on open", function()
  local fired = 0
  ns.On("FR_SETTINGS", function() fired = fired + 1 end)
  ForeverRouteOptions:Show(); ForeverRouteOptions:Hide(); ForeverRouteOptions:Show()
  assertEquals(0, fired)
end)

test("route switching keeps separate progress", function()
  local routes = ns.Routes()
  if #routes < 2 then return end
  ns.SelectRoute(routes[1].id, true)
  ns.char.skipped["test:999999"] = true
  ns.SelectRoute(routes[2].id, true)
  assertNil(ns.char.skipped["test:999999"])
  ns.SelectRoute(routes[1].id, true)
  assertTrue(ns.char.skipped["test:999999"])
  ns.char.skipped["test:999999"] = nil
end)

test("demo mode starts and stops cleanly", function()
  local before = ForeverRouteData
  ns.Demo.Start()
  assertTrue(ns.Demo.active)
  assertEquals("demo", ForeverRouteData.id)
  ns.Demo.Stop()
  assertFalse(ns.Demo.active)
  assertEquals(before, ForeverRouteData)
end)

test("zone choices: offered at the boundary, switching to a branch and back", function()
  local savedRoutes, savedData, savedChar = ForeverRouteRoutes, ForeverRouteData, ns.char
  ns.char = { skipped = {}, manualDone = {}, history = {}, progress = {} }
  local function steps(zone) return { { id = 1, k = "goto", text = "a", sec = 1 }, { id = 2, k = "goto", text = "b", sec = 1 }, { id = 3, k = "fly", dest = zone, to = 1431, text = zone, sec = 1 }, { id = 4, k = "goto", text = "c", sec = 1 } } end
  ForeverRouteRoutes = {
    { id = "path:A", title = "A", meta = {}, sections = { { title = "x" } }, steps = steps("Duskwood"),
      choices = { { at = 3, level = 21, options = { { zone = "Duskwood", xph = 20000, next = "Duskwood > Wetlands", main = true }, { zone = "Wetlands", xph = 18000, next = "Wetlands > Duskwood", route = "branch:A:2:Wetlands" } } } } },
    { id = "branch:A:2:Wetlands", title = "Wetlands instead", branch = true, parent = "path:A", branchAt = 3, meta = {}, sections = { { title = "x" } }, steps = steps("Wetlands") },
  }
  local ok, err = pcall(function()
    assertCount(1, ns.MainRoutes())
    ns.SelectRoute("path:A", true)
    assertNil(ns.ChoiceFor(2))
    local c, owner, key = ns.ChoiceFor(3)
    assertNotNil(c); assertEquals("path:A", owner.id)
    -- the card shows the options on that step
    ns.Engine.view = 3; ns.Card.Fill(); ns.Card.Layout(); ns.Engine.view = nil
    ns.TakeChoice(c.options[2], owner, key)
    assertEquals("branch:A:2:Wetlands", ForeverRouteData.id)
    -- the choice is made, but the branch's first step still lets you change your mind
    assertNotNil(ns.ChoiceFor(1))
    ns.char.choices[key] = nil
    local c2, owner2, key2 = ns.ChoiceFor(1)
    ns.TakeChoice(c2.options[1], owner2, key2)
    assertEquals("path:A", ForeverRouteData.id)
    assertNotNil(ns.ChoiceFor(3)) -- still shown, with the pick marked
  end)
  ForeverRouteRoutes, ns.char = savedRoutes, savedChar
  ForeverRouteData = savedData
  ns.SelectRoute(ns.Routes()[1].id, true)
  if not ok then error(err, 0) end
end)

test("path chooser draws every path and can switch", function()
  local routes = ns.MainRoutes()
  assertNotNil(ForeverRoutePaths)
  ns.Paths.Toggle(); assertTrue(ForeverRoutePaths:IsShown())
  if #routes > 1 then
    ns.SelectRoute(routes[2].id, true); ns.Paths.Draw()
    ns.SelectRoute(routes[1].id, true); ns.Paths.Draw()
  end
  ns.Paths.Toggle(); assertFalse(ForeverRoutePaths:IsShown())
end)

test("flight masters come from the database (Stormwind gryphon master)", function()
  assertNotNil(ns.FLIGHT)
  local sw = ns.FLIGHT[1453]
  assertNotNil(sw)
  assertEquals("Dungar Longdrink", sw[1][3])
  assertTrue(math.abs(sw[1][1] - 0.713) < 0.01 and math.abs(sw[1][2] - 0.722) < 0.01)
end)

test("out of order: a travel step you went past completes itself", function()
  withState({}, function()
    ForeverRouteData = { id = "o", title = "o", sections = { { title = "x" } }, steps = {
      { id = 1, k = "goto", text = "Go to the farm", sec = 1 },
      { id = 2, k = "turnin", q = 201, name = "A", sec = 1 },
      { id = 3, k = "turnin", q = 202, name = "B", sec = 1 },
      { id = 4, k = "accept", q = 203, name = "C", sec = 1 },
    } }
    assertEquals(1, ns.Engine.Compute())
    -- quests merely in the log are not progress: the goto stands
    ns.State.OnQuest = function(id) return id == 201 or id == 202 end
    assertEquals("todo", ns.Engine.Status(1))
    -- one handed in: still stands
    ns.State.IsCompleted = function(id) return id == 201 end
    assertEquals("todo", ns.Engine.Status(1))
    -- both handed in (done out of order): the goto is passed, the next open step is current
    ns.State.IsCompleted = function(id) return id == 201 or id == 202 end
    assertEquals("done", ns.Engine.Status(1))
    assertEquals(4, ns.Engine.Compute())
  end)
end)

test("errors are logged once with a count and context", function()
  local saved = ForeverRouteDB.log
  ForeverRouteDB.log = {}
  local guarded = ns.Guard("test", function() error("boom") end)
  local oldHandler = geterrorhandler(); seterrorhandler(function() end)
  guarded(); guarded(); guarded(); guarded()
  seterrorhandler(oldHandler)
  assertCount(1, ForeverRouteDB.log)
  assertEquals(4, ForeverRouteDB.log[1].count)
  assertEquals("test", ForeverRouteDB.log[1].where)
  assertNotNil(ForeverRouteDB.log[1].version)
  ForeverRouteDB.log = saved
end)

test("arrow driver runs a frame without errors", function()
  local saved = ForeverRouteDB.log
  ForeverRouteDB.log = {}
  ns.SelectRoute(ns.MainRoutes()[1].id, true)
  for i = 1, 5 do ns.Arrow.SetTarget(i + 1, true) end
  assertCount(0, ForeverRouteDB.log)
  ForeverRouteDB.log = saved
end)

test("never accepts or hands in quests by itself unless you turn it on (off by default)", function()
  local calls = 0
  local saved = { AcceptQuest = AcceptQuest, CompleteQuest = CompleteQuest, GetQuestReward = GetQuestReward }
  AcceptQuest = function() calls = calls + 1 end; CompleteQuest = AcceptQuest; GetQuestReward = AcceptQuest
  for _, ev in ipairs({ "GOSSIP_SHOW", "QUEST_GREETING", "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE" }) do ns.Fire(ev) end
  AcceptQuest, CompleteQuest, GetQuestReward = saved.AcceptQuest, saved.CompleteQuest, saved.GetQuestReward
  assertEquals(0, calls)
  assertTrue(ns.db.autoQuest ~= true, "automation is on by default")
end)

test("/fr options opens the options in its own window", function()
  ns.Fire("FR_OPEN_OPTIONS")
  assertNotNil(ForeverRouteOptionsWindow)
  assertTrue(ForeverRouteOptionsWindow:IsShown())
  assertTrue(ForeverRouteOptions:IsVisible())
  ns.Fire("FR_OPEN_OPTIONS")
  assertFalse(ForeverRouteOptionsWindow:IsShown())
end)

test("dungeon routes: a side trip that leaves your path alone", function()
  local d = ns.DungeonRoutes()
  assertTrue(#d >= 1)
  for _, r in ipairs(ns.MainRoutes()) do assertNil(r.dungeon) end
  local main = ns.MainRoutes()[1]
  ns.SelectRoute(main.id, true)
  ns.char.skipped["test:424242"] = true -- stands in for progress on the path
  ns.EnterDungeonRoute(d[1].id)
  assertTrue(ForeverRouteData.dungeon)
  assertEquals(main.id, ns.char.returnTo)
  assertNil(ns.char.skipped["test:424242"])
  ns.Fire("FR_TOGGLE_DUNGEONS"); assertTrue(ForeverRouteDungeons:IsShown()); ns.Fire("FR_TOGGLE_DUNGEONS")
  ns.Card.Fill(); ns.Card.Layout()
  assertTrue(ForeverRouteCard.home:IsShown())
  ns.LeaveDungeonRoute()
  assertEquals(main.id, ForeverRouteData.id)
  assertTrue(ns.char.skipped["test:424242"])
  ns.char.skipped["test:424242"] = nil
end)

test("abandoning from the quest log check drops the quest: the card does not go back to its pick-up; taking it again brings it back", function()
  local saved = { sel = C_QuestLog.SetSelectedQuest, set = C_QuestLog.SetAbandonQuest, ab = C_QuestLog.AbandonQuest }
  local abandoned = 0
  C_QuestLog.SetSelectedQuest = function() end; C_QuestLog.SetAbandonQuest = function() end; C_QuestLog.AbandonQuest = function() abandoned = abandoned + 1 end
  local ok, err = pcall(withState, {}, function()
    ForeverRouteData = { id = "lca", title = "lca", sections = { { title = "x" } }, steps = {
      { id = 1, k = "accept", q = 311, name = "Gray Later", sec = 1 },
      { id = 2, k = "accept", q = 312, name = "Next", sec = 1 },
      { id = 3, k = "obj", q = 311, text = "Kill 5 Wolf", match = "Wolf", sec = 1 },
      { id = 4, k = "turnin", q = 311, name = "Gray Later", sec = 1 },
    } }
    local inLog = { [311] = true }
    ns.State.OnQuest = function(id) return inLog[id] or false end
    ns.State.Quest = function(id) if inLog[id] then return { on = true, objectives = { { text = "Wolf slain: 1/5", finished = false, have = 1, need = 5 } } } end return { on = false, objectives = {} } end
    ns.Engine.Refresh()
    assertEquals(2, ns.Engine.current)
    ns.LogCheck.Abandon(311, "Gray Later", "gray by then")
    inLog[311] = nil
    ns.Engine.Refresh()
    assertEquals(1, abandoned)
    assertEquals(2, ns.Engine.current) -- not back to step 1
    assertTrue(ns.char.nope[311])
    ns.Fire("QUEST_ACCEPTED", 311)  -- you took it again: you want it
    assertNil(ns.char.nope[311])
    ns.Engine.Refresh()
    assertEquals(1, ns.Engine.current)
  end)
  C_QuestLog.SetSelectedQuest, C_QuestLog.SetAbandonQuest, C_QuestLog.AbandonQuest = saved.sel, saved.set, saved.ab
  if not ok then error(err, 0) end
end)

test("every quest in every route has an accept step before its turn-in (survives abandoning)", function()
  local missing = {}
  for _, r in ipairs(ns.Routes()) do
    local accepted = {}
    for _, s in ipairs(ns.Steps(r)) do
      if s.k == "accept" then accepted[s.q] = true end
      if s.k == "turnin" and not accepted[s.q] then missing[#missing + 1] = r.title .. ": " .. tostring(s.name) end
    end
  end
  if #missing > 0 then error(#missing .. " turn-ins without an accept, first: " .. missing[1]) end
end)

test("abandoning a quest sends you back to pick it up", function()
  withState({}, function()
    ForeverRouteData = { id = "a", title = "a", sections = { { title = "x" } }, steps = {
      { id = 1, k = "accept", q = 301, name = "A", sec = 1 },
      { id = 2, k = "obj", q = 301, text = "Kill 5 Wolf", match = "Wolf", sec = 1 },
      { id = 3, k = "turnin", q = 301, name = "A", sec = 1 },
    } }
    -- half done in the log: accept is done, the objective is current
    ns.State.OnQuest = function(id) return id == 301 end
    ns.State.Quest = function(id) if id == 301 then return { on = true, objectives = { { text = "Wolf slain: 2/5", finished = false, have = 2, need = 5 } } } end return { on = false, objectives = {} } end
    assertEquals(2, ns.Engine.Compute())
    -- abandoned: back to the accept step
    ns.State.OnQuest = function() return false end
    ns.State.Quest = function() return { on = false, objectives = {} } end
    assertEquals(1, ns.Engine.Compute())
  end)
end)

test("a travel step to the zone you're already in completes by itself", function()
  withState({}, function()
    ForeverRouteData = { id = "t", title = "t", sections = { { title = "x" } }, steps = {
      { id = 1, k = "fly", dest = "Stormwind City", to = 1453, text = "Stormwind City", sec = 1 },
      { id = 2, k = "accept", q = 401, name = "A", sec = 1 },
    } }
    local saved = ns.Engine.InZone
    ns.Engine.InZone = function(to) return to == 1453 end
    ns.Engine.Refresh()
    ns.Engine.InZone = saved
    assertEquals(2, ns.Engine.current)
  end)
end)

test("show on map opens the world map at the step", function()
  ns.SelectRoute(ns.MainRoutes()[1].id, true)
  local r = ForeverRouteData
  local i; for k, s in ipairs(r.steps) do if s.k == "turnin" and s.m then i = k; break end end
  assertNotNil(i)
  local saved = ForeverRouteDB.log; ForeverRouteDB.log = {}
  local old = geterrorhandler(); seterrorhandler(function() end)
  ns.ShowOnMap(i)
  seterrorhandler(old)
  assertEquals(i, ns.Engine.Shown()) -- the pins follow the step shown
  -- (the simulator has no map art, so Blizzard's map canvas can fail there; in game it opens on the step's zone)
  ForeverRouteDB.log = saved
  ns.Engine.view = nil
  if WorldMapFrame and WorldMapFrame:IsShown() then HideUIPanel(WorldMapFrame) end
end)

test("flight path and hearth steps notice what you already have", function()
  withState({}, function()
    ForeverRouteData = { id = "f", title = "f", sections = { { title = "x" } }, steps = {
      { id = 1, k = "fp", npc = "Ariena Stormfeather", zone = "Redridge Mountains", sec = 1 },
      { id = 2, k = "bind", npc = "Innkeeper Allison", zone = "Stormwind", sec = 1 },
      { id = 3, k = "accept", q = 501, name = "A", sec = 1 },
    } }
    local savedTaxi = ns.State.knownTaxi
    ns.State.knownTaxi = { ["Lakeshire, Redridge"] = true }
    assertEquals("done", ns.Engine.Status(1))
    ns.State.knownTaxi = { ["Sentinel Hill, Westfall"] = true }
    assertEquals("todo", ns.Engine.Status(1))
    ns.State.knownTaxi = savedTaxi
    local savedBind = GetBindLocation
    GetBindLocation = function() return "Stormwind City" end
    assertEquals("done", ns.Engine.Status(2))
    GetBindLocation = function() return "Sentinel Hill" end
    assertEquals("todo", ns.Engine.Status(2))
    GetBindLocation = savedBind
  end)
end)

test("a step you're too low for, or a quest not in your log, doesn't hold up the route", function()
  withState({}, function()
    ForeverRouteData = { id = "w", title = "w", sections = { { title = "x" } }, steps = {
      { id = 1, k = "accept", q = 601, name = "High", minLevel = 99, sec = 1 },
      { id = 2, k = "turnin", q = 602, name = "Gone", sec = 1 },
      { id = 3, k = "accept", q = 603, name = "Doable", sec = 1 },
    } }
    assertEquals("wait", ns.Engine.Status(1))
    assertEquals("blocked", ns.Engine.Status(2))
    assertEquals(3, ns.Engine.Compute())
    -- nothing else left: the waiting step is shown
    ns.char.manualDone[ns.Engine.Key(3)] = true
    assertEquals(1, ns.Engine.Compute())
  end)
end)

test("train and bonus steps you went past don't hold up the route", function()
  withState({}, function()
    ForeverRouteData = { id = "b", title = "b", sections = { { title = "x" } }, steps = {
      { id = 1, k = "train", text = "level 18 spells", sec = 1 },
      { id = 2, k = "bonus", text = "loot a book", item = 999999, sec = 1 },
      { id = 3, k = "turnin", q = 701, name = "A", sec = 1 },
      { id = 4, k = "turnin", q = 702, name = "B", sec = 1 },
      { id = 5, k = "accept", q = 703, name = "C", sec = 1 },
    } }
    assertEquals(1, ns.Engine.Compute())
    ns.State.IsCompleted = function(id) return id == 701 or id == 702 end
    assertEquals(5, ns.Engine.Compute())
  end)
end)

test("ticks stay on the same step when the route is regenerated", function()
  withState({}, function()
    local function route(extra)
      local st = { { k = "fly", dest = "Westfall", to = 1436, text = "Westfall", sec = 1 } }
      if extra then table.insert(st, 1, { k = "goto", text = "A new first step", sec = 1 }) end
      table.insert(st, { k = "obj", q = 155, text = "Escort The Defias Traitor", sec = 1 })
      for i, s in ipairs(st) do s.id = i end
      return { id = "r", title = "r", sections = { { title = "x" } }, steps = st }
    end
    ForeverRouteData = route(false)
    ns.char.manualDone[ns.Engine.Key(1)] = true -- the fly step
    ForeverRouteData = route(true)            -- regenerated: everything shifted by one
    assertEquals("done", ns.Engine.Status(2))  -- the fly step, now number 2
    assertTrue(ns.Engine.Status(3) ~= "done")  -- the escort is not ticked by mistake
    -- and old number-keyed ticks are dropped when a route is selected
    local p = { skipped = { [3] = true }, manualDone = { [8] = true, ["fly:x"] = true }, history = { { kind = "done", ids = { 8 } } } }
    local savedRoutes = ForeverRouteRoutes
    ns.char.progress = { r = p }; ForeverRouteRoutes = { ForeverRouteData }
    ns.SelectRoute("r", true)
    ForeverRouteRoutes = savedRoutes
    assertNil(p.manualDone[8]); assertNil(p.skipped[3]); assertTrue(p.manualDone["fly:x"]); assertCount(0, p.history)
  end)
end)

test("routed arrow: follows the path a look-ahead in front of you, carries on from a shortcut, knows when you're off it", function()
  local follow = ns.Arrow._follow
  -- an L-shaped path from (0,0): east to a corner at (100,0), then north to the target at (100,100), 20 yd up
  local function P() return { pts = { { 0, 0, 0 }, { 100, 0, 0 }, { 100, 100, 20 } }, rem = { 200, 100, 0 }, cursor = 1, z0 = 0, z1 = 20 } end
  local function far(a, x, y) return math.sqrt((a[1] - x) ^ 2 + (a[2] - y) ^ 2) end
  local p = P()
  local aim, walk, off = follow(p, 10, 2, 10)        -- on the first leg: the spot on that leg 10 yd from you - not the
  assertEquals(0, aim[2])                            -- far corner (a small step aside swung the arrow), never diagonally across
  assertTrue(math.abs(far(aim, 10, 2) - 10) < 0.01 and aim[1] > 10, "the spot is at " .. aim[1] .. ", " .. aim[2])
  assertTrue(math.abs(walk - 190) < 2)
  assertTrue(off < 3)
  local c = P()
  local before = follow(c, 80, 0, 10)                -- 20 yd before the corner: still straight on
  assertEquals(0, before[2]); assertTrue(math.abs(before[1] - 90) < 0.01)
  local atCorner = follow(c, 96, 0, 10)              -- 4 yd before it the spot is already round the corner, 10 yd from you:
  assertEquals(100, atCorner[1])                     -- the arrow has begun to turn, and turns on as you walk
  assertTrue(math.abs(far(atCorner, 96, 0) - 10) < 0.01 and atCorner[2] > 8 and atCorner[2] < 10, "the spot is at " .. atCorner[1] .. ", " .. atCorner[2])
  local last, swing = 0, 0
  for x = 80, 100, 0.5 do                            -- walking up to the corner the arrow turns in steps: the biggest
    local a = follow(c, x, 0, 10)                    -- (the moment the spot rounds the corner) a fifth of the corner,
    local dir = math.atan2(a[2], a[1] - x)           -- where it used to be all 90 degrees at once
    swing = math.max(swing, math.abs(dir - last)); last = dir
  end
  assertTrue(swing < math.rad(20) and math.abs(last - math.pi / 2) < 0.01, "the arrow jumps " .. math.floor(math.deg(swing)) .. " degrees in half a yard at the corner")
  local aim2 = follow(p, 98, 60, 10)                 -- took a shortcut and came out on the second leg: carry on from there
  assertEquals(100, aim2[1]); assertTrue(aim2[2] > 60 and aim2[2] <= 70.1)
  assertEquals(2, p.cursor)
  local aim3 = follow(p, 100, 10, 10)                -- doesn't go back to the first leg once past it
  assertEquals(100, aim3[1]); assertTrue(aim3[2] > 10)
  local aim4, _, off4 = follow(P(), 40, 60, 10)      -- wandered off into the field: back onto the path at a slant,
  assertTrue(off4 > 45)                              -- ahead of where you left it, never across to the other leg
  assertEquals(0, aim4[2]); assertTrue(aim4[1] > 60 and aim4[1] <= 100, "the spot is at " .. aim4[1] .. ", " .. aim4[2])
  local aim5, walk5 = follow(P(), 100, 95, 10)       -- the end of the path within reach: the end itself
  assertEquals(100, aim5[1]); assertEquals(100, aim5[2]); assertTrue(math.abs(walk5 - 5) < 0.01)
  local _, _, _, z = follow(P(), 100, 50)            -- halfway up the second leg
  assertTrue(z > 5 and z < 15)
end)

test("quest log check sorts your log and only abandons on request", function()
  local saved = { GetNumQuestLogEntries = C_QuestLog.GetNumQuestLogEntries, GetInfo = C_QuestLog.GetInfo, AbandonQuest = C_QuestLog.AbandonQuest }
  local entries = { { isHeader = true, title = "Loch Modan" }, { questID = 987654, title = "Far Away Quest", level = 17 }, { isHeader = true, title = "Westfall" } }
  local routeQ; for _, s in ipairs(ForeverRouteData.steps) do if s.q and s.k == "turnin" then routeQ = s; break end end
  entries[#entries + 1] = { questID = routeQ.q, title = routeQ.name, level = routeQ.level or UnitLevel("player") }
  local abandoned = 0
  C_QuestLog.GetNumQuestLogEntries = function() return #entries end
  C_QuestLog.GetInfo = function(i) return entries[i] end
  C_QuestLog.AbandonQuest = function() abandoned = abandoned + 1 end
  local ok, err = pcall(function()
    local list = ns.LogCheck.Classify()
    assertCount(2, list)
    assertEquals("drop", list[1].verdict); assertEquals(987654, list[1].e.id)
    assertEquals("keep", list[2].verdict)
    ns.LogCheck.Toggle(); ns.LogCheck.Draw(); ns.LogCheck.Toggle()
    assertEquals(0, abandoned) -- nothing happens without a click + confirm
  end)
  C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.AbandonQuest = saved.GetNumQuestLogEntries, saved.GetInfo, saved.AbandonQuest
  if not ok then error(err, 0) end
end)

test("walking trails: every 3 yd in cities and indoors, every 12 yd outdoors, on foot", function()
  local saved = { pos = ns.State.Position, wp = LibStub("HereBeDragons-2.0").GetPlayerWorldPosition, t = GetTime, trails = ForeverRouteDB.trailData }
  ForeverRouteDB.trails = true -- the on/off setting must not get in the way of the data
  local byChar = ForeverRouteByChar; ForeverRouteByChar = { ["Someone-Realm"] = function() end } -- (recorded only with the companion)
  local HBD = LibStub("HereBeDragons-2.0")
  ForeverRouteDB.trailData = {}
  local map, x, clock = 1453, 0.5, 100
  ns.State.Position = function() return map, x, 0.5 end
  HBD.GetPlayerWorldPosition = function() return x * 1000, 0, 0 end
  GetTime = function() return clock end
  saved.indoors = IsIndoors
  local inside = false
  IsIndoors = function() return inside end
  local ok, err = pcall(function()
    for k = 1, 10 do x = 0.5 + k * 0.004; clock = clock + 1; ns.Trails._tick() end   -- 4 yd steps in Stormwind
    x = x + 0.001; clock = clock + 1; ns.Trails._tick()                              -- 1 yd: not recorded
    map = 1436; clock = clock + 1; ns.Trails._tick()                                 -- left the city: trail saved
    assertNotNil(ForeverRouteDB.trailData[1453])
    assertCount(1, ForeverRouteDB.trailData[1453])
    local n = select(2, ForeverRouteDB.trailData[1453][1]:gsub(";", ";")) + 1
    assertEquals(10, n)
    for k = 1, 10 do x = 0.2 + k * 0.004; clock = clock + 1; ns.Trails._tick() end    -- out in Westfall: every 12 yd
    ns.Trails._flush()
    assertNotNil(ForeverRouteDB.trailData[1436])
    local outdoor = select(2, ForeverRouteDB.trailData[1436][1]:gsub(";", ";")) + 1    -- about every 12 yd of 40
    assertTrue(outdoor >= 3 and outdoor <= 4, "outdoor points: " .. outdoor)
    inside = true                                                                    -- into the Westfall inn: fine again
    for k = 1, 5 do x = 0.3 + k * 0.004; clock = clock + 1; ns.Trails._tick() end
    inside = false; x = x + 0.004; clock = clock + 1; ns.Trails._tick()               -- back outside: that trail saved
    assertCount(2, ForeverRouteDB.trailData[1436])
    assertEquals(5, select(2, ForeverRouteDB.trailData[1436][2]:gsub(";", ";")) + 1)
  end)
  IsIndoors = saved.indoors
  ns.State.Position, HBD.GetPlayerWorldPosition, GetTime, ForeverRouteDB.trailData = saved.pos, saved.wp, saved.t, saved.trails; ForeverRouteByChar = byChar
  if not ok then error(err, 0) end
end)

test("the dungeon run step is done while you're inside that dungeon", function()
  -- (on the quest done inside: a run for a quest you don't have is passed)
  withState({ [166] = { on = true, objectives = { { text = "Head of VanCleef: 0/1", finished = false } } } }, function()
    ns.State.OnQuest = function(id) return id == 166 end
    ns.char.ranRun = nil
    ForeverRouteData = { id = "d", title = "d", sections = { { title = "x" } }, steps = {
      { id = 1, k = "goto", text = "Run The Deadmines", m = 1436, x = 0.426, y = 0.718, r = 25, sec = 1 },
      { id = 2, k = "obj", q = 166, text = "Collect Head of VanCleef (in The Deadmines)", sec = 1 },
    } }
    local sv = { IsInInstance = IsInInstance, GetInstanceInfo = GetInstanceInfo }
    IsInInstance = function() return false end
    assertEquals("todo", ns.Engine.Status(1))
    IsInInstance = function() return true, "party" end
    GetInstanceInfo = function() return "The Deadmines", "party" end
    assertEquals("done", ns.Engine.Status(1))
    GetInstanceInfo = function() return "Wailing Caverns", "party" end
    assertEquals("todo", ns.Engine.Status(1))
    IsInInstance, GetInstanceInfo = sv.IsInInstance, sv.GetInstanceInfo
  end)
end)

test("the target button is on the card's layer and targets the NPC by name", function()
  assertNotNil(ForeverRouteTargetButton)
  assertEquals(ForeverRouteCard:GetFrameStrata(), ForeverRouteTargetButton:GetFrameStrata())
  assertEquals("macro", ForeverRouteTargetButton:GetAttribute("type"))
  local s = { k = "turnin", q = 1, name = "x", npc = "Gryan Stoutmantle", sec = 1 }
  ns.Card.SetButtons(s)
  local m = ForeverRouteTargetButton:GetAttribute("macrotext") or ""
  assertTrue(m:find("/targetexact Gryan Stoutmantle", 1, true) ~= nil)
end)

test("the card nudges you to drop quests you won't do", function()
  local saved = { n = C_QuestLog.GetNumQuestLogEntries, i = C_QuestLog.GetInfo }
  local e = { { isHeader = true, title = "Loch Modan" }, { questID = 987654, title = "Far Away Quest", level = 12 } }
  C_QuestLog.GetNumQuestLogEntries = function() return #e end
  C_QuestLog.GetInfo = function(k) return e[k] end
  local ok, err = pcall(function()
    ns.SelectRoute(ns.MainRoutes()[1].id, true)
    ns.Fire("FR_STATE")
    -- hovering the card brings the controls up where the link sits: the link moves to the left and stays clickable
    -- (it used to hide, so the mouse on its way to it made it vanish - tester)
    local c = ForeverRouteCard
    assertTrue(c.dropWanted, "the far-away quest should show the won't-do link")
    do
      ns.Card.Hover(true)
      assertTrue(c.drop:IsShown(), "the won't-do link hid while you hover the card")
      local p = { c.drop:GetPoint(1) }
      assertEquals("LEFT", p[1])
      ns.Card.PlaceDrop(false)
      assertTrue(c.drop:IsShown())
      assertEquals("TOPRIGHT", ({ c.drop:GetPoint(1) })[1])
    end
  end)
  C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo = saved.n, saved.i
  if not ok then error(err, 0) end
end)

test("camping and profession quests are kept; Keep protects any quest", function()
  local saved = { n = C_QuestLog.GetNumQuestLogEntries, i = C_QuestLog.GetInfo }
  local e = { { isHeader = true, title = "Camping" }, { questID = 900001, title = "Camping 101: First Aid", level = 6 },
    { isHeader = true, title = "Loch Modan" }, { questID = 900002, title = "Far Away Quest", level = 12 } }
  C_QuestLog.GetNumQuestLogEntries = function() return #e end
  C_QuestLog.GetInfo = function(k) return e[k] end
  local ok, err = pcall(function()
    local v = {}; for _, x in ipairs(ns.LogCheck.Classify()) do v[x.e.id] = x.verdict end
    assertEquals("keep", v[900001]); assertEquals("drop", v[900002])
    ns.char.keepQuests = { [900002] = true }
    v = {}; for _, x in ipairs(ns.LogCheck.Classify()) do v[x.e.id] = x.verdict end
    assertEquals("keep", v[900002])
    ns.char.keepQuests = nil
  end)
  C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo = saved.n, saved.i
  if not ok then error(err, 0) end
end)

test("no Blizzard globals are overwritten (taint)", function()
  if not issecurevariable then return end
  -- (GetTime, UnitLevel, C_QuestLog are swapped by other tests on purpose, so they are not checked here)
  for _, name in ipairs({ "StaticPopupDialogs", "UIParent", "GameTooltip", "WorldMapFrame", "SetCVar", "UISpecialFrames", "ChatFrame_AddMessageEventFilter" }) do
    local secure, by = issecurevariable(name)
    if secure == false then error(name .. " was overwritten by " .. tostring(by)) end
  end
end)

test("asking for a starting zone: saved, shown, and the path is picked once it arrives", function()
  local savedPlan, savedRoutes = ForeverRoutePlan, ForeverRouteRoutes
  ForeverRoutePlan = { zones = { { name = "Redridge Mountains", xph = 28017, turnins = 23 } }, later = { "Ashenvale" } }
  ns.Paths.Toggle(); ns.Paths.Request("Ashenvale")
  assertEquals("Ashenvale", ns.char.requestZone)
  ns.Paths.Draw(); ns.Paths.Toggle()
  ns.Paths.Request(nil); assertNil(ns.char.requestZone)
  ForeverRoutePlan, ForeverRouteRoutes = savedPlan, savedRoutes
end)

test("level-up notice: every ding says what's new - spells, best zones, and if another zone clearly beats yours", function()
  local savedPlan, routeBefore = ForeverRoutePlan, ForeverRouteData
  local savedLevel, savedPos = UnitLevel, ns.State.Position
  ForeverRoutePlan = { level = 19, zones = { { name = "Redridge Mountains", xph = 26000 }, { name = "Duskwood", xph = 18000 } },
    ahead = { [20] = { { name = "Redridge Mountains", xph = 31000 }, { name = "Darkshore", xph = 17000 }, { name = "Duskwood", xph = 20000 } } } }
  local ok, err = pcall(function()
    UnitLevel = function() return 20 end
    ns.char.offerDismissed = nil; ns.char.dingLevel = nil
    -- same best zones as at 19 (your case): still a line - spells to train and the ranking, yours marked
    local text, better = ns.Offers.Summary(20)
    assertTrue(text:find("new spells to train", 1, true) ~= nil)
    assertTrue(text:find("best zones now:", 1, true) ~= nil)
    local lv, info = ns.Offers.Current(); assertEquals(20, lv); assertNotNil(info)
    ns.Card.Fill(); ns.Card.Layout(); assertTrue(ForeverRouteCard.offer:IsShown())
    -- in Duskwood, Redridge (31k vs 20k) clearly beats it
    ForeverRouteData = { id = "t", steps = { { k = "accept", q = 1, zone = "Duskwood", m = 1431, x = 0.5, y = 0.5, sec = 1 } } }
    ns.Engine.Refresh()
    local _, b2 = ns.Offers.Summary(20)
    assertNotNil(b2); assertEquals("Redridge Mountains", b2.name)
    ns.Offers.Dismiss(); assertNil((ns.Offers.Current()))
  end)
  UnitLevel = savedLevel; ns.State.Position = savedPos; ForeverRoutePlan = savedPlan; ForeverRouteData = routeBefore; ns.char.offerDismissed = nil
  ns.Engine.Refresh()
  if not ok then error(err, 0) end
end)
test("inside an objective's area the card says so and the path line hides", function()
  ns.Fire("FR_DISTANCE", 78, true)
  assertTrue((ForeverRouteCard.cur.dist:GetText() or ""):find("in the area", 1, true) ~= nil)
  ns.Fire("FR_DISTANCE", 78, false)
  assertEquals("78 yd", ForeverRouteCard.cur.dist:GetText())
  ns.Fire("FR_ARRIVED", ns.Engine.Shown(), true); ns.Fire("FR_ARRIVED", ns.Engine.Shown(), false)
end)

test("progress is shown for the zone you're in, and upcoming objectives show their count", function()
  withState({ [101] = { on = true, objectives = { { text = "Wolf slain: 2/5", finished = false, have = 2, need = 5 } } } }, function()
    ForeverRouteData = { id = "lp", title = "lp", sections = { { title = "x" } }, steps = {
      { id = 1, k = "fly", dest = "Westfall", to = 1436, text = "Westfall", sec = 1 },
      { id = 2, k = "accept", q = 100, name = "A", zone = "Westfall", sec = 1 },
      { id = 3, k = "goto", text = "Go", zone = "Westfall", sec = 1 },
      { id = 4, k = "obj", q = 101, text = "Kill 5 Wolf", match = "Wolf", zone = "Westfall", sec = 1 },
      { id = 5, k = "fly", dest = "Redridge Mountains", to = 1433, text = "Redridge", sec = 1 },
      { id = 6, k = "accept", q = 102, name = "B", sec = 1 },
    } }
    ns.char.manualDone[ns.Engine.Key(2)] = true
    local done, total, zone = ns.Engine.LegProgress(3)
    assertEquals(1, done); assertEquals(3, total); assertEquals("Westfall", zone)
    ns.Engine.view = 3; ns.Card.Fill(); ns.Card.Layout(); ns.Card.UpdateProgress(); ns.Engine.view = nil
  end)
end)

test("still in the previous step's area is not 'off the path'", function()
  -- the check is in the arrow driver; here we only make sure targets pick up where their walk starts
  ns.SelectRoute(ns.MainRoutes()[1].id, true)
  for i, s in ipairs(ForeverRouteData.steps) do
    if s.wp and i > 2 then ns.Arrow.SetTarget(i, true); break end
  end
end)

test("a replan that renames your path keeps you on the same path, not the top one", function()
  local saved = ForeverRouteRoutes
  local function route(id, legs) return { id = id, title = id, meta = { legs = legs }, sections = { { title = "x" } }, steps = { { id = 1, k = "goto", text = "a", sec = 1 } } } end
  ForeverRouteRoutes = { route("path:Darkshore-A", "Darkshore > Redridge Mountains"), route("path:Westfall-Old", "Westfall > Redridge Mountains > Duskwood") }
  ns.SelectRoute("path:Westfall-Old", true)
  assertEquals("path:Westfall-Old", ForeverRouteData.id)
  -- replanned: the Westfall path has a new id and a slightly different tail; Darkshore is now listed first
  ForeverRouteRoutes = { route("path:Darkshore-B", "Darkshore > Redridge Mountains > Wetlands"), route("path:Westfall-New", "Westfall > Redridge Mountains > Wetlands") }
  ns.SelectRoute(ns.char.routeTitle, true)
  assertEquals("path:Westfall-New", ForeverRouteData.id)
  ForeverRouteRoutes = saved
  ns.SelectRoute(ns.MainRoutes()[1].id, true)
end)

-- A plan made from an older save does not have the path you switched to since. Real case (level-32 warlock in the
-- Wetlands, 2026-11-11): the saved path was Wetlands > Duskwood > Ashenvale > ...; the plan held Wetlands > Ashenvale >
-- Arathi, Duskwood > Ashenvale > Stranglethorn > Wetlands and Ashenvale > Arathi > Wetlands. Matching from the old
-- second zone on took the Duskwood path ("it swapped to the Ashenvale one").
test("a plan without your path: you stay on the one that starts where yours did, and are told once", function()
  local saved = { routes = ForeverRouteRoutes, pinned = ns.char.pinnedPath, print = ns.Print, switch = ns.pathSwitch }
  local function route(id, legs, extra) local r = { id = id, title = id, meta = { legs = legs }, sections = { { title = "x" } }, steps = { { id = 1, k = "goto", text = "a", sec = 1 } } }; for k, v in pairs(extra or {}) do r[k] = v end; return r end
  local said = {}
  local ok, err = pcall(function()
    ForeverRouteRoutes = { route("path:Wetlands-Duskwood-Ashenvale-Desolace-ArathiHighlands", "Wetlands > Duskwood > Ashenvale > Desolace > Arathi Highlands > Stranglethorn Vale > The Barrens > Swamp of Sorrows > Dustwallow Marsh > Hillsbrad Foothills > Stranglethorn Vale > Riverglades") }
    ns.SelectRoute("path:Wetlands-Duskwood-Ashenvale-Desolace-ArathiHighlands", true)
    ns.char.pinnedPath = "path:Wetlands-Duskwood-Ashenvale-Desolace-ArathiHighlands"
    ns.Print = function(m) said[#said + 1] = m end
    -- the plan from the older save, in the planner's order
    ForeverRouteRoutes = {
      route("path:Wetlands-Ashenvale-ArathiHighlands", "Wetlands > Ashenvale > Arathi Highlands > Desolace > Stranglethorn Vale > The Barrens > Swamp of Sorrows"),
      route("path:Wetlands-Duskwood-DunMorogh", "Duskwood > Ashenvale > Stranglethorn Vale > Wetlands > Desolace > Thousand Needles > Arathi Highlands", { continues = true }),
      route("path:Ashenvale-ArathiHighlands-Wetlands", "Ashenvale > Arathi Highlands > Wetlands > Desolace > Stranglethorn Vale"),
    }
    ns.SelectRoute(ns.char.routeTitle, true)
    assertEquals("path:Wetlands-Ashenvale-ArathiHighlands", ForeverRouteData.id)
    assertEquals("path:Wetlands-Ashenvale-ArathiHighlands", ns.char.routeTitle)
    -- your own pick follows the path to its new name
    assertEquals("path:Wetlands-Ashenvale-ArathiHighlands", ns.char.pinnedPath)
    -- the next zones differ from what you were on: said, with both
    if not (ns.pathSwitch and ns.pathSwitch.to == "path:Wetlands-Ashenvale-ArathiHighlands") then error("the switch was not recorded", 0) end
    local text = ns.pathSwitch.text
    if not (text:find("Wetlands > Duskwood > Ashenvale", 1, true) and text:find("Wetlands > Ashenvale > Arathi Highlands", 1, true)) then error("the note does not name both paths: " .. text, 0) end
    -- selecting again (the name is known now) says nothing more
    ns.pathSwitch = nil
    ns.SelectRoute(ns.char.routeTitle, true)
    if ns.pathSwitch then error("told twice", 0) end
  end)
  ForeverRouteRoutes, ns.char.pinnedPath, ns.Print, ns.pathSwitch = saved.routes, saved.pinned, saved.print, saved.switch
  ns.SelectRoute(ns.MainRoutes()[1].id, true)
  if not ok then error(err, 0) end
end)

test("a renamed path with the same next zones is the same path: no word about a switch", function()
  local saved = { routes = ForeverRouteRoutes, switch = ns.pathSwitch }
  local function route(id, legs, extra) local r = { id = id, title = id, meta = { legs = legs }, sections = { { title = "x" } }, steps = { { id = 1, k = "goto", text = "a", sec = 1 } } }; for k, v in pairs(extra or {}) do r[k] = v end; return r end
  local ok, err = pcall(function()
    ForeverRouteRoutes = { route("path:Old", "Wetlands > Ashenvale > Arathi Highlands > Desolace > The Barrens") }
    ns.SelectRoute("path:Old", true)
    ns.pathSwitch = nil
    ForeverRouteRoutes = { route("path:Other", "Arathi Highlands > Wetlands > Ashenvale > Desolace"), route("path:New", "Wetlands > Ashenvale > Arathi Highlands > Desolace > Stranglethorn Vale") }
    ns.SelectRoute(ns.char.routeTitle, true)
    assertEquals("path:New", ForeverRouteData.id)
    if ns.pathSwitch then error("a rename was announced as a switch: " .. ns.pathSwitch.text, 0) end
  end)
  ForeverRouteRoutes, ns.pathSwitch = saved.routes, saved.switch
  ns.SelectRoute(ns.MainRoutes()[1].id, true)
  if not ok then error(err, 0) end
end)

test("path continuity: zones in common in the same order, the first zone counting most; the planner's mark breaks a tie", function()
  local old = { "Westfall", "Redridge Mountains", "Duskwood", "Wetlands" }
  -- the zone you were in is finished: the continuation beats a path that only shares the old first zone
  if not (ns.PathContinuity(old, { "Redridge Mountains", "Duskwood", "Wetlands" }) > ns.PathContinuity(old, { "Westfall", "Darkshore", "Ashenvale" })) then error("the continuation lost to a path sharing only the first zone", 0) end
  -- same zones in order: the one starting where you did wins
  if not (ns.PathContinuity(old, { "Westfall", "Redridge Mountains", "Wetlands" }) > ns.PathContinuity(old, { "Redridge Mountains", "Duskwood", "Ashenvale" })) then error("the same start did not win", 0) end
  assertEquals(0, ns.PathContinuity(old, { "Darkshore", "Ashenvale" }))
  local saved = { routes = ForeverRouteRoutes, switch = ns.pathSwitch }
  local function route(id, legs, extra) local r = { id = id, title = id, meta = { legs = legs }, sections = { { title = "x" } }, steps = { { id = 1, k = "goto", text = "a", sec = 1 } } }; for k, v in pairs(extra or {}) do r[k] = v end; return r end
  local ok, err = pcall(function()
    ForeverRouteRoutes = { route("path:Old", "Wetlands > Ashenvale > Desolace") }
    ns.SelectRoute("path:Old", true)
    ForeverRouteRoutes = { route("path:A", "Wetlands > Ashenvale > Arathi Highlands"), route("path:B", "Wetlands > Ashenvale > Stranglethorn Vale", { continues = true }) }
    assertEquals("path:B", ns.ResolvePath("path:Old").id)
    -- nothing in common at all: the planner's continuation, not the top path
    ForeverRouteRoutes = { route("path:C", "Felwood > Winterspring"), route("path:D", "Tanaris > Feralas", { continues = true }) }
    assertEquals("path:D", ns.ResolvePath("path:Old").id)
  end)
  ForeverRouteRoutes, ns.pathSwitch = saved.routes, saved.switch
  ns.SelectRoute(ns.MainRoutes()[1].id, true)
  if not ok then error(err, 0) end
end)

test("back from a side trip: a path renamed by a replan is found by its zones, not swapped for the top path", function()
  local saved = { routes = ForeverRouteRoutes, returnTo = ns.char.returnTo, pinned = ns.char.pinnedPath }
  local function route(id, legs, extra) local r = { id = id, title = id, meta = { legs = legs }, sections = { { title = "x" } }, steps = { { id = 1, k = "goto", text = "a", sec = 1 } } }; for k, v in pairs(extra or {}) do r[k] = v end; return r end
  local trip = route("special:Succubus", "Darkshore", { dungeon = true, special = true, dungeonName = "Succubus" })
  local ok, err = pcall(function()
    ForeverRouteRoutes = { route("path:Darkshore-Ashenvale-Wetlands-Old", "Darkshore > Ashenvale > Wetlands > Redridge Mountains"), trip }
    ns.SelectRoute("path:Darkshore-Ashenvale-Wetlands-Old", true)
    ns.char.pinnedPath = "path:Darkshore-Ashenvale-Wetlands-Old"
    ns.EnterDungeonRoute("special:Succubus")
    -- replanned while on the trip: your path got a new id, and another path is now the planner's best
    ForeverRouteRoutes = { route("path:Stonetalon-Best", "Stonetalon Mountains > Darkshore", { best = true }), route("path:Darkshore-Ashenvale-Wetlands-New", "Darkshore > Ashenvale > Wetlands > Duskwood"), trip }
    ns.SelectRoute("special:Succubus", true)
    -- the quest log check sees your path without switching to it
    assertEquals("path:Darkshore-Ashenvale-Wetlands-New", ns.ResolvePath(ns.char.returnTo).id)
    assertEquals("special:Succubus", ForeverRouteData.id)
    ns.LeaveDungeonRoute()
    assertEquals("path:Darkshore-Ashenvale-Wetlands-New", ForeverRouteData.id)
    assertEquals("path:Darkshore-Ashenvale-Wetlands-New", ns.char.returnTo)
    assertEquals("path:Darkshore-Ashenvale-Wetlands-New", ns.char.pinnedPath)
  end)
  ForeverRouteRoutes, ns.char.returnTo, ns.char.pinnedPath = saved.routes, saved.returnTo, saved.pinned
  ns.SelectRoute(ns.MainRoutes()[1].id, true)
  if not ok then error(err, 0) end
end)

test("live reordering: a kill step takes over when your kills count for it (not for walking through it), holds, then back to the plan", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local have = 2
  withState({}, function()
    ns.State.Quest = function(id) if id == 602 then return { on = true, objectives = { { text = "Murloc slain: " .. have .. "/7", finished = false, have = have, need = 7 } } } end return { on = false, objectives = {} } end
    ForeverRouteData = { id = "lr", title = "lr", sections = { { title = "x" } }, steps = {
      { id = 1, k = "accept", q = 601, name = "Far Away", m = 1436, x = 0.30, y = 0.20, r = 6, sec = 1 },
      { id = 2, k = "obj", q = 602, text = "Kill 7 Murloc", match = "Murloc", m = 1436, x = 0.30, y = 0.75, r = 90, sec = 1 },
      { id = 3, k = "accept", q = 603, name = "Later", m = 1436, x = 0.60, y = 0.50, r = 6, sec = 1 },
    } }
    ns.State.OnQuest = function(id) return id == 602 end
    ns.Engine.focus = nil; ns.Engine.Refresh()
    assertEquals(1, ns.Engine.current)
    -- the simulator has no map data: a stand-in conversion, 1% of the map = 35 yards
    local realConv = HBD.GetWorldCoordinatesFromZone
    HBD.GetWorldCoordinatesFromZone = function(_, mx, my, m) return mx * 3500, my * 3500, 0 end
    local x, y, inst = HBD:GetWorldCoordinatesFromZone(0.30, 0.75, 1436)
    ns.Engine.UpdateFocus(x + 5, y, inst)        -- standing among the murlocs: walking through is not doing it
    assertEquals(1, ns.Engine.current)
    ns.Fire("FR_STATE"); have = 3; ns.Fire("FR_STATE") -- a murloc killed: now that's what you're doing
    assertEquals(2, ns.Engine.current); assertEquals(1, ns.Engine.planned)
    ns.Engine.UpdateFocus(x + 60, y, inst)       -- moving around the area: holds
    assertEquals(2, ns.Engine.current)
    ns.State.IsCompleted = function(id) return false end
    ns.State.Quest = function(id) if id == 602 then return { on = true, complete = true, objectives = { { text = "Murloc slain: 7/7", finished = true, have = 7, need = 7 } } } end return { on = false, objectives = {} } end
    ns.Engine.Refresh()                          -- murlocs done: back to the planned order
    assertEquals(1, ns.Engine.current)
    -- far from the plan, nothing nearby to do: stays on the plan
    ns.Engine.focus = nil
    ns.Engine.UpdateFocus(3000, 3000, 0)
    assertEquals(1, ns.Engine.current)
    HBD.GetWorldCoordinatesFromZone = realConv
  end)
end)

planOrderTest("live reordering: a finished quest whose hand-in is right here is handed in now, however late the plan has it", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local realConv = HBD.GetWorldCoordinatesFromZone
  local ok, err = pcall(withState, {}, function()
    -- Menethil: the plan points at a crate 400 yd out; Daily Delivery is ready and its NPC is right here, 15 steps later
    local list = { { id = 1, k = "turnin", q = 801, name = "Reclaiming Goods", m = 1437, x = 0.135, y = 0.414, r = 8, sec = 1 } }
    for k = 2, 16 do list[k] = { id = k, k = "accept", q = 900 + k, name = "Filler " .. k, m = 1437, x = 0.30, y = 0.30, r = 6, sec = 1 } end
    list[17] = { id = 17, k = "turnin", q = 802, name = "Daily Delivery", npc = "James Halloran", m = 1437, x = 0.105, y = 0.565, r = 8, sec = 1 }
    list[18] = { id = 18, k = "turnin", q = 803, name = "Not Done Yet", m = 1437, x = 0.104, y = 0.565, r = 8, sec = 1 }
    ForeverRouteData = { id = "rh", title = "rh", sections = { { title = "x" } }, steps = list }
    ns.State.OnQuest = function(id) return id == 801 or id == 802 or id == 803 end
    ns.State.IsCompleted = function() return false end
    ns.State.Quest = function(id)
      if id == 801 or id == 802 then return { on = true, complete = true, objectives = {} } end
      if id == 803 then return { on = true, objectives = { { text = "Thing: 0/1", finished = false, have = 0, need = 1 } } } end
      return { on = false, objectives = {} }
    end
    HBD.GetWorldCoordinatesFromZone = function(_, mx, my, m) return mx * 3500, my * 3500, 0 end
    ns.Engine.focus = nil; ns.Engine.Refresh()
    assertEquals(1, ns.Engine.current)
    local x, y, inst = HBD:GetWorldCoordinatesFromZone(0.104, 0.565, 1437)
    ns.Engine.UpdateFocus(x + 20, y, inst)       -- in town, 20 yd from James Halloran, the crate ~500 yd away
    assertEquals(17, ns.Engine.current)         -- the ready one, not the unfinished one standing next to it
    assertEquals(1, ns.Engine.planned)
    -- across town: the card takes you there, and holds while you go
    ns.Engine.focus = nil; ns.Engine.Refresh()
    ns.Engine.UpdateFocus(x + 200, y, inst)
    assertEquals(17, ns.Engine.current)
    ns.Engine.UpdateFocus(x + 150, y, inst)
    assertEquals(17, ns.Engine.current)
    -- handed in: back to the plan
    ns.State.IsCompleted = function(id) return id == 802 end
    ns.State.OnQuest = function(id) return id == 801 or id == 803 end
    ns.State.Quest = function(id)
      if id == 801 then return { on = true, complete = true, objectives = {} } end
      if id == 803 then return { on = true, objectives = { { text = "Thing: 0/1", finished = false, have = 0, need = 1 } } } end
      return { on = false, objectives = {} }
    end
    ns.Engine.UpdateFocus(x + 20, y, inst); ns.Engine.Refresh()
    assertEquals(1, ns.Engine.current)
  end)
  HBD.GetWorldCoordinatesFromZone = realConv
  ns.Engine.focus = nil
  if not ok then error(err, 0) end
end)

planOrderTest("live reordering: farming the planned loot step, a later step whose circle you wander into does not take over", function()
  -- the player's Wetlands report: on the Pristine Crimson Scales (crocs roam), the card jumped to the Dragonmaw War
  -- Banners, whose circle is 100 yd off and overlaps
  local HBD = LibStub("HereBeDragons-2.0")
  local realConv, realTime = HBD.GetWorldCoordinatesFromZone, GetTime
  local now, scales = 1000, 2
  local ok, err = pcall(withState, {}, function()
    ForeverRouteData = { id = "ov", title = "ov", sections = { { title = "x" } }, steps = {
      { id = 1, k = "obj", q = 98072, text = "Collect 8 Pristine Crimson Scale", match = "Pristine Crimson Scale", loot = true, m = 1437, x = 0.649, y = 0.464, r = 220, sec = 1 },
      { id = 2, k = "obj", q = 98245, text = "Collect 10 Razormaw Incisor", match = "Razormaw Incisor", loot = true, m = 1437, x = 0.686, y = 0.323, r = 163, sec = 1 },
      { id = 3, k = "obj", q = 464, text = "Collect 8 Dragonmaw War Banner", match = "Dragonmaw War Banner", loot = true, m = 1437, x = 0.621, y = 0.453, r = 220, sec = 1 },
      { id = 4, k = "obj", q = 465, text = "Collect 5 Far Thing", match = "Far Thing", loot = true, m = 1437, x = 0.20, y = 0.464, r = 220, sec = 1 },
    } }
    ns.State.OnQuest = function(id) return id == 98072 or id == 98245 or id == 464 or id == 465 end
    ns.State.Quest = function(id)
      if id == 98072 then return { on = true, objectives = { { text = "Pristine Crimson Scale: " .. scales .. "/8", finished = false, have = scales, need = 8 } } } end
      if id == 98245 then return { on = true, objectives = { { text = "Razormaw Incisor: 0/10", finished = false, have = 0, need = 10 } } } end
      if id == 464 then return { on = true, objectives = { { text = "Dragonmaw War Banner: 0/8", finished = false, have = 0, need = 8 } } } end
      if id == 465 then return { on = true, objectives = { { text = "Far Thing: 0/5", finished = false, have = 0, need = 5 } } } end
      return { on = false, objectives = {} }
    end
    GetTime = function() return now end
    HBD.GetWorldCoordinatesFromZone = function(_, mx, my, m) return mx * 3500, my * 3500, 0 end -- 1% = 35 yd
    ns.Engine.focus = nil; ns.Engine.Refresh()
    assertEquals(1, ns.Engine.current)
    local x, y, inst = HBD:GetWorldCoordinatesFromZone(0.649, 0.464, 1437)
    -- 240 yd west of the scales' marker: inside the banners' circle, still among the crocs
    ns.Engine.UpdateFocus(x - 240, y, inst); ns.Engine.Refresh()
    assertEquals(1, ns.Engine.current)
    -- far out (beyond twice the scales' circle) but still looting scales: no jump either
    ns.Fire("FR_STATE"); scales = 3; ns.Fire("FR_STATE")
    local fx, fy = HBD:GetWorldCoordinatesFromZone(0.20, 0.464, 1437)
    now = now + 20
    ns.Engine.UpdateFocus(fx, fy, inst); ns.Engine.Refresh()
    assertEquals(1, ns.Engine.current)
    -- no loot for a while and standing at the far step: still the plan - standing in a loot step's circle is not
    -- doing it (only its loot counting would take the card there)
    now = now + 200
    ns.Engine.UpdateFocus(fx, fy, inst); ns.Engine.Refresh()
    assertEquals(1, ns.Engine.current)
  end)
  GetTime, HBD.GetWorldCoordinatesFromZone = realTime, realConv
  ns.Engine.focus = nil
  if not ok then error(err, 0) end
end)

planOrderTest("live reordering: a step your kills count for stays shown while you farm far from its marker, until the kills stop", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local realConv, realTime = HBD.GetWorldCoordinatesFromZone, GetTime
  local now = 1000
  local have = 2
  local ok, err = pcall(withState, {}, function()
    ForeverRouteData = { id = "pf", title = "pf", sections = { { title = "x" } }, steps = {
      { id = 1, k = "accept", q = 701, name = "Far Away", m = 1436, x = 0.30, y = 0.20, r = 6, sec = 1 },
      { id = 2, k = "obj", q = 702, text = "Kill 7 Gnoll", match = "Gnoll", m = 1436, x = 0.30, y = 0.75, r = 90, sec = 1 },
    } }
    ns.State.OnQuest = function(id) return id == 702 end
    ns.State.Quest = function(id) if id == 702 then return { on = true, objectives = { { text = "Gnoll slain: " .. have .. "/7", finished = false, have = have, need = 7 } } } end return { on = false, objectives = {} } end
    GetTime = function() return now end
    HBD.GetWorldCoordinatesFromZone = function(_, mx, my, m) return mx * 3500, my * 3500, 0 end
    ns.Engine.focus = nil; ns.Engine.Refresh()
    assertEquals(1, ns.Engine.current)
    ns.Fire("FR_STATE")                          -- the count as it was
    have = 3; ns.Fire("FR_STATE")                -- a kill, 500 yd from the marker
    assertEquals(2, ns.Engine.current); assertEquals("progress", ns.Engine.focusWhy)
    local x, y, inst = HBD:GetWorldCoordinatesFromZone(0.30, 0.75, 1436)
    now = now + 30
    ns.Engine.UpdateFocus(x + 500, y, inst)      -- still farming out there: holds
    ns.Engine.Refresh()
    assertEquals(2, ns.Engine.current)
    now = now + 200                              -- no kills for a while and still far away: back to the plan
    ns.Engine.UpdateFocus(x + 500, y, inst)
    ns.Engine.Refresh()
    assertEquals(1, ns.Engine.current)
  end)
  GetTime, HBD.GetWorldCoordinatesFromZone = realTime, realConv
  ns.Engine.focus = nil
  if not ok then error(err, 0) end
end)

local doneCues, countCues = 0, false
ns.On("FR_STEP_DONE", function() if countCues then doneCues = doneCues + 1 end end)
test("the step-done cue plays only for a step that got done, not when live reordering or an abandon moves the card", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local realConv = HBD.GetWorldCoordinatesFromZone
  local wasQuiet = ns.Engine.SetQuiet(false)
  countCues, doneCues = true, 0
  local ok, err = pcall(withState, { [602] = { on = true, objectives = { { text = "Murloc slain: 2/7", finished = false, have = 2, need = 7 } } } }, function()
    ForeverRouteData = { id = "cue", title = "cue", sections = { { title = "x" } }, steps = {
      { id = 1, k = "accept", q = 601, name = "Far Away", m = 1436, x = 0.30, y = 0.20, r = 6, sec = 1 },
      { id = 2, k = "obj", q = 602, text = "Kill 7 Murloc", match = "Murloc", m = 1436, x = 0.30, y = 0.75, r = 90, sec = 1 },
      { id = 3, k = "accept", q = 603, name = "Later", m = 1436, x = 0.60, y = 0.50, r = 6, sec = 1 },
    } }
    ns.State.OnQuest = function(id) return id == 602 end
    ns.Engine.focus = nil; ns.Engine.Refresh()
    assertEquals(1, ns.Engine.current)
    HBD.GetWorldCoordinatesFromZone = function(_, mx, my, m) return mx * 3500, my * 3500, 0 end
    local x, y, inst = HBD:GetWorldCoordinatesFromZone(0.30, 0.75, 1436)
    ns.Fire("FR_STATE")                          -- the count as it was
    ns.State.Quest = function(id) if id == 602 then return { on = true, objectives = { { text = "Murloc slain: 3/7", finished = false, have = 3, need = 7 } } } end return { on = false, objectives = {} } end
    ns.Fire("FR_STATE")                          -- a murloc killed: the card moves to the murlocs, step 1 is untouched
    assertEquals(2, ns.Engine.current); assertEquals(0, doneCues)
    ns.Engine.focus = nil; ns.Engine.Refresh()   -- focus released: the murlocs are still to do
    assertEquals(1, ns.Engine.current); assertEquals(0, doneCues)
    ns.Engine.focus = 2; ns.Engine.Refresh()
    ns.State.Quest = function(id) if id == 602 then return { on = true, complete = true, objectives = { { text = "Murloc slain: 7/7", finished = true, have = 7, need = 7 } } } end return { on = false, objectives = {} } end
    ns.Engine.Refresh()                          -- murlocs done: that one is a real tick
    assertEquals(1, ns.Engine.current); assertEquals(1, doneCues)
    -- abandoning the murloc quest from its objective step: back to an accept, no tick
    ForeverRouteData.steps[1].q = 602
    ns.State.Quest = function(id) if id == 602 then return { on = true, objectives = { { text = "Murloc slain: 3/7", finished = false, have = 3, need = 7 } } } end return { on = false, objectives = {} } end
    ns.Engine.focus = nil; ns.Engine.Refresh()
    assertEquals(2, ns.Engine.current); assertEquals(2, doneCues) -- the pick-up is in your log: a real tick
    ns.State.OnQuest = function() return false end
    ns.State.Quest = function() return { on = false, objectives = {} } end
    ns.Engine.Refresh()
    assertEquals(1, ns.Engine.current); assertEquals(2, doneCues)
  end)
  countCues = false
  ns.Engine.SetQuiet(wasQuiet)
  HBD.GetWorldCoordinatesFromZone = realConv
  if not ok then error(err, 0) end
end)

test("the performance log takes a sample", function()
  local before = #(ns.char.perfLog or {})
  ns.Time("refresh", 1.5)
  ns._perfSample()
  assertEquals(math.min(60, before + 1), #ns.char.perfLog)
  local e = ns.char.perfLog[#ns.char.perfLog]
  assertNotNil(e.at); assertNotNil(e.refresh); assertNil(e.map)
  table.remove(ns.char.perfLog)
end)

test("errand reminders: bags nearly full or gear wearing out, with a vendor", function()
  local sv = { free = ns.Errands.FreeSlots, dur = ns.Errands.Durability }
  ns.char.errandDismissed = nil
  ns.Errands.FreeSlots = function() return 12 end; ns.Errands.Durability = function() return 0.9 end
  assertNil(ns.Errands.Current())
  ns.Errands.FreeSlots = function() return 2 end
  local text, key = ns.Errands.Current()
  assertTrue(text:find("2 free", 1, true) ~= nil); assertEquals("bags", key)
  ns.Errands.Durability = function() return 0.2 end
  text, key = ns.Errands.Current()
  assertTrue(text:find("20%", 1, true) ~= nil); assertEquals("bagsrepair", key)
  ns.Card.Fill(); ns.Card.Layout(); assertTrue(ForeverRouteCard.errand:IsShown())
  ns.Errands.Dismiss(); assertNil((ns.Errands.Current()))
  assertNotNil(ns.VENDORS and ns.VENDORS[1436])
  ns.Errands.FreeSlots, ns.Errands.Durability = sv.free, sv.dur; ns.char.errandDismissed = nil
end)

test("also hand in: a finished quest the route doesn't cover, when its NPC is near", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { enders = ForeverRouteEnders, ready = ns.State.QuestReady, done = ns.State.IsCompleted, conv = HBD.GetWorldCoordinatesFromZone, pos = HBD.GetPlayerWorldPosition }
  ForeverRouteEnders = { [92909] = { npc = "Gryan Stoutmantle", m = 1436, x = 0.5633, y = 0.4752, name = "Harvesting the Harvesters" } }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y) return x * 3500, y * 3500, 0 end
  HBD.GetPlayerWorldPosition = function() return 0.5633 * 3500 + 30, 0.4752 * 3500, 0 end
  ns.State.IsCompleted = function() return false end
  -- the quest is in your log (the hand-in list is looked up through the log)
  local svN, svI = C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo
  C_QuestLog.GetNumQuestLogEntries = function() return 1, 1 end
  C_QuestLog.GetInfo = function(i) return i == 1 and { questID = 92909 } or nil end
  local ok, err = pcall(function()
    ns.State.QuestReady = function(q) return q == 92909 end
    assertTrue((ns.Extras.Line() or ""):find("Harvesting the Harvesters", 1, true) ~= nil)
    ns.State.QuestReady = function() return false end            -- not finished: nothing
    assertNil(ns.Extras.Line())
    ns.State.QuestReady = function(q) return q == 92909 end
    HBD.GetPlayerWorldPosition = function() return 0, 0, 0 end    -- far away: nothing
    assertNil(ns.Extras.Line())
  end)
  ForeverRouteEnders, ns.State.QuestReady, ns.State.IsCompleted, HBD.GetWorldCoordinatesFromZone, HBD.GetPlayerWorldPosition = sv.enders, sv.ready, sv.done, sv.conv, sv.pos
  C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo = svN, svI
  if not ok then error(err, 0) end
end)

test("adding a stop: it takes the hub of the stretch it lands in, and the open list shows it without losing a step", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local conv = HBD.GetWorldCoordinatesFromZone
  HBD.GetWorldCoordinatesFromZone = function(_, x, y) return x * 1000, y * 1000, 0 end
  local ok, err = pcall(function()
    withState({}, function()
      local list = {}
      for k = 1, 30 do list[k] = { id = k, k = "accept", q = 700 + k, name = "Q" .. k, m = 1436, x = 0.02 + k * 0.03, y = 0.10, sec = k <= 15 and 1 or 2 } end
      ForeverRouteData = { id = "ins2", title = "ins2", sections = { { title = "First Hub" }, { title = "Second Hub" } }, steps = list }
      ns.Engine.Refresh()
      if ForeverRouteList:IsShown() then ns.List.Toggle() end
      ns.List.Toggle()   -- open
      local function headers() local h = {}; for _, e in ipairs(ns.List.Entries()) do if e.header then h[#h + 1] = e.header end end; return h end
      local function lastIndex() local n = 0; for _, e in ipairs(ns.List.Entries()) do if e.index then n = e.index end end; return n end
      assertEquals(2, #headers())
      -- a copy from another side trip, carrying that trip's section 7: it lands between steps 20 and 21 (Second Hub)
      local at = ns.Engine.InsertStop({ k = "turnin", q = 799, name = "X", m = 1436, x = 0.02 + 20.5 * 0.03, y = 0.11, sec = 7 }, 50, 100, 0)
      assertEquals(21, at)
      assertEquals(2, ForeverRouteData.steps[21].sec)
      ns.Fire("FR_STEP", ns.Engine.Shown())   -- what the engine fires after an insert: a redraw, not a route change
      local h = headers()
      assertEquals(2, #h); assertEquals("First Hub", h[1]); assertEquals("Second Hub", h[2])
      assertEquals(31, lastIndex())
      ns.List.Toggle()   -- close
    end)
  end)
  HBD.GetWorldCoordinatesFromZone = conv
  if ForeverRouteList:IsShown() then ns.List.Toggle() end
  if not ok then error(err, 0) end
end)

test("adding a stop: a finished quest's hand-in goes into the cheapest gap, after the current step", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local conv = HBD.GetWorldCoordinatesFromZone
  HBD.GetWorldCoordinatesFromZone = function(_, x, y) return x * 1000, y * 1000, 0 end
  local ok, err = pcall(function()
    withState({}, function()
      local function route() return { id = "ins", title = "ins", sections = { { title = "x" } }, steps = {
        { id = 1, k = "accept", q = 701, name = "A", m = 1436, x = 0.10, y = 0.10, sec = 1 },
        { id = 2, k = "accept", q = 702, name = "B", m = 1436, x = 0.50, y = 0.10, sec = 1 },
        { id = 3, k = "accept", q = 703, name = "C", m = 1436, x = 0.90, y = 0.10, sec = 1 },
      } } end
      -- a stop on the way between B and C
      ForeverRouteData = route(); ns.Engine.Refresh()
      local at = ns.Engine.InsertStop({ k = "turnin", q = 799, name = "X", m = 1436, x = 0.70, y = 0.12, sec = 1 }, 100, 100, 0)
      assertEquals(3, at); assertEquals("X", ForeverRouteData.steps[3].name); assertEquals(1, ns.Engine.current)
      -- a stop right where you are, with the current step far away: it becomes the next step
      ForeverRouteData = route(); ns.Engine.Refresh()
      at = ns.Engine.InsertStop({ k = "turnin", q = 798, name = "Here", m = 1436, x = 0.95, y = 0.95, sec = 1 }, 950, 940, 0)
      assertEquals(1, at)
      -- the engine adds it by itself for a finished quest with no hand-in on the route
      ForeverRouteData = route(); ns.Engine.Refresh()
      local savedEnders = ForeverRouteEnders
      ForeverRouteEnders = { [797] = { npc = "Gryan", m = 1436, x = 0.30, y = 0.11, name = "Murloc Gills" } }
      ns.State.QuestReady = function(q) return q == 797 end
      -- found through your quest log (one header, the finished quest, another quest)
      local svN, svI = C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo
      local fakeLog = { { isHeader = true, title = "Westfall" }, { questID = 797 }, { questID = 796 } }
      C_QuestLog.GetNumQuestLogEntries = function() return #fakeLog, 2 end
      C_QuestLog.GetInfo = function(i) return fakeLog[i] end
      local okI, added = pcall(ns.Engine.ApplyInserts)
      C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo = svN, svI
      if not okI then error(added, 0) end
      assertTrue(added)
      local found; for _, s in ipairs(ForeverRouteData.steps) do if s.q == 797 and s.k == "turnin" then found = s end end
      assertNotNil(found); assertTrue(found.inserted)
      assertFalse(ns.Engine.ApplyInserts()) -- not added twice
      ForeverRouteEnders = savedEnders
    end)
  end)
  HBD.GetWorldCoordinatesFromZone = conv
  if not ok then error(err, 0) end
end)

test("a gray finished quest gets a stop only right on the way (Messenger to Westfall at 26 is no detour)", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local conv = HBD.GetWorldCoordinatesFromZone
  HBD.GetWorldCoordinatesFromZone = function(_, x, y) return x * 1000, y * 1000, 0 end
  local svN, svI, svE, svR, svL = C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, ForeverRouteEnders, ns.State.QuestReady, UnitLevel
  local ok, err = pcall(function()
    withState({}, function()
      local function route() return { id = "gray", title = "gray", sections = { { title = "x" } }, steps = {
        { id = 1, k = "accept", q = 701, name = "A", m = 1436, x = 0.10, y = 0.10, sec = 1 },
        { id = 2, k = "accept", q = 702, name = "B", m = 1436, x = 0.50, y = 0.10, sec = 1 },
        { id = 3, k = "accept", q = 703, name = "C", m = 1436, x = 0.90, y = 0.10, sec = 1 },
      } } end
      UnitLevel = function() return 26 end
      ns.State.QuestReady = function(q) return q == 795 end
      local fakeLog = { { questID = 795, level = 14 } }
      C_QuestLog.GetNumQuestLogEntries = function() return #fakeLog, 1 end
      C_QuestLog.GetInfo = function(i) return fakeLog[i] end
      local function has() for _, s in ipairs(ForeverRouteData.steps) do if s.q == 795 then return true end end return false end
      -- far off the route (500 yd out and back): no stop for 250 XP
      ForeverRouteData = route(); ns.Engine.Refresh()
      ForeverRouteEnders = { [795] = { npc = "Gryan", m = 1436, x = 0.30, y = 0.60, name = "Messenger to Westfall" } }
      assertFalse(ns.Engine.ApplyInserts()); assertFalse(has())
      -- right on the way between A and B: fine
      ForeverRouteData = route(); ns.Engine.Refresh()
      ForeverRouteEnders = { [795] = { npc = "Gryan", m = 1436, x = 0.30, y = 0.11, name = "Messenger to Westfall" } }
      assertTrue(ns.Engine.ApplyInserts()); assertTrue(has())
      -- a quest at your level still gets its stop wherever it costs least
      ForeverRouteData = route(); ns.Engine.Refresh()
      fakeLog = { { questID = 795, level = 24 } }
      ForeverRouteEnders = { [795] = { npc = "Gryan", m = 1436, x = 0.30, y = 0.60, name = "Messenger to Westfall" } }
      assertTrue(ns.Engine.ApplyInserts()); assertTrue(has())
    end)
  end)
  C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, ForeverRouteEnders, ns.State.QuestReady, UnitLevel = svN, svI, svE, svR, svL
  HBD.GetWorldCoordinatesFromZone = conv
  if not ok then error(err, 0) end
end)

test("any plan (the built-in one too): a finished hand-in far below you that opens nothing is passed; one that opens a chain stays", function()
  local svL, svU = UnitLevel, ForeverRouteUnlocks
  local ok, err = pcall(function()
    UnitLevel = function() return 26 end
    withState({ [353] = { on = true, complete = true, objectives = {} }, [354] = { on = true, complete = true, objectives = {} } }, function()
      ForeverRouteData = { id = "builtin", steps = {
        { id = 1, k = "accept", q = 900, name = "Something at your level", level = 25, m = 1436, x = 0.5, y = 0.5 },
        { id = 2, k = "turnin", q = 353, name = "Stormpike's Delivery", level = 15, m = 1432, x = 0.3, y = 0.3 },
        { id = 3, k = "turnin", q = 354, name = "A low quest that opens a chain", level = 15, m = 1432, x = 0.3, y = 0.4 },
      } }
      ForeverRouteUnlocks = { [354] = { 355 } }
      ns.Engine.Refresh()
      assertEquals("done", ns.Engine.Status(2)) -- passed: not worth the trip
      assertTrue(ns.Engine.Status(3) ~= "done") -- it opens quest 355: still on the route
      -- the quest log check agrees with the card
      local saved = { n = C_QuestLog.GetNumQuestLogEntries, i = C_QuestLog.GetInfo }
      local e = { { isHeader = true, title = "Stormwind City" }, { questID = 353, title = "Stormpike's Delivery", level = 15 } }
      C_QuestLog.GetNumQuestLogEntries = function() return #e end
      C_QuestLog.GetInfo = function(k) return e[k] end
      local okC, list = pcall(ns.LogCheck.Classify)
      C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo = saved.n, saved.i
      if not okC then error(list, 0) end
      local v = {}; for _, x in ipairs(list) do v[x.e.id] = x.verdict end
      assertEquals("drop", v[353])
    end)
  end)
  UnitLevel, ForeverRouteUnlocks = svL, svU
  if not ok then error(err, 0) end
end)

test("a breadcrumb is passed once its quest is yours (Argos has no Corruption Abroad with Researching the Corruption in your log)", function()
  local svL = UnitLevel; UnitLevel = function() return 26 end -- the test client is 70: everything would be outlevelled
  local okT, errT = pcall(function()
  withState({ [1275] = { on = true, objectives = {} } }, function()
    ForeverRouteData = { id = "bc", steps = {
      { id = 1, k = "accept", q = 3765, name = "The Corruption Abroad", level = 24, m = 1453, x = 0.36, y = 0.68 },
      { id = 2, k = "turnin", q = 3765, name = "The Corruption Abroad", level = 24, m = 1439, x = 0.38, y = 0.43 },
      { id = 3, k = "accept", q = 1275, name = "Researching the Corruption", level = 24, m = 1439, x = 0.38, y = 0.43 },
    } }
    ns.Engine.Refresh()
    assertEquals("done", ns.Engine.Status(1))
    assertEquals("done", ns.Engine.Status(2))
    assertTrue(ns.BREADCRUMBS[3765] ~= nil, "the breadcrumb table is loaded")
  end)
  -- not yet on its quest: the breadcrumb stays
  withState({}, function()
    ForeverRouteData = { id = "bc2", steps = { { id = 1, k = "accept", q = 3765, name = "The Corruption Abroad", level = 24, m = 1453, x = 0.36, y = 0.68 } } }
    ns.Engine.Refresh()
    assertTrue(ns.Engine.Status(1) ~= "done")
  end)
  end)
  UnitLevel = svL
  if not okT then error(errT, 0) end
end)

test("an alternative is passed once another is yours (no Briarthorn for Menara Voidrender, taken from Demisette Cloyce)", function()
  local svL = UnitLevel; UnitLevel = function() return 31 end -- the test client is 70: everything would be outlevelled
  local route = { id = "alt", steps = {
    { id = 1, k = "accept", q = 4736, name = "In Search of Menara Voidrender", npc = "Briarthorn", level = 31, m = 1455, x = 0.51, y = 0.08 },
    { id = 2, k = "turnin", q = 4736, name = "In Search of Menara Voidrender", npc = "Menara Voidrender", level = 31, m = 1413, x = 0.49, y = 0.57 },
  } }
  local okT, errT = pcall(function()
    assertTrue(ns.QUEST_EX and ns.QUEST_EX[4736] ~= nil, "the alternatives table is loaded")
    -- done in Stormwind: Briarthorn's is closed, pick-up and hand-in
    withState({ [4738] = { done = true, objectives = {} } }, function()
      ForeverRouteData = route
      ns.Engine.Refresh()
      assertEquals("done", ns.Engine.Status(1))
      assertEquals("done", ns.Engine.Status(2))
    end)
    -- in your log from Stormwind: the same
    withState({ [4738] = { on = true, objectives = {} } }, function()
      ForeverRouteData = route
      ns.Engine.Refresh()
      assertEquals("done", ns.Engine.Status(1))
    end)
    -- neither: Briarthorn's stays
    withState({}, function()
      ForeverRouteData = route
      ns.Engine.Refresh()
      assertTrue(ns.Engine.Status(1) ~= "done")
    end)
    -- Briarthorn's own in your log (taken there after all): its hand-in stays whatever else you have
    withState({ [4736] = { on = true, objectives = {} }, [4738] = { done = true, objectives = {} } }, function()
      ForeverRouteData = route
      ns.Engine.Refresh()
      assertTrue(ns.Engine.Status(2) ~= "done")
    end)
  end)
  UnitLevel = svL
  if not okT then error(errT, 0) end
end)

test("a quest's own prerequisite is not an alternative (Stars of Elune stays after Returning Home)", function()
  -- QuestieDB names Stars of Elune's breadcrumbs both as its prerequisites (one of them) and in its exclusive list;
  -- read as written, handing in Returning Home closed the quest it leads to (tools/exclusive-alternatives.js closers)
  local svL = UnitLevel; UnitLevel = function() return 10 end
  local route = { id = "elune", steps = {
    { id = 1, k = "accept", q = 5627, name = "Stars of Elune", npc = "Priestess Alathea", level = 10, m = 1457, x = 0.39, y = 0.81 },
    { id = 2, k = "turnin", q = 5627, name = "Stars of Elune", npc = "Priestess Alathea", level = 10, m = 1457, x = 0.39, y = 0.81 },
  } }
  local okT, errT = pcall(function()
    for _, e in ipairs(ns.QUEST_EX[5627] or {}) do assertTrue(e ~= 5629, "Returning Home is not among Stars of Elune's alternatives") end
    withState({ [5629] = { done = true, objectives = {} } }, function()
      ForeverRouteData = route
      ns.Engine.Refresh()
      assertTrue(ns.Engine.Status(1) ~= "done", "Stars of Elune is still to do")
    end)
  end)
  UnitLevel = svL
  if not okT then error(errT, 0) end
end)

test("'giver doesn't offer it': the quest leaves the route until your next level; its chain stays", function()
  local svL, svC = UnitLevel, ForeverRouteChar
  local lvl = 26
  local ok, err = pcall(function()
    UnitLevel = function() return lvl end
    ForeverRouteChar = ForeverRouteChar or {}
    local svAvail = ForeverRouteChar.avail; ForeverRouteChar.avail = nil
    withState({}, function()
      ForeverRouteData = { id = "noff", steps = {
        { id = 1, k = "accept", q = 98072, name = "Crocs of the Sky", npc = "James Halloran", level = 27, m = 1437, x = 0.0855, y = 0.5574 },
        { id = 2, k = "accept", q = 98240, name = "Crimson Crate Delivery", npc = "James Halloran", level = 29, m = 1437, x = 0.0855, y = 0.5574 },
      } }
      ns.Engine.Refresh()
      assertEquals(1, ns.Engine.Shown())
      ns.Engine.NotOffered()
      assertEquals("done", ns.Engine.Status(1))         -- off the route at 26
      assertTrue(ns.Engine.Status(2) ~= "done")         -- its chain stays
      lvl = 27; ns.Engine.Refresh()
      assertTrue(ns.Engine.Status(1) ~= "done")         -- tried again at the next level
    end)
    ForeverRouteChar.avail = svAvail
  end)
  UnitLevel, ForeverRouteChar = svL, svC
  if not ok then error(err, 0) end
end)

test("quest log check: a finished quest that is gray and off the route is worth dropping, not 'on your route'", function()
  local saved = { n = C_QuestLog.GetNumQuestLogEntries, i = C_QuestLog.GetInfo, lvl = UnitLevel }
  local e = { { isHeader = true, title = "Redridge Mountains" }, { questID = 900144, title = "Messenger to Westfall", level = 14 },
    { isHeader = true, title = "Duskwood" }, { questID = 900145, title = "A Finished Duskwood Quest", level = 24 } }
  C_QuestLog.GetNumQuestLogEntries = function() return #e end
  C_QuestLog.GetInfo = function(k) return e[k] end
  UnitLevel = function() return 26 end
  local ok, err = pcall(function()
    withState({ [900144] = { on = true, complete = true, objectives = {} }, [900145] = { on = true, complete = true, objectives = {} } }, function()
      local v = {}; for _, x in ipairs(ns.LogCheck.Classify()) do v[x.e.id] = x.verdict end
      assertEquals("drop", v[900144])
      assertEquals("turnin", v[900145])
    end)
  end)
  C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, UnitLevel = saved.n, saved.i, saved.lvl
  if not ok then error(err, 0) end
end)

test("not doing a quest: dropped now, chain quests ask first, undo brings it back", function()
  withState({}, function()
    ForeverRouteData = { id = "nope", title = "nope", sections = { { title = "x" } }, steps = {
      { id = 1, k = "accept", q = 801, name = "Westfall Stew", sec = 1 },
      { id = 2, k = "obj", q = 801, text = "Collect 3 Stringy Vulture Meat", sec = 1 },
      { id = 3, k = "accept", q = 802, name = "Chain Start", sec = 1 },
      { id = 4, k = "accept", q = 803, name = "Chain Next", sec = 1 },
      { id = 5, k = "accept", q = 804, name = "Other", sec = 1 },
    } }
    local savedU = ForeverRouteUnlocks
    ForeverRouteUnlocks = { [802] = { 803 } }
    ns.char.nope = nil
    ns.Engine.Refresh(); assertEquals(1, ns.Engine.current)
    ns.Engine.Nope(801)                                  -- no chain: dropped straight away
    assertTrue(ns.char.nope[801]); assertEquals(3, ns.Engine.current)
    ns.Engine.Undo(); assertNil(ns.char.nope[801]); assertEquals(1, ns.Engine.current)
    local shown
    local realShow = StaticPopup_Show
    StaticPopup_Show = function(which, a, b) shown = { which, a, b }; return {} end
    ns.Engine.Nope(802)                                  -- part of a chain: asks, names what goes with it
    StaticPopup_Show = realShow
    assertNotNil(shown); assertEquals("FOREVERROUTE_NOPE", shown[1]); assertTrue(shown[3]:find("Chain Next", 1, true) ~= nil)
    assertNil(ns.char.nope[802])                         -- nothing dropped until you say so
    ns.Engine.NopeNow({ 802, 803 }); assertTrue(ns.char.nope[803])
    ForeverRouteUnlocks = savedU; ns.char.nope = nil
  end)
end)

test("the map line only shows the part of the path still ahead", function()
  ns.SelectRoute(ns.MainRoutes()[1].id, true)
  local i; for k, s in ipairs(ForeverRouteData.steps) do if s.wp and s.m then i = k; break end end
  if not i then return end
  ns.Engine.view = i; ns.Fire("FR_STEP", i)
  ns.Fire("FR_PATHPROGRESS", i, 0); ns.Fire("FR_PATHPROGRESS", i, 2); ns.Fire("FR_PATHPROGRESS", i, -1)
  ns.Engine.view = nil; ns.Fire("FR_STEP", ns.Engine.Shown())
end)

test("setting your hearthstone ticks off every hearth step on that map", function()
  withState({}, function()
    ForeverRouteData = { id = "b", title = "b", sections = { { title = "x" } }, steps = {
      { id = 1, k = "turnin", q = 901, name = "Something First", sec = 1 },
      { id = 2, k = "accept", q = 902, name = "Two", sec = 1 },
      { id = 3, k = "accept", q = 903, name = "Three", sec = 1 },
      { id = 4, k = "accept", q = 904, name = "Four", sec = 1 },
      { id = 5, k = "bind", npc = "Innkeeper Allison", m = 1453, zone = "Stormwind", sec = 1 },
      { id = 6, k = "bind", npc = "Innkeeper Allison", m = 1453, zone = "Stormwind", sec = 1 },
    } }
    local sv = { gb = GetBindLocation, pos = ns.State.Position }
    GetBindLocation = function() return "Trade District" end    -- a name that doesn't match "Stormwind"
    ns.State.Position = function() return 1453, 0.6, 0.75 end
    ns.char.boundAt = nil
    assertEquals("todo", ns.Engine.Status(5))
    ns.Fire("HEARTHSTONE_BOUND")                                 -- bound while the card was on step 1
    assertEquals("done", ns.Engine.Status(5)); assertEquals("done", ns.Engine.Status(6))
    GetBindLocation = function() return "Ironforge" end         -- bound somewhere else later: they come back
    assertEquals("todo", ns.Engine.Status(5))
    GetBindLocation, ns.State.Position = sv.gb, sv.pos; ns.char.boundAt = nil
  end)
end)

test("when the zone you were in is done, you stay on the continuation of your path", function()
  local saved = ForeverRouteRoutes
  local function route(id, legs) return { id = id, title = id, meta = { legs = legs }, sections = { { title = "x" } }, steps = { { id = 1, k = "goto", text = "a", sec = 1 } } } end
  ForeverRouteRoutes = { route("path:Westfall-Redridge", "Westfall > Redridge Mountains > Duskwood > Wetlands") }
  ns.SelectRoute("path:Westfall-Redridge", true)
  -- Westfall finished: the new plan has no Westfall path; Loch Modan and Darkshore are listed first
  ForeverRouteRoutes = { route("path:LochModan", "Loch Modan > Redridge Mountains"), route("path:Darkshore", "Darkshore > Redridge Mountains"), route("path:Redridge-Duskwood", "Redridge Mountains > Duskwood > Ashenvale") }
  ns.SelectRoute(ns.char.routeTitle, true)
  assertEquals("path:Redridge-Duskwood", ForeverRouteData.id)
  ForeverRouteRoutes = saved
  ns.SelectRoute(ns.MainRoutes()[1].id, true)
end)

test("boats: the pier you waited at is learned and the boat step points there", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local saved = { pos = ns.State.Position, wp = HBD.GetPlayerWorldPosition, t = GetTime, inz = ns.Engine.InZone, cur = ns.Engine.current, data = ForeverRouteData, docks = ForeverRouteDB.docks, conv = HBD.GetWorldCoordinatesFromZone }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y) return x * 2000, y * 2000, 0 end -- map geometry: 2000 yd across (the sim has none)
  local map, x, y, clock, here = 1437, 0.05, 0.57, 500, 1437
  ns.State.Position = function() return map, x, y end
  HBD.GetPlayerWorldPosition = function() return x * 1000, y * 1000, 0 end
  GetTime = function() return clock end
  ns.Engine.InZone = function(to) return to == here end
  ForeverRouteDB.docks = {}
  ForeverRouteData = { steps = { { k = "fly", boat = "menethil", to = 1439, m = 1437, x = 0.0949, y = 0.5969, r = 60, wp = "a" } } }
  local ok, err = pcall(function()
    for k = 1, 20 do clock = clock + 1; ns.Boats._tick() end            -- waiting on the pier
    map, x, y = 1437, 0.02, 0.55; clock = clock + 1; ns.Boats._tick()   -- the boat sails off
    ns.Engine.current = 1; here = 1439; ns.Boats._arrived()             -- Auberdine
    local d = ForeverRouteDB.docks.menethil
    assertNotNil(d)
    assertEquals(0.05, d.x)
    assertEquals(0.05, ForeverRouteData.steps[1].x)
    assertNil(ForeverRouteData.steps[1].wp)
  end)
  ns.State.Position, HBD.GetPlayerWorldPosition, GetTime, ns.Engine.InZone, ns.Engine.current, ForeverRouteData, ForeverRouteDB.docks, HBD.GetWorldCoordinatesFromZone = saved.pos, saved.wp, saved.t, saved.inz, saved.cur, saved.data, saved.docks, saved.conv
  if not ok then error(err, 0) end
end)

test("boats: a wait at the inn is not learned as the pier (you walked straight onto a boat that was in)", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local saved = { pos = ns.State.Position, wp = HBD.GetPlayerWorldPosition, t = GetTime, inz = ns.Engine.InZone, cur = ns.Engine.current, data = ForeverRouteData, docks = ForeverRouteDB.docks, conv = HBD.GetWorldCoordinatesFromZone }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y) return x * 2000, y * 2000, 0 end -- map geometry: 2000 yd across (the sim has none)
  local map, x, y, clock, here = 1453, 0.52, 0.65, 5000, 1453
  ns.State.Position = function() return map, x, y end
  HBD.GetPlayerWorldPosition = function() return x * 1000, y * 1000, 0 end
  GetTime = function() return clock end
  ns.Engine.InZone = function(to) return to == here end
  ForeverRouteDB.docks = {}
  ForeverRouteData = { steps = { { k = "fly", boat = "stormwind", to = 1439, m = 1453, x = 0.256, y = 0.544, r = 60, text = "Boat to Auberdine" } } }
  local ok, err = pcall(function()
    for _ = 1, 20 do clock = clock + 1; ns.Boats._tick() end              -- reading the card at the inn
    for k = 1, 20 do clock = clock + 1; x, y = 0.52 - k * 0.012, 0.65 - k * 0.0188; ns.Boats._tick() end -- walking to the harbor
    ns.Engine.current = 1; here = 1439; ns.Boats._arrived()               -- straight onto the boat, now in Auberdine
    assertNil(ForeverRouteDB.docks.stormwind, "the inn was learned as the pier")
    assertEquals(0.256, ForeverRouteData.steps[1].x)
    -- the same guess from a planned trip's boat leg is refused too; a wait at the pier itself is learned
    ns.Boats.LearnDock("stormwind", 1453)
    assertNil(ForeverRouteDB.docks.stormwind)
    map, x, y = 1453, 0.258, 0.546; here = 1453 -- on the Auberdine pier (Idrieth Mossgrove)
    for _ = 1, 20 do clock = clock + 1; ns.Boats._tick() end
    ns.Boats.LearnDock("stormwind", 1453)
    assertNotNil(ForeverRouteDB.docks.stormwind, "a wait on the pier was not learned")
  end)
  ns.State.Position, HBD.GetPlayerWorldPosition, GetTime, ns.Engine.InZone, ns.Engine.current, ForeverRouteData, ForeverRouteDB.docks, HBD.GetWorldCoordinatesFromZone = saved.pos, saved.wp, saved.t, saved.inz, saved.cur, saved.data, saved.docks, saved.conv
  if not ok then error(err, 0) end
end)

test("travel: no flight path in the zone -> fly to the closest one you have, then ride; with one -> just fly", function()
  local saved = { taxi = ns.State.knownTaxi, pos = ns.State.Position, info = C_Map.GetMapInfo }
  local names = { [1453] = "Stormwind City", [1433] = "Redridge Mountains", [1436] = "Westfall", [1431] = "Duskwood", [1426] = "Dun Morogh" }
  C_Map.GetMapInfo = function(m) return names[m] and { name = names[m] } or (saved.info and saved.info(m)) end
  local where = 1453
  ns.State.Position = function() return where, 0.66, 0.62 end
  local HBD = LibStub("HereBeDragons-2.0"); saved.conv = HBD.GetWorldCoordinatesFromZone
  local off = { [1453] = { -1200, -1200 }, [1436] = { -200, 900 }, [1433] = { 1300, 300 }, [1431] = { 400, 900 }, [1426] = { 0, -3000 } }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) local o = off[m]; if not o then return nil end return o[1] + x * 1000, o[2] + y * 1000, 0 end
  local ok, err = pcall(function()
    ns.State.knownTaxi = { ["Stormwind, Elwynn"] = true, ["Lakeshire, Redridge"] = true, ["Sentinel Hill, Westfall"] = true }
    local s = { k = "fly", to = 1431, dest = "Duskwood" }
    local plan = ns.Engine.TravelPlan(s)
    assertNotNil(plan)
    assertTrue(plan.via == 1433 or plan.via == 1436, "flies to Lakeshire or Sentinel Hill, got " .. tostring(plan.via))
    assertNil((ns.Engine.TravelTarget(s)) == 1431 and "x" or nil)          -- in Stormwind: still points at the flight master
    where = plan.via
    assertEquals(1431, (ns.Engine.TravelTarget(s)))                         -- landed: points into Duskwood
    ns.State.knownTaxi["Darkshire, Duskwood"] = true
    local p3 = ns.Engine.TravelPlan(s); assertTrue(p3 == nil or p3.ride)  -- have it: fly, or ride if that is shorter from here
  end)
  ns.State.knownTaxi, ns.State.Position, C_Map.GetMapInfo, HBD.GetWorldCoordinatesFromZone = saved.taxi, saved.pos, saved.info, saved.conv
  if not ok then error(err, 0) end
end)

test("minimap pins: only steps near you", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { p = HBD.GetPlayerWorldPosition, c = HBD.GetWorldCoordinatesFromZone }
  HBD.GetPlayerWorldPosition = function() return 0, 0, 0 end
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) return x * 1000 + (m == 1431 and 3000 or 0), y * 1000, 0 end
  local ok, err = pcall(function()
    assertTrue(ns.Pins.Near(1453, 0.2, 0.2), "a step 280 yd away is near")
    assertFalse(ns.Pins.Near(1431, 0.2, 0.2), "a step in Duskwood is not")
  end)
  HBD.GetPlayerWorldPosition, HBD.GetWorldCoordinatesFromZone = sv.p, sv.c
  if not ok then error(err, 0) end
end)

test("minimap pins: the current step's minimap pin appears as you walk up to it (and goes as you walk off)", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { p = HBD.GetPlayerWorldPosition, c = HBD.GetWorldCoordinatesFromZone, pins = ns.db.pins, pos = ns.State.Position }
  local px = 0
  HBD.GetPlayerWorldPosition = function() return px, 500, 0 end
  HBD.GetWorldCoordinatesFromZone = function(_, x, y) return x * 1000, y * 1000, 0 end
  ns.State.Position = function() return 1453, px / 1000, 0.5 end
  ns.db.pins = true
  local ok, err = pcall(withState, {}, function()
    ForeverRouteData = { id = "pn", title = "pn", sections = { { title = "x" } }, steps = {
      { id = 1, k = "goto", text = "Over there", m = 1453, x = 0.9, y = 0.5, sec = 1 },
    } }
    ns.Engine.view = nil; ns.Engine.current = 1
    local function mini() local n = 0; for _, p in ipairs(ns.Pins._used) do if p.where == "mini" and p.index == 1 then n = n + 1 end end; return n end
    ns.Pins.Update(true)
    assertEquals(0, mini(), "900 yd away: no minimap pin")
    px = 600; ns.Pins.Update()                  -- walked within 300 yd, same step, same zone
    assertEquals(1, mini(), "no minimap pin next to the step")
    px = 0; ns.Pins.Update()
    assertEquals(0, mini(), "the minimap pin stayed after walking off")
  end)
  HBD.GetPlayerWorldPosition, HBD.GetWorldCoordinatesFromZone, ns.db.pins, ns.State.Position = sv.p, sv.c, sv.pins, sv.pos
  ns.Engine.Refresh(); ns.Pins.Update(true)
  if not ok then error(err, 0) end
end)

test("side trips: a special-reward route opens like a dungeon route and keeps your path", function()
  local saved = ForeverRouteRoutes
  local main = { id = "path:A", title = "A", meta = { legs = "Redridge Mountains" }, sections = { { title = "x" } }, steps = { { id = 1, k = "goto", text = "a", sec = 1 } } }
  local bag = { id = "special:CozySleepingBag", title = "Special: Cozy Sleeping Bag", dungeon = true, special = true, dungeonName = "Cozy Sleeping Bag", why = "lasting XP bonus", meta = { legs = "Westfall > The Barrens" }, sections = { { title = "Westfall" } }, steps = { { id = 1, k = "accept", q = 79008, name = "note", sec = 1 } } }
  ForeverRouteRoutes = { main, bag }
  local ok, err = pcall(function()
    ns.SelectRoute("path:A", true)
    assertCount(1, ns.MainRoutes())
    ns.EnterDungeonRoute("special:CozySleepingBag")
    assertEquals("special:CozySleepingBag", ForeverRouteData.id)
    ns.LeaveDungeonRoute()
    assertEquals("path:A", ForeverRouteData.id)
    ns.Dungeons.Toggle(); ns.Dungeons.Toggle()
  end)
  ForeverRouteRoutes = saved
  ns.SelectRoute(ns.MainRoutes()[1].id, true)
  if not ok then error(err, 0) end
end)

test("card: a special reward you haven't done shows as a one-click row; hiding it keeps it under Side trips", function()
  local saved = ForeverRouteRoutes
  local main = { id = "path:A", title = "A", meta = { legs = "Redridge Mountains" }, sections = { { title = "x" } }, steps = { { id = 1, k = "goto", text = "a", sec = 1 } } }
  local bag = { id = "special:CozySleepingBag", title = "Special: Cozy Sleeping Bag", dungeon = true, special = true, dungeonName = "Cozy Sleeping Bag", meta = { legs = "Westfall" }, sections = { { title = "Westfall" } }, steps = { { id = 1, k = "accept", q = 79008, name = "note", sec = 1 } } }
  ForeverRouteRoutes = { main, bag }
  local ok, err = pcall(function()
    ns.SelectRoute("path:A", true)
    ns.char.hideSpecial = nil
    local o = ns.Card.SpecialOffer()
    assertNotNil(o)
    assertEquals("special:CozySleepingBag", o.route.id)
    ns.Card.Layout()
    ns.char.hideSpecial = { ["special:CozySleepingBag"] = true }
    assertNil(ns.Card.SpecialOffer())
    ns.Card.Layout()
  end)
  ns.char.hideSpecial = nil
  ForeverRouteRoutes = saved
  ns.SelectRoute(ns.MainRoutes()[1].id, true)
  if not ok then error(err, 0) end
end)

test("errands: eat Well Fed food before a kill step when you have some and aren't fed", function()
  local sv = { fed = ns.Errands.WellFed, food = ns.Errands.Food, free = ns.Errands.FreeSlots, dur = ns.Errands.Durability, data = ForeverRouteData, shown = ns.Engine.Shown }
  ns.Errands.FreeSlots = function() return 10 end
  ns.Errands.Durability = function() return 1 end
  ns.Errands.Food = function() return { name = "Goretusk Liver Pie" } end
  ns.char.errandDismissed = nil
  local fed = false
  ns.Errands.WellFed = function() return fed end
  ForeverRouteData = { steps = { { k = "obj", text = "Kill 10 Redridge Mongrel", q = 1 }, { k = "turnin", q = 1, name = "x" } } }
  local at = 1
  ns.Engine.Shown = function() return at end
  local ok, err = pcall(function()
    local t = ns.Errands.Current()
    assertNotNil(t); assertTrue(t:find("Goretusk Liver Pie", 1, true) ~= nil)
    fed = true; assertNil(ns.Errands.Current())          -- fed already
    fed = false; at = 2; assertNil(ns.Errands.Current()) -- a hand-in: no kills, no nudge
  end)
  ns.Errands.WellFed, ns.Errands.Food, ns.Errands.FreeSlots, ns.Errands.Durability, ForeverRouteData, ns.Engine.Shown = sv.fed, sv.food, sv.free, sv.dur, sv.data, sv.shown
  if not ok then error(err, 0) end
end)

test("save nudge: shows on a flight after a few minutes played, not on foot, not when dismissed, not without the companion", function()
  local sv = { taxi = UnitOnTaxi, after = ns.Card.SAVE_AFTER, comp = ns.HasCompanion }
  local ok, err = pcall(function()
    ns.Card.SAVE_AFTER = -1; ns.Card.saveDismissed = nil
    ns.HasCompanion = function() return false end; UnitOnTaxi = function() return true end
    assertNil(ns.Card.SaveNudge(), "addon only: nothing replans from a save")
    ns.HasCompanion = function() return true end
    UnitOnTaxi = function() return false end
    assertNil(ns.Card.SaveNudge())
    UnitOnTaxi = function() return true end
    assertNotNil(ns.Card.SaveNudge())
    ns.Card.Layout(); assertTrue(ForeverRouteCard.save:IsShown())
    ns.Card.saveDismissed = true
    assertNil(ns.Card.SaveNudge())
    ns.Card.SAVE_AFTER = 1e9; ns.Card.saveDismissed = nil
    assertNil(ns.Card.SaveNudge())
  end)
  UnitOnTaxi, ns.Card.SAVE_AFTER, ns.Card.saveDismissed, ns.HasCompanion = sv.taxi, sv.after, nil, sv.comp
  ns.Card.Layout()
  if not ok then error(err, 0) end
end)

test("new route ready: the companion's sound-file signal shows a Reload row anywhere, out of combat", function()
  local sv = { play = PlaySoundFile, grace = ns.Card.READY_GRACE, taxi = UnitOnTaxi, plan = ForeverRoutePlan }
  local ok, err = pcall(function()
    ns.Card.READY_GRACE = -1; ns.Card.planReady = nil; ns.Card.readyDismissed = nil
    UnitOnTaxi = function() return false end
    local valid = false
    ForeverRoutePlan = { generated = 12345 }
    PlaySoundFile = function(path) assertEquals("Interface\\AddOns\\ForeverRoute\\signal\\newer-12345.wav", path); return valid, valid and 7 or nil end
    ns.Card.CheckReady(); assertNil(ns.Card.SaveNudge())
    valid = true; ns.Card.CheckReady()
    local text, btn = ns.Card.SaveNudge()
    assertNotNil(text); assertEquals("Reload", btn)
    assertTrue(ForeverRouteCard.save:IsShown())
    ns.Card.readyDismissed = true; assertNil(ns.Card.SaveNudge())
    valid = false; ns.Card.CheckReady(); assertFalse(ns.Card.planReady)
  end)
  PlaySoundFile, ns.Card.READY_GRACE, UnitOnTaxi, ns.Card.planReady, ns.Card.readyDismissed = sv.play, sv.grace, sv.taxi, nil, nil
  ForeverRoutePlan = sv.plan
  ns.Card.Layout()
  if not ok then error(err, 0) end
end)

test("insertion: a hand-in on the road you're riding (no flight path yet) goes first, before the travel step", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { conv = HBD.GetWorldCoordinatesFromZone, plan = ns.Engine.TravelPlan, pos = ns.State.Position, data = ForeverRouteData, cur = ns.Engine.current }
  local off = { [1433] = { 1300, 300 }, [1431] = { 400, 900 } }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) local o = off[m]; if not o then return nil end return o[1] + x * 1000, o[2] + y * 1000, 0 end
  ns.State.Position = function() return 1433, 0.26, 0.59 end
  local ok, err = pcall(function()
    ForeverRouteData = { id = "t", steps = {
      { k = "fly", to = 1431, dest = "Duskwood", sec = 1 },
      { k = "fp", m = 1431, x = 0.77, y = 0.44, sec = 2 },
      { k = "accept", q = 1, m = 1431, x = 0.75, y = 0.45, sec = 2 },
      { k = "accept", q = 2, m = 1431, x = 0.20, y = 0.30, sec = 2 },
      { k = "turnin", q = 2, m = 1431, x = 0.75, y = 0.47, sec = 2 },
    } }
    ns.Engine.current = 1
    ns.Engine.TravelPlan = function() return { via = 1433, m = 1431, x = 0.77, y = 0.44 } end
    local px, py, pinst = HBD:GetWorldCoordinatesFromZone(0.26, 0.59, 1433)
    local at = ns.Engine.InsertStop({ k = "turnin", q = 98247, m = 1433, x = 0.097, y = 0.709 }, px, py, pinst)
    assertEquals(1, at)
    assertEquals(98247, ForeverRouteData.steps[1].q)
    assertEquals("fly", ForeverRouteData.steps[2].k)
  end)
  HBD.GetWorldCoordinatesFromZone, ns.Engine.TravelPlan, ns.State.Position, ForeverRouteData, ns.Engine.current = sv.conv, sv.plan, sv.pos, sv.data, sv.cur
  if not ok then error(err, 0) end
end)

test("flight paths: opening the flight map elsewhere doesn't tick the next zone's 'get the flight path' step", function()
  local sv = { pos = ns.State.Position, data = ForeverRouteData, cur = ns.Engine.current, taxi = ns.State.knownTaxi }
  local ok, err = pcall(function()
    ns.State.knownTaxi = { ["Stormwind, Elwynn"] = true }
    ForeverRouteData = { id = "fptest", steps = {
      { k = "fly", to = 1431, dest = "Duskwood", sec = 1 },
      { k = "fp", npc = "Felicia Maline", m = 1431, x = 0.77, y = 0.44, zone = "Duskwood", sec = 2 },
      { k = "accept", q = 1, m = 1431, x = 0.75, y = 0.45, sec = 2 },
    } }
    ns.char.manualDone = ns.char.manualDone or {}
    local k = ns.Engine.Key(2); ns.char.manualDone[k] = nil
    ns.Engine.Refresh()
    ns.State.Position = function() return 1453, 0.7, 0.7 end   -- Stormwind flight master
    ns.Fire("FR_TAXI_OPENED")
    assertNil(ns.char.manualDone[k])
    ns.State.Position = function() return 1431, 0.77, 0.44 end -- Darkshire flight master
    ns.Fire("FR_TAXI_OPENED")
    assertTrue(ns.char.manualDone[k])
    ns.char.manualDone[k] = nil
  end)
  ns.State.Position, ForeverRouteData, ns.Engine.current, ns.State.knownTaxi = sv.pos, sv.data, sv.cur, sv.taxi
  ns.Engine.Refresh()
  if not ok then error(err, 0) end
end)

planOrderTest("live reorder: standing in a town, its flight path and pick-ups come before a step across the zone", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { conv = HBD.GetWorldCoordinatesFromZone, data = ForeverRouteData, cur = ns.Engine.current, focus = ns.Engine.focus, view = ns.Engine.view, taxi = ns.State.knownTaxi }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) return x * 1500, y * 1000, 0 end
  local ok, err = pcall(function()
    ns.State.knownTaxi = {}
    ForeverRouteData = { id = "focustest", steps = {
      { k = "accept", q = 226, name = "Wolves at Our Heels", m = 1431, x = 0.077, y = 0.332, sec = 1 },
      { k = "fp", npc = "Felicia Maline", m = 1431, x = 0.7749, y = 0.4429, zone = "Duskwood", sec = 2 },
      { k = "accept", q = 163, name = "Raven Hill", m = 1431, x = 0.7534, y = 0.4875, sec = 2 },
    } }
    ns.Engine.view = nil; ns.Engine.focus = nil
    ns.Engine.Refresh()
    assertEquals(1, ns.Engine.current)
    ns.Engine.UpdateFocus(0.776 * 1500, 0.442 * 1000, 0)  -- standing by the flight master
    assertEquals(2, ns.Engine.focus)
  end)
  HBD.GetWorldCoordinatesFromZone, ForeverRouteData, ns.Engine.current, ns.Engine.focus, ns.Engine.view, ns.State.knownTaxi = sv.conv, sv.data, sv.cur, sv.focus, sv.view, sv.taxi
  ns.Engine.Refresh()
  if not ok then error(err, 0) end
end)

planOrderTest("live reorder: never jumps to a pick-up whose earlier chain quest isn't handed in (Chef Grual)", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { conv = HBD.GetWorldCoordinatesFromZone, data = ForeverRouteData, cur = ns.Engine.current, focus = ns.Engine.focus, view = ns.Engine.view, unl = ForeverRouteUnlocks, done = ns.State.IsCompleted }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) return x * 1500, y * 1000, 0 end
  local ok, err = pcall(function()
    ForeverRouteUnlocks = { [5] = { 93 } }
    ns.State.IsCompleted = function(q) return false end
    ForeverRouteData = { id = "grual", steps = {
      { k = "accept", q = 226, name = "Wolves at Our Heels", m = 1431, x = 0.077, y = 0.332, sec = 1 },
      { k = "accept", q = 93, name = "Dusky Crab Cakes", m = 1431, x = 0.7375, y = 0.4348, sec = 2 },
    } }
    ns.Engine.view = nil; ns.Engine.focus = nil
    ns.Engine.Refresh()
    ns.Engine.UpdateFocus(0.74 * 1500, 0.44 * 1000, 0)   -- standing next to Chef Grual
    assertNil(ns.Engine.focus)
    ns.State.IsCompleted = function(q) return q == 5 end -- Growling Gut handed in: now he offers it
    ns.Engine.UpdateFocus(0.74 * 1500, 0.44 * 1000, 0)
    assertEquals(2, ns.Engine.focus)
  end)
  HBD.GetWorldCoordinatesFromZone, ForeverRouteData, ns.Engine.current, ns.Engine.focus, ns.Engine.view, ForeverRouteUnlocks, ns.State.IsCompleted = sv.conv, sv.data, sv.cur, sv.focus, sv.view, sv.unl, sv.done
  ns.Engine.Refresh()
  if not ok then error(err, 0) end
end)

test("special reward: its next stop on your map is offered as a detour, even if you hid the row", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local saved = { routes = ForeverRouteRoutes, pos = ns.State.Position, on = ns.State.OnQuest, done = ns.State.IsCompleted, wp = HBD.GetPlayerWorldPosition, conv = HBD.GetWorldCoordinatesFromZone }
  local main = { id = "path:A", title = "A", meta = { legs = "Westfall" }, sections = { { title = "x" } }, steps = { { id = 1, k = "goto", text = "a", sec = 1 } } }
  local bag = { id = "special:CozySleepingBag", title = "Special: Cozy Sleeping Bag", dungeon = true, special = true, dungeonName = "Cozy Sleeping Bag", meta = { legs = "Westfall" }, sections = { { title = "Westfall" } },
    steps = { { id = 1, k = "accept", q = 79008, name = "note", m = 1436, x = 0.374, y = 0.507, sec = 1 }, { id = 2, k = "turnin", q = 79008, name = "note", m = 1413, x = 0.46, y = 0.74, sec = 1 } } }
  ForeverRouteRoutes = { main, bag }
  HBD.GetPlayerWorldPosition = function() return 500, 500, 0 end
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) return x * 1000, y * 1000, 0 end
  ns.State.OnQuest = function() return false end
  ns.State.IsCompleted = function() return false end
  local ok, err = pcall(function()
    ns.SelectRoute("path:A", true)
    ns.char.hideSpecial = { ["special:CozySleepingBag"] = true }
    ns.State.Position = function() return 1433, 0.5, 0.5 end            -- elsewhere: hidden row stays hidden
    assertNil(ns.Card.SpecialOffer())
    ns.State.Position = function() return 1436, 0.5, 0.5 end            -- in Westfall: offered as a detour
    local o = ns.Card.SpecialOffer()
    assertNotNil(o); assertTrue(o.near)
    assertTrue(o.text:find("next stop here", 1, true) ~= nil)
  end)
  ns.char.hideSpecial = nil
  ForeverRouteRoutes, ns.State.Position, ns.State.OnQuest, ns.State.IsCompleted, HBD.GetPlayerWorldPosition, HBD.GetWorldCoordinatesFromZone = saved.routes, saved.pos, saved.on, saved.done, saved.wp, saved.conv
  ns.SelectRoute(ns.MainRoutes()[1].id, true)
  if not ok then error(err, 0) end
end)

test("special reward: a hand-in whose objectives aren't done is not 'next stop here'; its objective's place is", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local saved = { routes = ForeverRouteRoutes, pos = ns.State.Position, quest = ns.State.Quest, done = ns.State.IsCompleted, wp = HBD.GetPlayerWorldPosition, conv = HBD.GetWorldCoordinatesFromZone }
  local main = { id = "path:A", title = "A", meta = { legs = "Westfall" }, sections = { { title = "x" } }, steps = { { id = 1, k = "goto", text = "a", sec = 1 } } }
  local tome = { id = "special:Felhunter", title = "Special: Felhunter", dungeon = true, special = true, dungeonName = "Felhunter", meta = { legs = "Ironforge" }, sections = { { title = "Ironforge" } },
    steps = { { id = 1, k = "accept", q = 1802, name = "Tome of the Cabal", m = 1455, x = 0.5, y = 0.5, sec = 1 },
      { id = 2, k = "obj", q = 1802, text = "Collect Tome of the Cabal Pages", match = "Tome of the Cabal", m = 1424, x = 0.6, y = 0.4, sec = 1 },
      { id = 3, k = "turnin", q = 1802, name = "Tome of the Cabal", m = 1455, x = 0.5, y = 0.5, sec = 1 },
      { id = 4, k = "accept", q = 1803, name = "Tome of the Cabal, part 2", m = 1455, x = 0.5, y = 0.5, sec = 1 } } }
  ForeverRouteRoutes = { main, tome }
  HBD.GetPlayerWorldPosition = function() return 500, 500, 0 end
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) return x * 1000, y * 1000, 0 end
  local quest = { on = true, complete = false, objectives = { { text = "Tome of the Cabal: 2/4", finished = false, have = 2, need = 4 } } }
  ns.State.Quest = function(id) if id == 1802 then return quest end return { on = false, objectives = {} } end
  ns.State.IsCompleted = function() return false end
  local ok, err = pcall(function()
    ns.SelectRoute("path:A", true)
    ns.char.hideSpecial = { ["special:Felhunter"] = true }
    ns.State.Position = function() return 1455, 0.5, 0.5 end            -- in Ironforge, at the giver: not ready, no nag
    assertNil(ns.Card.SpecialOffer())
    assertEquals(2, ns.Card.SpecialNext(tome).id)                        -- the next stop is the pages, in Hillsbrad
    ns.State.Position = function() return 1424, 0.5, 0.5 end            -- in Hillsbrad: the pages are worth a detour
    local o = ns.Card.SpecialOffer(); assertNotNil(o); assertTrue(o.near)
    quest.complete = true; quest.objectives[1].finished = true           -- pages done: the hand-in in Ironforge is next
    assertEquals(3, ns.Card.SpecialNext(tome).id)
    ns.State.Position = function() return 1455, 0.5, 0.5 end
    o = ns.Card.SpecialOffer(); assertNotNil(o); assertTrue(o.near)
    -- not ready, and no objective step to point at: nothing (not the follow-up's giver either)
    quest.complete = false; quest.objectives[1].finished = false
    table.remove(tome.steps, 2)
    assertNil(ns.Card.SpecialNext(tome))
  end)
  ns.char.hideSpecial = nil
  ForeverRouteRoutes, ns.State.Position, ns.State.Quest, ns.State.IsCompleted, HBD.GetPlayerWorldPosition, HBD.GetWorldCoordinatesFromZone = saved.routes, saved.pos, saved.quest, saved.done, saved.wp, saved.conv
  ns.SelectRoute(ns.MainRoutes()[1].id, true)
  if not ok then error(err, 0) end
end)

test("side trips: finished quests' hand-ins are not slotted into a special or dungeon route", function()
  local sv = { data = ForeverRouteData, enders = ForeverRouteEnders, ready = ns.State.QuestReady, done = ns.State.IsCompleted, cur = ns.Engine.current }
  local ok, err = pcall(function()
    ForeverRouteEnders = { [163] = { npc = "Jitters", m = 1431, x = 0.18, y = 0.56, name = "Raven Hill" } }
    ns.State.QuestReady = function(q) return q == 163 end
    ns.State.IsCompleted = function() return false end
    ForeverRouteData = { id = "special:CozySleepingBag", dungeon = true, special = true, steps = {
      { k = "fly", to = 1436, dest = "Westfall", sec = 1 },
      { k = "accept", q = 79008, name = "note", m = 1436, x = 0.37, y = 0.51, sec = 1 } } }
    ns.Engine.current = 1
    assertFalse(ns.Engine.ApplyInserts())
    assertCount(2, ForeverRouteData.steps)
  end)
  ForeverRouteData, ForeverRouteEnders, ns.State.QuestReady, ns.State.IsCompleted, ns.Engine.current = sv.data, sv.enders, sv.ready, sv.done, sv.cur
  ns.Engine.Refresh()
  if not ok then error(err, 0) end
end)

test("travel: the first stop right across the border is a ride, even with the flight path (Westfall -> Sven's camp)", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { conv = HBD.GetWorldCoordinatesFromZone, pos = ns.State.Position, taxi = ns.State.knownTaxi, data = ForeverRouteData, info = C_Map.GetMapInfo }
  -- Westfall to the west of Duskwood, Darkshire far east
  local off = { [1436] = { -1000, 0 }, [1431] = { 0, 0 } }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) local o = off[m]; if not o then return nil end return o[1] + x * 1700, o[2] + y * 1100, 0 end
  local names = { [1436] = "Westfall", [1431] = "Duskwood" }
  C_Map.GetMapInfo = function(m) return names[m] and { name = names[m] } or (sv.info and sv.info(m)) end
  local ok, err = pcall(function()
    ns.State.knownTaxi = { ["Sentinel Hill, Westfall"] = true, ["Darkshire, Duskwood"] = true }
    ForeverRouteData = { id = "ride", steps = {
      { k = "fly", to = 1431, dest = "Duskwood", sec = 1 },
      { k = "turnin", q = 164, name = "Deliveries to Sven", npc = "Sven Yorgen", m = 1431, x = 0.077, y = 0.333, sec = 2 },
    } }
    ns.State.Position = function() return 1436, 0.62, 0.40 end   -- east Westfall, near the Duskwood border
    local plan = ns.Engine.TravelPlan(ForeverRouteData.steps[1])
    assertNotNil(plan); assertTrue(plan.ride)
    assertEquals(1431, (ns.Engine.TravelTarget(ForeverRouteData.steps[1])))
    ns.State.Position = function() return 1431, 0.78, 0.44 end   -- standing at Darkshire: not a "ride to the west" plan from here
    ForeverRouteData.steps[2].x = 0.73                             -- first stop in Darkshire itself
    local p2 = ns.Engine.TravelPlan(ForeverRouteData.steps[1])
    assertTrue(p2 == nil or p2.ride)
  end)
  HBD.GetWorldCoordinatesFromZone, ns.State.Position, ns.State.knownTaxi, ForeverRouteData, C_Map.GetMapInfo = sv.conv, sv.pos, sv.taxi, sv.data, sv.info
  if not ok then error(err, 0) end
end)

test("travel for any step: in Stormwind with a Redridge hand-in next -> fly from the Stormwind flight master", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { conv = HBD.GetWorldCoordinatesFromZone, pos = ns.State.Position, taxi = ns.State.knownTaxi, info = C_Map.GetMapInfo, data = ForeverRouteData }
  local off = { [1453] = { -1200, -1200 }, [1433] = { 1300, 300 } }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) local o = off[m]; if not o then return nil end return o[1] + x * 1000, o[2] + y * 1000, 0 end
  local names = { [1453] = "Stormwind City", [1433] = "Redridge Mountains" }
  C_Map.GetMapInfo = function(m) return names[m] and { name = names[m] } or (sv.info and sv.info(m)) end
  local ok, err = pcall(function()
    ns.State.knownTaxi = { ["Stormwind, Elwynn"] = true, ["Lakeshire, Redridge"] = true }
    local s = { k = "turnin", q = 120, name = "Messenger to Stormwind", npc = "Magistrate Solomon", m = 1433, x = 0.25, y = 0.44 }
    ForeverRouteData = { id = "t", steps = { s } }
    ns.State.Position = function() return 1453, 0.5, 0.5 end
    local t = ns.Engine.TravelFor(s)
    assertNotNil(t); assertEquals("fly", t.how); assertEquals(1453, t.m)
    assertTrue(t.text:find("Fly to Redridge", 1, true) ~= nil)
    ns.State.Position = function() return 1433, 0.30, 0.50 end   -- landed in Redridge: same zone, no travel
    assertNil(ns.Engine.TravelFor(s))
  end)
  HBD.GetWorldCoordinatesFromZone, ns.State.Position, ns.State.knownTaxi, C_Map.GetMapInfo, ForeverRouteData = sv.conv, sv.pos, sv.taxi, sv.info, sv.data
  if not ok then error(err, 0) end
end)

-- a scripted loot window: target = { guid, name } or nil; slots = { { name, qty, sources = { guid, qty, ... } }, ... }
local guidSerial = 0
local function lootGuid(kind, npc) guidSerial = guidSerial + 1; return kind .. "-0-1-2-3-" .. npc .. "-" .. guidSerial end
local function withLoot(fn)
  local sv = { data = ForeverRouteData, cur = ns.Engine.current, view = ns.Engine.view, exists = UnitExists, dead = UnitIsDead, name = UnitName, guid = UnitGUID,
    n = GetNumLootItems, info = GetLootSlotInfo, link = GetLootSlotLink, src = GetLootSourceInfo, drops = ForeverRouteDB.drops }
  local window = { slots = {} }
  local ok, err = pcall(function()
    ForeverRouteDB.drops = {}
    UnitExists = function() return window.target ~= nil end
    UnitIsDead = function() return window.target ~= nil end
    UnitName = function() return window.target and window.target[2] end
    UnitGUID = function() return window.target and window.target[1] end
    GetNumLootItems = function() return #window.slots end
    GetLootSlotInfo = function(i) local sl = window.slots[i]; return 134400, sl[1], sl[2] or 1 end
    GetLootSlotLink = function() return nil end
    GetLootSourceInfo = function(i) return unpack(window.slots[i].sources or {}) end
    fn(window)
  end)
  ForeverRouteData, ns.Engine.current, ns.Engine.view, UnitExists, UnitIsDead, UnitName, UnitGUID = sv.data, sv.cur, sv.view, sv.exists, sv.dead, sv.name, sv.guid
  GetNumLootItems, GetLootSlotInfo, GetLootSlotLink, GetLootSourceInfo, ForeverRouteDB.drops = sv.n, sv.info, sv.link, sv.src, sv.drops
  if not ok then error(err, 0) end
end

test("drop rates: kills and drops are counted on a collect step, and rare drops are flagged", function()
  withLoot(function(w)
    local s = { k = "obj", q = 20, text = "Collect 10 Battleworn Axe", match = "Battleworn Axe", target = "Blackrock Outrunner", loot = true, rate = 50 }
    ForeverRouteData = { id = "t", steps = { s } }
    ns.Engine.current = 1; ns.Engine.view = nil
    for k = 1, 20 do
      local g = lootGuid("Creature", 437)
      w.target = { g, "Blackrock Outrunner" }
      w.slots = { { "5 Copper", 1, sources = { g, 1 } } }
      if k % 10 == 0 then w.slots[2] = { "Battleworn Axe", 1, sources = { g, 1 } } end
      ns.Drops.OnLoot()
    end
    local e = ForeverRouteDB.drops["Battleworn Axe"]
    assertEquals(20, e.kills); assertEquals(2, e.drops)
    local note = ns.Drops.Note(s)
    assertNotNil(note); assertTrue(note:find("2 from 20 kills", 1, true) ~= nil)
    s.rate = 8; assertNil(ns.Drops.Note(s))   -- 10% measured vs 8% planned: fine
  end)
end)

test("drop rates: a tree or chest, skinning, reopening, the wrong mob and a step you only view are not kills", function()
  withLoot(function(w)
    local s = { k = "obj", q = 21, text = "Collect 10 Razormaw Incisor (Highland Razormaw, Elder Razormaw)", match = "Razormaw Incisor", loot = true, rate = 40 }
    local tree = { k = "obj", q = 1738, text = "Collect Heartswood", match = "Heartswood", loot = true }
    ForeverRouteData = { id = "t", steps = { s, tree } }
    ns.Engine.current = 1; ns.Engine.view = nil
    local function e(item) return ForeverRouteDB.drops[item] or { kills = 0, drops = 0 } end
    -- a Highland Razormaw corpse (named in the step text): one kill
    local g = lootGuid("Creature", 1018)
    w.target = { g, "Highland Razormaw" }; w.slots = { { "3 Copper", 1, sources = { g, 1 } } }
    ns.Drops.OnLoot(); assertEquals(1, e("Razormaw Incisor").kills)
    -- reopening it, then skinning it: the same corpse, still one kill
    ns.Drops.OnLoot()
    w.slots = { { "Light Leather", 1, sources = { g, 1 } } }; ns.Drops.OnLoot()
    assertEquals(1, e("Razormaw Incisor").kills)
    -- a wolf on the way (not named by the step, no incisor): not a kill
    local wolf = lootGuid("Creature", 1131)
    w.target = { wolf, "Mottled Wolf" }; w.slots = { { "2 Copper", 1, sources = { wolf, 1 } } }
    ns.Drops.OnLoot(); assertEquals(1, e("Razormaw Incisor").kills)
    -- a chest opened while that dead wolf is still targeted: the source is a game object, not a kill
    w.slots = { { "Linen Cloth", 1, sources = { lootGuid("GameObject", 2843), 1 } } }
    ns.Drops.OnLoot(); assertEquals(1, e("Razormaw Incisor").kills)
    -- the Heartswood tree with a dead mob targeted: never a kill
    ns.Engine.current = 2
    w.slots = { { "Heartswood", 1, sources = { lootGuid("GameObject", 19901), 1 } } }
    ns.Drops.OnLoot(); assertEquals(0, e("Heartswood").kills); assertEquals(0, e("Heartswood").drops)
    -- a corpse looted while you are only viewing the collect step from the list: not counted for it
    ns.Engine.view = 1
    local g2 = lootGuid("Creature", 1018)
    w.target = { g2, "Highland Razormaw" }; w.slots = { { "Razormaw Incisor", 1, sources = { g2, 1 } } }
    ns.Drops.OnLoot(); assertEquals(1, e("Razormaw Incisor").kills); assertEquals(0, e("Razormaw Incisor").drops)
    -- area loot: the targeted corpse and another of the same npc (learned from the target) both count, once each
    ns.Engine.current = 1; ns.Engine.view = nil
    local a, b = lootGuid("Creature", 1018), lootGuid("Creature", 1018)
    w.target = { a, "Highland Razormaw" }; w.slots = { { "Razormaw Incisor", 1, sources = { b, 1 } }, { "4 Copper", 1, sources = { a, 1, b, 1 } } }
    ns.Drops.OnLoot(); assertEquals(3, e("Razormaw Incisor").kills); assertEquals(1, e("Razormaw Incisor").drops)
  end)
end)

test("drop rates: a step with no planned rate is not judged against a made-up one, and the decision log gets one line", function()
  local saved = { drops = ForeverRouteDB.drops, why = ForeverRouteDB.why }
  local ok, err = pcall(function()
    ForeverRouteDB.why = {}
    local s = { k = "obj", q = 23, text = "Collect 1 Head of Targorr (Targorr the Dread) (in The Stockade)", match = "Head of Targorr", loot = true }
    ForeverRouteDB.drops = { ["Head of Targorr"] = { kills = 20, drops = 4 } }   -- 20%: fine for an unknown rate
    assertNil(ns.Drops.Note(s))
    ForeverRouteDB.drops["Head of Targorr"] = { kills = 20, drops = 1 }           -- 5%, but too few corpses to say
    assertNil(ns.Drops.Note(s))
    for k = 26, 30 do
      ForeverRouteDB.drops["Head of Targorr"] = { kills = k, drops = 1 }
      local note = ns.Drops.Note(s)
      assertNotNil(note); assertNil(note:find("assumed", 1, true)); assertTrue(note:find("1 from " .. k .. " kills", 1, true) ~= nil)
    end
    local n = 0
    for _, w in ipairs(ForeverRouteDB.why) do if w.k == "drops" then n = n + 1 end end
    assertEquals(1, n)
  end)
  ForeverRouteDB.drops, ForeverRouteDB.why = saved.drops, saved.why
  if not ok then error(err, 0) end
end)

test("drop rates: when the step names no mob, only mobs seen dropping the item count", function()
  withLoot(function(w)
    local s = { k = "obj", q = 22, text = "Collect 10 Murloc Head", match = "Murloc Head", loot = true, rate = 30 }
    ForeverRouteData = { id = "t", steps = { s } }
    ns.Engine.current = 1; ns.Engine.view = nil
    local function kill(npc, name, head)
      local g = lootGuid("Creature", npc); w.target = { g, name }
      w.slots = { { "1 Copper", 1, sources = { g, 1 } } }
      if head then w.slots[2] = { "Murloc Head", 1, sources = { g, 1 } } end
      ns.Drops.OnLoot()
    end
    kill(1768, "Bluegill Murloc", false)   -- nothing known yet: not counted
    kill(1131, "Mottled Wolf", false)
    local e0 = ForeverRouteDB.drops["Murloc Head"]
    assertEquals(0, e0 and e0.kills or 0)
    kill(1768, "Bluegill Murloc", true)    -- dropped one: a source from now on
    kill(1768, "Bluegill Murloc", false)
    kill(1131, "Mottled Wolf", false)      -- never dropped it: still not counted
    local e = ForeverRouteDB.drops["Murloc Head"]
    assertEquals(2, e.kills); assertEquals(1, e.drops)
  end)
end)

test("decision log: reasons are recorded, repeats within two minutes are not, /fr why prints them", function()
  local saved = ForeverRouteDB.why
  local ok, err = pcall(function()
    ForeverRouteDB.why = {}
    ns.Why("test", "a reason")
    ns.Why("test", "a reason")            -- same thing again: once is enough
    ns.Why("test", "another reason")
    assertCount(2, ForeverRouteDB.why)
    assertEquals("test", ForeverRouteDB.why[1].k)
    ns.WhyPrint(5)
    ns.Card.Layout()                        -- card rows log themselves without errors
  end)
  ForeverRouteDB.why = saved
  if not ok then error(err, 0) end
end)

test("side trips merge: on the Succubus trip, nearby sleeping bag stops are slotted in on the way, far ones wait", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { routes = ForeverRouteRoutes, conv = HBD.GetWorldCoordinatesFromZone, wp = HBD.GetPlayerWorldPosition, on = ns.State.OnQuest, done = ns.State.IsCompleted }
  local off = { [1413] = { 0, 0 }, [1440] = { 0, -1500 }, [1442] = { -1500, -1000 }, [1432] = { 5000, 5000 } }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) local o = off[m]; if not o then return nil end return o[1] + x * 1000, o[2] + y * 1000, (m == 1432) and 1 or 0 end
  HBD.GetPlayerWorldPosition = function() return 490, 570, 0 end
  ns.State.IsCompleted = function() return false end
  ns.State.OnQuest = function(q) return q == 79008 end
  local main = { id = "path:A", title = "A", meta = { legs = "Redridge" }, sections = { { title = "x" } }, steps = { { id = 1, k = "goto", text = "a", sec = 1 } } }
  local succ = { id = "special:Succubus", title = "Succubus", dungeon = true, special = true, dungeonName = "Succubus (warlock 20)", needsLevel = 1, meta = { legs = "x" }, sections = { { title = "x" } }, steps = {
    { k = "turnin", q = 1716, name = "Devourer of Souls", npc = "Takar the Seer", m = 1413, x = 0.49, y = 0.57, sec = 1 },
    { k = "accept", q = 1738, name = "Heartswood", npc = "Takar the Seer", m = 1413, x = 0.49, y = 0.57, sec = 1 },
    { k = "obj", q = 1738, name = "Heartswood", text = "Collect Heartswood", m = 1440, x = 0.31, y = 0.31, sec = 1 },
  } }
  local bag = { id = "special:CozySleepingBag", title = "Bag", dungeon = true, special = true, dungeonName = "Cozy Sleeping Bag", needsLevel = 1, meta = { legs = "x" }, sections = { { title = "x" } }, steps = {
    { k = "turnin", q = 79008, name = "note", m = 1413, x = 0.46, y = 0.74, sec = 1 },
    { k = "accept", q = 79192, name = "Stepping Stones", m = 1413, x = 0.46, y = 0.74, sec = 1 },
    { k = "turnin", q = 79974, name = "Wet Job", m = 1432, x = 0.49, y = 0.13, sec = 1 },   -- other continent: waits
  } }
  ForeverRouteRoutes = { main, succ, bag }
  local ok, err = pcall(function()
    ns.SelectRoute("special:Succubus", true)
    ns.Engine.Refresh()
    ForeverRouteData.steps._merged = nil
    assertTrue(ns.Engine.MergeSideTrips())
    local qs = {}; for _, s in ipairs(ForeverRouteData.steps) do qs[#qs + 1] = s.q end
    local has = function(q) for _, x in ipairs(qs) do if x == q then return true end end end
    if not (has(79008) and has(79192)) or has(79974) then error("steps: " .. table.concat(qs, ",") .. " current=" .. tostring(ns.Engine.current), 0) end
    -- the note goes in before the Stepping Stones pick-up
    local a, b; for i, s in ipairs(ForeverRouteData.steps) do if s.q == 79008 then a = i end; if s.q == 79192 then b = i end end
    assertTrue(a < b)
    -- never between the two Takar steps (turn in Devourer, accept Heartswood: same NPC)
    for i = 2, #ForeverRouteData.steps do local p, q = ForeverRouteData.steps[i - 1], ForeverRouteData.steps[i]; assertTrue(not (q.inserted and p.q == 1716 and ForeverRouteData.steps[i + 1] and ForeverRouteData.steps[i + 1].q == 1738), "split the Takar steps") end
    -- and with a travel step first (you are still in Stormwind): the order must hold too
    table.insert(succ.steps, 1, { k = "fly", to = 1413, dest = "The Barrens", sec = 1 })
  end)
  ForeverRouteRoutes, HBD.GetWorldCoordinatesFromZone, HBD.GetPlayerWorldPosition, ns.State.OnQuest, ns.State.IsCompleted = sv.routes, sv.conv, sv.wp, sv.on, sv.done
  ns.SelectRoute(ns.MainRoutes()[1].id, true)
  if not ok then error(err, 0) end
end)

test("chat lines from the addon are kept in the saved chat log", function()
  local saved = ForeverRouteDB.chat
  ForeverRouteDB.chat = {}
  ns.Print("|cff00ff00hello|r there")
  assertCount(1, ForeverRouteDB.chat)
  assertEquals("hello there", ForeverRouteDB.chat[1].x)
  ForeverRouteDB.chat = saved
end)

test("travel: standing on a city waypoint, the arrow's first target is really ahead (Trade District -> the harbor, not 1 yd)", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { conv = HBD.GetWorldCoordinatesFromZone, pos = ns.State.Position, taxi = ns.State.knownTaxi, info = C_Map.GetMapInfo, docks = ForeverRouteDB.docks }
  local off = { [1453] = { 0, 0, 0 }, [1437] = { 500, -2000, 0 }, [1429] = { 0, 1000, 0 }, [1439] = { 0, -3000, 1 } }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) local o = off[m]; if not o then return nil end return o[1] + x * 1000, o[2] + y * 1000, o[3] end
  local names = { [1453] = "Stormwind City", [1437] = "Wetlands", [1429] = "Elwynn Forest", [1439] = "Darkshore" }
  C_Map.GetMapInfo = function(m) return names[m] and { name = names[m] } or nil end
  ForeverRouteDB.docks = {}
  local ok, err = pcall(function()
    ns.State.knownTaxi = { ["Stormwind, Elwynn"] = true }
    -- the network's "Stormwind City" waypoint is at 61.5, 73.5: where you stand by the bank
    local px, py = 0.615, 0.735
    ns.State.Position = function() return 1453, px, py end
    local legs = ns.Travel.Plan({ m = 1453, x = px, y = py }, { m = 1439, x = 0.3704, y = 0.4413, name = "Auberdine" })
    assertNotNil(legs)
    local l1 = legs[1]
    assertNotNil(l1.x, ns.Travel.Describe(legs))
    local a1, a2 = HBD:GetWorldCoordinatesFromZone(px, py, 1453)
    local b1, b2 = HBD:GetWorldCoordinatesFromZone(l1.x, l1.y, l1.m)
    local yd = math.sqrt((a1 - b1) ^ 2 + (a2 - b2) ^ 2)
    assertTrue(yd >= ns.Travel.AHEAD_YD, "the first leg points " .. math.floor(yd) .. " yd away: " .. ns.Travel.Describe(legs))
  end)
  HBD.GetWorldCoordinatesFromZone, ns.State.Position, ns.State.knownTaxi, C_Map.GetMapInfo, ForeverRouteDB.docks = sv.conv, sv.pos, sv.taxi, sv.info, sv.docks
  if not ok then error(err, 0) end
end)

test("travel graph: Stormwind to the Barrens goes by boat (no flying across the sea)", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { conv = HBD.GetWorldCoordinatesFromZone, pos = ns.State.Position, taxi = ns.State.knownTaxi, info = C_Map.GetMapInfo, docks = ForeverRouteDB.docks }
  -- Eastern Kingdoms (instance 0) and Kalimdor (instance 1), roughly laid out
  local off = { [1453] = { 0, 0, 0 }, [1437] = { 500, -2000, 0 }, [1434] = { -500, 3000, 0 }, [1433] = { 1500, 300, 0 },
    [1439] = { 0, -3000, 1 }, [1445] = { 2500, 1500, 1 }, [1413] = { 1500, 500, 1 } }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) local o = off[m]; if not o then return nil end return o[1] + x * 1000, o[2] + y * 1000, o[3] end
  local names = { [1453] = "Stormwind City", [1437] = "Wetlands", [1434] = "Stranglethorn Vale", [1433] = "Redridge Mountains", [1439] = "Darkshore", [1445] = "Dustwallow Marsh", [1413] = "The Barrens" }
  C_Map.GetMapInfo = function(m) return names[m] and { name = names[m] } or nil end
  ForeverRouteDB.docks = {}
  local ok, err = pcall(function()
    ns.State.knownTaxi = { ["Stormwind, Elwynn"] = true, ["Lakeshire, Redridge"] = true }
    ns.State.Position = function() return 1453, 0.5, 0.5 end
    local legs = ns.Travel.Plan({ m = 1453, x = 0.5, y = 0.5 }, { m = 1413, x = 0.49, y = 0.57, name = "The Barrens" })
    assertNotNil(legs)
    local boat = false; for _, l in ipairs(legs) do if l.how == "boat" then boat = true end end
    assertTrue(boat, ns.Travel.Describe(legs))
    local t = ns.Engine.TravelFor({ k = "turnin", q = 1716, m = 1413, x = 0.49, y = 0.57, zone = "The Barrens" })
    assertNotNil(t); assertTrue(t.text:find("Boat", 1, true) ~= nil)
  end)
  HBD.GetWorldCoordinatesFromZone, ns.State.Position, ns.State.knownTaxi, C_Map.GetMapInfo, ForeverRouteDB.docks = sv.conv, sv.pos, sv.taxi, sv.info, sv.docks
  if not ok then error(err, 0) end
end)

test("travel graph: off Zephras Isle by the skyship to Dalaran and the Skyborne portal to Stormwind, said on the card", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { conv = HBD.GetWorldCoordinatesFromZone, pos = ns.State.Position, taxi = ns.State.knownTaxi, info = C_Map.GetMapInfo, docks = ForeverRouteDB.docks, net = ns.Travel.NET, key = ns.StarterKey }
  ns.Travel.NET = nil -- straight lines on a made-up map; Zephras Isle is its own world, off any network
  ns.StarterKey = function() return "skyborne-hunter" end -- the portal is Skyborne-only
  local off = { [1453] = { 0, 0, 0 }, [1429] = { 0, 1000, 0 }, [1416] = { -3000, 0, 0 }, [2521] = { 0, 0, 7 } }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) local o = off[m]; if not o then return nil end return o[1] + x * 1000, o[2] + y * 1000, o[3] end
  local names = { [1453] = "Stormwind City", [1429] = "Elwynn Forest", [1416] = "Alterac Mountains", [2521] = "Zephras Isle" }
  C_Map.GetMapInfo = function(m) return names[m] and { name = names[m] } or nil end
  ForeverRouteDB.docks = {}
  local ok, err = pcall(function()
    ns.State.knownTaxi = {}
    ns.State.Position = function() return 2521, 0.64, 0.75 end
    local legs = ns.Travel.Plan({ m = 2521, x = 0.64, y = 0.75 }, { m = 1429, x = 0.42, y = 0.65, name = "Elwynn Forest" })
    assertNotNil(legs, "no way off the island")
    local texts = {}; for _, l in ipairs(legs) do texts[#texts + 1] = l.text or "" end
    local said = table.concat(texts, " | ")
    assertTrue(said:find("skyship", 1, true) ~= nil, said)
    assertTrue(said:find("Skyborne portal", 1, true) ~= nil, said)
    assertTrue(said:find("Boat to", 1, true) == nil, "a skyship is not a boat: " .. said)
    -- anyone else has no Skyborne portal (Method: "the Skyborne-only portal from Dalaran to Stormwind")
    ns.StarterKey = function() return "gnome-warlock" end
    local legs2 = ns.Travel.Plan({ m = 2521, x = 0.64, y = 0.75 }, { m = 1429, x = 0.42, y = 0.65, name = "Elwynn Forest" })
    local t2 = {}; for _, l in ipairs(legs2 or {}) do t2[#t2 + 1] = l.text or "" end
    assertTrue(table.concat(t2, " | "):find("Skyborne portal", 1, true) == nil, "a gnome took the Skyborne portal: " .. table.concat(t2, " | "))
  end)
  HBD.GetWorldCoordinatesFromZone, ns.State.Position, ns.State.knownTaxi, C_Map.GetMapInfo, ForeverRouteDB.docks, ns.Travel.NET, ns.StarterKey = sv.conv, sv.pos, sv.taxi, sv.info, sv.docks, sv.net, sv.key
  if not ok then error(err, 0) end
end)

test("travel graph: never rides out through a zone far above you (Theramore at 21 -> fly, not ride through Dustwallow)", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { conv = HBD.GetWorldCoordinatesFromZone, taxi = ns.State.knownTaxi, info = C_Map.GetMapInfo, lvl = UnitLevel, docks = ForeverRouteDB.docks, net = ns.Travel.NET }
  ns.Travel.NET = nil -- the straight-line rules on a made-up map (the real network has its own test)
  local off = { [1445] = { 2500, 1500, 1 }, [1413] = { 1200, 500, 1 }, [1439] = { 0, -3000, 1 }, [1440] = { 500, -1500, 1 } }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) local o = off[m]; if not o then return nil end return o[1] + x * 1000, o[2] + y * 1000, o[3] end
  local names = { [1445] = "Dustwallow Marsh", [1413] = "The Barrens", [1439] = "Darkshore", [1440] = "Ashenvale" }
  C_Map.GetMapInfo = function(m) return names[m] and { name = names[m] } or nil end
  ForeverRouteDB.docks = {}
  UnitLevel = function() return 21 end
  local ok, err = pcall(function()
    ns.State.knownTaxi = { ["Theramore, Dustwallow Marsh"] = true, ["Auberdine, Darkshore"] = true }
    local legs = ns.Travel.Plan({ m = 1445, x = 0.65, y = 0.46 }, { m = 1413, x = 0.49, y = 0.57, name = "The Barrens" })
    assertNotNil(legs)
    assertEquals("fly", legs[1].how, ns.Travel.Describe(legs))
    for _, l in ipairs(legs) do if l.how == "ride" then assertTrue(l.sm ~= 1445, "rode out of Dustwallow: " .. ns.Travel.Describe(legs)) end end
  end)
  HBD.GetWorldCoordinatesFromZone, ns.State.knownTaxi, C_Map.GetMapInfo, UnitLevel, ForeverRouteDB.docks, ns.Travel.NET = sv.conv, sv.taxi, sv.info, sv.lvl, sv.docks, sv.net
  if not ok then error(err, 0) end
end)

test("travel graph: with both flight paths, Theramore to Darkshore is a flight, not two boats", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { conv = HBD.GetWorldCoordinatesFromZone, taxi = ns.State.knownTaxi, info = C_Map.GetMapInfo, lvl = UnitLevel, docks = ForeverRouteDB.docks, net = ns.Travel.NET }
  ns.Travel.NET = nil -- the straight-line rules on a made-up map (the real network has its own test)
  local off = { [1445] = { 2500, 1500, 1 }, [1439] = { 0, -3000, 1 }, [1437] = { 500, -2000, 0 } }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) local o = off[m]; if not o then return nil end return o[1] + x * 1000, o[2] + y * 1000, o[3] end
  local names = { [1445] = "Dustwallow Marsh", [1439] = "Darkshore", [1437] = "Wetlands" }
  C_Map.GetMapInfo = function(m) return names[m] and { name = names[m] } or nil end
  ForeverRouteDB.docks = {}
  UnitLevel = function() return 21 end
  local ok, err = pcall(function()
    ns.State.knownTaxi = { ["Theramore, Dustwallow Marsh"] = true, ["Auberdine, Darkshore"] = true }
    local legs = ns.Travel.Plan({ m = 1445, x = 0.66, y = 0.42 }, { m = 1439, x = 0.40, y = 0.80, name = "Darkshore" })
    assertNotNil(legs)
    assertEquals("fly", legs[1].how, ns.Travel.Describe(legs))
  end)
  HBD.GetWorldCoordinatesFromZone, ns.State.knownTaxi, C_Map.GetMapInfo, UnitLevel, ForeverRouteDB.docks, ns.Travel.NET = sv.conv, sv.taxi, sv.info, sv.lvl, sv.docks, sv.net
  if not ok then error(err, 0) end
end)

test("travel graph: Ashenvale to the Barrens goes through the breach, never past Mor'shan Rampart", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { conv = HBD.GetWorldCoordinatesFromZone, taxi = ns.State.knownTaxi, info = C_Map.GetMapInfo, lvl = UnitLevel, docks = ForeverRouteDB.docks, net = ns.Travel.NET }
  ns.Travel.NET = nil -- the straight-line rules on a made-up map (the real network has its own test)
  local off = { [1440] = { 0, -1000, 1 }, [1413] = { 0, 0, 1 } }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) local o = off[m]; if not o then return nil end return o[1] + x * 1000, o[2] + y * 1000, o[3] end
  local names = { [1440] = "Ashenvale", [1413] = "The Barrens" }
  C_Map.GetMapInfo = function(m) return names[m] and { name = names[m] } or nil end
  ForeverRouteDB.docks = {}
  UnitLevel = function() return 21 end
  local ok, err = pcall(function()
    ns.State.knownTaxi = {}
    local legs = ns.Travel.Plan({ m = 1440, x = 0.30, y = 0.80 }, { m = 1413, x = 0.49, y = 0.57, name = "The Barrens" })
    assertNotNil(legs)
    assertTrue(ns.Travel.Describe(legs):find("breach", 1, true) ~= nil, ns.Travel.Describe(legs))
  end)
  HBD.GetWorldCoordinatesFromZone, ns.State.knownTaxi, C_Map.GetMapInfo, UnitLevel, ForeverRouteDB.docks, ns.Travel.NET = sv.conv, sv.taxi, sv.info, sv.lvl, sv.docks, sv.net
  if not ok then error(err, 0) end
end)

test("travel network (real maps): Stormwind to the Crossroads at 21 is a boat and rides through crossings; level 12 never rides into Duskwood", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local B = ns.TravelData.BOUNDS
  assertNotNil(ns.Travel.NET); assertNotNil(B)
  -- the sim has no map data: world coords from the zone bounds the planner uses (same yards as the network)
  local sv = { conv = HBD.GetWorldCoordinatesFromZone, info = C_Map.GetMapInfo, taxi = ns.State.knownTaxi, lvl = UnitLevel, docks = ForeverRouteDB.docks }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) local b = B[m]; if not b then return nil end return b[1] + x * (b[2] - b[1]), b[3] + y * (b[4] - b[3]), b[5] end
  local names = { [1453] = "Stormwind City", [1439] = "Darkshore", [1440] = "Ashenvale", [1413] = "The Barrens", [1445] = "Dustwallow Marsh", [1436] = "Westfall", [1431] = "Duskwood", [1429] = "Elwynn Forest" }
  C_Map.GetMapInfo = function(m) return { name = names[m] or ("map " .. m) } end
  ForeverRouteDB.docks = {}
  local ok, err = pcall(function()
    ns.State.knownTaxi = { ["Stormwind, Elwynn"] = true, ["Auberdine, Darkshore"] = true }
    UnitLevel = function() return 21 end
    local legs = ns.Travel.Plan({ m = 1453, x = 0.62, y = 0.72 }, { m = 1413, x = 0.52, y = 0.30, name = "The Crossroads" })
    assertNotNil(legs)
    local text = ns.Travel.Describe(legs)
    local boat = false
    for _, l in ipairs(legs) do
      if l.how == "boat" then boat = true end
      assertTrue(not (l.how == "ride" and l.sm == 1445), "rode out of Dustwallow: " .. text)
    end
    assertTrue(boat, text)
    assertTrue(text:find("border", 1, true) ~= nil, "the ride names its crossings: " .. text)
    UnitLevel = function() return 12 end
    ns.State.knownTaxi = { ["Sentinel Hill, Westfall"] = true }
    assertNil(ns.Travel.Plan({ m = 1436, x = 0.56, y = 0.47 }, { m = 1431, x = 0.75, y = 0.45, name = "Darkshire" }), "level 12 rode into Duskwood")
  end)
  HBD.GetWorldCoordinatesFromZone, C_Map.GetMapInfo, ns.State.knownTaxi, UnitLevel, ForeverRouteDB.docks = sv.conv, sv.info, sv.taxi, sv.lvl, sv.docks
  if not ok then error(err, 0) end
end)

test("travel network: bound in Stormwind with the hearthstone ready, the Crossroads to Gakin is a hearth; on cooldown it never is, and the long ride to the boat is its own leg", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local B = ns.TravelData.BOUNDS
  local sv = { conv = HBD.GetWorldCoordinatesFromZone, info = C_Map.GetMapInfo, taxi = ns.State.knownTaxi, lvl = UnitLevel, docks = ForeverRouteDB.docks,
    bind = GetBindLocation, count = GetItemCount, cd = ns.HearthCooldown, bound = ns.char.boundAt }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) local b = B[m]; if not b then return nil end return b[1] + x * (b[2] - b[1]), b[3] + y * (b[4] - b[3]), b[5] end
  local names = { [1453] = "Stormwind City", [1439] = "Darkshore", [1440] = "Ashenvale", [1413] = "The Barrens" }
  C_Map.GetMapInfo = function(m) return { name = names[m] or ("map " .. m) } end
  ForeverRouteDB.docks = {}
  local cd = 0
  GetBindLocation = function() return "Stormwind City" end
  GetItemCount = function(id) return id == 6948 and 1 or 0 end
  ns.HearthCooldown = function() return cd end
  ns.char.boundAt = { m = 1453, name = "Stormwind City" }
  local ok, err = pcall(function()
    ns.State.knownTaxi = { ["Stormwind, Elwynn"] = true, ["Auberdine, Darkshore"] = true }
    UnitLevel = function() return 21 end
    local gakin = { m = 1453, x = 0.3922, y = 0.8523, name = "Gakin the Darkbinder" }
    local legs = ns.Travel.Plan({ m = 1413, x = 0.49, y = 0.57 }, gakin)
    assertNotNil(legs)
    assertEquals("hearth", legs[1].how, ns.Travel.Describe(legs))
    cd = 1800
    legs = ns.Travel.Plan({ m = 1413, x = 0.49, y = 0.57 }, gakin)
    assertNotNil(legs)
    for _, l in ipairs(legs) do assertTrue(l.how ~= "hearth", "hearth on cooldown: " .. ns.Travel.Describe(legs)) end
    assertEquals("ride", legs[1].how, "the ride up to the boat is a leg of its own: " .. ns.Travel.Describe(legs))
  end)
  HBD.GetWorldCoordinatesFromZone, C_Map.GetMapInfo, ns.State.knownTaxi, UnitLevel, ForeverRouteDB.docks = sv.conv, sv.info, sv.taxi, sv.lvl, sv.docks
  GetBindLocation, GetItemCount, ns.HearthCooldown, ns.char.boundAt = sv.bind, sv.count, sv.cd, sv.bound
  if not ok then error(err, 0) end
end)

test("boat steps read 'Boat to <town>' on the card, the timeline and the arrow, never 'Fly to'", function()
  local s = { k = "fly", boat = "stormwind", dest = "Darkshore", to = 1439, m = 1453, x = 0.2789, y = 0.2741, r = 60, text = "Boat to Auberdine" }
  local title = ns.Card.Plain((ns.Card.Describe(s)))
  assertEquals("Boat to Auberdine", title:sub(1, #"Boat to Auberdine"))
  assertTrue(not title:find("Fly", 1, true), title)
  assertEquals("Boat to", ns.Style.Kind(s).verb)
  -- without a town name it still says boat
  assertEquals("Boat to Darkshore", ns.Card.Plain((ns.Card.Describe({ k = "fly", boat = "x", dest = "Darkshore" }))))
  -- a real flight is unchanged
  assertEquals("Fly to Westfall", ns.Card.Plain((ns.Card.Describe({ k = "fly", dest = "Westfall", to = 1436 }))))
end)

test("live reordering keeps the step's own warnings and the full-log alert, with the planned step as a dim line", function()
  local sv = { lc = ns.State.LogCount, ml = ns.State.MaxLog }
  local ok, err = pcall(withState, {}, function()
    ForeverRouteData = { id = "fw", title = "fw", sections = { { title = "x" } }, steps = {
      { id = 1, k = "accept", q = 701, name = "Far Away", npc = "A", sec = 1 },
      { id = 2, k = "accept", q = 702, name = "Escort", npc = "B", warn = true, note = "Heads up: 3 elites around the objective", sec = 1 },
    } }
    ns.Engine.view = nil; ns.Engine.current = 2; ns.Engine.planned = 1
    local note = function() ns.Card.Fill(); return ns.Card.Plain(ForeverRouteCard.cur.note:GetText()) end
    ns.State.LogCount = function() return 10 end; ns.State.MaxLog = function() return 40 end
    local t = note()
    assertTrue(t:find("3 elites", 1, true) ~= nil, t)
    assertTrue(t:find("planned next: Accept Far Away", 1, true) ~= nil, t)
    ns.State.LogCount = function() return 40 end
    t = note()
    assertTrue(t:find("Quest log full", 1, true) ~= nil, t)
    assertTrue(t:find("3 elites", 1, true) ~= nil, t)
    assertTrue(t:find("planned next", 1, true) ~= nil, t)
  end)
  ns.State.LogCount, ns.State.MaxLog = sv.lc, sv.ml
  ns.Engine.planned = nil; ns.Engine.Refresh()
  if not ok then error(err, 0) end
end)

test("travel notes: a hand-written note stays under a multi-leg trip; the planner's generic 'Fly, or ride' goes", function()
  local sv = { tf = ns.Engine.TravelFor }
  local ok, err = pcall(withState, {}, function()
    local wall = "Reach it from Hillsbrad, not the Wetlands: fly to Southshore, ride to the cart at Hillsbrad 87.4, 49.7 and climb up onto Thoradin's Wall. The Messenger Bag is up there."
    ForeverRouteData = { id = "tn", title = "tn", sections = { { title = "x" } }, steps = {
      { id = 1, k = "fly", dest = "Arathi Highlands", to = 1417, text = "Arathi Highlands", sec = 1, note = wall },
      { id = 2, k = "fly", dest = "Ashenvale", to = 1440, text = "Ashenvale", sec = 1, note = "Fly, or ride if there is no flight path yet.  Next leg: Ashenvale 22+" },
      { id = 3, k = "fly", dest = "Westfall", to = 1436, text = "Westfall", sec = 1, note = "Fly, or ride if it is close." },
    } }
    local note = function(i) ns.Engine.view = nil; ns.Engine.current = i; ns.Engine.planned = i; ns.Card.Fill(); return ns.Card.Plain(ForeverRouteCard.cur.note:GetText()) end
    ns.Engine.TravelFor = function() return { how = "fly", text = "Fly to Southshore, then ride", legs = { { how = "fly", text = "Fly to Southshore" }, { how = "ride", text = "Ride to Arathi Highlands" } } } end
    local t = note(1)
    assertTrue(t:find("1. Fly to Southshore", 1, true) ~= nil, t)
    assertTrue(t:find("Thoradin's Wall", 1, true) ~= nil, t)
    ns.Engine.TravelFor = function() return { how = "ride", text = "Ride to Ashenvale (through the Darkshore - Ashenvale border)", legs = { { how = "ride", text = "Ride to Ashenvale" } } } end
    t = note(2)
    assertTrue(t:find("Fly, or ride", 1, true) == nil, t)
    assertTrue(t:find("Next leg: Ashenvale 22+", 1, true) ~= nil, t)
    t = note(3)
    assertEquals("Ride to Ashenvale (through the Darkshore - Ashenvale border).", t)
  end)
  ns.Engine.TravelFor = sv.tf
  ns.Engine.planned = nil; ns.Engine.Refresh()
  if not ok then error(err, 0) end
end)

test("arrow: reaching the flight master on the way does not tick a 'Run the dungeon' goto or say 'in the area'", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { conv = HBD.GetWorldCoordinatesFromZone, wp = HBD.GetPlayerWorldPosition, tf = ns.Engine.TravelFor, uf = ns.Engine.UpdateFocus }
  local off = { [1453] = { -1200, -1200 }, [1433] = { 1300, 300 } }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) local o = off[m]; if not o then return nil end return o[1] + x * 1000, o[2] + y * 1000, 0 end
  local px, py = HBD:GetWorldCoordinatesFromZone(0.53, 0.45, 1433) -- next to the Lakeshire flight master
  HBD.GetPlayerWorldPosition = function() return px, py, 0 end
  ns.Engine.UpdateFocus = function() end
  local ok, err = pcall(withState, {}, function()
    ForeverRouteData = { id = "lg", title = "lg", sections = { { title = "x" } }, steps = {
      { id = 1, k = "goto", text = "Run The Stockade with a group", m = 1453, x = 0.40, y = 0.58, r = 25, zone = "Stormwind City", sec = 1 },
    } }
    ns.Engine.view = nil; ns.Engine.current = 1
    ns.Engine.TravelFor = function() return { how = "fly", m = 1433, x = 0.53, y = 0.45, text = "Fly to Stormwind City", legs = { { how = "fly", m = 1433, x = 0.53, y = 0.45, text = "Fly to Stormwind City (flight master Ariena Stormfeather)" } } } end
    ns.Arrow.SetTarget(1, true)
    local tick = ns.Arrow._driver:GetScript("OnUpdate")
    tick(ns.Arrow._driver, 0.5); tick(ns.Arrow._driver, 0.5)
    assertNil(ns.char.manualDone[ns.Engine.Key(1)], "the goto was ticked at the flight master")
    local d = ns.Card.Plain(ForeverRouteCard.cur.dist:GetText() or "")
    assertTrue(d:find("in the area", 1, true) == nil, d)
    assertTrue(d:find("FM", 1, true) ~= nil, d)
    -- at the dungeon itself the goto does tick
    ns.Engine.TravelFor = function() return nil end
    px, py = HBD:GetWorldCoordinatesFromZone(0.40, 0.58, 1453)
    ns.Arrow.SetTarget(1, true)
    tick(ns.Arrow._driver, 0.5)
    assertTrue(ns.char.manualDone[ns.Engine.Key(1)] and true or false, "the goto did not tick at the dungeon")
  end)
  HBD.GetWorldCoordinatesFromZone, HBD.GetPlayerWorldPosition, ns.Engine.TravelFor, ns.Engine.UpdateFocus = sv.conv, sv.wp, sv.tf, sv.uf
  ns.Engine.Refresh(); ns.Arrow.SetTarget(ns.Engine.Shown(), true)
  if not ok then error(err, 0) end
end)

test("arrow: a ride into the next zone points at the crossing the trip chose, not straight over the mountains", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { conv = HBD.GetWorldCoordinatesFromZone, wp = HBD.GetPlayerWorldPosition, tf = ns.Engine.TravelFor, uf = ns.Engine.UpdateFocus }
  local off = { [1429] = { 0, 0 }, [1431] = { 0, -1000 } } -- Elwynn Forest, Duskwood next to it (north here: a walking path cannot hold negative map coordinates)
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) local o = off[m]; if not o then return nil end return o[1] + x * 1000, o[2] + y * 1000, 0 end
  local px, py = 500, 500
  HBD.GetPlayerWorldPosition = function() return px, py, 0 end
  ns.Engine.UpdateFocus = function() end
  local ok, err = pcall(withState, {}, function()
    ForeverRouteData = { id = "rd", title = "rd", sections = { { title = "x" } }, steps = {
      { id = 1, k = "goto", text = "Darkshire", m = 1431, x = 0.5, y = 0.2, r = 20, zone = "Duskwood", sec = 1 },
    } }
    ns.Engine.view = nil; ns.Engine.current = 1
    local tick = ns.Arrow._driver:GetScript("OnUpdate")
    local function dist() tick(ns.Arrow._driver, 0.5); return ns.Card.Plain(ForeverRouteCard.cur.dist:GetText() or "") end
    local ride = "Ride to Duskwood (through the Elwynn Forest - Duskwood border)"
    ns.Engine.TravelFor = function() return { how = "ride", m = 1429, x = 0.5, y = 0.1, text = ride, legs = { { how = "ride", m = 1429, x = 0.5, y = 0.1, text = ride } } } end
    ns.Arrow.SetTarget(1, true)
    local d = dist()
    assertEquals("via " .. ns.Card.Plain(ns.Style.Distance(400)), d)
    -- no crossing on the way: the step itself, as before (and it can be reached)
    ns.Engine.TravelFor = function() return { how = "ride", m = 1431, x = 0.5, y = 0.2, text = "Ride to Duskwood", legs = { { how = "ride", m = 1431, x = 0.5, y = 0.2, text = "Ride to Duskwood" } } } end
    ns.Arrow.SetTarget(1, true)
    assertEquals(ns.Card.Plain(ns.Style.Distance(1300)), dist())
    -- standing on the planner's own walking path to the step: follow that instead of the crossing
    ForeverRouteData.steps[1].wp = "0.5,1.5,0;0.5,1.0,0"
    ns.Engine.TravelFor = function() return { how = "ride", m = 1429, x = 0.5, y = 0.1, text = ride, legs = { { how = "ride", m = 1429, x = 0.5, y = 0.1, text = ride } } } end
    ns.Arrow.SetTarget(1, true)
    assertTrue(dist():find("via", 1, true) == nil, "left the planned path for the crossing")
  end)
  HBD.GetWorldCoordinatesFromZone, HBD.GetPlayerWorldPosition, ns.Engine.TravelFor, ns.Engine.UpdateFocus = sv.conv, sv.wp, sv.tf, sv.uf
  ns.Engine.Refresh(); ns.Arrow.SetTarget(ns.Engine.Shown(), true)
  if not ok then error(err, 0) end
end)

test("travel step title follows the live trip: 'Ride to' when it is a ride, 'Travel to' for a mix, 'Fly to' for a flight", function()
  local sv = { tf = ns.Engine.TravelFor }
  local ok, err = pcall(withState, {}, function()
    ForeverRouteData = { id = "tt", title = "tt", sections = { { title = "x" } }, steps = {
      { id = 1, k = "fly", dest = "Ashenvale", to = 1440, text = "Ashenvale", sec = 1, note = "Fly, or ride if there is no flight path yet." },
    } }
    ns.Engine.view = nil; ns.Engine.current = 1; ns.Engine.planned = 1
    local title = function() ns.Card.Fill(); return ns.Card.Plain(ForeverRouteCard.cur.titleText:GetText()) end
    ns.Engine.TravelFor = function() return { how = "ride", text = "Ride to Ashenvale (through the Darkshore - Ashenvale border)", legs = { { how = "ride", text = "Ride to Ashenvale" } } } end
    local can = ns.State.CanRide
    ns.State.CanRide = function() return true end
    assertEquals("Ride to Ashenvale", title())
    -- no mount yet: on foot
    ns.State.CanRide = function() return false end
    assertEquals("Run to Ashenvale", title())
    ns.State.CanRide = can
    ns.Engine.TravelFor = function() return { how = "ride", text = "x", legs = { { how = "ride", text = "Ride to the pier" }, { how = "boat", text = "Boat to Auberdine" } } } end
    assertEquals("Travel to Ashenvale", title())
    ns.Engine.TravelFor = function() return { how = "fly", text = "Fly to Ashenvale", legs = { { how = "fly", text = "Fly to Ashenvale" } } } end
    assertEquals("Fly to Ashenvale", title())
    ns.Engine.TravelFor = function() return nil end
    assertEquals("Fly to Ashenvale", title())
  end)
  ns.Engine.TravelFor = sv.tf
  ns.Engine.planned = nil; ns.Engine.Refresh()
  if not ok then error(err, 0) end
end)

test("on a flight: crossing a zone mid-air does not replan from the sky, and the arrow points nowhere until you land", function()
  local sv = { taxi = UnitOnTaxi, after = C_Timer.After, pos = ns.State.Position, plan = ns.Travel.Plan, tf = ns.Engine.TravelFor }
  local taxi, planned = false, 0
  UnitOnTaxi = function() return taxi end
  C_Timer.After = function(_, fn) fn() end -- the zone and landing handlers wait a moment; run them now
  ns.State.Position = function() return 1426, 0.5, 0.5 end -- over Dun Morogh, on the way to the Wetlands
  local ok, err = pcall(withState, {}, function()
    ForeverRouteData = { id = "fl", title = "fl", sections = { { title = "x" } }, steps = {
      { id = 1, k = "fly", dest = "Wetlands", to = 1437, text = "Wetlands", sec = 1 },
    } }
    ns.Engine.view = nil; ns.Engine.current = 1
    ns.Fire("PLAYER_CONTROL_LOST") -- takeoff
    taxi = true
    ns.Fire("PLAYER_CONTROL_LOST")
    ns.Travel.Plan = function(...) planned = planned + 1; return sv.plan(...) end
    ns.Fire("ZONE_CHANGED_NEW_AREA")
    assertEquals(0, planned, "a trip was planned from the sky")
    local trip = ns.Engine.TravelFor(ForeverRouteData.steps[1])
    assertEquals("aboard", trip.how)
    ns.Card.Fill()
    local title = ns.Card.Plain(ForeverRouteCard.cur.titleText:GetText())
    assertTrue(title:find("Ride to", 1, true) == nil, title)
    assertEquals("", ForeverRouteCard.cur.dist:GetText() or "")
    assertFalse(ForeverRouteArrow:IsShown())
    -- landing brings a trip planned from the ground back
    taxi = false
    local asked
    ns.Engine.TravelFor = function(s) local t = sv.tf(s); asked = t or false; return t end
    ns.Fire("PLAYER_CONTROL_GAINED")
    assertTrue(asked ~= nil, "landing did not re-target the arrow")
    assertTrue(not asked or asked.how ~= "aboard", "still 'sit tight' after landing")
  end)
  UnitOnTaxi, C_Timer.After, ns.State.Position, ns.Travel.Plan, ns.Engine.TravelFor = sv.taxi, sv.after, sv.pos, sv.plan, sv.tf
  ns.Engine.Refresh(); ns.Arrow.SetTarget(ns.Engine.Shown(), true)
  if not ok then error(err, 0) end
end)

test("boats: on the route's 'Boat to X' step the arrow does not point back at the pier while you sail", function()
  local sv = { pos = ns.State.Position, aboard = ns.Arrow.aboard }
  ns.State.Position = function() return 1453, 0.27, 0.27 end -- Stormwind Harbor
  local ok, err = pcall(withState, {}, function()
    ForeverRouteData = { id = "bt", title = "bt", sections = { { title = "x" } }, steps = {
      { id = 1, k = "fly", boat = "stormwind", dest = "Darkshore", to = 1439, m = 1453, x = 0.2789, y = 0.2741, r = 60, text = "Boat to Auberdine", sec = 1, note = "Board the boat to Auberdine at the Stormwind Harbor pier." },
    } }
    ns.Engine.view = nil; ns.Engine.current = 1
    ns.Arrow.aboard = false
    assertNil(ns.Engine.TravelFor(ForeverRouteData.steps[1]), "on the pier's map the pier itself is the target")
    ns.Arrow.aboard = true
    local trip = ns.Engine.TravelFor(ForeverRouteData.steps[1])
    assertEquals("aboard", trip.how)
    assertEquals("On the boat to Auberdine - sit tight", trip.text)
    ns.Arrow.SetTarget(1, true)
    assertEquals("", ForeverRouteCard.cur.dist:GetText() or "")
    assertFalse(ForeverRouteArrow:IsShown())
    ns.Card.Fill()
    local note = ns.Card.Plain(ForeverRouteCard.cur.note:GetText() or "")
    assertTrue(note:find("sit tight", 1, true) ~= nil, note)
    assertTrue(note:find("Board the boat", 1, true) == nil, note)
  end)
  ns.State.Position, ns.Arrow.aboard = sv.pos, sv.aboard
  ns.Engine.Refresh(); ns.Arrow.SetTarget(ns.Engine.Shown(), true)
  if not ok then error(err, 0) end
end)

test("boats: with no arrow target on a trip boat, landing and walking off still clears 'aboard'", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { wp = HBD.GetPlayerWorldPosition, tf = ns.Engine.TravelFor, aboard = ns.Arrow.aboard, uf = ns.Engine.UpdateFocus }
  local px = 1000
  HBD.GetPlayerWorldPosition = function() return px, 500, 0 end
  ns.Engine.UpdateFocus = function() end
  local ok, err = pcall(withState, {}, function()
    ForeverRouteData = { id = "bt2", title = "bt2", sections = { { title = "x" } }, steps = {
      { id = 1, k = "turnin", q = 5, name = "Q", npc = "N", m = 1438, x = 0.5, y = 0.5, sec = 1 },
    } }
    ns.Engine.view = nil; ns.Engine.current = 1
    ns.Arrow.aboard = true
    ns.Engine.TravelFor = function() return { how = "aboard", text = "On the boat to Rut'theran Village - sit tight", legs = { { how = "aboard", text = "On the boat to Rut'theran Village - sit tight" } } } end
    ns.Arrow.SetTarget(1, true) -- no target while sailing
    local tick = ns.Arrow._driver:GetScript("OnUpdate")
    for _ = 1, 12 do px = px + 1; tick(ns.Arrow._driver, 0.5) end -- landed: walking down the pier
    assertFalse(ns.Arrow.aboard and true or false, "still 'aboard' after landing")
  end)
  HBD.GetPlayerWorldPosition, ns.Engine.TravelFor, ns.Arrow.aboard, ns.Engine.UpdateFocus = sv.wp, sv.tf, sv.aboard, sv.uf
  ns.Engine.Refresh(); ns.Arrow.SetTarget(ns.Engine.Shown(), true)
  if not ok then error(err, 0) end
end)

test("learning: the XP message is read without the rested bonus, and a kill is recorded by your level and the mob's", function()
  local L = ns.Learn
  local name, xp = L.ParseXp(string.format(COMBATLOG_XPGAIN_FIRSTPERSON or "%s dies, you gain %d experience.", "Dire Wolf", 140))
  assertEquals("Dire Wolf", name); assertEquals(140, xp)
  if COMBATLOG_XPGAIN_EXHAUSTION1 then
    name, xp = L.ParseXp(string.format(COMBATLOG_XPGAIN_EXHAUSTION1, "Dire Wolf", 210, "+70", "Rested"))
    assertEquals("Dire Wolf", name); assertEquals(140, xp)
  end
  assertNil(L.ParseXp("You receive loot: [Wolf Fang]."))
  local saved = ForeverRouteDB.learn
  ForeverRouteDB.learn = nil
  L._levelOf["Dire Wolf"] = 22
  assertTrue(L.RecordKill("Dire Wolf", 140, 21))
  assertTrue(L.RecordKill("Dire Wolf", 150, 21))
  assertTrue(not L.RecordKill("Unknown Thing", 99, 21)) -- no level known: nothing guessed
  local c = ForeverRouteDB.learn.killxp[21][22]
  assertEquals(2, c.n); assertEquals(290, c.xp)
  ForeverRouteDB.learn = saved
end)

test("learning: a kill step's pace is recorded when it gets done, and a step ticked by hand is an incident", function()
  local saved = ForeverRouteDB.learn
  ForeverRouteDB.learn = nil
  local svTime = GetTime
  local now = 1000
  GetTime = function() return now end
  local ok, err = pcall(withState, {}, function()
    ForeverRouteData = { id = "learn", title = "learn", sections = { { title = "x" } }, steps = {
      { id = 1, k = "obj", q = 501, text = "Kill 10 Wolf", match = "Wolf", sec = 1 },
      { id = 2, k = "turnin", q = 501, name = "Wolves", npc = "Lars", sec = 1 },
    } }
    ns.Learn.StepShown(1)
    now = now + 300 -- five minutes of work
    assertTrue(ns.Learn.StepDone(1))
    local p = ForeverRouteDB.learn.pace[1]
    assertEquals("Kill", p.k); assertEquals(10, p.need); assertEquals(300, p.sec)
    -- too quick to be real work: not recorded
    ns.Learn.StepShown(1); now = now + 5
    assertTrue(not ns.Learn.StepDone(1))
    ns.Learn.Incident("ticked by hand", 2)
    local inc = ForeverRouteDB.learn.incidents[1]
    assertEquals("ticked by hand", inc.kind); assertEquals(2, inc.step); assertEquals("learn", inc.route)
    -- one death the game reports twice is one incident
    ns.Learn.Incident("died", 2); ns.Learn.Incident("died", 2)
    assertEquals(2, #ForeverRouteDB.learn.incidents)
  end)
  GetTime = svTime
  ForeverRouteDB.learn = saved
  if not ok then error(err, 0) end
end)

test("learning: time per zone counts steady play only (not flights, not long gaps) and the steps finished there", function()
  local saved, svTaxi, svPos = ForeverRouteDB.learn, UnitOnTaxi, ns.State.Position
  ForeverRouteDB.learn = nil
  local taxi, m = false, 1431
  UnitOnTaxi = function() return taxi end
  ns.State.Position = function() return m, 0.5, 0.5 end
  local ok, err = pcall(function()
    local L = ns.Learn
    L.ZoneTick(100); L.ZoneTick(130); L.ZoneTick(160) -- a minute in Duskwood
    L.ZoneStepDone(); L.ZoneStepDone()
    taxi = true; L.ZoneTick(190); taxi = false -- flying: not counted
    L.ZoneTick(1000) -- a long gap (loading, a break): not counted
    L.ZoneTick(1030)
    local z = ForeverRouteDB.learn.zones[1431]
    assertEquals(90, z.sec)
    assertEquals(2, z.steps)
  end)
  UnitOnTaxi, ns.State.Position, ForeverRouteDB.learn = svTaxi, svPos, saved
  if not ok then error(err, 0) end
end)

test("learning: a step on the card for over 25 minutes of play is reported once as stuck", function()
  local saved = ForeverRouteDB.learn
  ForeverRouteDB.learn = nil
  local ok, err = pcall(withState, {}, function()
    ForeverRouteData = { id = "stuck", title = "stuck", sections = { { title = "x" } }, steps = {
      { id = 1, k = "obj", q = 601, text = "Collect 10 Battleworn Axe", match = "Battleworn Axe", sec = 1 } } }
    ns.Engine.Refresh()
    ns.Learn.StepShown(1)
    local t0 = GetTime()
    assertTrue(not ns.Learn.CheckStuck(t0 + 10 * 60))
    assertTrue(ns.Learn.CheckStuck(t0 + 26 * 60))
    assertTrue(not ns.Learn.CheckStuck(t0 + 40 * 60)) -- once per step
    local inc = ForeverRouteDB.learn.incidents[#ForeverRouteDB.learn.incidents]
    assertEquals("stuck on a step", inc.kind); assertEquals(26, inc.minutes)
  end)
  ForeverRouteDB.learn = saved
  if not ok then error(err, 0) end
end)

test("plan stability: the card shows what changed in a new plan once, until OK", function()
  local sv = ForeverRoutePlan and ForeverRoutePlan.changeNote
  local seen = ns.char.changeSeen
  ForeverRoutePlan.changeNote = "zones now Duskwood > Wetlands (Redridge Mountains dropped: finished or outlevelled)"
  ns.char.changeSeen = nil
  assertEquals(ForeverRoutePlan.changeNote, ns.Card.ChangeNote())
  ns.char.changeSeen = ForeverRoutePlan.generated
  assertNil(ns.Card.ChangeNote())
  ForeverRoutePlan.changeNote, ns.char.changeSeen = sv, seen
end)

test("zone picker: picking a zone with a ready route switches to it at once and asks the next plan to start there; zone routes are not paths", function()
  local sv = { routes = ForeverRouteRoutes, data = ForeverRouteData, req = ns.char.requestZone, handled = ns.char.requestHandled, title = ns.char.routeTitle }
  local main = { id = "path:A", title = "A", meta = { legs = "Redridge Mountains" }, sections = { { title = "x" } }, steps = { { id = 1, k = "goto", text = "x", sec = 1 } } }
  local zr = { id = "zone:Duskwood", title = "Zone: Duskwood", zoneRoute = true, zoneName = "Duskwood", meta = { legs = "Duskwood" }, sections = { { title = "x" } }, steps = { { id = 1, k = "goto", text = "y", sec = 1 } } }
  ForeverRouteRoutes = { main, zr }
  local ok, err = pcall(function()
    assertEquals(1, #ns.MainRoutes())
    assertEquals(zr, ns.ZoneRouteFor("Duskwood"))
    ns.Paths.Request("Duskwood")
    assertEquals(zr, ForeverRouteData)
    assertEquals("Duskwood", ns.char.requestZone)
    assertNil(ns.char.requestHandled) -- the next plan's path starting there still takes over
  end)
  ForeverRouteRoutes, ns.char.requestZone, ns.char.requestHandled = sv.routes, sv.req, sv.handled
  ns.SelectRoute(sv.title, true)
  if not ok then error(err, 0) end
end)

test("zone picker on a built-in plan: one zone route per zone and level band, the one for your level is offered and taken", function()
  local sv = { routes = ForeverRouteRoutes, data = ForeverRouteData, req = ns.char.requestZone, handled = ns.char.requestHandled, title = ns.char.routeTitle }
  local function zr(zone, level, xph) return { id = "zone:" .. zone .. ":" .. level, title = "Zone: " .. zone, zoneRoute = true, zoneName = zone, level = level, xph = xph, meta = { legs = zone }, sections = { { title = "x" } }, steps = { { id = 1, k = "goto", text = "y", sec = 1 } } } end
  local main = { id = "path:A", title = "A", meta = { legs = "Redridge Mountains" }, sections = { { title = "x" } }, steps = { { id = 1, k = "goto", text = "x", sec = 1 } } }
  local dw24, dw30, ash24, stv36 = zr("Duskwood", 24, 9000), zr("Duskwood", 30, 8000), zr("Ashenvale", 24, 12000), zr("Stranglethorn Vale", 36, 15000)
  ForeverRouteRoutes = { main, dw24, dw30, ash24, stv36 }
  local ok, err = pcall(function()
    -- at 29: Duskwood's 30 band (in reach: up to 2 above), not its 24; Stranglethorn's 36 is out of reach
    assertEquals(dw30, ns.ZoneRouteFor("Duskwood", 29))
    assertNil(ns.ZoneRouteFor("Stranglethorn Vale", 29))
    local at = ns.ZoneRoutesAt(29)
    assertEquals(2, #at)
    assertEquals(ash24, at[1]) -- best XP per hour first
    -- at 24: Duskwood's 24 band (its 30 is 6 above)
    assertEquals(dw24, ns.ZoneRouteFor("Duskwood", 24))
    -- a plan's own zone route without a level still works as before
    local plain = { id = "zone:Wetlands", title = "Zone: Wetlands", zoneRoute = true, zoneName = "Wetlands", meta = { legs = "Wetlands" }, sections = { { title = "x" } }, steps = { { id = 1, k = "goto", text = "y", sec = 1 } } }
    ForeverRouteRoutes = { main, plain }
    assertEquals(plain, ns.ZoneRouteFor("Wetlands", 40))
  end)
  ForeverRouteRoutes, ns.char.requestZone, ns.char.requestHandled = sv.routes, sv.req, sv.handled
  ns.SelectRoute(sv.title, true)
  if not ok then error(err, 0) end
end)

test("one plan file for several characters: only the logged-in character's block is loaded", function()
  local sv = { by = ForeverRouteByChar, plan = ForeverRoutePlan, routes = ForeverRouteRoutes, st = ForeverRouteStarter, key = ns.planKey }
  ForeverRouteStarter = nil -- no built-in plans here (their own test is below), and none loaded on demand
  sv.load = C_AddOns and C_AddOns.LoadAddOn
  if C_AddOns then C_AddOns.LoadAddOn = function() return false end end
  local me = ns.CharKey()
  local ranMine, ranOther = false, false
  ForeverRouteByChar = {
    [me] = function() ranMine = true; ForeverRoutePlan = { generated = 42 } end,
    ["Someone-Else"] = function() ranOther = true; ForeverRoutePlan = { generated = 7 } end,
  }
  local ok, err = pcall(function()
    assertTrue(ns.LoadMyPlan())
    assertTrue(ranMine); assertTrue(not ranOther)
    assertEquals(42, ForeverRoutePlan.generated)
    ForeverRouteByChar = { ["Someone-Else"] = function() ranOther = true end }
    assertTrue(not ns.LoadMyPlan()) -- no plan for this character yet
    assertTrue(not ranOther)
  end)
  ForeverRouteByChar, ForeverRoutePlan, ForeverRouteRoutes, ForeverRouteStarter, ns.planKey = sv.by, sv.plan, sv.routes, sv.st, sv.key
  if C_AddOns then C_AddOns.LoadAddOn = sv.load end
  if not ok then error(err, 0) end
end)

test("no plan of your own: the built-in plan for your race and class is followed; your own wins when there is one", function()
  local sv = { by = ForeverRouteByChar, plan = ForeverRoutePlan, routes = ForeverRouteRoutes, st = ForeverRouteStarter, key = ns.planKey, race = UnitRace, class = UnitClass, data = ForeverRouteData }
  UnitRace = function() return "Night Elf", "NightElf" end
  UnitClass = function() return "Druid", "DRUID" end
  local ran
  ForeverRouteStarter = {
    ["nightelf-druid"] = function() ran = "starter"; ForeverRoutePlan = { generated = 1 } end,
    ["gnome-warlock"] = function() ran = "other starter" end,
  }
  local ok, err = pcall(function()
    assertEquals("nightelf-druid", ns.StarterKey())
    -- the game calls undead "Scourge"; the plans are undead_<class>
    UnitRace = function() return "Undead", "Scourge" end
    assertEquals("undead-druid", ns.StarterKey())
    -- both factions have Skyborne: the Horde's are skybornehorde, told apart by the faction
    local svF = UnitFactionGroup
    UnitRace = function() return "Skyborne", "Skyborne" end
    UnitFactionGroup = function() return "Alliance", "Alliance" end
    assertEquals("skyborne-druid", ns.StarterKey())
    UnitFactionGroup = function() return "Horde", "Horde" end
    assertEquals("skybornehorde-druid", ns.StarterKey())
    UnitFactionGroup = svF
    UnitRace = function() return "Night Elf", "NightElf" end
    ForeverRouteByChar = { ["Someone-Else"] = function() ran = "someone else" end }
    assertTrue(ns.LoadMyPlan()); assertEquals("starter", ran); assertEquals("nightelf-druid", ns.planKey.starter)
    ForeverRouteByChar = nil; ForeverRouteRoutes = nil; ForeverRouteData = nil -- an addon-only install: no plan file at all
    ran = nil; assertTrue(ns.LoadMyPlan()); assertEquals("starter", ran)
    ForeverRouteByChar = { [ns.CharKey()] = function() ran = "mine" end }
    ran = nil; assertTrue(ns.LoadMyPlan()); assertEquals("mine", ran); assertNil(ns.planKey.starter)
    UnitClass = function() return "Rogue", "ROGUE" end -- no built-in plan for this one here (none loaded on demand in this test)
    ForeverRouteByChar = {}
    local svLoad = C_AddOns and C_AddOns.LoadAddOn
    if C_AddOns then C_AddOns.LoadAddOn = function() return false end end
    ran = nil; local got = ns.LoadMyPlan()
    if C_AddOns then C_AddOns.LoadAddOn = svLoad end
    assertTrue(not got); assertNil(ran)
  end)
  ForeverRouteByChar, ForeverRoutePlan, ForeverRouteRoutes, ForeverRouteStarter, ns.planKey, UnitRace, UnitClass, ForeverRouteData = sv.by, sv.plan, sv.routes, sv.st, sv.key, sv.race, sv.class, sv.data
  if not ok then error(err, 0) end
end)

test("a logged error carries what you were doing: the step shown, the plan and the last decisions", function()
  withState({}, function()
    ForeverRouteData = miniRoute()
    ns.Engine.Refresh()
    ns.Why("test", "a decision just before the error")
    ns.LogError("ctxtest", "boom with context")
    local e
    for i, x in ipairs(ForeverRouteDB.log) do if x.where == "ctxtest" then e = x; table.remove(ForeverRouteDB.log, i); break end end
    assertNotNil(e, "not logged")
    assertTrue(type(e.shown) == "string" and e.shown:find("accept", 1, true) ~= nil, "no step: " .. tostring(e.shown))
    assertEquals("test", e.routeId)
    assertTrue(type(e.recent) == "table" and tostring(e.recent[#e.recent]):find("a decision just before", 1, true) ~= nil, "no recent decisions")
  end)
end)

test("standing at the step: no minimap pin on top of you (the world map keeps it)", function()
  withWorld(worldRoute(), function(w)
    local function mini(i) for _, p in ipairs(ns.Pins._used) do if p.where == "mini" and p.index == i then return true end end return false end
    w:go(1431, 0.73, 0.48) -- a short walk from Lars: his pin is on the minimap
    assertTrue(mini(1), "no minimap pin near the step")
    w:go(1431, 0.75, 0.48) -- at Lars
    assertTrue(not mini(1), "the step's minimap pin sits on your arrow")
    local world = false
    for _, p in ipairs(ns.Pins._used) do if p.where == "world" and p.index == 1 then world = true end end
    assertTrue(world, "the world map lost the pin")
  end, { anyTarget = true })
end)

test("a quest turned down at two levels stays off after that; once, it's tried again a level on; one waiting on an earlier quest comes back with it", function()
  local sv = { avail = ForeverRouteChar.avail, gossip = C_GossipInfo.GetAvailableQuests, un = UnitName, lvl = UnitLevel, unl = ForeverRouteUnlocks, done = ns.State.IsCompleted }
  ForeverRouteChar.avail = nil
  local level, done = 28, {}
  local ok, err = pcall(withState, {}, function()
    UnitLevel = function() return level end
    UnitName = function(u, ...) if u == "npc" then return "Captain Stoutfist" end return sv.un(u, ...) end
    ns.State.IsCompleted = function(q) return done[q] or false end
    ForeverRouteUnlocks = { [98072] = { 98240 } }
    ForeverRouteData = { id = "avail2", title = "avail2", sections = { { title = "Wetlands" } }, steps = {
      { id = 1, k = "accept", q = 98230, name = "This Land Was Their Land", npc = "Captain Stoutfist", minLevel = 22, m = 1437, x = 0.10, y = 0.57, sec = 1 },
      { id = 2, k = "accept", q = 98240, name = "Crimson Crate Delivery", npc = "Captain Stoutfist", minLevel = 19, m = 1437, x = 0.10, y = 0.57, sec = 1 },
    } }
    ns.Engine.Refresh()
    C_GossipInfo.GetAvailableQuests = function() return {} end
    ns.Avail.OnGiver("GOSSIP_SHOW")
    assertTrue(ns.Avail.Unavailable(98230) and ns.Avail.Unavailable(98240))
    -- once (at 28, though the data says it needs 22): a level on, it's worth another look - Forever asks more for some
    level = 29
    assertTrue(not ns.Avail.Unavailable(98230), "turned down once: tried again a level on")
    ns.Avail.OnGiver("GOSSIP_SHOW")
    level = 32
    assertTrue(ns.Avail.Unavailable(98230), "turned down at 28 and 29: a level up isn't a reason to send you back")
    assertTrue(ns.Avail.Unavailable(98240), "still waiting on Crocs of the Sky")
    done[98072] = true
    assertTrue(not ns.Avail.Unavailable(98240), "Crocs of the Sky handed in: worth another look")
    -- offered after all: back on the route
    C_GossipInfo.GetAvailableQuests = function() return { { questID = 98230 } } end
    ns.Avail.OnGiver("GOSSIP_SHOW"); assertTrue(not ns.Avail.Unavailable(98230))
  end)
  ForeverRouteChar.avail, C_GossipInfo.GetAvailableQuests, UnitName, UnitLevel, ForeverRouteUnlocks, ns.State.IsCompleted = sv.avail, sv.gossip, sv.un, sv.lvl, sv.unl, sv.done
  if not ok then error(err, 0) end
end)

test("a quest its giver doesn't offer you leaves the route (until a level-up, or until it's offered after all)", function()
  local sv = { avail = ForeverRouteChar.avail, gossip = C_GossipInfo.GetAvailableQuests, un = UnitName, lvl = UnitLevel }
  ForeverRouteChar.avail = nil
  local level = 23
  local ok, err = pcall(withState, {}, function()
    UnitLevel = function() return level end
    UnitName = function(u, ...) if u == "npc" then return "Highlord Bolvar Fordragon" end return sv.un(u, ...) end
    ForeverRouteData = { id = "avail", title = "avail", sections = { { title = "Stormwind" } }, steps = {
      { id = 1, k = "accept", q = 98191, name = "A Friend of the Family", npc = "Highlord Bolvar Fordragon", m = 1453, x = 0.80, y = 0.38, sec = 1 },
      { id = 2, k = "accept", q = 343, name = "Speaking of Fortitude", npc = "Highlord Bolvar Fordragon", m = 1453, x = 0.80, y = 0.38, sec = 1 },
      { id = 3, k = "turnin", q = 98191, name = "A Friend of the Family", npc = "Lord Grayson Shadowbreaker", m = 1453, x = 0.48, y = 0.50, sec = 1 },
    } }
    ns.Engine.Refresh()
    assertEquals(1, ns.Engine.Shown())
    -- he lists only Speaking of Fortitude
    C_GossipInfo.GetAvailableQuests = function() return { { questID = 343, title = "Speaking of Fortitude" } } end
    ns.Avail.OnGiver("GOSSIP_SHOW")
    assertTrue(ns.Avail.Unavailable(98191), "not recorded as not offered")
    assertTrue(not ns.Avail.Unavailable(343))
    assertEquals(2, ns.Engine.Shown(), "the card still shows the quest he doesn't offer")
    assertEquals("done", ns.Engine.Status(3), "its hand-in stayed on the route")
    -- a level up: it may be offered now
    level = 24
    assertTrue(not ns.Avail.Unavailable(98191))
    -- not offered again at 24, then offered after all
    ns.Avail.OnGiver("GOSSIP_SHOW"); assertTrue(ns.Avail.Unavailable(98191))
    C_GossipInfo.GetAvailableQuests = function() return { { questID = 98191 } } end
    ns.Avail.OnGiver("GOSSIP_SHOW"); assertTrue(not ns.Avail.Unavailable(98191))
  end)
  ForeverRouteChar.avail, C_GossipInfo.GetAvailableQuests, UnitName, UnitLevel = sv.avail, sv.gossip, sv.un, sv.lvl
  if not ok then error(err, 0) end
end)

test("a quest newer than the original game is flagged on the card: its requirements may be missing from the data", function()
  local svT = ns.Engine.TravelFor
  local ok, err = pcall(withState, {}, function()
    ns.Engine.TravelFor = function() return nil end
    ForeverRouteData = { id = "nq", title = "nq", sections = { { title = "x" } }, steps = {
      { id = 1, k = "accept", q = 98191, name = "A Friend of the Family", npc = "Highlord Bolvar Fordragon", m = 1453, x = 0.8, y = 0.38, sec = 1 },
      { id = 2, k = "accept", q = 343, name = "Speaking of Fortitude", npc = "Brother Kristoff", m = 1453, x = 0.55, y = 0.54, sec = 1 },
    } }
    local note = function(i) ns.Engine.view = nil; ns.Engine.current = i; ns.Engine.planned = i; ns.Card.Fill(); return ns.Card.Plain(ForeverRouteCard.cur.note:GetText() or "") end
    assertTrue(note(1):find("New quest", 1, true) ~= nil, "no flag on a new quest")
    assertTrue(note(2):find("New quest", 1, true) == nil, "an original quest flagged as new")
  end)
  ns.Engine.TravelFor = svT
  if not ok then error(err, 0) end
end)

test("a replayed world fails when the addon logs an error during it (guards would otherwise hide it)", function()
  local ok, err = pcall(withWorld, worldRoute(), function(w) ns.LogError("test", "boom from a replay") end, { anyTarget = true })
  assertTrue(not ok, "an error logged during the replay went unnoticed")
  assertTrue(tostring(err):find("boom from a replay", 1, true) ~= nil, tostring(err))
  -- the test's own error must not stay in the log for the next ones
  for i, e in ipairs(ForeverRouteDB.log or {}) do if e.where == "test" then table.remove(ForeverRouteDB.log, i); break end end
end)

test("a right-clicked arrow stays hidden for that step only, even when a replan renumbers the steps", function()
  local steps = ForeverRouteData.steps
  local sv = { hid = ns.Arrow.hiddenFor, arrow = ns.db.arrow, view = ns.Engine.view }
  ns.db.arrow, ns.Engine.view = true, nil
  local ok, err = pcall(function()
    ns.Arrow.hiddenFor = steps[2]
    assertTrue(not ns.Arrow.Visible(2)); assertTrue(ns.Arrow.Visible(3))
    table.insert(steps, 1, { k = "goto", text = "a step the replan put first", m = 1453, x = 0.5, y = 0.5 })
    assertTrue(ns.Arrow.Visible(2), "an unrelated step took the hidden one's number and lost its arrow")
    assertTrue(not ns.Arrow.Visible(3))
    table.remove(steps, 1)
  end)
  ns.Arrow.hiddenFor, ns.db.arrow, ns.Engine.view = sv.hid, sv.arrow, sv.view
  if not ok then error(err, 0) end
end)

test("your plan is found when the realm is spelled differently, or the name isn't known yet at login", function()
  local sv = { by = ForeverRouteByChar, plan = ForeverRoutePlan, routes = ForeverRouteRoutes, key = ForeverRouteChar.charKey, un = UnitName }
  local me = ns.CharKey()
  local name, realm = me:match("^([^-]+)-(.*)$")
  local ran
  local ok, err = pcall(function()
    -- the planner wrote the realm in another case, with a space and an apostrophe
    ForeverRouteByChar = { [name .. "-" .. realm:upper() .. " 'x"] = function() ran = "case" end, ["Someone-Else"] = function() ran = "other" end }
    ran = nil; ns.FindMyPlan(name .. "-" .. realm .. "x")() ; assertEquals("case", ran)
    -- only your name matches (realm folder differs): that block
    ForeverRouteByChar = { [name .. "-OtherRealm"] = function() ran = "name" end, ["Someone-Else"] = function() ran = "other" end }
    ran = nil; assertTrue(ns.LoadMyPlan()); assertEquals("name", ran)
    -- two blocks with your name on different realms: not guessed
    ForeverRouteByChar = { [name .. "-A"] = function() end, [name .. "-B"] = function() end }
    assertTrue(ns.FindMyPlan(name .. "-C") == nil)
    -- ...unless this character matched one of them before (the game says "SomeRealmId", the folder "Testrealm")
    local saved = ForeverRouteChar.planBlock
    ForeverRouteChar.planBlock = name .. "-B"
    local _, k = ns.FindMyPlan(name .. "-C"); assertEquals(name .. "-B", k)
    ForeverRouteChar.planBlock = saved
    -- name not known yet: the key saved last time
    ForeverRouteChar.charKey = me
    UnitName = function() return "Unknown" end
    assertEquals(me, ns.CharKey())
    ForeverRouteByChar = { [me] = function() ran = "saved" end }
    ran = nil; assertTrue(ns.LoadMyPlan()); assertEquals("saved", ran)
  end)
  UnitName = sv.un
  ForeverRouteByChar, ForeverRoutePlan, ForeverRouteRoutes, ForeverRouteChar.charKey = sv.by, sv.plan, sv.routes, sv.key
  if not ok then error(err, 0) end
end)

test("learning: quest rewards are asked about once - a toy and its Use: line are saved, an unloaded item is retried", function()
  local saved, svTip, svToy = ForeverRouteDB.learn, C_TooltipInfo, C_ToyBox
  ForeverRouteDB.learn = nil
  local loaded = false
  C_TooltipInfo = { GetItemByID = function(id)
    if id == 276242 and loaded then return { lines = { { leftText = "Replica Dartol's Rod of Transformation" }, { leftText = "Use: Transforms you into a furbolg." } } } end
    return nil
  end }
  C_ToyBox = { GetToyInfo = function(id) if id == 276242 then return id end end }
  local ok, err = pcall(function()
    assertTrue(not ns.Learn.ScanItem(276242)) -- not loaded yet
    loaded = true
    assertTrue(ns.Learn.ScanItem(276242))
    local it = ForeverRouteDB.learn.items[276242]
    assertTrue(it.toy); assertEquals("Use: Transforms you into a furbolg.", it.use)
    assertTrue(ns.Learn.ScanItem(276242)) -- once: already known
  end)
  ForeverRouteDB.learn, C_TooltipInfo, C_ToyBox = saved, svTip, svToy
  if not ok then error(err, 0) end
end)

test("errands: a warlock in Stormwind is reminded once of a grimoire for a demon they have, and not for one they don't", function()
  local sv = { pos = ns.State.Position, done = ns.State.IsCompleted, lvl = UnitLevel, class = UnitClass, g = ns.char.grimoires, free = ns.Errands.FreeSlots, dur = ns.Errands.Durability }
  ns.State.Position = function() return 1453, 0.4, 0.85 end
  UnitClass = function() return "Warlock", "WARLOCK" end
  ns.Errands.FreeSlots = function() return 20 end
  ns.Errands.Durability = function() return 1 end
  ns.char.grimoires = { Sacrifice = true, ["Consume Shadows"] = true }
  local haveSuccubus = false
  ns.State.IsCompleted = function(q) return q == 1739 and haveSuccubus end
  UnitLevel = function() return 26 end
  local ok, err = pcall(function()
    assertNil(ns.Errands.Grimoire()) -- no Succubus yet: no Seduction
    haveSuccubus = true
    local text, key = ns.Errands.Grimoire()
    assertEquals("grimoire:Seduction", key); assertTrue(text:find("Spackle Thornberry", 1, true) ~= nil)
    ns.Errands.Dismiss()
    assertNil(ns.Errands.Grimoire()) -- marked bought
    ns.State.Position = function() return 1436, 0.5, 0.5 end -- Westfall: no demon trainer
    ns.char.grimoires.Seduction = nil
    assertNil(ns.Errands.Grimoire())
  end)
  ns.State.Position, ns.State.IsCompleted, UnitLevel, UnitClass, ns.char.grimoires, ns.Errands.FreeSlots, ns.Errands.Durability = sv.pos, sv.done, sv.lvl, sv.class, sv.g, sv.free, sv.dur
  if not ok then error(err, 0) end
end)

test("secret values: in a dungeon the game hides whether you're AFK or on a flight; that counts as no, and the zone timer and stuck check carry on", function()
  local SECRET = {}
  local sv = { isv = issecretvalue, afk = UnitIsAFK, taxi = UnitOnTaxi, fly = IsFlying }
  issecretvalue = function(v) return v == SECRET end
  UnitIsAFK = function() return SECRET end
  UnitOnTaxi = function() return SECRET end
  IsFlying = function() error("not here") end
  local ok, err = pcall(function()
    assertEquals(false, ns.Is(UnitIsAFK, "player"))
    assertEquals(false, ns.Is(UnitOnTaxi, "player"))
    assertEquals(false, ns.Is(IsFlying)) -- an error asking counts as no
    assertEquals(false, ns.Is(nil)) -- not in this client
    UnitIsAFK = function() return true end
    assertEquals(true, ns.Is(UnitIsAFK, "player"))
    UnitIsAFK = function() return SECRET end
    ns.Learn.ZoneTick(1000); ns.Learn.ZoneTick(1030)
    ns.Learn.CheckStuck(1060)
  end)
  issecretvalue, UnitIsAFK, UnitOnTaxi, IsFlying = sv.isv, sv.afk, sv.taxi, sv.fly
  if not ok then error(err, 0) end
end)

test("incidents: a death inside a dungeon is the dungeon's, not the step on the card's", function()
  local sv = { inst = IsInInstance, info = GetInstanceInfo, shown = ns.Engine.Shown }
  IsInInstance = function() return true, "party" end
  GetInstanceInfo = function() return "Blackfathom Deeps" end
  ns.Engine.Shown = function() return 8 end
  local ok, err = pcall(function()
    local e = ns.Learn.Died()
    assertEquals("Blackfathom Deeps", e.dungeon); assertNil(e.step); assertNil(e.what)
    IsInInstance = function() return false end
    local e2 = ns.Learn.Died()
    assertEquals(8, e2.step)
  end)
  IsInInstance, GetInstanceInfo, ns.Engine.Shown = sv.inst, sv.info, sv.shown
  if not ok then error(err, 0) end
end)

test("travel: on the Deeprun Tram (its own little world, no trip starts there) the trip you're on carries on; out in Stormwind it's planned again", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { conv = HBD.GetWorldCoordinatesFromZone, pos = ns.State.Position, taxi = ns.State.knownTaxi, info = C_Map.GetMapInfo, docks = ForeverRouteDB.docks, lt = ns.Engine.lastTrip, lts = ns.Engine.lastTripStep }
  local TRAM = 2257
  local off = { [1453] = { 0, 0, 0 }, [1437] = { 500, -2000, 0 }, [1433] = { 1500, 300, 0 }, [1439] = { 0, -3000, 1 }, [1440] = { 500, -1500, 1 }, [1413] = { 1500, 500, 1 }, [TRAM] = { 0, 0, 369 } }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) local o = off[m]; if not o then return nil end return o[1] + x * 1000, o[2] + y * 1000, o[3] end
  local names = { [1453] = "Stormwind City", [1440] = "Ashenvale", [1439] = "Darkshore", [TRAM] = "Deeprun Tram" }
  C_Map.GetMapInfo = function(m) return names[m] and { name = names[m] } or nil end
  ForeverRouteDB.docks = {}
  local s = { k = "accept", q = 1010, name = "Bathran's Hair", m = 1440, x = 0.264, y = 0.386, zone = "Ashenvale" }
  local ok, err = pcall(function()
    ns.State.knownTaxi = { ["Stormwind, Elwynn"] = true }
    assertFalse(ns.Travel.OnNetwork(TRAM, 0.5, 0.5)); assertTrue(ns.Travel.OnNetwork(1453, 0.5, 0.5))
    -- planned in Ironforge: tram first
    ns.Engine.lastTrip, ns.Engine.lastTripStep = { { how = "boat", dock = "tramIF", m = 1455, x = 0.765, y = 0.51, text = "Take the Deeprun Tram to Stormwind" }, { how = "boat", text = "Boat to Auberdine (Darkshore)" } }, s
    ns.State.Position = function() return TRAM, 0.5, 0.6 end
    local t = ns.Engine.TravelFor(s)
    assertEquals("aboard", t.how)
    assertTrue(t.text:find("On the Deeprun Tram to Stormwind - sit tight", 1, true) ~= nil, t.text)
    assertTrue(t.text:find("Auberdine", 1, true) ~= nil, t.text) -- the rest of the trip stays on the card
    assertNil(t.m) -- nothing to point at until you're out
    -- no trip planned before: say so, don't point anywhere
    ns.Engine.lastTrip = nil
    local t2 = ns.Engine.TravelFor(s)
    assertEquals("aboard", t2.how); assertTrue(t2.text:find("Deeprun Tram", 1, true) ~= nil, t2.text)
    -- out in Stormwind: a real trip again
    ns.State.Position = function() return 1453, 0.69, 0.31 end
    local t3 = ns.Engine.TravelFor(s)
    assertNotNil(t3); assertTrue(t3.how ~= "aboard", t3.text)
  end)
  HBD.GetWorldCoordinatesFromZone, ns.State.Position, ns.State.knownTaxi, C_Map.GetMapInfo, ForeverRouteDB.docks = sv.conv, sv.pos, sv.taxi, sv.info, sv.docks
  ns.Engine.lastTrip, ns.Engine.lastTripStep = sv.lt, sv.lts
  if not ok then error(err, 0) end
end)

test("a plan made for someone lower (the built-in plan from level 1): at 24 the quests you've outgrown and the trips to them are passed over", function()
  local sv = { lvl = UnitLevel }
  withState({}, function()
    ForeverRouteData = { id = "low", title = "low", sections = { { title = "Dun Morogh" }, { title = "Ashenvale" } }, steps = {
      { k = "accept", q = 179, name = "Dwarven Outfitters", level = 1, m = 1426, x = 0.29, y = 0.71, sec = 1, lvl = 1 },
      { k = "obj", q = 179, name = "Dwarven Outfitters", text = "Collect 8 Tough Wolf Meat", level = 1, sec = 1, lvl = 1 },
      { k = "turnin", q = 179, name = "Dwarven Outfitters", level = 1, m = 1426, x = 0.29, y = 0.71, sec = 1, lvl = 1 },
      { k = "accept", q = 233, name = "Coldridge Valley Mail Delivery", level = 3, m = 1426, x = 0.29, y = 0.71, sec = 1, lvl = 2 },
      { k = "turnin", q = 233, name = "Coldridge Valley Mail Delivery", level = 3, m = 1426, x = 0.22, y = 0.52, sec = 1, lvl = 2 },
      { k = "train", text = "level 4 spells", until_ = 4, sec = 1, lvl = 4 },
      { k = "fly", to = 1440, dest = "Ashenvale", text = "Ashenvale", sec = 2, lvl = 20 },
      { k = "accept", q = 1010, name = "Bathran's Hair", level = 20, m = 1440, x = 0.26, y = 0.38, sec = 2, lvl = 20 },
      { k = "turnin", q = 1010, name = "Bathran's Hair", level = 20, m = 1440, x = 0.26, y = 0.38, sec = 2, lvl = 20 },
      { k = "train", text = "level 22/24 spells", sec = 2, lvl = 24 },
    } }
    UnitLevel = function() return 3 end
    ns.Engine.Refresh(); assertEquals(1, ns.Engine.Shown()) -- a level-3 player starts at the start
    UnitLevel = function() return 24 end
    ns.Engine.Refresh()
    -- Dun Morogh's quests and the level-4 training are behind you; so is the trip to Ashenvale when you're there,
    -- but from elsewhere the trip is the step
    local shown = ns.Engine.Shown()
    assertTrue(shown == 7 or shown == 8, "shown step " .. tostring(shown))
    for i = 1, 6 do assertTrue(ns.Engine.IsDone(i), "step " .. i .. " should be passed at 24") end
    assertTrue(not ns.Engine.Outlevelled(ForeverRouteData.steps[8])) -- level 20 at 24: still yours
    assertEquals(24, ns.Engine.TrainLevel(ForeverRouteData.steps[10]))
    assertTrue(not ns.Engine.IsDone(10)) -- the stop that's due now stays
  end)
  UnitLevel = sv.lvl
end)

test("joining the built-in plan at 30: what the plan does below your level is behind you, quests in your log stay", function()
  local sv = { lvl = UnitLevel, pk = ns.planKey }
  withState({ [244] = { on = true, objectives = { { finished = false, text = "x: 0/1" } } } }, function()
    ns.State.OnQuest = function(id) return id == 244 end
    ForeverRouteData = { id = "join", title = "join", sections = { { title = "Redridge Mountains" }, { title = "Duskwood" } }, steps = {
      -- the plan does Redridge at 20-22: quests of level 24-26, not far enough below 30 to be outlevelled
      { k = "accept", q = 34, name = "An Unwelcome Guest", level = 24, m = 1433, x = 0.17, y = 0.46, sec = 1, lvl = 21 },
      { k = "turnin", q = 34, name = "An Unwelcome Guest", level = 24, m = 1433, x = 0.17, y = 0.46, sec = 1, lvl = 22 },
      { k = "fp", fp = "Lakeshire, Redridge", m = 1433, x = 0.30, y = 0.59, sec = 1, lvl = 20 },
      -- one of them already in your log: it stays yours
      { k = "turnin", q = 244, name = "Encroaching Gnolls", level = 24, m = 1433, x = 0.30, y = 0.44, sec = 1, lvl = 22 },
      -- Duskwood at 28-30: your level
      { k = "accept", q = 1110, name = "Raven Hill", level = 28, m = 1431, x = 0.73, y = 0.46, sec = 2, lvl = 28 },
    } }
    UnitLevel = function() return 30 end
    ns.planKey = { starter = "human-mage" }
    ns.Engine.Refresh()
    for _, i in ipairs({ 1, 2, 3 }) do assertTrue(ns.Engine.IsDone(i), "step " .. i .. " (planned at " .. ForeverRouteData.steps[i].lvl .. ") should be behind a level 30") end
    assertTrue(not ns.Engine.IsDone(4), "a quest in your log was dropped")
    assertTrue(not ns.Engine.IsDone(5), "a step at your level was passed")
    -- a plan of your own (the companion's) is made from your save: nothing is passed for this
    ns.planKey = { found = "x" }
    ns.Engine.Refresh()
    assertTrue(not ns.Engine.IsDone(1), "your own plan's step was passed")
    -- levelling along the built-in plan: a step a level or two behind stays
    ns.planKey = { starter = "human-mage" }
    UnitLevel = function() return 24 end
    ns.Engine.Refresh()
    assertTrue(not ns.Engine.IsDone(1), "a step 3 levels behind was passed")
  end)
  UnitLevel, ns.planKey = sv.lvl, sv.pk
end)

test("a quest far below you that you're still on is finished, not dropped", function()
  local sv = { lvl = UnitLevel }
  withState({ [179] = { on = true, objectives = { { finished = false, text = "Tough Wolf Meat: 2/8" } } } }, function()
    ns.State.OnQuest = function(id) return id == 179 end
    ForeverRouteData = { id = "low2", title = "low2", sections = { { title = "x" } }, steps = {
      { k = "obj", q = 179, name = "Dwarven Outfitters", text = "Collect 8 Tough Wolf Meat", level = 1, sec = 1 },
      { k = "turnin", q = 179, name = "Dwarven Outfitters", level = 1, m = 1426, x = 0.29, y = 0.71, sec = 1 },
    } }
    UnitLevel = function() return 24 end
    assertTrue(not ns.Engine.Outlevelled(ForeverRouteData.steps[1]))
    ns.Engine.Refresh(); assertEquals(1, ns.Engine.Shown())
  end)
  UnitLevel = sv.lvl
end)

test("gear rewards: the enchant on what you wear counts (you'd lose it), the verdict goes on the card and into the save", function()
  local sv = { info = ns.GetItemInfo, stats = ns.GetItemStats, link = GetInventoryItemLink, tip = C_TooltipInfo.GetInventoryItem, class = UnitClass, char = ns.char, data = ForeverRouteData }
  local ITEMS = {
    [5000] = { link = "item:5000", loc = "INVTYPE_ROBE", stats = { ITEM_MOD_INTELLECT_SHORT = 7 } },              -- the reward
    [5001] = { link = "item:5001", loc = "INVTYPE_ROBE", stats = { ITEM_MOD_INTELLECT_SHORT = 6 } },              -- what you wear
    [5002] = { link = "item:5002", loc = "INVTYPE_ROBE", stats = { ITEM_MOD_INTELLECT_SHORT = 20 } },             -- a real upgrade
  }
  local byLink = {}; for id, it in pairs(ITEMS) do byLink[it.link] = it; it.id = id end
  ns.GetItemInfo = function(x)
    local it = ITEMS[tonumber(x)] or byLink[x]; if not it then return nil end
    return "Robe " .. it.id, it.link, 2, 25, 20, "Armor", "Cloth", 1, it.loc, 0, 100, 4, 1
  end
  ns.GetItemStats = function(link) return (byLink[link] or {}).stats or {} end
  GetInventoryItemLink = function(_, slot) return slot == 5 and "item:5001" or nil end
  local enchanted = true
  C_TooltipInfo.GetInventoryItem = function(_, slot)
    if slot ~= 5 or not enchanted then return { lines = { { leftText = "Robe" } } } end
    return { lines = { { leftText = "Robe" }, { leftText = "Enchanted: Stamina +2 and Armor +16" } } }
  end
  UnitClass = function() return "Warlock", "WARLOCK" end
  local ok, err = pcall(function()
    assertEquals(2, ns.Quests.EnchantStats(5).STAMINA); assertEquals(16, ns.Quests.EnchantStats(5).RESISTANCE0)
    -- +1 Intellect over yours, but you'd lose +2 Stamina and +16 Armor: not an upgrade
    assertTrue(ns.Quests.Evaluate("item:5000") < 0)
    enchanted = false
    assertTrue(ns.Quests.Evaluate("item:5000") > 0) -- without the enchant it would be
    enchanted = true
    ns.char = { gearVerdict = {} }
    ForeverRouteData = { id = "g", steps = {
      { k = "accept", q = 1009, name = "Ruuzel", reward = 5000, note = "Reward: Robe 5000 (armor upgrade, ilvl 25)  ·  Heads up: single-spawn target (respawn waits)" },
      { k = "turnin", q = 1010, name = "Other", reward = 5002, note = "Reward: Robe 5002 (armor upgrade, ilvl 26)" },
    } }
    ns.Quests.JudgeTick(5)
    assertTrue(ns.char.gearVerdict[5000].d < 0); assertTrue(ns.char.gearVerdict[5002].d > 0)
    assertEquals("Reward: Robe 5000 (not an upgrade for you)  ·  Heads up: single-spawn target (respawn waits)", ns.Quests.RewardNote(ForeverRouteData.steps[1]))
    assertTrue(ns.Quests.RewardNote(ForeverRouteData.steps[2]):find("upgrade for you, +", 1, true) ~= nil)
    -- changing gear makes every verdict stale
    ns.Fire("PLAYER_EQUIPMENT_CHANGED", 5)
    assertNil(ns.Quests.Verdict(5000))
    assertEquals("Reward: Robe 5000 (armor upgrade, ilvl 25)  ·  Heads up: single-spawn target (respawn waits)", ns.Quests.RewardNote(ForeverRouteData.steps[1]))
  end)
  ns.GetItemInfo, ns.GetItemStats, GetInventoryItemLink, C_TooltipInfo.GetInventoryItem, UnitClass, ns.char, ForeverRouteData = sv.info, sv.stats, sv.link, sv.tip, sv.class, sv.char, sv.data
  if not ok then error(err, 0) end
end)

test("objectives with no match word (objects, places): the step is matched by its distinctive words, never on a tie", function()
  withState({ [953] = { on = true, objectives = { { text = "Lay of Ameth'Aran read: 1/1", finished = true }, { text = "Fall of Ameth'Aran read: 0/1", finished = false } } },
              [1140] = { on = true, objectives = { { text = "Highborne soul in Satyrnaar freed: 0/1", finished = false }, { text = "Highborne soul in Night Run freed: 1/1", finished = true } } } }, function()
    local lay = ns.Engine.ObjectiveFor({ k = "obj", q = 953, text = "Read the Lay of Ameth'Aran" })
    assertNotNil(lay); assertTrue(lay.finished)
    local fall = ns.Engine.ObjectiveFor({ k = "obj", q = 953, text = "Read the Fall of Ameth'Aran" })
    assertNotNil(fall); assertTrue(not fall.finished)
    assertTrue(ns.Engine.ObjectiveFor({ k = "obj", q = 1140, text = "Free the Highborne soul in Night Run" }).finished)
    assertNil(ns.Engine.ObjectiveFor({ k = "obj", q = 1140, text = "Free the Highborne soul" })) -- both share these words: a tie
  end)
end)

test("travel: a ride through the other faction's town is flagged (Alliance: the Crossroads; Horde: not)", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { conv = HBD.GetWorldCoordinatesFromZone, fac = UnitFactionGroup }
  local B = ns.TravelData.BOUNDS
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) local b = B[m]; if not b then return nil end return b[1] + x * (b[2] - b[1]), b[3] + y * (b[4] - b[3]), b[5] end
  local ok, err = pcall(function()
    local function w(x, y) local a, b, c = HBD:GetWorldCoordinatesFromZone(x, y, 1413); return { a, b, c } end
    UnitFactionGroup = function() return "Alliance" end
    assertEquals("the Crossroads", ns.Travel.Through(w(0.52, 0.22), w(0.52, 0.40)).name) -- straight through it
    assertTrue(not ns.Travel.Through(w(0.38, 0.22), w(0.38, 0.40))) -- well west of it (at 0.30 the Horde camp by the Thunder Bluff lift in Mulgore, from QuestieDB 1.0.15, is 58 yd off)
    UnitFactionGroup = function() return "Horde" end
    assertTrue(not ns.Travel.Through(w(0.52, 0.22), w(0.52, 0.40)))
  end)
  HBD.GetWorldCoordinatesFromZone, UnitFactionGroup = sv.conv, sv.fac
  if not ok then error(err, 0) end
end)

test("travel: a trip that does go through the other faction's town says so on the card (still the way, not avoided at any cost)", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { conv = HBD.GetWorldCoordinatesFromZone, fac = UnitFactionGroup, lvl = UnitLevel }
  local B = ns.TravelData.BOUNDS
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) local b = B[m]; if not b then return nil end return b[1] + x * (b[2] - b[1]), b[3] + y * (b[4] - b[3]), b[5] end
  UnitFactionGroup = function() return "Alliance" end
  UnitLevel = function() return 30 end
  local ok, err = pcall(function()
    -- from just north of the Crossroads to its south gate: through it is the way
    local legs = ns.Travel.Plan({ m = 1413, x = 0.515, y = 0.27 }, { m = 1413, x = 0.52, y = 0.33, name = "the south gate" })
    assertNotNil(legs, "no trip")
    local text = ns.Travel.Describe(legs)
    assertTrue(text:find("passes the Crossroads", 1, true) ~= nil, text)
  end)
  HBD.GetWorldCoordinatesFromZone, UnitFactionGroup, UnitLevel = sv.conv, sv.fac, sv.lvl
  if not ok then error(err, 0) end
end)

test("bind: binding at a later inn of the route passes the earlier bind step (never back across the sea to rebind)", function()
  local sv = { bind = GetBindLocation }
  withState({}, function()
    ForeverRouteData = { id = "bind2", title = "b", sections = { { title = "x" } }, steps = {
      { k = "bind", bind = "Auberdine", zone = "Darkshore", m = 1439, x = 0.37, y = 0.44, sec = 1 },
      { k = "accept", q = 1, name = "A", m = 1437, x = 0.1, y = 0.6, sec = 1 },
      { k = "bind", bind = "Menethil Harbor", zone = "Wetlands", m = 1437, x = 0.1, y = 0.6, sec = 1 },
    } }
    GetBindLocation = function() return "Menethil Harbor" end
    ns.char.boundAt = { name = "Menethil Harbor", m = 1437 }
    assertTrue(ns.Engine.IsDone(1)) -- Auberdine's bind is behind you
    assertTrue(ns.Engine.IsDone(3))
    GetBindLocation = function() return "Auberdine" end
    ns.char.boundAt = { name = "Auberdine", m = 1439 }
    assertTrue(ns.Engine.IsDone(1)); assertTrue(not ns.Engine.IsDone(3)) -- Menethil's is still ahead
  end)
  GetBindLocation = sv.bind
end)

test("dungeons: done once you've been in; half a run, or a skipped run, leaves what's inside for later (the card moves on); a second planned run stays", function()
  local sv = { inst = IsInInstance, info = GetInstanceInfo }
  local inside = nil
  IsInInstance = function() return inside ~= nil, inside and "party" or "none" end
  GetInstanceInfo = function() return inside end
  withState({ [1740] = { on = true, objectives = { { text = "Large Soran'ruk Fragment: 0/1", finished = false } } },
              [1199] = { on = true, objectives = { { text = "Twilight Pendant: 4/10", finished = false } } },
              [1275] = { on = true, objectives = { { text = "Corrupted Brain Stem: 8/8", finished = true } } } }, function()
    ns.State.OnQuest = function(id) return id == 1199 or id == 1275 or id == 1740 end
    ForeverRouteData = { id = "bfd", title = "bfd", sections = { { title = "x" } }, steps = {
      { k = "goto", text = "Run Blackfathom Deeps with a group", dungeon = "Blackfathom Deeps", m = 1440, x = 0.14, y = 0.14, sec = 1 },
      { k = "obj", q = 1199, name = "Twilight Falls", text = "Collect 10 Twilight Pendant (in Blackfathom Deeps)", match = "Twilight Pendant", sec = 1 },
      { k = "obj", q = 1275, name = "Researching the Corruption", text = "Collect 8 Corrupted Brain Stem (in Blackfathom Deeps)", match = "Corrupted Brain Stem", sec = 1 },
      { k = "turnin", q = 1199, name = "Twilight Falls", m = 1457, x = 0.5, y = 0.5, sec = 1 },
      { k = "accept", q = 1035, name = "Fallen Sky Lake", m = 1440, x = 0.5, y = 0.5, sec = 1 },
      { k = "goto", text = "Run Blackfathom Deeps with a group", dungeon = "Blackfathom Deeps", m = 1440, x = 0.14, y = 0.14, sec = 2 },
      { k = "obj", q = 1740, name = "The Orb of Soran'ruk", text = "Collect Large Soran'ruk Fragment (in Blackfathom Deeps)", match = "Large Soran'ruk Fragment", sec = 2 },
    } }
    ns.char.ranRun = nil
    ns.Engine.Refresh(); assertEquals(1, ns.Engine.Shown()) -- go run it
    inside = "Blackfathom Deeps"; ns.Fire("ZONE_CHANGED_NEW_AREA"); ns.Engine.Refresh()
    assertEquals(2, ns.Engine.Shown()) -- inside: the pendants
    inside = nil; ns.Engine.Refresh() -- left with 4/10 pendants (they didn't drop)
    assertTrue(ns.Engine.IsDone(1), "the run came back after you left")
    assertEquals("later", ns.Engine.Status(2)); assertEquals("later", ns.Engine.Status(4))
    assertEquals(5, ns.Engine.Shown()) -- the route goes on
    assertTrue(not ns.Engine.IsDone(6)) -- the second planned run is still to do
    -- a new plan after the run (the drops still missing): its run is to do again, not taken as already run
    local svPlan = ForeverRoutePlan
    ForeverRoutePlan = { generated = 99 }
    ns.Engine.Refresh()
    assertTrue(not ns.Engine.IsDone(1), "a new plan's run was taken as already run")
    ForeverRoutePlan = svPlan; ns.Engine.Refresh()
    -- skipping a run: what's inside waits too
    ns.char.ranRun = nil; ns.char.skipped = { [ns.Engine.Key(1)] = true }
    ns.Engine.Refresh()
    assertEquals("later", ns.Engine.Status(2)); assertEquals(5, ns.Engine.Shown())
  end)
  IsInInstance, GetInstanceInfo = sv.inst, sv.info
end)

-- work the quest data lists none of (route2.js unknownWork: Brewer's Trade, given and handed in by Brewmeister Bilger,
-- "Deliver the bottles ... to Dun Garok"): one step that says so, placed at the giver only to keep its place in the
-- order - no arrow, pin or line for it; the card shows the quest log's own lines; done when the quest is ready
local function unknownRoute()
  local s = {
    { k = "accept", q = 98071, name = "Brewer's Trade", npc = "Brewmeister Bilger", m = 1424, x = 0.5213, y = 0.5874, r = 6, sec = 1, lvl = 27 },
    { k = "obj", unknown = true, q = 98071, name = "Brewer's Trade", text = "Deliver the bottles of Fallrook Varietal to Dun Garok in southeast\226\128\166", r = 40,
      note = "Where to do this isn't in the quest data: follow your quest log and map.", m = 1424, x = 0.5213, y = 0.5874, sec = 1, lvl = 27 },
    { k = "turnin", q = 98071, name = "Brewer's Trade", npc = "Brewmeister Bilger", m = 1424, x = 0.5213, y = 0.5874, r = 6, sec = 1, lvl = 27 },
    { k = "accept", q = 702, name = "Elsewhere", npc = "Someone", m = 1424, x = 0.30, y = 0.40, r = 6, sec = 1, lvl = 27 },
  }
  for i, t in ipairs(s) do t.id = i end
  return { id = "unk", title = "unk", sections = { { title = "Southshore" } }, steps = s }
end
test("unknown work: no arrow, pin or line for it; the card shows its words, the note and the quest log's lines; done when the quest is ready", function()
  withWorld(unknownRoute(), function(w)
    w:go(1424, 0.52, 0.587) -- at Brewmeister Bilger
    assertEquals(1, w:shown())
    w:quest(98071, { on = true, objectives = { { text = "Homebrew Hops: 0/1", finished = false, have = 0, need = 1 } } })
    assertEquals(2, w:shown(), "the card does not show the work after the pick-up")
    assertEquals("todo", ns.Engine.Status(2))
    ns.Arrow.SetTarget(2, true)
    assertNil(ns.Arrow.Current(), "the arrow points at a place the quest data does not have")
    ns.Pins.Update(true)
    for _, p in ipairs(ns.Pins._used) do assertTrue(p.index ~= 2, "a map pin for the unknown step") end
    assertNil(ns.Engine.TravelFor(ForeverRouteData.steps[2]), "a trip planned to it")
    assertEquals(0, ns.Pins.PathDots(), "a path line drawn to it")
    -- the card: its words, the note, the live line of the quest - no coordinates, no map button
    ns.Card.Fill()
    local cur = ForeverRouteCard.cur
    assertTrue(ns.Card.Plain(cur.titleText:GetText()):find("Deliver the bottles", 1, true) ~= nil, cur.titleText:GetText())
    assertTrue(ns.Card.Plain(cur.note:GetText() or ""):find("isn't in the quest data", 1, true) ~= nil, cur.note:GetText())
    assertTrue(not (cur.detail:GetText() or ""):find("52, 59", 1, true), "the card gives the giver's coordinates for it")
    assertTrue(not cur.map:IsShown(), "a map button for a place nobody knows")
    assertEquals(1, cur.nbars); assertEquals("Homebrew Hops", cur.bars[1].label:GetText()); assertEquals("0/1", cur.bars[1].value:GetText())
    -- the hand-in after it waits ("not ready"); the quest is ready: the work is done, the hand-in is next
    assertEquals("notready", ns.Engine.Status(3))
    w:quest(98071, { on = true, complete = true, objectives = { { text = "Homebrew Hops: 1/1", finished = true, have = 1, need = 1 } } })
    assertEquals("done", ns.Engine.Status(2)); assertEquals(3, w:shown())
  end)
end)
test("unknown work: skipped, the route goes on; the hand-in waits and comes back when the quest is ready", function()
  withWorld(unknownRoute(), function(w)
    w:go(1424, 0.52, 0.587)
    w:quest(98071, { on = true, objectives = { { text = "Homebrew Hops: 0/1", finished = false, have = 0, need = 1 } } })
    assertEquals(2, w:shown())
    ns.Engine.Skip(2)
    assertEquals("later", ns.Engine.Status(3), "the hand-in holds up the route")
    assertEquals(4, w:shown(), "the route does not go on")
    local why, j = ns.Engine.NotYet(3); assertEquals("objectives", why); assertEquals(2, j)
    w:quest(98071, { on = true, complete = true, objectives = { { text = "Homebrew Hops: 1/1", finished = true, have = 1, need = 1 } } })
    assertEquals(3, w:shown(), "the hand-in did not come back once the quest was ready")
  end)
end)

test("pace is learned from the quest log's counts (not the card): seconds between kills, breaks left out", function()
  local sv = { ids = ns.State.LogIDs, quest = ns.State.Quest, learn = ForeverRouteDB.learn }
  ForeverRouteDB.learn = nil
  local have = 0
  ns.State.LogIDs = function() return { [33] = true } end
  ns.State.Quest = function() return { on = true, objectives = { { text = "Wolf slain: " .. have .. "/8", have = have, need = 8 } } } end
  local ok, err = pcall(function()
    ns.Learn.ProgressTick(1000)                 -- first look: nothing to time yet
    have = 1; ns.Learn.ProgressTick(1030)       -- 30 s for the first wolf
    have = 3; ns.Learn.ProgressTick(1070)       -- 2 more in 40 s
    have = 4; ns.Learn.ProgressTick(2000)       -- a break: not a sample
    local P = ForeverRouteDB.learn.pace
    assertEquals(2, #P)
    assertEquals("Kill", P[1].k); assertEquals(1, P[1].need); assertEquals(30, P[1].sec)
    assertEquals(2, P[2].need); assertEquals(40, P[2].sec)
  end)
  ns.State.LogIDs, ns.State.Quest, ForeverRouteDB.learn = sv.ids, sv.quest, sv.learn
  if not ok then error(err, 0) end
end)

test("dungeons: a run for its XP (nothing to do inside) waits for you - going in or skipping passes it", function()
  local sv = { inst = IsInInstance, info = GetInstanceInfo }
  local inside = nil
  IsInInstance = function() return inside ~= nil, inside and "party" or "none" end
  GetInstanceInfo = function() return inside end
  withState({}, function()
    ForeverRouteData = { id = "xp", title = "xp", sections = { { title = "x" } }, steps = {
      { k = "goto", text = "Run Scarlet Monastery with a group", dungeon = "Scarlet Monastery", xpRun = true, m = 1420, x = 0.82, y = 0.33, sec = 1 },
      { k = "accept", q = 1, name = "Next", m = 1424, x = 0.5, y = 0.5, sec = 1 },
    } }
    ns.char.ranRun = nil
    ns.Engine.Refresh(); assertEquals(1, ns.Engine.Shown())
    inside = "Scarlet Monastery"; ns.Fire("ZONE_CHANGED_NEW_AREA"); inside = nil; ns.Engine.Refresh()
    assertEquals(2, ns.Engine.Shown())
  end)
  IsInInstance, GetInstanceInfo = sv.inst, sv.info
end)

test("built-in plans load on demand: only your race and class's plan addon is loaded, and only when there's no plan of your own", function()
  local sv = { by = ForeverRouteByChar, st = ForeverRouteStarter, key = ns.planKey, race = UnitRace, class = UnitClass, load = C_AddOns and C_AddOns.LoadAddOn, routes = ForeverRouteRoutes, data = ForeverRouteData }
  UnitRace = function() return "Night Elf", "NightElf" end
  UnitClass = function() return "Druid", "DRUID" end
  local asked = {}
  C_AddOns = C_AddOns or {}
  C_AddOns.LoadAddOn = function(name) asked[#asked + 1] = name; if name == "ForeverRoute_Starter_nightelf_druid" then ForeverRouteStarter = { ["nightelf-druid"] = function() ForeverRouteRoutes = { { id = "path:X", steps = {} } } end } end; return true end
  local ok, err = pcall(function()
    ForeverRouteStarter = nil; ForeverRouteByChar = {}
    assertTrue(ns.LoadMyPlan())
    -- the faction addon first (no such addon here: the older per-plan one is the fallback), never another race's plan
    assertEquals("ForeverRoute_Plans_Alliance", asked[1]); assertEquals("ForeverRoute_Starter_nightelf_druid", asked[#asked])
    for _, n in ipairs(asked) do assertTrue(n:find("^ForeverRoute_Plans_") or n == "ForeverRoute_Starter_nightelf_druid", "loaded " .. n) end
    -- a plan of your own: nothing loaded
    asked = {}; ForeverRouteStarter = nil; ForeverRouteByChar = { [ns.CharKey()] = function() end }
    assertTrue(ns.LoadMyPlan()); assertEquals(0, #asked)
  end)
  ForeverRouteByChar, ForeverRouteStarter, ns.planKey, UnitRace, UnitClass, ForeverRouteRoutes, ForeverRouteData = sv.by, sv.st, sv.key, sv.race, sv.class, sv.routes, sv.data
  C_AddOns.LoadAddOn = sv.load
  if not ok then error(err, 0) end
end)

test("objective matching: the exact name before a longer one ('Murloc' is not 'Murloc Streamrunner'), and by elimination for a step that says nothing ('Explore')", function()
  withState({ [99128] = { on = true, objectives = { { text = "Murloc Streamrunner slain: 1/4", finished = false }, { text = "Murloc slain: 7/7", finished = true } } },
              [98386] = { on = true, objectives = { { text = "Tarantula Egg used: 1/1", finished = true }, { text = "Alther's Mill explored", finished = false } } } }, function()
    ForeverRouteData = { id = "m", steps = {
      { k = "obj", q = 99128, text = "Kill 4 Murloc Streamrunner", match = "Murloc Streamrunner" },
      { k = "obj", q = 99128, text = "Kill 7 Murloc", match = "Murloc" },
      { k = "obj", q = 98386, text = "Use Tarantula Egg" },
      { k = "obj", q = 98386, text = "Explore" },
    } }
    assertTrue(ns.Engine.ObjectiveFor(ForeverRouteData.steps[2]).finished) -- the plain Murlocs
    assertTrue(not ns.Engine.ObjectiveFor(ForeverRouteData.steps[1]).finished)
    assertTrue(ns.Engine.ObjectiveFor(ForeverRouteData.steps[3]).finished)
    assertEquals("Alther's Mill explored", ns.Engine.ObjectiveFor(ForeverRouteData.steps[4]).text)
  end)
end)

test("objective matching: two steps of a quest that both need elimination don't ask each other forever (a stack overflow at level 54)", function()
  withState({ [98999] = { on = true, objectives = { { text = "Winterfall ritual disrupted: 0/1", finished = false }, { text = "Totem of the north cleansed: 0/1", finished = false }, { text = "Shrine visited", finished = false } } } }, function()
    ForeverRouteData = { id = "e", steps = {
      { k = "obj", q = 98999, text = "Use the Winterfall Totem" },
      { k = "obj", q = 98999, text = "Use the North Shrine" },
    } }
    local ok, err = pcall(ns.Engine.ObjectiveFor, ForeverRouteData.steps[1])
    assertTrue(ok, tostring(err))
    ok, err = pcall(ns.Engine.ObjectiveFor, ForeverRouteData.steps[2])
    assertTrue(ok, tostring(err))
  end)
end)

test("dungeons: three XP runs in a row - inside, only the run you're on is done; the next ones stay", function()
  local sv = { inst = IsInInstance, info = GetInstanceInfo }
  local inside = nil
  IsInInstance = function() return inside ~= nil, inside and "party" or "none" end
  GetInstanceInfo = function() return inside end
  withState({}, function()
    local run = function() return { k = "goto", text = "Run The Temple of Atal'Hakkar with a group", dungeon = "The Temple of Atal'Hakkar", xpRun = true, m = 1435, x = 0.69, y = 0.53, sec = 1 } end
    ForeverRouteData = { id = "st", title = "st", sections = { { title = "x" } }, steps = { run(), run(), run(), { k = "fly", to = 1457, dest = "Darnassus", text = "Darnassus", sec = 2 } } }
    ns.char.ranRun = nil
    ns.Engine.Refresh(); assertEquals(1, ns.Engine.Shown()) -- the card on the first run as you go in
    inside = "The Temple of Atal'Hakkar"; ns.Fire("ZONE_CHANGED_NEW_AREA"); ns.Engine.Refresh()
    assertTrue(ns.Engine.IsDone(1)); assertTrue(not ns.Engine.IsDone(2)); assertTrue(not ns.Engine.IsDone(3))
    assertEquals(2, ns.Engine.Shown()) -- the next run, not Darnassus
    inside = nil; ns.Fire("ZONE_CHANGED_NEW_AREA"); inside = "The Temple of Atal'Hakkar"; ns.Fire("ZONE_CHANGED_NEW_AREA"); ns.Engine.Refresh()
    assertTrue(ns.Engine.IsDone(2)); assertEquals(3, ns.Engine.Shown())
  end)
  IsInInstance, GetInstanceInfo = sv.inst, sv.info
end)

test("zone chips: only the next few zones, then how many more", function()
  local Style = ns.Style
  local holder = CreateFrame("Frame", nil, UIParent); holder:SetSize(400, 20)
  local zones = { "Wetlands", "Duskwood", "Dun Morogh", "Ashenvale", "Stranglethorn", "Wetlands", "Desolace", "Duskwood", "Arathi", "Tanaris" }
  Style.Chips(holder, zones, 400, 5)
  local shown = 0; for _, c in ipairs(holder.chips) do if c:IsShown() then shown = shown + 1 end end
  assertEquals(5, shown)
  assertTrue(holder.more:IsShown()); assertEquals("> +5 more zones", holder.more:GetText())
  Style.Chips(holder, { "Wetlands", "Duskwood" }, 400, 5) -- fewer than the limit: all of them, no "more"
  shown = 0; for _, c in ipairs(holder.chips) do if c:IsShown() then shown = shown + 1 end end
  assertEquals(2, shown); assertTrue(not holder.more:IsShown())
end)

test("a quest you said you won't do comes back when you finish it anyway; one already finished when you dropped it stays dropped", function()
  local done = false
  local ok, err = pcall(withState, {}, function()
    ForeverRouteData = { id = "np", title = "np", sections = { { title = "x" } }, steps = {
      { id = 1, k = "accept", q = 98221, name = "From the Ashes", m = 1437, x = 0.1, y = 0.57, r = 6, sec = 1 },
      { id = 2, k = "turnin", q = 98221, name = "From the Ashes", m = 1437, x = 0.1, y = 0.57, r = 6, sec = 1 },
      { id = 3, k = "turnin", q = 500, name = "Gray Old Thing", m = 1437, x = 0.1, y = 0.57, r = 6, sec = 1 },
    } }
    ns.State.OnQuest = function(id) return id == 98221 or id == 500 end
    ns.State.IsCompleted = function() return false end
    ns.State.Quest = function(id)
      if id == 98221 then return { on = true, complete = done, objectives = { { text = "Attack Plan: 0/1", finished = done, have = done and 1 or 0, need = 1 } } } end
      if id == 500 then return { on = true, complete = true, objectives = {} } end
      return { on = false, objectives = {} }
    end
    ns.char.nope = {}
    ns.Engine.NopeNow({ 98221 }); ns.Engine.NopeNow({ 500 })
    assertEquals("done", ns.Engine.Status(2)); assertEquals("done", ns.Engine.Status(3))
    done = true; ns.Fire("FR_STATE")          -- finished it after all
    assertNil(ns.char.nope[98221]); assertEquals("todo", ns.Engine.Status(2))
    assertEquals("ready", ns.char.nope[500]); assertEquals("done", ns.Engine.Status(3)) -- dropped when already done: stays
  end)
  ns.char.nope = {}
  if not ok then error(err, 0) end
end)

test("won't-do quests are listed and can be brought back; the route list can hide what's done", function()
  local ok, err = pcall(withState, {}, function()
    ForeverRouteData = { id = "hd", title = "hd", sections = { { title = "A" }, { title = "B" } }, steps = {
      { id = 1, k = "accept", q = 801, name = "Done One", m = 1437, x = 0.1, y = 0.5, r = 6, sec = 1 },
      { id = 2, k = "accept", q = 802, name = "Done Two", m = 1437, x = 0.1, y = 0.5, r = 6, sec = 1 },
      { id = 3, k = "accept", q = 803, name = "Open One", m = 1437, x = 0.1, y = 0.5, r = 6, sec = 2 },
      { id = 4, k = "accept", q = 804, name = "Dropped", m = 1437, x = 0.1, y = 0.5, r = 6, sec = 2 },
    } }
    ns.State.OnQuest = function(id) return id == 801 or id == 802 end
    ns.State.IsCompleted = function() return false end
    ns.char.nope = { [804] = true }
    ns.Engine.Refresh()
    local n = ns.Engine.Noped(); assertEquals(1, #n); assertEquals(804, n[1].q); assertEquals("Dropped", n[1].name)
    assertEquals("done", ns.Engine.Status(4))
    ns.Engine.Unnope(804)
    assertNil(ns.char.nope[804]); assertEquals("todo", ns.Engine.Status(4))
    -- the list: with done steps hidden, section A (all done) is gone
    ns.db.hideDone = true
    ns.Fire("FR_TOGGLE_LIST")
    local shownTexts = {}
    for _, r in ipairs({ ForeverRouteList:GetChildren() }) do if r.text and r:IsShown() and r.text:GetText() then shownTexts[#shownTexts + 1] = r.text:GetText() end end
    local all = table.concat(shownTexts, "|")
    assertTrue(all:find("Open One", 1, true) ~= nil, all); assertTrue(all:find("Done One", 1, true) == nil, all)
    ns.Fire("FR_TOGGLE_LIST")
  end)
  ns.db.hideDone = nil; ns.char.nope = {}
  if not ok then error(err, 0) end
end)

planOrderTest("live reordering: at an NPC with a finished quest to hand in, that hand-in shows - however far down the plan, over a held one", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local realConv = HBD.GetWorldCoordinatesFromZone
  local ok, err = pcall(withState, {}, function()
    local list = { { id = 1, k = "accept", q = 901, name = "Far Planned", m = 1437, x = 0.60, y = 0.30, r = 6, sec = 1 } }
    list[2] = { id = 2, k = "turnin", q = 98072, name = "Crocs of the Sky", npc = "James Halloran", m = 1437, x = 0.0855, y = 0.5574, r = 6, sec = 1 }
    for k = 3, 260 do list[k] = { id = k, k = "accept", q = 1000 + k, name = "Filler " .. k, m = 1437, x = 0.5, y = 0.5, r = 6, sec = 1 } end
    list[261] = { id = 261, k = "turnin", q = 98221, name = "From the Ashes", npc = "Captain Stoutfist", m = 1437, x = 0.0986, y = 0.5749, r = 6, sec = 1 }
    ForeverRouteData = { id = "st", title = "st", sections = { { title = "x" } }, steps = list }
    ns.State.OnQuest = function(id) return id == 98072 or id == 98221 end
    ns.State.IsCompleted = function() return false end
    ns.State.Quest = function(id) if id == 98072 or id == 98221 then return { on = true, complete = true, objectives = {} } end return { on = false, objectives = {} } end
    HBD.GetWorldCoordinatesFromZone = function(_, mx, my, m) return mx * 3500, my * 3500, 0 end
    ns.Engine.focus = nil; ns.Engine.Refresh()
    assertEquals(1, ns.Engine.current)
    local hx, hy, inst = HBD:GetWorldCoordinatesFromZone(0.0855, 0.5574, 1437)
    ns.Engine.UpdateFocus(hx + 60, hy, inst); ns.Engine.Refresh()   -- in town, near James Halloran: Crocs (held)
    assertEquals(2, ns.Engine.current)
    local sx, sy = HBD:GetWorldCoordinatesFromZone(0.0986, 0.5749, 1437)
    ns.Engine.UpdateFocus(sx + 3, sy, inst); ns.Engine.Refresh()    -- now right at Captain Stoutfist
    assertEquals(261, ns.Engine.current)
  end)
  HBD.GetWorldCoordinatesFromZone = realConv
  ns.Engine.focus = nil
  if not ok then error(err, 0) end
end)

test("a flight to a stop with nothing left to do there is done: no 'Fly to Wetlands, Fly to Stormwind' ping-pong", function()
  local ok, err = pcall(withState, {}, function()
    ForeverRouteData = { id = "pp", title = "pp", sections = { { title = "x" } }, steps = {
      { id = 1, k = "turnin", q = 1274, name = "The Missing Diplomat", m = 1453, x = 0.8, y = 0.44, r = 6, sec = 1 },
      { id = 2, k = "fly", to = 1437, m = 1453, x = 0.66, y = 0.62, sec = 1 },
      { id = 3, k = "accept", q = 98190, name = "A Friend of the Family", m = 1437, x = 0.1, y = 0.57, r = 6, sec = 1 },
      { id = 4, k = "fly", to = 1453, m = 1437, x = 0.09, y = 0.59, sec = 1 },
      { id = 5, k = "turnin", q = 98190, name = "A Friend of the Family", m = 1453, x = 0.5, y = 0.5, r = 6, sec = 1 },
    } }
    ns.State.OnQuest = function(id) return id == 1274 or id == 98190 end
    ns.State.IsCompleted = function() return false end
    ns.State.Quest = function(id) if id == 1274 or id == 98190 then return { on = true, complete = true, objectives = {} } end return { on = false, objectives = {} } end
    ns.Engine.Refresh()
    assertEquals("done", ns.Engine.Status(2)) -- to the Wetlands for a pick-up you already have: nothing there
    assertEquals("todo", ns.Engine.Status(5))
  end)
  if not ok then error(err, 0) end
end)

-- Stormwind: The Missing Diplomat part 2 is in your log (hand in to Jorgen in Old Town), part 3 comes from him and is
-- handed in to Elling Trias in the Trade District - where you happen to stand
local function diplomatRoute()
  return { id = "dip", title = "dip", sections = { { title = "Stormwind" } }, steps = {
    { id = 1, k = "turnin", q = 1241, name = "The Missing Diplomat", npc = "Jorgen", m = 1453, x = 0.763, y = 0.851, r = 6, sec = 1 },
    { id = 2, k = "accept", q = 1242, name = "The Missing Diplomat", npc = "Jorgen", m = 1453, x = 0.763, y = 0.851, r = 6, sec = 1 },
    { id = 3, k = "turnin", q = 1242, name = "The Missing Diplomat", npc = "Elling Trias", m = 1453, x = 0.660, y = 0.741, r = 6, sec = 1 },
    { id = 4, k = "accept", q = 1243, name = "The Missing Diplomat", npc = "Elling Trias", m = 1453, x = 0.660, y = 0.741, r = 6, sec = 1 },
  } }
end
local function pinsOf(i, where) local out = {}; for _, p in ipairs(ns.Pins._used) do if p.index == i and p.where == where then out[#out + 1] = p end end; return out end
local function tipText(i, n) local t = {}; for _, l in ipairs(ns.Pins.Tip(i, n)) do t[#t + 1] = ns.Card.Plain(l[1]) end; return table.concat(t, " | ") end

test("pins: a stop that isn't open yet is grey on the world map, never on the minimap, and says what comes first", function()
  local svU = ForeverRouteUnlocks
  ForeverRouteUnlocks = { [1241] = { 1242 }, [1242] = { 1243 } }
  local ok, err = pcall(withWorld, diplomatRoute(), function(w)
    w.quests[1241] = { on = true, complete = true, objectives = {} }
    w:go(1453, 0.655, 0.735) -- in the Trade District, a few steps from Elling Trias
    ns.Pins.Update(true)
    assertEquals(1, w:shown())
    assertEquals(1, #pinsOf(1, "mini"), "Jorgen (the card's step, near) is not on the minimap")
    -- the hand-in to Elling Trias: the quest comes from Jorgen first
    local why, opener = ns.Engine.NotYet(3)
    assertEquals("pickup", why); assertEquals(2, opener)
    assertEquals(0, #pinsOf(3, "mini"), "a hand-in for a quest you don't have yet sits on the minimap beside you")
    local world = pinsOf(3, "world")
    assertEquals(1, #world, "the world map lost the later stop")
    assertTrue(world[1].notYet, "the later stop isn't marked as not open")
    assertTrue(world[1]:GetWidth() < pinsOf(1, "world")[1]:GetWidth(), "the later stop is as big as the card's step")
    local tip = tipText(3, world[1].n)
    assertTrue(tip:find("Later on your plan", 1, true) ~= nil, tip)
    assertTrue(tip:find("Not yet - first: Accept The Missing Diplomat from Jorgen", 1, true) ~= nil, tip)
    assertTrue(tip:find("Shift-click", 1, true) == nil, "jumping to a stop that isn't open is offered: " .. tip)
    -- the next part from Jorgen is the same stop as the hand-in to him: one pin there, not two
    assertEquals("handin", (ns.Engine.NotYet(2)))
    assertEquals(0, #pinsOf(2, "world"), "a second pin on Jorgen")
    assertEquals("1", world[1].num:GetText(), "numbers count the pins drawn")
    -- the card's own pin reads as before
    local now = tipText(1, 1)
    assertTrue(now:find("Turn in The Missing Diplomat", 1, true) ~= nil and now:find("Shift-click to jump here", 1, true) ~= nil and now:find("Not yet", 1, true) == nil, now)

    -- handed in to Jorgen: his pick-up is the card's step, Elling Trias still waits for it
    w:go(1453, 0.763, 0.851)
    w:quest(1241, { on = false, done = true, objectives = {} })
    assertEquals(2, w:shown())
    ns.Pins.Update()
    assertTrue(pinsOf(3, "world")[1].notYet, "still not open")
    -- part 3 in your log: the hand-in is the card's step now, a full pin, on the minimap when near
    w:quest(1242, { on = true, complete = true, objectives = {} })
    assertEquals(3, w:shown())
    w:go(1453, 0.700, 0.780)
    ns.Pins.Update()
    assertEquals(nil, (ns.Engine.NotYet(3)))
    assertEquals(1, #pinsOf(3, "mini"), "the open hand-in is not on the minimap")
    assertTrue(not pinsOf(3, "mini")[1].notYet)
  end)
  ForeverRouteUnlocks = svU
  if not ok then error(err, 0) end
end)

test("pins: a pin opens when its quest is picked up; a hand-in with objectives left names them; an open stop keeps colour, number and jump", function()
  local svU = ForeverRouteUnlocks
  ForeverRouteUnlocks = nil -- the test quests' ids are real quests with prerequisites in the built-in plan
  local ok, err = pcall(withWorld, worldRoute(), function(w)
    w:go(1431, 0.70, 0.48) -- a short walk from Lars
    ns.Pins.Update(true)
    -- 1 pick up from Lars (the card), 2 the wolves (not in your log yet), 3 hand in to Lars (not yet)
    assertEquals("pickup", (ns.Engine.NotYet(2)))
    assertTrue(pinsOf(2, "world")[1].notYet)
    w:quest(201, { on = true, objectives = { { text = "Wolf slain: 0/5", finished = false, have = 0, need = 5 } } })
    assertEquals(2, w:shown())
    ns.Pins.Update() -- no force: the pins must notice by themselves
    assertTrue(not pinsOf(2, "world")[1].notYet, "the card's step is dimmed")
    -- the hand-in at Lars, beside you: objectives left, so not on the minimap, and the tooltip names them
    local why, first = ns.Engine.NotYet(3)
    assertEquals("objectives", why); assertEquals(2, first)
    assertEquals(0, #pinsOf(3, "mini"), "a later step sits on the minimap")
    local tip = tipText(3, 2)
    assertTrue(tip:find("Not yet - first: Kill 5 Wolf", 1, true) ~= nil, tip)
    -- wolves done: the hand-in is the card's step
    w:quest(201, { on = true, complete = true, objectives = { { text = "Wolf slain: 5/5", finished = true, have = 5, need = 5 } } })
    assertEquals(3, w:shown())
    assertEquals(nil, (ns.Engine.NotYet(3)))
    -- the pick-up in Redridge is open (nothing before it): coloured, numbered, with the jump offered
    ns.Pins.Update()
    local p = pinsOf(5, "world")[1]
    assertTrue(p and not p.notYet, "an open pick-up is dimmed")
    assertEquals("1", p.num:GetText())
    local t5 = tipText(5, p.n)
    assertTrue(t5:find("Next on your plan (1)", 1, true) ~= nil and t5:find("Shift-click to jump here", 1, true) ~= nil, t5)
  end)
  ForeverRouteUnlocks = svU
  if not ok then error(err, 0) end
end)

test("pins: a step waiting on a level says the level; the minimap has the card's step only, as a badge with its icon", function()
  local route = { id = "lv", title = "lv", sections = { { title = "x" } }, steps = {
    { id = 1, k = "goto", text = "Walk over", m = 1431, x = 0.70, y = 0.50, r = 6, sec = 1 },
    { id = 2, k = "accept", q = 301, name = "Open", npc = "Ann", m = 1431, x = 0.72, y = 0.52, r = 6, sec = 1 },
    { id = 3, k = "accept", q = 302, name = "Too High", npc = "Bob", minLevel = 30, m = 1431, x = 0.74, y = 0.50, r = 6, sec = 1 },
  } }
  local svU = ForeverRouteUnlocks
  ForeverRouteUnlocks = nil
  local ok, err = pcall(withWorld, route, function(w)
    w:go(1431, 0.66, 0.50)
    ns.Pins.Update(true)
    local why, _, lvl = ns.Engine.NotYet(3)
    assertEquals("level", why); assertEquals(30, lvl)
    assertTrue(tipText(3, 3):find("Not yet - at level 30", 1, true) ~= nil, tipText(3, 3))
    assertEquals(0, #pinsOf(3, "mini"))
    -- the minimap: the card's step and nothing else, even an open next stop right beside you
    local n = 0; for _, p in ipairs(ns.Pins._used) do if p.where == "mini" then n = n + 1 end end
    assertEquals(1, n, "the minimap shows more than the card's step")
    local cur = pinsOf(1, "mini")[1]
    assertTrue(cur ~= nil, "the card's step (near) is not on the minimap")
    assertTrue(cur.icon:IsShown() and (cur.num:GetText() or "") == "", "the minimap badge shows the step's icon")
    assertTrue(cur:GetWidth() <= pinsOf(1, "world")[1]:GetWidth(), "the minimap pin grew")
    assertTrue(tipText(1, cur.n):find("Walk over", 1, true) ~= nil, "the minimap pin lost its tooltip")
    -- the world map: the open stop numbered and coloured, the one waiting on a level grey
    local open, waits = pinsOf(2, "world")[1], pinsOf(3, "world")[1]
    assertTrue(not open.notYet and open.num:GetText() == "1" and not open.icon:IsShown())
    assertTrue(waits.notYet and waits.num:GetText() == "2")
    w:ding(30)
    ns.Pins.Update()
    assertEquals(nil, (ns.Engine.NotYet(3)))
    assertTrue(not pinsOf(3, "world")[1].notYet, "level reached: the pick-up is open")
  end)
  ForeverRouteUnlocks = svU
  if not ok then error(err, 0) end
end)

test("ready nearby: a finished quest's hand-in close by gets a line on the card, and Do it now shows it", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local realConv = HBD.GetWorldCoordinatesFromZone
  local ok, err = pcall(withState, {}, function()
    -- Duskwood: the card on Madame Eva (1.3k yd off), The Hermit ready with Abercrombie 20 yd away
    local list = { { id = 1, k = "turnin", q = 148, name = "Supplies from Darkshire", npc = "Madame Eva", m = 1431, x = 0.76, y = 0.45, r = 6, sec = 1 } }
    for k = 2, 9 do list[k] = { id = k, k = "accept", q = 3000 + k, name = "Filler " .. k, m = 1431, x = 0.7, y = 0.5, r = 6, sec = 1 } end
    list[10] = { id = 10, k = "turnin", q = 165, name = "The Hermit", npc = "Abercrombie", m = 1431, x = 0.2811, y = 0.3146, r = 6, sec = 1 }
    ForeverRouteData = { id = "rn", title = "rn", sections = { { title = "x" } }, steps = list }
    ns.State.OnQuest = function(id) return id == 148 or id == 165 end
    ns.State.IsCompleted = function() return false end
    ns.State.Quest = function(id) if id == 148 or id == 165 then return { on = true, complete = true, objectives = {} } end return { on = false, objectives = {} } end
    HBD.GetWorldCoordinatesFromZone = function(_, mx, my, m) return mx * 2700, my * 1800, 0 end
    ns.Engine.focus = nil; ns.Engine.Refresh()
    assertEquals(1, ns.Engine.current)
    local x, y, inst = HBD:GetWorldCoordinatesFromZone(0.274, 0.312, 1431)
    local r = ns.Engine.ReadyNearby(x, y, inst)
    assertNotNil(r); assertEquals(10, r.i); assertTrue(r.d < 30, tostring(r.d))
    ns.Card.readyNear = r; ns.Card.Layout()
    assertTrue(ForeverRouteCard.ready:IsShown()); assertTrue(ForeverRouteCard.ready.text:GetText():find("The Hermit", 1, true) ~= nil, ForeverRouteCard.ready.text:GetText())
    ns.Engine.FocusOn(r.i)
    assertEquals(10, ns.Engine.current)
    assertNil(ns.Engine.ReadyNearby(x + 2000, y, inst)) -- far from it: no line
  end)
  HBD.GetWorldCoordinatesFromZone = realConv
  ns.Engine.focus = nil; ns.Card.readyNear = nil
  if not ok then error(err, 0) end
end)

-- ---------------------------------------------------------------------------------------------------------------
-- Minimap pins stay where they belong (docs/research/navigation-paths.md, "The pin that walked with you")
-- A world of 1000 x 1000 yd per map; the world map closed on another zone (it only follows you when it is opened).
local function withPinWorld(fn)
  local HBD, HBDP = LibStub("HereBeDragons-2.0"), LibStub("HereBeDragons-Pins-2.0")
  local sv = { p = HBD.GetPlayerWorldPosition, c = HBD.GetWorldCoordinatesFromZone, pins = ns.db.pins, pos = ns.State.Position, wm = WorldMapFrame.GetMapID }
  local W = { x = 0, y = 500 }
  HBD.GetPlayerWorldPosition = function() return W.x, W.y, 0 end
  HBD.GetWorldCoordinatesFromZone = function(_, x, y) return x * 1000, y * 1000, 0 end
  ns.State.Position = function() return 1453, W.x / 1000, W.y / 1000 end
  WorldMapFrame.GetMapID = function() return nil end
  ns.db.pins = true
  -- one pass of HereBeDragons' own minimap placement, as a frame would run it (a full sweep)
  function W.place() HBDP.updateFrame:GetScript("OnUpdate")(HBDP.updateFrame, 1.5) end
  -- every frame of ours that is on the minimap and visible must be one HereBeDragons is placing
  function W.strays()
    local n = 0
    for _, f in ipairs(ns.Pins.Frames()) do
      if f:IsShown() and f:GetParent() == Minimap and not HBDP.minimapPins[f] then n = n + 1 end
    end
    return n
  end
  local ok, err = pcall(withState, {}, function()
    ForeverRouteData = { id = "pw", title = "pw", sections = { { title = "x" } }, steps = {
      { id = 1, k = "goto", text = "Over there", m = 1453, x = 0.3, y = 0.5, r = 8, sec = 1 },
      { id = 2, k = "goto", text = "And on", m = 1453, x = 0.4, y = 0.5, r = 8, sec = 1 },
      { id = 3, k = "goto", text = "Further", m = 1453, x = 0.45, y = 0.55, r = 8, sec = 1 },
    } }
    ns.Engine.view = nil; ns.Engine.current = 1
    fn(W, HBDP)
  end)
  HBD.GetPlayerWorldPosition, HBD.GetWorldCoordinatesFromZone, ns.db.pins, ns.State.Position, WorldMapFrame.GetMapID = sv.p, sv.c, sv.pins, sv.pos, sv.wm
  ns.Engine.Refresh(); ns.Pins.Update(true)
  if not ok then error(err, 0) end
end

test("minimap pins: no pin is left behind on the minimap when the pins are rebuilt (it walked with you)", function()
  withPinWorld(function(W)
    ns.Pins.Update(true); W.place()
    assertEquals(0, W.strays(), "after the first build")
    -- walk up to the step: its minimap pin appears, then goes when you stand on it; walk off and it is back. Each
    -- change rebuilds the pins from the pool - a frame that was on the minimap must not come back as a world-map
    -- pin still sitting there
    for _, x in ipairs({ 200, 280, 298, 300, 290, 250, 100, 250, 299, 320, 600, 300 }) do
      W.x = x; ns.Pins.Update(); W.place()
      assertEquals(0, W.strays(), "a pin HereBeDragons is not placing is showing on the minimap (you at " .. x .. ")")
    end
    ns.Engine.current = 2; ns.Pins.Update(); W.place()
    assertEquals(0, W.strays(), "after the step changed")
  end)
end)

test("minimap pins: the pin sits at the step, not at a fixed offset from you", function()
  withPinWorld(function(W)
    local function badge() for _, p in ipairs(ns.Pins._used) do if p.where == "mini" then return p end end end
    local function offset(p) local _, rel, _, x, y = p:GetPoint(1); return rel, x, y end
    W.x, W.y = 200, 500 -- the step is 100 yd to the east (HereBeDragons' x grows to the west)
    ns.Pins.Update(true); W.place()
    local p = badge()
    assertTrue(p ~= nil and p:IsShown(), "no minimap pin for a step 100 yd away")
    local radius, half = C_Minimap.GetViewRadius(), Minimap:GetWidth() / 2
    local rel, x, y = offset(p)
    assertTrue(rel == Minimap, "the pin is not anchored to the minimap")
    assertTrue(math.abs(x - (-100 / radius * half)) < 0.5 and math.abs(y) < 0.5, "100 yd away: at " .. tostring(x) .. ", " .. tostring(y))
    -- walk 50 yd toward it and 30 yd south: the pin moves by exactly that much on the minimap (now up a little)
    W.x, W.y = 250, 470
    W.place()
    rel, x, y = offset(badge())
    assertTrue(math.abs(x - (-50 / radius * half)) < 0.5, "after 50 yd the pin is at x " .. tostring(x))
    assertTrue(math.abs(y - (30 / radius * half)) < 0.5, "after 30 yd south the pin is at y " .. tostring(y))
    -- and it does not depend on which map the game says you are on (a keep's own map, a district)
    local HBD = LibStub("HereBeDragons-2.0")
    local zone = HBD.GetPlayerZone
    HBD.GetPlayerZone = function() return 99999, 0 end
    W.x = 260; W.place()
    HBD.GetPlayerZone = zone
    rel, x = offset(badge())
    assertTrue(badge():IsShown() and math.abs(x - (-40 / radius * half)) < 0.5, "on another map id the pin stopped following the step")
  end)
end)

-- ---------------------------------------------------------------------------------------------------------------
-- Navigation: the line from where you stand (Nav.lua, docs/research/navigation-paths.md)
-- map % -> world yards on a map that has a walk map, by the walk map's own bounds
local function navWorld(m, x, y) local D = ns.Nav.Data(m); return D.left + x / 100 * (D.right - D.left), D.top + y / 100 * (D.bottom - D.top) end
-- every yard of a line must lie on ground the grid knows (its square, or one beside it: a line between the middles
-- of two squares may graze a corner)
local function offGround(m, P)
  local N = ns.Nav.Grid(m)
  local bad, total = 0, 0
  local function ground(x, y)
    local sq = ns.Nav._squareAt(N, x, y); if not sq then return false end
    return ns.Nav.Ground(N, sq)
  end
  for k = 1, #P.pts - 1 do
    local a, b = P.pts[k], P.pts[k + 1]
    local len = math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
    for t = 0, math.floor(len) do
      local x, y = a[1] + (b[1] - a[1]) * t / math.max(len, 1), a[2] + (b[2] - a[2]) * t / math.max(len, 1)
      total = total + 1
      if not ground(x, y) then
        local near = false
        for dx = -1, 1 do for dy = -1, 1 do if ground(x + dx * N.cell, y + dy * N.cell) then near = true end end end
        if not near then bad = bad + 1 end
      end
    end
  end
  return bad, total
end

test("nav: the walk maps unpack to the size they say, and a square's byte only points at squares with ground", function()
  for _, m in ipairs({ 1453, 1429 }) do
    local N = ns.Nav.Grid(m)
    assertEquals(N.W * N.H, #N.base, "map " .. m)
    assertEquals(N.W * N.H, #N.swim, "map " .. m .. " water")
    local DR, DC = { -1, -1, -1, 0, 0, 1, 1, 1 }, { -1, 0, 1, -1, 1, -1, 0, 1 }
    local bad = 0
    for sq = 0, N.NC - 1, 7 do
      local v = N.base:byte(sq + 1)
      for d = 1, 8 do
        if v % 2 == 1 then
          local r, c = math.floor(sq / N.W) + DR[d], sq % N.W + DC[d]
          if r < 0 or c < 0 or r >= N.H or c >= N.W or not ns.Nav.Ground(N, r * N.W + c) then bad = bad + 1 end
        end
        v = math.floor(v / 2)
      end
    end
    assertEquals(0, bad, "map " .. m .. ": steps from squares without ground")
  end
end)

test("nav: Stormwind, Trade District to Bolvar in the Keep - along the streets, not over the walls", function()
  local sx, sy = navWorld(1453, 66.1, 70.8)
  local tx, ty = navWorld(1453, 80.0, 38.0)
  local P, S = ns.Nav.Find(1453, sx, sy, nil, tx, ty, nil)
  assertTrue(P ~= nil, "no way found")
  local straight = math.sqrt((sx - tx) ^ 2 + (sy - ty) ^ 2)
  -- the walk map's own shortest way is 525 yd (450 as the crow flies): the line must go round like it does
  assertTrue(P.len > straight * 1.1, "the line is " .. math.floor(P.len) .. " yd, the straight line " .. math.floor(straight) .. ": it cut through")
  assertTrue(P.len < 525 * 1.15, "the line is " .. math.floor(P.len) .. " yd, the walk map's own way 525")
  local bad, total = offGround(1453, P)
  assertEquals(0, bad, "yards of the line off the ground (of " .. total .. ")")
  -- it starts where you stand and ends at the target
  assertTrue(math.abs(P.pts[1][1] - sx) < 0.01 and math.abs(P.pts[#P.pts][1] - tx) < 0.01)
  -- the straight line from the Trade District to the Keep crosses ground the grid does not have (walls, roofs)
  local direct = { pts = { { sx, sy }, { tx, ty } } }
  assertTrue(offGround(1453, direct) > 20, "the straight line was expected to cross walls here")
  assertTrue(S.expansions < 20000, "the search looked at " .. S.expansions .. " squares")
end)

test("nav: Elwynn, Goldshire to the Eastvale logging camp - on the ground all the way, close to the walk map's distance", function()
  local sx, sy = navWorld(1429, 42, 65)
  local tx, ty = navWorld(1429, 80, 60)
  local P, S = ns.Nav.Find(1429, sx, sy, nil, tx, ty, nil)
  assertTrue(P ~= nil, "no way found")
  -- the walk map's own shortest way is 1363 yd
  assertTrue(P.len > 1324 and P.len < 1363 * 1.12, "the line is " .. math.floor(P.len) .. " yd, the walk map's own way 1363")
  assertEquals(0, (offGround(1429, P)), "yards of the line off the ground")
  assertTrue(#P.pts < 60, "the line has " .. #P.pts .. " points: not straightened")
  assertTrue(S.expansions < 20000, "the search looked at " .. S.expansions .. " squares")
end)

-- the live line in a small world: Stormwind, a walk to Bolvar in the Keep, then one back to the Trade District
local function navRoute()
  return { id = "nav", title = "nav", sections = { { title = "Stormwind" } }, steps = {
    { id = 1, k = "goto", text = "To the Keep", m = 1453, x = 0.800, y = 0.380, r = 8, sec = 1 },
    { id = 2, k = "goto", text = "Back to the Trade District", m = 1453, x = 0.661, y = 0.708, r = 8, sec = 1 },
  } }
end
local function lineWorld(fn)
  local HBDP = LibStub("HereBeDragons-Pins-2.0")
  local sv = { path = ns.db.pathLine }
  ns.db.pathLine = true
  local ok, err = pcall(withWorld, navRoute(), function(w)
    -- where the dots of the live line are in the world, by yards still to walk
    function w:dots(where)
      local out, reg = {}, where == "mini" and HBDP.minimapPins or HBDP.worldmapPins
      for _, d in ipairs(ns.Pins.LineDots(where)) do local t = reg[d.frame]; out[#out + 1] = { rem = d.rem, x = t and t.x, y = t and t.y } end
      return out
    end
    function w:walk(m, x, y) self:go(m, x, y); ns.Nav.Settle() end
    ns.Nav.Want(nil); ns.Arrow.SetTarget(w:shown(), true) -- a fresh target (an earlier test may have left the same one)
    fn(w)
  end, { at = { m = 1453, x = 0.661, y = 0.708 } })
  ns.db.pathLine = sv.path
  ns.Nav.Want(nil)
  if not ok then error(err, 0) end
end
local function yards(m, x, y) return navWorld(m, x * 100, y * 100) end

test("nav line: drawn from where you stand, on the minimap too, and only the part behind you goes as you walk", function()
  lineWorld(function(w)
    ns.Nav.Settle()
    local key = ns.Arrow.Current().key
    local P = ns.Nav.PathFor(key)
    assertTrue(P ~= nil, "no live line for the step")
    local px, py = yards(1453, 0.661, 0.708)
    assertTrue(math.abs(P.pts[1][1] - px) < 1 and math.abs(P.pts[1][2] - py) < 1, "the line does not start where you stand")
    assertEquals(0, (offGround(1453, P)), "yards of the line off the ground")
    assertTrue(ns.Pins.Line() ~= nil and ns.Pins.Line().P == P, "the pins are not drawing the live line")
    local world, mini = w:dots("world"), w:dots("mini")
    assertTrue(#world >= 20 and #world <= 200, #world .. " dots on the world map")
    assertTrue(#mini >= 20, #mini .. " dots on the minimap")
    for _, d in ipairs(mini) do
      assertTrue(d.x ~= nil, "a minimap dot HereBeDragons does not know")
      assertTrue(d.rem <= P.len - ns.Pins.MINI_GAP + 0.01 and d.rem >= P.len - ns.Pins.MINI_AHEAD - 0.01, "a minimap dot " .. (P.len - d.rem) .. " yd ahead")
    end
    -- every dot is on the ground
    local N = ns.Nav.Grid(1453)
    for _, d in ipairs(world) do
      local sq = ns.Nav._squareAt(N, d.x, d.y)
      local ok = sq and ns.Nav.Ground(N, sq)
      for dx = -1, 1 do for dy = -1, 1 do local q = ns.Nav._squareAt(N, d.x + dx * N.cell, d.y + dy * N.cell); if q and ns.Nav.Ground(N, q) then ok = true end end end
      assertTrue(ok, "a dot of the line is off the ground")
    end
    -- walk 80 yd along the line
    local before = {}
    for _, d in ipairs(world) do before[d.rem] = d end
    local i, walked = 1, 0
    while walked + (P.rem[i] - P.rem[i + 1]) < 80 do walked = walked + (P.rem[i] - P.rem[i + 1]); i = i + 1 end
    local a, b = P.pts[i], P.pts[i + 1]
    local t = (80 - walked) / (P.rem[i] - P.rem[i + 1])
    local D = ns.Nav.Data(1453)
    local nx, ny = a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t
    w:walk(1453, (nx - D.left) / (D.right - D.left), (ny - D.top) / (D.bottom - D.top))
    assertTrue(ns.Nav.PathFor(key) == P, "walking along the line made a new one")
    assertTrue(math.abs(P.left - (P.len - 80)) < 3, "80 yd along, " .. P.left .. " yd left of " .. P.len)
    local after = w:dots("world")
    assertTrue(#after < #world and #after >= #world - 80 / ns.Pins.Line().step - 2, "world dots: " .. #world .. " before, " .. #after .. " after 80 yd")
    for _, d in ipairs(after) do
      assertTrue(d.rem < P.left, "a dot behind you is still drawn")
      local was = before[d.rem]
      assertTrue(was and math.abs(was.x - d.x) < 0.01 and math.abs(was.y - d.y) < 0.01, "a dot ahead of you moved")
    end
    for _, d in ipairs(w:dots("mini")) do assertTrue(d.rem <= P.left - ns.Pins.MINI_GAP + 0.01, "a minimap dot under or behind you") end
    assertEquals(0, ns.Pins.Sweep(), "stray frames on the minimap")
  end)
end)

test("nav line: the arrow re-aiming ('not there yet') does not lay a second set of dots that walking never takes away", function()
  lineWorld(function(w)
    ns.Nav.Settle()
    local P = ns.Nav.PathFor(ns.Arrow.Current().key)
    assertTrue(P ~= nil, "no live line")
    local HBDP = LibStub("HereBeDragons-Pins-2.0")
    -- every world-map icon that is not a step pin is a dot of the line (HereBeDragons keeps no owner per icon)
    local function onMap() local pin = {}; for _, p in ipairs(ns.Pins._used) do pin[p] = true end; local n = 0; for fr in pairs(HBDP.worldmapPins) do if not pin[fr] then n = n + 1 end end; return n end
    assertEquals(#w:dots("world"), onMap(), "dots on the world map before")
    -- the arrow takes a fresh aim at the same step: its first check says 'not arrived'
    ns.Fire("FR_ARRIVED", w:shown(), false); ns.Fire("FR_ARRIVED", w:shown(), false)
    assertEquals(#w:dots("world"), onMap(), "dots on the world map after the arrow re-aimed")
    -- walk 80 yd along the line: none behind you is left
    local i, walked = 1, 0
    while walked + (P.rem[i] - P.rem[i + 1]) < 80 do walked = walked + (P.rem[i] - P.rem[i + 1]); i = i + 1 end
    local a, b = P.pts[i], P.pts[i + 1]
    local t = (80 - walked) / (P.rem[i] - P.rem[i + 1])
    local D = ns.Nav.Data(1453)
    local nx, ny = a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t
    w:walk(1453, (nx - D.left) / (D.right - D.left), (ny - D.top) / (D.bottom - D.top))
    assertEquals(#w:dots("world"), onMap(), "dots on the world map after walking (some behind you stayed)")
    -- arriving and walking back out still brings the line back
    ns.Fire("FR_ARRIVED", w:shown(), true)
    assertEquals(0, onMap(), "dots while standing at the step")
    ns.Fire("FR_ARRIVED", w:shown(), false)
    assertTrue(onMap() > 0 and onMap() == #w:dots("world"), "the line did not come back after walking out")
  end)
end)

test("nav line: stray from it and a new one runs from where you are; the next step gets its own", function()
  lineWorld(function(w)
    ns.Nav.Settle()
    local key = ns.Arrow.Current().key
    local P = ns.Nav.PathFor(key)
    assertTrue(P ~= nil, "no live line")
    -- off to the west, well away from the line
    w:walk(1453, 0.60, 0.66)
    local P2 = ns.Nav.PathFor(key)
    assertTrue(P2 ~= nil and P2 ~= P, "no new line after straying")
    local px, py = yards(1453, 0.60, 0.66)
    assertTrue(math.abs(P2.pts[1][1] - px) < 1 and math.abs(P2.pts[1][2] - py) < 1, "the new line does not start where you are")
    assertEquals(0, (offGround(1453, P2)), "yards of the new line off the ground")
    assertTrue(ns.Pins.Line().P == P2, "the pins still draw the old line")
    -- a small step aside (10 yd) is not straying
    local D = ns.Nav.Data(1453)
    w:walk(1453, 0.60 + 10 / (D.left - D.right), 0.66)
    assertTrue(ns.Nav.PathFor(key) == P2, "10 yd aside made a new line")
    -- the step changes: the line is for the new target
    w:walk(1453, 0.800, 0.380)
    ns.Engine.Jump(2) -- at Bolvar: on to the next step
    assertEquals(2, w:shown())
    ns.Nav.Settle()
    local key2 = ns.Arrow.Current().key
    assertTrue(key2 ~= key, "the target of the arrow did not change")
    local P3 = ns.Nav.PathFor(key2)
    assertTrue(P3 ~= nil and ns.Nav.PathFor(key) == nil, "no line for the new step")
    local tx, ty = yards(1453, 0.661, 0.708)
    assertTrue(math.abs(P3.pts[#P3.pts][1] - tx) < 1 and math.abs(P3.pts[#P3.pts][2] - ty) < 1, "the new line does not end at the new step")
    assertTrue(ns.Pins.Line().P == P3)
    assertEquals(0, ns.Pins.Sweep(), "stray frames on the minimap")
  end)
end)

test("nav cost: a search is cut into slices, looks at a bounded number of squares, and knows the ground along its line", function()
  local sx, sy = navWorld(1453, 28, 50)      -- the harbour
  local tx, ty = navWorld(1453, 80.0, 38.0)  -- the Keep: the longest walk in town
  local N = ns.Nav.Grid(1453)
  local S = ns.Nav.Search(N, sx, sy, nil, tx, ty, nil)
  local slices = 0
  while not ns.Nav.Run(S, 0.5) do slices = slices + 1; assertTrue(slices < 100000, "the search never ends") end
  assertTrue(slices >= 2, "a long search ran in one slice (" .. slices .. ")")
  assertTrue(S.found ~= nil, "no way from the harbour to the Keep")
  assertTrue(S.expansions < 40000, "the search looked at " .. S.expansions .. " squares")
  local P = ns.Nav.Path(S)
  assertEquals(0, (offGround(1453, P)), "yards of the line off the ground")
  -- straying is read off the same search: it knows the ground along its own line
  local a, b = P.pts[3], P.pts[4]
  local known = false
  for _, n in ipairs(ns.Nav._nodesNear(N, (a[1] + b[1]) / 2, (a[2] + b[2]) / 2)) do if S.closed[n] then known = true end end
  assertTrue(known, "the search does not know the ground along its own line")
  -- memory: only Nav.KEEP zones stay unpacked
  ns.Nav.Grid(1429); ns.Nav.Grid(1437)
  local n = 0
  for _ in pairs(ns.Nav._grids()) do n = n + 1 end
  assertEquals(ns.Nav.KEEP, n, "unpacked zones kept")
end)

test("nav across a zone border: from Goldshire to the Trade District on the walk map of Elwynn, through the gate", function()
  local sx, sy = navWorld(1429, 42, 65)
  local tx, ty = navWorld(1453, 66.1, 70.8)
  assertEquals(1429, ns.Nav.MapFor(sx, sy, tx, ty, 0, 1429, 1453), "the map you are on holds both ends")
  local P = ns.Nav.Find(1429, sx, sy, nil, tx, ty, nil)
  assertTrue(P ~= nil, "no way from Goldshire into Stormwind")
  local straight = math.sqrt((sx - tx) ^ 2 + (sy - ty) ^ 2)
  assertTrue(P.len >= straight and P.len < straight * 1.6, "the line is " .. math.floor(P.len) .. " yd, the straight line " .. math.floor(straight))
  assertEquals(0, (offGround(1429, P)), "yards of the line off the ground")
  -- a target in a zone with no walk map: no live line (the planned path is used)
  assertEquals(nil, ns.Nav.MapFor(sx, sy, -10500, -1200, 0, 1429, 1431))
  assertEquals(nil, ns.Nav.MapFor(sx, sy, tx, ty, 1, 1429, 1453), "another continent")
end)

-- Roads and mobs (tools/roads.js, tools/navgrid.js "terr"; docs/research/navigation-paths.md, "Roads and mobs")
do
-- (the simulator's assertTrue drops its message; these tests are about numbers, so a failure says them)
local function assertTrue(ok, msg) if not ok then error(msg or "expected truthy", 0) end end
-- what a line is made of, a yard at a time: yards in all, on road squares, beside a hostile spawn that matters at
-- this level, right on top of one
local function lineGround(m, P, level)
  local N = ns.Nav.Grid(m)
  local total, road, near, close = 0, 0, 0, 0
  for k = 1, #P.pts - 1 do
    local a, b = P.pts[k], P.pts[k + 1]
    local len = math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
    for t = 0, math.floor(len) do
      local sq = ns.Nav._squareAt(N, a[1] + (b[1] - a[1]) * t / math.max(len, 1), a[2] + (b[2] - a[2]) * t / math.max(len, 1))
      if sq then
        total = total + 1
        if ns.Nav.Road(N, sq) then road = road + 1 end
        local mob = ns.Nav.Mob(N, sq, level)
        if mob == 2 then close = close + 1 elseif mob then near = near + 1 end
      end
    end
  end
  return total, road, near, close
end
-- the line the search gave before it knew roads and mobs (every yard of ground the same)
local function plainLine(m, sx, sy, tx, ty, level)
  local sv = { ns.Nav.ROAD, ns.Nav.MOB_NEAR, ns.Nav.MOB_CLOSE, ns.Nav.MOB_ROAD, ns.Nav.WEIGHT_RATED, ns.Nav.SLACK_ROAD, ns.Nav.SLACK_OPEN }
  ns.Nav.ROAD, ns.Nav.MOB_NEAR, ns.Nav.MOB_CLOSE, ns.Nav.MOB_ROAD, ns.Nav.WEIGHT_RATED, ns.Nav.SLACK_ROAD, ns.Nav.SLACK_OPEN = 1, 1, 1, 1, ns.Nav.WEIGHT, ns.Nav.SLACK, ns.Nav.SLACK
  local ok, P, S = pcall(ns.Nav.Find, m, sx, sy, nil, tx, ty, nil, level)
  ns.Nav.ROAD, ns.Nav.MOB_NEAR, ns.Nav.MOB_CLOSE, ns.Nav.MOB_ROAD, ns.Nav.WEIGHT_RATED, ns.Nav.SLACK_ROAD, ns.Nav.SLACK_OPEN = unpack(sv)
  if not ok then error(P, 0) end
  return P, S
end

test("nav ground: the outdoor walk maps know their roads and the hostile spawns; a city's has neither", function()
  for _, m in ipairs({ 1429, 1437 }) do
    local N = ns.Nav.Grid(m)
    assertTrue(N.rated, "map " .. m .. " has no ground data")
    assertEquals(N.W * N.H, #N.terr, "map " .. m .. " ground")
    local roads, mobs, wet, bad = 0, 0, 0, 0
    for sq = 0, N.NC - 1 do
      local b = string.byte(N.terr, sq + 1)
      if b >= 128 then wet = wet + 1 end
      if ns.Nav.Road(N, sq) then roads = roads + 1; if not ns.Nav.Ground(N, sq) or b >= 128 then bad = bad + 1 end end
      if b % 32 > 0 then mobs = mobs + 1; if not ns.Nav.Ground(N, sq) then bad = bad + 1 end end
      if (b >= 128) ~= (string.byte(N.swim, sq + 1) == 1) then bad = bad + 1 end
    end
    -- a road is a thin thread through a zone: some hundreds of 8-yd squares, a percent or two of the ground
    assertTrue(roads > 700 and roads < N.NC * 0.04, "map " .. m .. ": " .. roads .. " road squares")
    assertTrue(mobs > 5000 and mobs < N.NC * 0.5, "map " .. m .. ": " .. mobs .. " squares by a hostile spawn")
    assertEquals(0, bad, "map " .. m .. ": road or mob squares without ground, in water, or water that disagrees with the swim bits")
  end
  local N = ns.Nav.Grid(1429)
  -- the road east out of Goldshire, and the Defias camp at the Jerod's Landing road (bandits, level 8-9)
  local rx, ry = navWorld(1429, 49.6, 70.9)
  local onRoad = false
  for dx = -1, 1 do for dy = -1, 1 do local sq = ns.Nav._squareAt(N, rx + dx * N.cell, ry + dy * N.cell); if sq and ns.Nav.Road(N, sq) then onRoad = true end end end
  assertTrue(onRoad, "the road east of Goldshire is not a road on the walk map")
  local bx, by = navWorld(1429, 31.02, 57.51)
  local camp = ns.Nav._squareAt(N, bx, by)
  assertEquals(2, ns.Nav.Mob(N, camp, 8), "a Defias Bandit's spawn at level 8")
  assertEquals(nil, ns.Nav.Mob(N, camp, 20), "the same at level 20: grey, it hardly notices you")
  local gx, gy = navWorld(1429, 42.1, 65.9)
  assertEquals(nil, ns.Nav.Mob(N, ns.Nav._squareAt(N, gx, gy), 5), "Goldshire's square by Marshal Dughan")
  local city = ns.Nav.Grid(1453)
  assertTrue(not city.rated, "Stormwind's walk map is rated")
  assertEquals(city.W * city.H, #city.terr, "Stormwind ground (water only)")
end)

test("nav ground: what a yard costs - road cheaper, by a mob dearer, on a road only a mob right there counts, by level", function()
  local N = ns.Nav.Grid(1429)
  local F = ns.Nav.Factors(N, 8)
  assertEquals(1, F[0]); assertEquals(ns.Nav.ROAD, F[64]); assertEquals(ns.Nav.SWIM, F[128])
  -- code 5 = spawns of level 9-10
  assertEquals(ns.Nav.MOB_NEAR, F[5]); assertEquals(ns.Nav.MOB_CLOSE, F[32 + 5])
  assertEquals(ns.Nav.ROAD, F[64 + 5], "a spawn 20 yd off the road")
  assertEquals(ns.Nav.ROAD * ns.Nav.MOB_ROAD, F[64 + 32 + 5], "a spawn on the road")
  assertEquals(ns.Nav.SWIM * ns.Nav.MOB_NEAR, F[128 + 5])
  assertTrue(F[64] < 1 and F[5] > 1 and F[32 + 5] > F[5] and F[64 + 32 + 5] < F[32 + 5])
  -- level 10 mobs: they matter up to level 14 (MOB_GAP 5), not at 15
  assertEquals(ns.Nav.MOB_NEAR, ns.Nav.Factors(N, 14)[5]); assertEquals(1, ns.Nav.Factors(N, 15)[5]); assertEquals(ns.Nav.ROAD, ns.Nav.Factors(N, 60)[64 + 32 + 5])
  -- a city: every yard of ground the same, as before
  local C = ns.Nav.Factors(ns.Nav.Grid(1453), 8)
  assertEquals(1, C[0]); assertEquals(ns.Nav.SWIM, C[128])
end)

test("nav roads: Goldshire to Eastvale and to Westbrook Garrison keep to the road and off the mobs, not much further", function()
  for _, T in ipairs({ { "Eastvale", 79.5, 68.8, 0.4 }, { "Westbrook Garrison", 24.2, 74.5, 0.1 } }) do
    local name, x, y, share = unpack(T)
    local sx, sy = navWorld(1429, 42.1, 65.9)
    local tx, ty = navWorld(1429, x, y)
    local P, S = ns.Nav.Find(1429, sx, sy, nil, tx, ty, nil, 8)
    local Q = plainLine(1429, sx, sy, tx, ty, 8)
    assertTrue(P ~= nil and Q ~= nil, "no way to " .. name)
    local total, road, near, close = lineGround(1429, P, 8)
    local qTotal, qRoad, qNear, qClose = lineGround(1429, Q, 8)
    assertTrue(road / total >= share, name .. ": " .. road .. " of " .. total .. " yd on the road")
    assertTrue(qRoad / qTotal < 0.1, name .. ": the plain line had " .. qRoad .. " of " .. qTotal .. " yd on the road - the test proves nothing")
    assertTrue(close <= 10 and qClose >= 100, name .. ": " .. close .. " yd on top of a hostile spawn (the plain line: " .. qClose .. ")")
    assertTrue(near + close < (qNear + qClose) / 2, name .. ": " .. (near + close) .. " yd by a mob, the plain line " .. (qNear + qClose))
    assertTrue(P.len <= Q.len * 1.12, name .. ": " .. math.floor(P.len) .. " yd, the plain line " .. math.floor(Q.len))
    assertEquals(0, (offGround(1429, P)), name .. ": yards of the line off the ground")
    assertTrue(#P.pts < 60, name .. ": " .. #P.pts .. " points")
    assertTrue(S.expansions < 5000, name .. ": the search looked at " .. S.expansions .. " squares")
  end
end)

test("nav roads: out of Menethil the line takes the road; at 60 the marsh's mobs no longer bend it, the road still pulls", function()
  local sx, sy = navWorld(1437, 10.9, 59.6)
  local tx, ty = navWorld(1437, 56.3, 40.4) -- the Green Belt
  local P, S = ns.Nav.Find(1437, sx, sy, nil, tx, ty, nil, 24)
  local Q = plainLine(1437, sx, sy, tx, ty, 24)
  local total, road, near, close = lineGround(1437, P, 24)
  local qTotal, qRoad, qNear, qClose = lineGround(1437, Q, 24)
  assertTrue(road / total >= 0.25 and qRoad / qTotal < 0.1, road .. " of " .. total .. " yd on the road (the plain line: " .. qRoad .. " of " .. qTotal .. ")")
  assertTrue(close <= 40 and close < qClose / 4, close .. " yd on top of a hostile spawn (the plain line: " .. qClose .. ")")
  assertTrue(P.len <= Q.len * 1.12, math.floor(P.len) .. " yd, the plain line " .. math.floor(Q.len))
  assertEquals(0, (offGround(1437, P)), "yards of the line off the ground")
  -- the cost in game: the search may look at more squares than before, within reason (2 ms a frame)
  assertTrue(S.expansions < 14000, "the search looked at " .. S.expansions .. " squares")
  local slices, S2 = 1, ns.Nav.Search(ns.Nav.Grid(1437), sx, sy, nil, tx, ty, nil, 24)
  while not ns.Nav.Run(S2, 0.5) do slices = slices + 1; assertTrue(slices < 100000, "the search never ends") end
  assertTrue(slices > 3, "the search was not cut into slices")
  -- level 60: nothing in the Wetlands comes for you
  local H = ns.Nav.Find(1437, sx, sy, nil, tx, ty, nil, 60)
  local hTotal, hRoad = lineGround(1437, H, 24)
  assertTrue(hRoad / hTotal >= 0.15, "at 60: " .. hRoad .. " of " .. hTotal .. " yd on the road")
  assertTrue(H.len <= P.len + 1, "at 60 the line is " .. math.floor(H.len) .. " yd, at 24 " .. math.floor(P.len))
end)

-- The arrow's look-ahead (Nav.Aim; docs/research/navigation-paths.md, "The arrow")
local function turnOf(a) return (a + math.pi) % (2 * math.pi) - math.pi end
-- follow the arrow along a line the way a player does: every 0.05 s it gives a direction, you turn toward it (240
-- degrees a second at most) and move. aimAt(P, px, py) -> the spot the arrow points at.
-- -> the biggest change of the arrow's direction within a quarter second (degrees), all its turning (degrees), the
--    furthest you got from the line (yards), whether you arrived
local function followArrow(P, speed, aimAt)
  local px, py = P.pts[1][1], P.pts[1][2]
  local tx, ty = P.pts[#P.pts][1], P.pts[#P.pts][2]
  local dt, facing, hist, worst, total, maxOff = 0.05, nil, {}, 0, 0, 0
  P.cursor = 1
  for _ = 1, 40000 do
    if math.sqrt((px - tx) ^ 2 + (py - ty) ^ 2) < 6 then return math.deg(worst), math.deg(total), maxOff, true end
    local aim, _, off = aimAt(P, px, py)
    if off and off > maxOff then maxOff = off end
    local a = math.atan2(aim[2] - py, aim[1] - px)
    local n = #hist + 1
    hist[n] = a
    if n > 1 then total = total + math.abs(turnOf(a - hist[n - 1])) end
    if n > 5 then local d = math.abs(turnOf(a - hist[n - 5])); if d > worst then worst = d end end
    facing = facing or a
    local turn, lim = turnOf(a - facing), math.rad(240) * dt
    if turn > lim then turn = lim elseif turn < -lim then turn = -lim end
    facing = facing + turn
    px, py = px + math.cos(facing) * speed * dt, py + math.sin(facing) * speed * dt
  end
  return math.deg(worst), math.deg(total), maxOff, false
end
-- the arrow as it was: at the far end of the stretch you are nearest to; within 7 yd of it, the one after
local function cornerAim(P, px, py)
  local pts = P.pts
  local best, bd = P.cursor, math.huge
  for j = P.cursor, #pts - 1 do
    local a, b = pts[j], pts[j + 1]
    local dx, dy = b[1] - a[1], b[2] - a[2]; local L2 = dx * dx + dy * dy
    local t = L2 > 0 and math.max(0, math.min(1, ((px - a[1]) * dx + (py - a[2]) * dy) / L2)) or 0
    local d = math.sqrt((px - a[1] - t * dx) ^ 2 + (py - a[2] - t * dy) ^ 2)
    if d < bd - 0.01 then best, bd = j, d end
  end
  P.cursor = best
  local ai = best + 1
  if ai < #pts and math.sqrt((pts[ai][1] - px) ^ 2 + (pts[ai][2] - py) ^ 2) < 7 then ai = ai + 1 end
  return pts[ai], nil, bd
end

test("arrow look-ahead: further on a mount than on foot, short in a city and on the planner's path, least indoors", function()
  local look = ns.Arrow._lookFor
  local open, city, planned = { nav = true, cell = 8 }, { nav = true, cell = 4 }, {}
  local sv = ns.Arrow.Indoors
  ns.Arrow.Indoors = function() return false end
  local ok, err = pcall(function()
    assertTrue(look(open, 14) > look(open, 7), "a mount looks no further ahead than feet")
    assertTrue(look(open, 7) >= 16 and look(open, 30) <= 40, "open country: " .. look(open, 7) .. " on foot, " .. look(open, 30) .. " at a gallop")
    assertTrue(look(city, 7) >= 8 and look(city, 30) <= 10, "a city: " .. look(city, 7) .. " to " .. look(city, 30))
    assertTrue(look(planned, 7) >= 8 and look(planned, 30) <= 12, "the planner's path: " .. look(planned, 7) .. " to " .. look(planned, 30))
    assertTrue(look(open, 0) >= 10, "standing still")
    ns.Arrow.Indoors = function() return true end
    assertEquals(6, look(open, 14)); assertEquals(6, look(city, 7))
  end)
  ns.Arrow.Indoors = sv
  if not ok then error(err, 0) end
end)

test("arrow look-ahead: it turns into a corner over the yards before it - no swing at the corner, on real lines", function()
  local walks = {
    { "Stormwind, Trade District to the Keep", 1453, 66.1, 70.8, 80.0, 38.0, 20, 7 },
    { "Stormwind, the harbour to the Trade District", 1453, 28.0, 50.0, 66.1, 70.8, 20, 7 },
    { "Elwynn, Goldshire to Eastvale on foot", 1429, 42.1, 65.9, 79.5, 68.8, 8, 7 },
    { "Elwynn, Goldshire to Eastvale on a mount", 1429, 42.1, 65.9, 79.5, 68.8, 8, 14 },
    { "the Wetlands, Menethil to Dun Modr on a mount", 1437, 10.9, 59.6, 49.9, 18.3, 24, 14 },
  }
  for _, T in ipairs(walks) do
    local name, m, x1, y1, x2, y2, level, speed = unpack(T)
    local sx, sy = navWorld(m, x1, y1)
    local tx, ty = navWorld(m, x2, y2)
    local P = ns.Nav.Find(m, sx, sy, nil, tx, ty, nil, level)
    assertTrue(P ~= nil, name .. ": no way")
    local look = ns.Arrow._lookFor(P, speed)
    local worst, total, off, there = followArrow(P, speed, function(Q, px, py) return ns.Arrow._follow(Q, px, py, look) end)
    local oldWorst, oldTotal, _, oldThere = followArrow(P, speed, cornerAim)
    assertTrue(there and oldThere, name .. ": following the arrow never got there")
    -- the old arrow swung by the whole corner at once (35 to 130 degrees within a quarter second on these lines)
    assertTrue(oldWorst > 30, name .. ": the old arrow's worst swing was only " .. math.floor(oldWorst) .. " degrees - the test proves nothing")
    assertTrue(worst < oldWorst * 0.7 and worst <= (m == 1453 and 55 or 25), name .. ": the arrow swings " .. math.floor(worst) .. " degrees within a quarter second (the old one " .. math.floor(oldWorst) .. ")")
    -- ...and it does not pay for that with more turning in all, or by leading you off the line
    assertTrue(total <= oldTotal * 1.15 + 20, name .. ": the arrow turns " .. math.floor(total) .. " degrees in all, the old one " .. math.floor(oldTotal))
    assertTrue(off <= look * 0.6 + 2, name .. ": following the arrow strays " .. string.format("%.1f", off) .. " yd from the line (look-ahead " .. look .. ")")
  end
end)

test("arrow, open country: it aims as far as the line runs nearly straight, and still turns smoothly at a bend", function()
  -- a made-up line: 160 yd east with 2-yd wiggles every 10 yd, then a right-angle bend and 80 yd north
  local pts = {}
  for i = 0, 16 do pts[#pts + 1] = { i * 10, (i % 2 == 0) and 0 or 2 } end
  for i = 1, 8 do pts[#pts + 1] = { 160, i * 10 } end
  local rem = { [#pts] = 0 }
  for k = #pts - 1, 1, -1 do rem[k] = rem[k + 1] + math.sqrt((pts[k + 1][1] - pts[k][1]) ^ 2 + (pts[k + 1][2] - pts[k][2]) ^ 2) end
  local function line() return { pts = pts, rem = rem, cursor = 1, nav = true, cell = 8 } end
  local P = line()
  local aim = ns.Nav.Aim(P, 0, 0, 20, true)
  assertTrue(aim[1] >= 150 and aim[2] <= ns.Nav.STRAIGHT_TOL + 1, string.format("from the start it aims at %.0f,%.0f: not near the bend, or past it", aim[1], aim[2]))
  P = line()
  local near = ns.Nav.Aim(P, 0, 0, 20, false)
  assertTrue(near[1] <= 25, "without far it should stay at the look-ahead: " .. near[1])
  -- followed all the way: no swing at the bend, close to the line, less turning than the short look-ahead
  local worst, total, off, there = followArrow(line(), 7, function(Q, px, py) return ns.Nav.Aim(Q, px, py, 20, true) end)
  local nearWorst, nearTotal, nearOff = followArrow(line(), 7, function(Q, px, py) return ns.Nav.Aim(Q, px, py, 20, false) end)
  assertTrue(there, "following it never got there")
  -- at the right-angle bend: as smooth as the short look-ahead, about as close to the line; steadier in all
  assertTrue(worst <= nearWorst + 3, "it swings " .. math.floor(worst) .. " degrees within a quarter second, the short look-ahead " .. math.floor(nearWorst))
  assertTrue(off <= nearOff + 2, string.format("following it strays %.1f yd from the line, the short look-ahead %.1f", off, nearOff))
  assertTrue(total <= nearTotal * 0.85, "it turns " .. math.floor(total) .. " degrees in all, the short look-ahead " .. math.floor(nearTotal))
end)

test("arrow, open country: real lines - no swing, near the line", function()
  local walks = {
    { "Elwynn, Goldshire to Eastvale on foot", 1429, 42.1, 65.9, 79.5, 68.8, 8, 7 },
    { "the Wetlands, Menethil to Dun Modr on a mount", 1437, 10.9, 59.6, 49.9, 18.3, 24, 14 },
  }
  for _, T in ipairs(walks) do
    local name, m, x1, y1, x2, y2, level, speed = unpack(T)
    local sx, sy = navWorld(m, x1, y1)
    local tx, ty = navWorld(m, x2, y2)
    local P = ns.Nav.Find(m, sx, sy, nil, tx, ty, nil, level)
    local look = ns.Arrow._lookFor(P, speed)
    local worst, total, off, there = followArrow(P, speed, function(Q, px, py) return ns.Arrow._follow(Q, px, py, look, true) end)
    assertTrue(there, name .. ": never got there")
    assertTrue(worst <= 30, name .. ": swings " .. math.floor(worst) .. " degrees within a quarter second")
    assertTrue(off <= look * 0.6 + ns.Nav.STRAIGHT_TOL, string.format("%s: strays %.1f yd from the line", name, off))
  end
end)
end

test("flight paths you know come from the world map's flight points, no flight master needed", function()
  local sv = { api = C_TaxiMap, known = ns.State.knownTaxi, charKnown = ns.char.knownTaxi, fac = UnitFactionGroup }
  local F = Enum.FlightPathFaction
  local nodes = {
    [1429] = { { name = "Stormwind, Elwynn", faction = F.Alliance, isUndiscovered = false } },
    [1436] = { { name = "Sentinel Hill, Westfall", faction = F.Alliance, isUndiscovered = true } },
    [1413] = { { name = "Crossroads, The Barrens", faction = F.Horde, isUndiscovered = false },
               { name = "Ratchet, The Barrens", faction = F.Neutral, isUndiscovered = false } },
  }
  local ok, err = pcall(function()
    UnitFactionGroup = function() return "Alliance" end
    C_TaxiMap = { GetTaxiNodesForMap = function(m) return nodes[m] or {} end }
    ns.State.knownTaxi = {}
    assertEquals(2, ns.State.ScanTaxi())
    assertTrue(ns.State.knownTaxi["Stormwind, Elwynn"] and ns.State.knownTaxi["Ratchet, The Barrens"], "a discovered path of yours or a neutral one")
    assertTrue(not ns.State.knownTaxi["Sentinel Hill, Westfall"], "an undiscovered path counted as known")
    assertTrue(not ns.State.knownTaxi["Crossroads, The Barrens"], "the other faction's path counted as yours")
    assertTrue(ns.char.knownTaxi == ns.State.knownTaxi, "not saved with the character")
    assertEquals(0, ns.State.ScanTaxi(), "nothing new the second time")
    -- a client that marks nothing undiscovered among many nodes says nothing
    local many = {}
    for i = 1, 12 do many[i] = { name = "Node " .. i, faction = F.Alliance, isUndiscovered = false } end
    C_TaxiMap = { GetTaxiNodesForMap = function(m) return m == 1414 and many or {} end }
    ns.State.knownTaxi = {}
    assertEquals(0, ns.State.ScanTaxi())
    assertTrue(next(ns.State.knownTaxi) == nil, "an all-discovered list was trusted")
    -- no such API: nothing happens
    C_TaxiMap = nil
    assertEquals(0, ns.State.ScanTaxi())
  end)
  C_TaxiMap, ns.State.knownTaxi, ns.char.knownTaxi, UnitFactionGroup = sv.api, sv.known, sv.charKnown, sv.fac
  if not ok then error(err, 0) end
end)

test("Target key: a real keybinding (Options > Keybindings > AddOns), and targeting marks the NPC with a star once", function()
  -- the binding is there, with a name (the options hint used to point at one that didn't exist)
  local found
  for i = 1, (GetNumBindings and GetNumBindings() or 0) do
    local action = GetBinding(i)
    if action == "CLICK ForeverRouteTargetButton:LeftButton" then found = true end
  end
  -- the simulator loads no addon Bindings.xml (tools/install.sh checks the file itself); the game does
  do local any = false; for i = 1, (GetNumBindings and GetNumBindings() or 0) do local a = GetBinding(i); if type(a) == "string" and a:find("^FOREVERROUTE") then any = true end end; if any then assertTrue(found, "no Target binding in Bindings.xml") end end
  assertEquals("Forever Route Targeting", _G["BINDING_NAME_CLICK ForeverRouteTargetButton:LeftButton"])
  assertTrue(ns.Card.TargetMacro("Martie Jainrose"):find("/target Martie Jainrose", 1, true) ~= nil)
  -- marking goes through the game's own /tm in the macro: addon code setting a raid marker (/run ... SetRaidTarget)
  -- is a protected action on Forever (ADDON_ACTION_FORBIDDEN, and no star). Clear then set: /tm 1 alone toggles, and
  -- the button fires on key down and up
  local sv = ns.db.markTarget
  ns.db.markTarget = true
  local m = ns.Card.TargetMacro("x")
  assertTrue(m:find("/tm 0\n/tm 1", 1, true) ~= nil, "the macro does not mark with the game's /tm (clear, then set)")
  assertTrue(not m:find("/run", 1, true), "the macro runs addon code: a protected action on Forever")
  ns.db.markTarget = false
  assertTrue(not ns.Card.TargetMacro("x"):find("/tm", 1, true), "marks with the option off")
  ns.db.markTarget = sv
end)

test("stops on the way: a gap you fly is not a walk (Thorium Point lies under the line from Southshore to Duskwood, and a level 30 was sent there next for its flight path)", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { info = C_Map.GetMapInfo, routes = ns.DungeonRoutes, flight = ns.FLIGHT }
  local names = { [1424] = "Hillsbrad Foothills", [1427] = "Searing Gorge", [1428] = "Burning Steppes", [1431] = "Duskwood", [1433] = "Redridge Mountains" }
  C_Map.GetMapInfo = function(m) local i = (sv.info and sv.info(m)) or {}; if names[m] then return { mapID = m, name = names[m], mapType = i.mapType, parentMapID = i.parentMapID } end return i end
  ns.DungeonRoutes = function() return {} end
  local A = ns.FLIGHT_BY.Alliance
  ns.FLIGHT = { [1424] = A[1424], [1427] = A[1427], [1428] = A[1428], [1431] = A[1431], [1433] = A[1433] }
  -- the plan is in Duskwood; you went north for something else and stand in Southshore, a flight away
  local route = { id = "fpgap", title = "fpgap", sections = { { title = "Darkshire" } }, steps = {
    { id = 1, k = "accept", q = 221, name = "Worgen in the Woods", npc = "Calor", m = 1431, x = 0.7575, y = 0.4757, zone = "Duskwood", r = 6, sec = 1 },
    { id = 2, k = "obj", q = 221, text = "Kill 12 Nightbane Dark Runner", match = "Nightbane Dark Runner", m = 1431, x = 0.645, y = 0.724, zone = "Duskwood", r = 124, sec = 1 },
    { id = 3, k = "turnin", q = 221, name = "Worgen in the Woods", npc = "Calor", m = 1431, x = 0.7575, y = 0.4757, zone = "Duskwood", r = 6, sec = 1 },
  } }
  local quests = { [221] = { on = true, complete = false, objectives = { { text = "Nightbane Dark Runner slain: 0/12", finished = false, have = 0, need = 12 } } } }
  local function added() local t = {}; for i, s in ipairs(ForeverRouteData.steps) do if s.inserted then t[#t + 1] = i .. ":" .. tostring(s.k) .. ":" .. tostring(s.zone or s.name) end end; return table.concat(t, " ") end
  local ok, err = pcall(ForeverRouteTest.withWorld, route, function(w)
    w:knows({ "Southshore, Hillsbrad", "Darkshire, Duskwood", "Lakeshire, Redridge" })
    ns.Engine.Refresh()
    assertEquals(2, w:shown())
    -- the way to the step is a flight: nothing under that line is on the way (Searing Gorge, the Burning Steppes)
    ForeverRouteData.steps._merged = nil
    ns.Engine.MergeSideTrips(); ns.Engine.Refresh()
    if added() ~= "" then error("stops added from Southshore: " .. added(), 0) end
    assertEquals(2, w:shown()); assertEquals("obj", ForeverRouteData.steps[2].k)
    assertFalse(ns.Engine.OnFoot(1424, 0.5052, 0.5183, 1431, 0.645, 0.724), "Southshore to Duskwood read as a ride")
    -- a hand-in right beside you still goes first: there and back from where you leave
    local px, py, pinst = HBD:GetPlayerWorldPosition()
    local at = ns.Engine.InsertStop({ k = "turnin", q = 98219, name = "The Shamed Lieutenant", npc = "Lieutenant Farren Orinelle", m = 1424, x = 0.5146, y = 0.5839, r = 6, inserted = true }, px, py, pinst)
    assertEquals(2, at)
    -- in Duskwood without its flight path: the flight master is a few steps off your way to the kill spot - added
    w:go(1431, 0.74, 0.47)
    w:knows({ "Southshore, Hillsbrad" })
    ForeverRouteData.steps._merged = nil
    assertTrue(ns.Engine.MergeSideTrips(), "Darkshire's flight path, right on the way, was not added")
    local fp; for i, s in ipairs(ForeverRouteData.steps) do if s.inserted and s.k == "fp" then if fp then error("more than one flight path added: " .. added(), 0) end; fp = s end end
    assertNotNil(fp); assertEquals(1431, fp.m)
  end, { anyTarget = true, at = { m = 1424, x = 0.5052, y = 0.5183, level = 30, quests = quests } })
  C_Map.GetMapInfo, ns.DungeonRoutes, ns.FLIGHT = sv.info, sv.routes, sv.flight
  if not ok then error(err, 0) end
end)

test("/fr report: packs what a replay needs, reads back the same, no name or realm, the short form fits a Discord message", function()
  local d = {
    full = false,
    meta = { version = "1.2.2", client = 16001, time = 1794431000, race = "Gnome", class = "WARLOCK", faction = "Alliance", level = 30, xp = 12345, xpMax = 40000,
      map = 1424, x = 0.505, y = 0.518, bind = "Southshore", plan = "built-in gnome-warlock", stamp = "plans 2026-11-10", route = "path:ElwynnForest-Westfall",
      current = 7, steps = 2431, step = "obj Worgen in the Woods", stepQ = 221, stepKey = "obj:221#1" },
    log = { [221] = { complete = false, objectives = { { 3, 15, false, "x" } } }, [1100] = { complete = true, objectives = {} } },
    completed = {}, taxi = { "Southshore, Hillsbrad", "Stormwind, Elwynn" },
    ticks = { skipped = { "fly::Duskwood#1" }, manualDone = {}, nope = { 34 } },
    card = { { i = 5, r = ns.Report.REASON.behind, k = "accept", q = 34 }, { i = 6, r = ns.Report.REASON.done, k = "fly", q = 0 } },
    why = { { t = 1794430000, k = "insert", lv = 30, m = 1424, x = "added fp as step 7" } },
    errors = {}, settings = { pathLine = true, pins = true, hideDone = true, markTarget = true },
  }
  local text = ns.Report.Pack(d)
  assertTrue(text:find("^FR report 1.2.2 |") ~= nil, text:sub(1, 60))
  local back = ns.Report.Unpack(text)
  assertNotNil(back and back.meta, "did not read back")
  assertEquals(30, back.meta.level); assertEquals(1424, back.meta.map); assertEquals(7, back.meta.current)
  assertTrue(math.abs(back.meta.x - 0.505) < 0.0001)
  assertEquals("built-in gnome-warlock", back.meta.plan); assertEquals("obj:221#1", back.meta.stepKey)
  assertEquals(3, back.log[221].objectives[1][1]); assertEquals(15, back.log[221].objectives[1][2]); assertTrue(back.log[1100].complete)
  assertEquals("Stormwind, Elwynn", back.taxi[2])
  assertEquals(ns.Report.REASON.behind, back.card[1].r); assertEquals("fly", back.card[2].k)
  -- completed quests: sorted gaps, any order in
  d.full, d.completed = true, { 900, 7, 4000, 33 }
  local full = ns.Report.Unpack(ns.Report.Pack(d))
  assertEquals("7,33,900,4000", table.concat(full.completed, ","))
  -- the real thing, gathered in a world: anonymous, short enough
  ForeverRouteTest.withWorld({ id = "rep", title = "rep", sections = { { title = "x" } }, steps = {
    { k = "accept", q = 783, name = "A Threat Within", level = 1, m = 1429, x = 0.48, y = 0.43, sec = 1, lvl = 1 },
  } }, function(w)
    local before = { pos = { map = 1, x = 0.1, y = 0.2 }, reason = "logout" }
    ns.char.snapshot = before
    local live = ns.Report.Pack(ns.Report.Gather(false))
    assertTrue(ns.char.snapshot == before, "the report replaced the save's snapshot (the planner reads it)")
    local name, realm = UnitName("player"), GetRealmName()
    if name and #name > 2 then assertTrue(not live:find(name, 1, true), "the report has the character's name") end
    if realm and #realm > 2 then assertTrue(not live:find(realm, 1, true), "the report has the realm") end
    assertTrue(#live < 1900, #live .. " characters: too long for one Discord message")
    assertNotNil(ns.Report.Unpack(live).meta)
  end, { anyTarget = true })
  -- the fixed vector tools/check-report.js decodes: the addon must keep packing exactly this
  local vec = {
    full = false,
    meta = { version = "1.2.2", client = 16001, time = 1794431000, race = "Gnome", class = "WARLOCK", faction = "Alliance", level = 30, xp = 12345, xpMax = 40000,
      map = 1424, x = 0.505, y = 0.518, bind = "Southshore", plan = "built-in gnome-warlock", stamp = "plans 2026-11-10", route = "path:ElwynnForest-Westfall",
      current = 7, steps = 2431, step = "obj Worgen in the Woods", stepQ = 221, stepKey = "obj:221#1" },
    log = { [221] = { complete = false, objectives = { { 3, 15, false, "x" } } }, [1100] = { complete = true, objectives = {} } },
    completed = { 7, 33, 900, 4000 }, taxi = { "Southshore, Hillsbrad", "Stormwind, Elwynn" },
    ticks = { skipped = { "fly::Duskwood#1" }, manualDone = {}, nope = { 34 } },
    card = { { i = 5, r = ns.Report.REASON.behind, k = "accept", q = 34 } },
    why = { { t = 1794430000, k = "insert", lv = 30, m = 1424, x = "added fp as step 7" } },
    errors = { { where = "nav", count = 2, msg = "boom", shown = "7 obj" } }, settings = { pathLine = true, pins = false, hideDone = true, markTarget = true },
  }
  local packed = ns.Report.Pack(vec)
  assertEquals("FR1.AakBBTEuMi4yBTE2MDAxmLDT1wYFR25vbWUHV0FSTE9DSwhBbGxpYW5jZR65YMC4ApALuie8KApTb3V0aHNob3JlFmJ1aWx0LWluIGdub21lLXdhcmxvY2sQcGxhbnMgMjAyNi0xMS0xMBpwYXRoOkVsd3lubkZvcmVzdC1XZXN0ZmFsbAf_EhdvYmogV29yZ2VuIGluIHRoZSBXb29kc90BCW9iajoyMjEjMQIMAt0BAAEDDwDMCAEAAwcEBxrjBpwYBCkCFVNvdXRoc2hvcmUsIEhpbGxzYnJhZBFTdG9ybXdpbmQsIEVsd3lubgUUAQ9mbHk6OkR1c2t3b29kIzEAASIIBQEFDQEiBiMBsKjT1wYGaW5zZXJ0HpALEmFkZGVkIGZwIGFzIHN0ZXAgNwsTAQNuYXYCBGJvb20FNyBvYmoAAAkBDQ", packed:match("FR1%.%S+"))
end)

----------------------------------------------------------------------------------------------------------------
-- Your place in the built-in plan (Engine.BehindYou, Engine.FindPlace)
----------------------------------------------------------------------------------------------------------------
-- a small built-in plan: Redridge at 21-22, Duskwood at 28-29, the Wetlands at 29-30, town, Redridge again at 31.
-- Travel, the flight path, the bind and the training stop carry no level, like the plans shipped in v1.2.0.
local function joinPlan() return { id = "joinplan", title = "joinplan", sections = { { title = "Redridge Mountains" }, { title = "Duskwood" }, { title = "Wetlands" } }, steps = {
  { k = "fly", dest = "Redridge Mountains", text = "Redridge Mountains", sec = 1 },                                                                    -- 1
  { k = "fp", npc = "Ariena Stormfeather", fp = "Lakeshire, Redridge", zone = "Redridge Mountains", m = 1433, x = 0.30, y = 0.59, sec = 1 },           -- 2
  { k = "accept", q = 34, name = "An Unwelcome Guest", level = 24, m = 1433, x = 0.17, y = 0.46, sec = 1, lvl = 21 },                                  -- 3
  { k = "turnin", q = 34, name = "An Unwelcome Guest", level = 24, m = 1433, x = 0.17, y = 0.46, sec = 1, lvl = 22 },                                  -- 4
  { k = "turnin", q = 244, name = "Encroaching Gnolls", npc = "Deputy Feldon", level = 26, m = 1433, x = 0.30, y = 0.44, sec = 1, lvl = 22 },           -- 5: in your log, finished
  { k = "obj", q = 245, name = "Assessing the Threat", text = "Collect 8 Gnoll Paws", match = "Gnoll Paws", level = 26, m = 1433, x = 0.40, y = 0.40, sec = 1, lvl = 22 }, -- 6: in your log, half done
  { k = "bind", npc = "Innkeeper Allison", zone = "Stormwind", m = 1453, x = 0.60, y = 0.75, sec = 1 },                                                -- 7
  { k = "train", text = "level 22 spells", zone = "Stormwind", m = 1453, x = 0.39, y = 0.85, sec = 1 },                                                -- 8
  { k = "fly", dest = "Duskwood", text = "Duskwood", sec = 2 },                                                                                        -- 9
  { k = "accept", q = 1110, name = "Raven Hill", level = 28, m = 1431, x = 0.73, y = 0.46, sec = 2, lvl = 28 },                                        -- 10
  { k = "turnin", q = 1110, name = "Raven Hill", level = 28, m = 1431, x = 0.18, y = 0.56, sec = 2, lvl = 29 },                                        -- 11
  { k = "fly", dest = "Wetlands", text = "Wetlands", sec = 3 },                                                                                        -- 12: where a level 30 joins
  { k = "accept", q = 900, name = "The Dark Iron War", level = 30, m = 1437, x = 0.50, y = 0.50, sec = 3, lvl = 29 },                                  -- 13
  { k = "turnin", q = 900, name = "The Dark Iron War", level = 30, m = 1437, x = 0.50, y = 0.50, sec = 3, lvl = 30 },                                  -- 14
  { k = "hearth", dest = "Stormwind", text = "Stormwind", bindMap = 1453, sec = 3 },                                                                   -- 15
  { k = "turnin", q = 690, name = "Malin's Request", level = 32, m = 1453, x = 0.40, y = 0.60, sec = 3, lvl = 30 },                                    -- 16: in your log, its hand-in ahead
  { k = "accept", q = 901, name = "Jitters' Growling Gut", level = 31, m = 1453, x = 0.50, y = 0.60, sec = 3, lvl = 30 },                              -- 17: needs Raven Hill handed in
  { k = "turnin", q = 901, name = "Jitters' Growling Gut", level = 31, m = 1453, x = 0.55, y = 0.60, sec = 3, lvl = 30 },                              -- 18
  { k = "turnin", q = 245, name = "Assessing the Threat", level = 26, m = 1453, x = 0.60, y = 0.60, sec = 3, lvl = 30 },                               -- 19
  { k = "fly", dest = "Redridge Mountains", text = "Redridge Mountains", sec = 3 },                                                                    -- 20
  { k = "accept", q = 902, name = "Shadow Magic", level = 31, m = 1433, x = 0.20, y = 0.45, sec = 3, lvl = 31 },                                       -- 21
  { k = "accept", q = 903, name = "Howling in the Hills", level = 31, m = 1433, x = 0.60, y = 0.45, sec = 3, lvl = 31 },                               -- 22
} } end
-- the log of someone who levelled without the addon: a finished Redridge quest, a half-done one, and one for later
local function joinLog() return {
  [244] = { on = true, complete = true, objectives = {} },
  [245] = { on = true, objectives = { { finished = false, have = 2, need = 8, text = "Gnoll Paws: 2/8" } } },
  [690] = { on = true, complete = true, objectives = {} },
} end
local function onBuiltIn(fake, fn)
  local sv = { lvl = UnitLevel, pk = ns.planKey, ready = ns.Engine.placeReady, unl = ForeverRouteUnlocks, bind = GetBindLocation, after = C_Timer.After }
  local ok, err = pcall(withState, fake, function()
    ns.planKey = { starter = "gnome-warlock" }
    ns.Engine.placeReady = true
    ForeverRouteUnlocks = { [1110] = { 901 } }
    GetBindLocation = function() return "Southshore" end
    C_Timer.After = function() end -- (the note to the player)
    ForeverRouteData = joinPlan()
    fn()
  end)
  UnitLevel, ns.planKey, ns.Engine.placeReady, ForeverRouteUnlocks, GetBindLocation, C_Timer.After = sv.lvl, sv.pk, sv.ready, sv.unl, sv.bind, sv.after
  if not ok then error(err, 0) end
end

test("joining the built-in plan at 30: you start at the trip where it reaches your level - travel, flight paths, binds and quests in your log before it are behind you", function()
  onBuiltIn(joinLog(), function()
    UnitLevel = function() return 30 end
    ns.Engine.Refresh()
    assertEquals(30, ns.char.join and ns.char.join.level, "no place found for a level 30 meeting the plan")
    local level, at = ns.Engine.Place()
    assertEquals(30, level); assertEquals(12, at, "you join at the trip into the stretch where the plan reaches 30")
    assertEquals(12, ns.Engine.Shown(), "the card starts at that trip")
    -- everything before it: the flight to Redridge and its flight path (no level of their own), the bind, the training
    -- stop, and the quests in your log - finished (5) or not (6)
    for i = 1, 11 do assertTrue(ns.Engine.IsDone(i), "step " .. i .. " (" .. ForeverRouteData.steps[i].k .. ") is before the trip you joined at") end
    -- the stretch you join is whole: its first pick-up is planned a level below you
    assertEquals(21, ns.Engine.PlanLevel(1)); assertEquals(28, ns.Engine.PlanLevel(9)); assertEquals(29, ns.Engine.PlanLevel(12))
    assertTrue(not ns.Engine.IsDone(13), "the first pick-up of the stretch you joined was passed")
    assertTrue(not ns.Engine.IsDone(14))
    -- a hearth to the inn the plan bound you at back there: you are not bound there
    assertTrue(ns.Engine.IsDone(15), "a hearth to an inn you never bound at")
    -- a quest in your log whose hand-in is ahead stays; one with something left to do behind you goes as a whole
    assertTrue(not ns.Engine.IsDone(16), "a quest in your log with its hand-in ahead was dropped")
    assertTrue(ns.Engine.IsDone(19), "the hand-in of a quest whose objective is behind you")
    -- a pick-up that needs a quest handed in behind you is not offered, and its hand-in goes with it
    assertTrue(ns.Engine.IsDone(17), "a pick-up that needs a quest you never did"); assertTrue(ns.Engine.IsDone(18))
    for i = 20, 22 do assertTrue(not ns.Engine.IsDone(i), "step " .. i .. " is ahead of you") end
    -- bound at that inn after all: the hearth is yours
    GetBindLocation = function() return "Stormwind City" end
    ns.Engine.Refresh()
    assertTrue(not ns.Engine.IsDone(15), "a hearth to the inn you are bound at was passed")
    -- your place holds as you level: at 31 nothing more is passed (the plan's 29-30 stretch is still yours)
    UnitLevel = function() return 31 end
    ns.Engine.Refresh()
    assertEquals(30, ns.char.join.level); assertEquals(12, ns.Engine.Shown())
    -- a plan of your own (the companion's) is made from your save: none of this
    ns.planKey = { found = "x" }
    ns.Engine.Refresh()
    assertTrue(not ns.Engine.IsDone(10), "your own plan's step was passed"); assertNil(ns.Engine.Place())
  end)
end)

test("levelling along the built-in plan: up to 3 levels ahead nothing is passed, and you are never taken for someone joining", function()
  local fake = joinLog(); fake[34] = { on = false, done = true, objectives = {} }
  onBuiltIn(fake, function()
    -- 24 where the plan has you at 21 (rested XP): you are following it
    UnitLevel = function() return 24 end
    ns.Engine.Refresh()
    assertEquals(0, ns.char.join and ns.char.join.level, "someone 2-3 levels ahead of the plan was taken for joining")
    assertNil(ns.Engine.Place())
    for _, i in ipairs({ 1, 2, 5, 6, 7 }) do assertTrue(not ns.Engine.IsDone(i), "step " .. i .. " was passed for someone following the plan") end
    assertEquals(1, ns.Engine.Shown())
    -- 4 and more ahead (a dungeon or two): what the plan does down there is passed - its travel and flight path too -
    -- but a quest in your log stays: you picked it up on the plan
    UnitLevel = function() return 27 end; ns.char.join.seen = 27
    ns.Engine.Refresh()
    assertEquals(0, ns.char.join.level, "racing ahead is not joining")
    assertTrue(ns.Engine.IsDone(1), "the flight to a zone 5 levels below you"); assertTrue(ns.Engine.IsDone(2), "its flight path")
    assertTrue(not ns.Engine.IsDone(5), "a quest in your log was dropped"); assertTrue(not ns.Engine.IsDone(6))
    assertTrue(not ns.Engine.IsDone(10), "a step 1 level above you was passed")
  end)
end)

test("coming back to the built-in plan many levels on finds your place again, and /fr rejoin does it when you ask", function()
  onBuiltIn(joinLog(), function()
    -- tried the addon at 4 (following from the start), came back at 30
    ns.char.join = { plan = "gnome-warlock", level = 0, seen = 4 }
    UnitLevel = function() return 30 end
    -- (not while you are on a side trip: its steps have no levels to tell by)
    ForeverRouteData.dungeon = true
    ns.Engine.Refresh()
    assertEquals(0, ns.char.join.level, "your place was looked for on a side trip")
    ForeverRouteData.dungeon = nil
    ns.Engine.Refresh()
    assertEquals(30, ns.char.join.level); assertEquals(30, ns.char.join.seen); assertEquals(12, ns.Engine.Shown())
    -- seen levelling all the way (seen keeps up): nothing is looked up again
    ns.char.join = { plan = "gnome-warlock", level = 0, seen = 29 }
    ns.Engine.Refresh()
    assertEquals(0, ns.char.join.level); assertNil(ns.Engine.Place())
    -- asked for
    local said = {}; local svP = ns.Print; ns.Print = function(m) said[#said + 1] = m end
    local ok, err = pcall(function()
      ns.Engine.Rejoin()
      assertEquals(30, ns.char.join.level); assertEquals(12, ns.Engine.Shown())
      assertTrue(#said == 1 and said[1]:find("level 30", 1, true) ~= nil, "no word to the player about where they joined")
      -- another character's place (another race and class) is not yours
      ns.char.join = { plan = "human-mage", level = 50, seen = 50 }
      ns.Engine.Refresh()
      assertEquals("gnome-warlock", ns.char.join.plan); assertEquals(30, ns.char.join.level)
      -- on a plan of your own there is nothing to rejoin
      ns.planKey = { found = "x" }; ns.char.join = nil
      ns.Engine.Rejoin()
      assertNil(ns.char.join)
    end)
    ns.Print = svP
    if not ok then error(err, 0) end
  end)
end)

test("a finished quest in your log whose hand-in is behind you: the log check says so, and it gets a stop where the plan passes its NPC again", function()
  local HBD = LibStub("HereBeDragons-2.0")
  local sv = { conv = HBD.GetWorldCoordinatesFromZone, n = C_QuestLog.GetNumQuestLogEntries, i = C_QuestLog.GetInfo, enders = ForeverRouteEnders }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) return x * 1000, y * 1000, m end
  local log = { { isHeader = true, title = "Redridge Mountains" }, { questID = 244, title = "Encroaching Gnolls", level = 28 }, { questID = 245, title = "Assessing the Threat", level = 28 },
    { isHeader = true, title = "Stormwind City" }, { questID = 690, title = "Malin's Request", level = 32 } }
  C_QuestLog.GetNumQuestLogEntries = function() return #log, 3 end
  C_QuestLog.GetInfo = function(k) return log[k] end
  ForeverRouteEnders = { [244] = { npc = "Deputy Feldon", m = 1433, x = 0.30, y = 0.44, name = "Encroaching Gnolls" } }
  local ok, err = pcall(onBuiltIn, joinLog(), function()
    UnitLevel = function() return 30 end
    ns.Engine.Refresh()
    local function verdicts() local v = {}; for _, x in ipairs(ns.LogCheck.Classify()) do v[x.e.id] = x.verdict end return v end
    local v = verdicts()
    assertEquals("turnin", v[244], "finished, its hand-in behind you: hand it in if you pass by")
    assertEquals("drop", v[245], "half done, behind you: not on your route")
    assertEquals("keep", v[690], "its hand-in is ahead")
    -- the plan comes back to Redridge at 31: the hand-in gets a stop there (not a trip of its own now)
    assertTrue(ns.Engine.ApplyInserts(), "no stop for a finished quest whose hand-in is behind you")
    local at; for j, s in ipairs(ForeverRouteData.steps) do if s.q == 244 and s.inserted then at = j end end
    assertTrue(at ~= nil and at > 20, "the stop belongs in the Redridge stretch ahead, it went to step " .. tostring(at))
    assertFalse(ns.Engine.ApplyInserts()) -- once
    ns.Engine.Refresh()
    assertEquals(12, ns.Engine.Shown(), "the card left the trip you joined at")
    assertTrue(not ns.Engine.IsDone(at)); assertEquals("keep", verdicts()[244])
  end)
  HBD.GetWorldCoordinatesFromZone, C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, ForeverRouteEnders = sv.conv, sv.n, sv.i, sv.enders
  if not ok then error(err, 0) end
end)

test("joining the built-in plan waits until the game has told us your done quests (a cold login must not read a follower as a joiner)", function()
  local sv = { lvl = UnitLevel, done = ns.State.completed, rc = ns.State.RefreshCompleted, pk = ns.planKey, data = ForeverRouteData, join = ns.char.join }
  local ok, err = pcall(function()
    ForeverRouteData = { id = "j", title = "j", sections = { { title = "x" } }, steps = { { k = "accept", q = 783, name = "x", level = 1, sec = 1, lvl = 1 } } }
    ns.planKey = { starter = "gnome-warlock" }; ns.char.join = nil
    UnitLevel = function() return 30 end
    ns.State.completed = {}; ns.State.RefreshCompleted = function() end -- the game has nothing yet
    assertTrue(not ns.Engine.PlaceDue(), "decided where you join before your done quests were known")
    ns.State.completed = { [783] = true }
    assertTrue(ns.Engine.PlaceDue(), "never decides once they are known")
  end)
  UnitLevel, ns.State.completed, ns.State.RefreshCompleted, ns.planKey, ForeverRouteData, ns.char.join = sv.lvl, sv.done, sv.rc, sv.pk, sv.data, sv.join
  if not ok then error(err, 0) end
end)

test("what's new: a bar under the card once per version for someone updating, never on a first install; the panel lists only newer versions", function()
  local sv = { news = ns.NEWS, ver = ns.VERSION, seen = ns.db.newsSeen, db = ForeverRouteDB.why, snap = ns.char.snapshot, md = ns.char.manualDone }
  local ok, err = pcall(function()
    ns.NEWS = { { version = "1.2.2", date = "d", items = { "a", "b" } }, { version = "1.2.1", date = "d", items = { "c" } }, { version = "1.2.0", date = "d", items = { "e" } } }
    ns.VERSION = "1.2.2"
    -- a first install: nothing is new to you
    ns.db.newsSeen = nil; ForeverRouteDB.why = {}; ns.char.snapshot = nil; ns.char.manualDone = {}
    assertTrue(not ns.News.Due(), "a first install got the what's-new bar")
    assertEquals("1.2.2", ns.db.newsSeen)
    -- someone who had 1.2.0: the bar, and the panel lists 1.2.2 and 1.2.1 only
    ns.db.newsSeen = "1.2.0"
    assertTrue(ns.News.Check(), "no bar after an update")
    assertTrue(ForeverRouteNewsBar:IsShown())
    assertEquals("1.2.2,1.2.1", (function() local t = {} for _, e in ipairs(ns.News.Since("1.2.0")) do t[#t + 1] = e.version end return table.concat(t, ",") end)())
    -- dismissed: gone, and gone for good
    ns.News.Dismiss()
    assertTrue(not ForeverRouteNewsBar:IsShown()); assertEquals("1.2.2", ns.db.newsSeen); assertTrue(not ns.News.Due())
    -- an older user with no record of a version (from before this feature): the bar
    ns.db.newsSeen = nil; ForeverRouteDB.why = { { t = 1, k = "card", x = "x" } }
    assertTrue(ns.News.Due(), "an existing user updating from before the bar existed got nothing")
    -- the panel opens and marks it seen; versions compare as numbers
    ns.News.Show("1.2.0"); assertTrue(ForeverRouteNews:IsShown()); ForeverRouteNews:Hide()
    -- long notes scroll inside a panel that stays a fixed size
    local many = {}; for i = 1, 60 do many[i] = "a change worth a line of its own, number " .. i end
    ns.NEWS = { { version = "1.3.0", date = "d", items = many } }
    ns.News.Show(nil)
    assertTrue(ForeverRouteNews:GetHeight() <= ns.News.MAX_HEIGHT + 0.5, "the panel grew to " .. ForeverRouteNews:GetHeight())
    assertTrue(ForeverRouteNewsScroll:GetVerticalScrollRange() > 0, "long notes do not scroll")
    -- older versions on request, and the panel resizes
    ns.NEWS = { { version = "1.3.1", date = "d", items = { "x" } }, { version = "1.3.0", date = "d", items = { "y" } }, { version = "1.2.0", date = "d", items = { "z" } } }
    ns.db.newsSize = nil
    ns.News.Show("1.3.0")
    local function body() return ForeverRouteNews.body:GetText() or "" end
    assertTrue(body():find("1.3.1", 1, true) and not body():find("1.2.0", 1, true), "showed more than what is new")
    assertTrue(ForeverRouteNews.older:IsShown(), "no way to see older versions")
    ForeverRouteNews.older:Click()
    assertTrue(body():find("1.2.0", 1, true) ~= nil, "Older versions did not add the earlier notes")
    assertTrue(not ForeverRouteNews.older:IsShown(), "Older versions still offered with everything shown")
    assertTrue(ForeverRouteNews:IsResizable(), "the panel cannot be resized")
    assertNotNil(ForeverRouteNewsGrip, "no resize grip")
    ForeverRouteNews:Hide()
    assertTrue(ns.News.Newer("1.2.10", "1.2.9")); assertTrue(not ns.News.Newer("1.2.2", "1.2.2"))
  end)
  ns.NEWS, ns.VERSION, ns.db.newsSeen, ForeverRouteDB.why, ns.char.snapshot, ns.char.manualDone = sv.news, sv.ver, sv.seen, sv.db, sv.snap, sv.md
  if ForeverRouteNewsBar then ForeverRouteNewsBar:Hide() end
  if not ok then error(err, 0) end
end)

test("quest log full: pick-ups wait and the card goes to hand-ins and objectives first; with room again they come back", function()
  local sv = { lc = ns.State.LogCount, lvl = UnitLevel }
  withState({ [244] = { on = true, complete = true, objectives = {} } }, function()
    ns.State.OnQuest = function(id) return id == 244 end
    ns.State.QuestReady = function(id) return id == 244 end
    ForeverRouteData = { id = "full", title = "full", sections = { { title = "x" } }, steps = {
      { k = "accept", q = 1110, name = "Raven Hill", level = 28, m = 1431, x = 0.73, y = 0.46, sec = 1, lvl = 28 },
      { k = "turnin", q = 244, name = "Encroaching Gnolls", level = 24, m = 1431, x = 0.75, y = 0.45, sec = 1, lvl = 28 },
    } }
    UnitLevel = function() return 28 end
    ns.State.LogCount = function() return 40 end
    ns.Fire("QUEST_LOG_UPDATE") -- (what the game fires when the log changes)
    ns.Engine.Refresh()
    assertEquals(2, ns.Engine.Shown(), "a full log should send you to the hand-in first")
    assertEquals("full", ns.Engine.Status(1))
    assertEquals("full", (ns.Engine.NotYet(1)))
    ns.State.LogCount = function() return 12 end
    -- (the full check is cached for a second; the log changing clears it)
    ns.Fire("QUEST_LOG_UPDATE")
    ns.Engine.Refresh()
    assertEquals(1, ns.Engine.Shown(), "with room again the pick-up comes back")
  end)
  ns.State.LogCount, UnitLevel = sv.lc, sv.lvl
end)

----------------------------------------------------------------------------------------------------------------
-- Where you start on the built-in plan (Engine.ChooseStart): by value, from where you stand
----------------------------------------------------------------------------------------------------------------
-- joinPlan() with a place to stand and a trip that costs 10 minutes between zones, none within one
local function standing(m, fn)
  local sv = { pos = ns.State.Position, plan = ns.Travel.Plan, min = ns.Engine.START_MIN_TURNINS }
  ns.State.Position = function() return m, 0.5, 0.5 end
  ns.Travel.Plan = function(from, to) return {}, (from.m == to.m) and 0 or 600 end
  ns.Engine.START_MIN_TURNINS = 1
  local ok, err = pcall(onBuiltIn, joinLog(), function() UnitLevel = function() return 30 end; fn() end)
  ns.State.Position, ns.Travel.Plan, ns.Engine.START_MIN_TURNINS = sv.pos, sv.plan, sv.min
  if not ok then error(err, 0) end
end

test("joining the built-in plan: you start in the stretch worth most from where you stand - its XP over its work and the travel it adds", function()
  -- in Duskwood, whose level 28 stretch the plan has just before the trip a level 30 joins at: no trip to it, and the
  -- trip on to the Wetlands is the one you'd make anyway
  standing(1431, function()
    ns.Engine.Refresh()
    local _, at = ns.Engine.Place()
    assertEquals(12, at)
    local a, b = ns.Engine.FirstStretch()
    assertEquals(9, a, "standing in Duskwood, its stretch is where to start"); assertEquals(11, b)
    assertEquals(9, ns.Engine.Shown())
    for i = 1, 8 do assertTrue(ns.Engine.IsDone(i), "step " .. i .. " is behind you") end
    assertTrue(not ns.Engine.IsDone(10), "the stretch you start in was passed")
    local _, priced = ns.Engine.ChooseStart(30)
    assertTrue(#priced >= 2 and priced[1].from == 9 and priced[1].xph > priced[2].xph, "the stretches are priced, best first")
    assertEquals(0, priced[1].extra, "a stretch around you adds no travel")
    -- done there: on to the trip you joined at
    ns.State.IsCompleted = function(id) return id == 1110 end
    ns.Engine.Refresh()
    assertEquals(12, ns.Engine.Shown())
  end)
  -- in the Wetlands: the plan's own trip costs nothing, Duskwood would be a detour there and back
  standing(1437, function()
    ns.Engine.Refresh()
    assertNil(ns.Engine.FirstStretch(), "a detour won over the stretch you stand in")
    assertEquals(12, ns.Engine.Shown())
    assertTrue(ns.Engine.IsDone(10), "Duskwood's stretch is behind someone who starts in the Wetlands")
  end)
  -- in Stormwind, where the plan has you hand in Malin's Request after the Wetlands: that stretch first (though the
  -- plan has it later), then the plan's order again
  standing(1453, function()
    ns.Engine.Refresh()
    local a = ns.Engine.FirstStretch()
    assertEquals(15, a, "the stretch in the city you stand in")
    assertEquals(16, ns.Engine.Shown(), "its hand-in comes first (the hearth to it is not yours)")
    assertTrue(not ns.Engine.IsDone(12), "the trip you joined at is still to do")
    local q = ns.State.Quest
    ns.State.Quest = function(id) if id == 690 then return { on = false, objectives = {} } end return q(id) end
    ns.State.IsCompleted = function(id) return id == 690 end
    ns.Engine.Refresh()
    assertEquals(12, ns.Engine.Shown(), "after it, the plan's order")
  end)
end)

test("a finished quest from before you joined is handed in first while you are in its hand-in's zone; an unfinished one stays yours", function()
  standing(1433, function() -- Redridge: Encroaching Gnolls (finished) is handed in right here
    ns.Engine.Refresh()
    assertEquals(5, ns.Engine.Shown(), "the hand-in in your zone comes first")
    assertTrue(ns.Engine.IsDone(6), "an unfinished quest from before you joined is not the plan's")
    assertTrue(ns.Engine.IsDone(3), "a pick-up behind you is not opened by standing next to it")
  end)
  standing(1437, function() -- anywhere else it is behind you (and gets a stop where the route passes its NPC)
    ns.Engine.Refresh()
    assertTrue(ns.Engine.IsDone(5))
    -- a quest picked up since you joined is the plan's, wherever it leads
    ns.char.join.had[244] = nil
    ns.Engine.Refresh()
    assertTrue(not ns.Engine.IsDone(5), "a quest picked up since you joined was dropped")
  end)
end)

test("the built-in plan first met in the start zone: you are following it, and nothing of the zone is behind you", function()
  local sv = { lvl = UnitLevel, pk = ns.planKey, ready = ns.Engine.placeReady }
  local ok, err = pcall(withState, {}, function()
    ns.planKey = { starter = "gnome-warlock" }
    ns.Engine.placeReady = true
    ForeverRouteData = { id = "startzone", title = "startzone", sections = { { title = "Dun Morogh" } }, steps = {
      { k = "accept", q = 179, name = "Dwarven Outfitters", level = 1, m = 1426, x = 0.30, y = 0.71, sec = 1, lvl = 1 },
      { k = "turnin", q = 179, name = "Dwarven Outfitters", level = 1, m = 1426, x = 0.30, y = 0.71, sec = 1, lvl = 2 },
      { k = "accept", q = 233, name = "Coldridge Valley Mail Delivery", level = 4, m = 1426, x = 0.30, y = 0.71, sec = 1, lvl = 4 },
      { k = "turnin", q = 233, name = "Coldridge Valley Mail Delivery", level = 4, m = 1426, x = 0.23, y = 0.80, sec = 1, lvl = 5 },
      { k = "accept", q = 287, name = "Frostmane Hold", level = 9, m = 1426, x = 0.46, y = 0.52, sec = 1, lvl = 6 },
      { k = "fly", dest = "Stormwind", text = "Stormwind", sec = 1 },
      { k = "accept", q = 333, name = "Harlan Needs a Resupply", level = 6, m = 1453, x = 0.5, y = 0.5, sec = 1, lvl = 7 },
    } }
    UnitLevel = function() return 5 end
    ns.Engine.Refresh()
    assertEquals(0, ns.char.join and ns.char.join.level, "a level 5 in the start zone was taken for someone joining")
    assertEquals(1, ns.Engine.Shown())
    for i = 1, 5 do assertTrue(not ns.Engine.IsDone(i), "step " .. i .. " of the start zone was passed") end
    -- out of the start zone the usual rule holds: at 12, what the plan did at 7 and below is passed
    UnitLevel = function() return 12 end; ns.char.join.seen = 12
    ns.Engine.Refresh()
    assertTrue(ns.Engine.IsDone(7))
  end)
  UnitLevel, ns.planKey, ns.Engine.placeReady = sv.lvl, sv.pk, sv.ready
  if not ok then error(err, 0) end
end)

test("flight path hint: level 10+ with at most one known flight path is asked to open a flight master's map, once that's done it goes", function()
  local sv = { lvl = UnitLevel, taxi = ns.State.knownTaxi, off = ns.db.hintTaxiOff }
  local ok, err = pcall(function()
    ns.db.hintTaxiOff = nil
    UnitLevel = function() return 30 end
    ns.State.knownTaxi = { ["Stormwind, Elwynn"] = true }
    assertTrue(ns.Hints.Check(), "no hint at 30 with one flight path known"); assertTrue(ForeverRouteHintBar:IsShown())
    ns.State.knownTaxi = { ["Stormwind, Elwynn"] = true, ["Southshore, Hillsbrad"] = true, ["Darkshire, Duskwood"] = true }
    ns.Fire("FR_TAXI_OPENED")
    assertTrue(not ForeverRouteHintBar:IsShown(), "the hint stayed after the flight paths were learned")
    UnitLevel = function() return 6 end; ns.State.knownTaxi = {}
    assertTrue(not ns.Hints.Check(), "a level 6 was asked")
    UnitLevel = function() return 30 end; ns.db.hintTaxiOff = true
    assertTrue(not ns.Hints.Check(), "dismissed for good, but shown again")
  end)
  UnitLevel, ns.State.knownTaxi, ns.db.hintTaxiOff = sv.lvl, sv.taxi, sv.off
  if ForeverRouteHintBar then ForeverRouteHintBar:Hide() end
  if not ok then error(err, 0) end
end)

-- (an error, not assertTrue: the simulator shows an error's message, an assert's only as "expected truthy")
local function must(ok, what) if not ok then error(what or "not so", 0) end end
-- the card up on the step it shows, laid out, its secure buttons placed
local function cardOn()
  local card = ForeverRouteCard
  ns.db.collapsed = nil; ns.Engine.view = nil
  card:Show(); ns.Card.Fill(); ns.Card.Layout(); ns.Card.PlaceSecure()
  return card
end
-- where something is on the screen, in UIParent's units: { l, r, t, b }
local function box(o)
  local s = ((o.GetEffectiveScale and o:GetEffectiveScale()) or o:GetParent():GetEffectiveScale()) / UIParent:GetEffectiveScale()
  local l, r, t, b = o:GetLeft(), o:GetRight(), o:GetTop(), o:GetBottom()
  if not (l and r and t and b) then return nil end
  return { l = l * s, r = r * s, t = t * s, b = b * s }
end
-- do two boxes share any area? (half a unit of slack: edges that touch are not on top of each other)
local function overlap(a, b) return a and b and a.l < b.r - 0.5 and b.l < a.r - 0.5 and a.b < b.t - 0.5 and b.b < a.t - 0.5 end
local function boxText(a) return a and string.format("%.0f-%.0f x %.0f-%.0f", a.l, a.r, a.b, a.t) or "nowhere" end
-- the Target button is where it belongs above the card: its left edge on the card's, the gap above the card's top
local function aboveCard(what)
  local t, card = ForeverRouteTargetButton, ForeverRouteCard
  local T, C = box(t), box(card)
  local S = card:GetEffectiveScale() / UIParent:GetEffectiveScale()
  if not t:IsShown() then error(what .. ": the Target button is hidden", 0) end
  if not (T and C) then error(what .. ": the Target button or the card has no place", 0) end
  if overlap(T, C) then error(what .. ": the Target button (" .. boxText(T) .. ") is on the card (" .. boxText(C) .. ")", 0) end
  if math.abs(T.l - C.l) > 0.6 or math.abs(T.b - (C.t + ns.Card.SECURE_GAP * S)) > 0.6 then
    error(what .. ": the Target button is at " .. boxText(T) .. ", not just above the card's top-left corner (" .. boxText(C) .. ")", 0)
  end
end
-- a pick-up with someone to target, then an objective with two bars, a target and an item to use (a taller card)
local function buttonRoute()
  return { id = "tb", title = "tb", sections = { { title = "x" } }, steps = {
    { k = "accept", q = 99783, name = "A Threat Within", npc = "Deputy Willem", m = 1429, x = 0.48, y = 0.43, sec = 1 },
    { k = "obj", q = 99783, text = "Kill 15 Kobold Vermin", match = "Vermin", target = "Kobold Vermin", item = 2589, m = 1429, x = 0.47, y = 0.36, r = 40, sec = 1 },
    { k = "obj", q = 99783, text = "Collect 8 Candles", match = "Candle", target = "Kobold Worker", m = 1429, x = 0.47, y = 0.36, r = 40, sec = 1 },
    { k = "turnin", q = 99783, name = "A Threat Within", npc = "Marshal McBride", m = 1429, x = 0.49, y = 0.42, sec = 1 },
  } }
end
local function onQuest(w)
  w:quest(99783, { on = true, objectives = { { text = "Kobold Vermin slain: 10/15", have = 10, need = 15 }, { text = "Candles: 2/8", have = 2, need = 8 } } })
end

test("Target button: floats just above the card (never on it) on the card's layer, follows the card; Ctrl-click doesn't target; Ctrl+drag spot kept; /fr target reset puts it back above the card - in a fight, once it ends", function()
  local sv = { pos = ns.db.targetPos, card = ns.db.cardPos, combat = InCombatLockdown, print = ns.Print }
  local said = {}
  local ok, err = pcall(ForeverRouteTest.withWorld, buttonRoute(), function(w)
    local t, item, card = ForeverRouteTargetButton, ForeverRouteItemButton, ForeverRouteCard
    ns.Print = function(m) said[#said + 1] = tostring(m) end
    ns.db.targetPos = nil
    card:Show(); ns.db.cardPos = { "ABS", 300, 600 }; ns.Card.ApplyPos()
    cardOn()
    assertEquals(card:GetFrameStrata(), t:GetFrameStrata(), "the Target button is not on the card's layer")
    must(t:GetFrameStrata() ~= "HIGH" and t:GetFrameStrata() ~= "DIALOG", "it floats over windows: " .. t:GetFrameStrata())
    must(t:GetFrameLevel() > card:GetFrameLevel(), "under the card: the card would take its clicks")
    assertEquals("macro", t:GetAttribute("ctrl-type1")); assertEquals("", t:GetAttribute("ctrl-macrotext1"))
    must(t:IsMovable(), "not movable")
    -- above the card's top edge, not in a row on it
    aboveCard("on a pick-up")
    assertEquals("above", card.cur.secureAt)
    must(not item:IsShown(), "the use-item button shows on a step with nothing to use")
    local top = box(t).t
    -- a taller card (objective bars, an item to use): the button has not moved, the item button is next to it
    onQuest(w); cardOn()
    assertEquals(2, w:shown()); must(card.cur.nbars >= 1, "no objective bar on the objective step")
    aboveCard("on an objective with bars")
    must(math.abs(box(t).t - top) < 0.6, "the button moved when the card grew")
    must(item:IsShown(), "no use-item button on a step with an item")
    local T, I = box(t), box(item)
    must(math.abs(I.l - (T.r + ns.Card.SECURE_GAP * card:GetEffectiveScale() / UIParent:GetEffectiveScale())) < 0.6 and math.abs(I.b - T.b) < 0.6, "the use-item button (" .. boxText(I) .. ") is not next to the Target button (" .. boxText(T) .. ")")
    must(not overlap(I, box(card)), "the use-item button is on the card")
    for k = 1, card.cur.nbars do must(not overlap(T, box(card.cur.bars[k])) and not overlap(I, box(card.cur.bars[k])), "a button is over objective bar " .. k) end
    -- the card dragged somewhere else: the buttons come with it
    card:ClearAllPoints(); card:SetPoint("CENTER", UIParent, "CENTER", -200, 40)
    card:GetScript("OnDragStop")(card)
    assertEquals("TOPLEFT", (card:GetPoint(1)), "a dragged card is not hung from its top")
    aboveCard("after dragging the card")
    -- a spot you dragged the button to is where it goes
    ns.db.targetPos = { 300, 400 }
    ns.Card.PlaceSecure()
    T = box(t)
    must(math.abs(T.l - 300) < 0.6 and math.abs(T.t - 400) < 0.6, "not at the dragged spot: " .. boxText(T))
    assertEquals("dragged", card.cur.secureAt)
    -- /fr target reset in a fight: the button can't move, and the addon says so (it said "back on the card")
    InCombatLockdown = function() return true end
    said = {}
    SlashCmdList["FOREVERROUTE"]("target reset")
    assertNil(ns.db.targetPos, "/fr target reset kept the spot")
    must(#said == 1 and said[1]:find("fight", 1, true) ~= nil, "in a fight /fr target reset said: " .. tostring(said[1]))
    must(not said[1]:find("button back", 1, true), "it says the button is back while it can't move")
    -- the fight over: back above the card
    InCombatLockdown = sv.combat
    ns.Fire("PLAYER_REGEN_ENABLED")
    aboveCard("after the fight that /fr target reset waited for")
    -- out of a fight: at once
    ns.db.targetPos = { 300, 400 }; ns.Card.PlaceSecure()
    said = {}
    SlashCmdList["FOREVERROUTE"]("target reset")
    assertNil(ns.db.targetPos)
    aboveCard("after /fr target reset")
    must(#said == 1 and said[1]:find("above the card", 1, true) ~= nil, "/fr target reset said: " .. tostring(said[1]))
    -- the card at the top of the screen: no room above it, so beside its top corner - on the screen, not on the card
    local W, H = UIParent:GetWidth(), UIParent:GetHeight()
    for _, c in ipairs({ { 300, "left" }, { 0, "right" } }) do
      ns.db.cardPos = { "ABS", c[1], H }; ns.Card.ApplyPos(); ns.Card.PlaceSecure()
      assertEquals(c[2], card.cur.secureAt, "the card at the top of the screen, its left edge at " .. c[1])
      for name, b in pairs({ Target = t, ["use-item"] = item }) do
        local B = box(b)
        must(not overlap(B, box(card)), "the " .. name .. " button is on the card when the card is at the top of the screen")
        must(B.l >= -0.5 and B.r <= W + 0.5 and B.b >= -0.5 and B.t <= H + 0.5, "the " .. name .. " button is off the screen: " .. boxText(B))
      end
    end
    -- a step with no one to target and nothing to use: no buttons
    ns.Card.SetButtons(nil); ns.Card.PlaceSecure()
    must(not t:IsShown() and not item:IsShown(), "buttons on a step with no one to target")
  end, { anyTarget = true })
  InCombatLockdown, ns.Print = sv.combat, sv.print
  ns.db.targetPos, ns.db.cardPos = sv.pos, sv.card
  if ns.Card.ApplyPos then ns.Card.ApplyPos() end
  if not ok then error(err, 0) end
end)

test("the 'not doing this quest' (red X) and 'giver doesn't offer it' buttons are small icons beside Map with a tooltip each: never over the title, the detail, the distance, Map, an objective's count or the note, at every card width and scale", function()
  local sv = { w = ns.db.cardWidth, ui = ns.db.uiScale, pos = ns.db.cardPos, tp = ns.db.targetPos }
  local route = { id = "nl", title = "nl", sections = { { title = "x" } }, steps = {
    { k = "accept", q = 99783, name = "A Threat Within the Walls of the Abbey of Northshire", npc = "Deputy Willem", zone = "Northshire Valley", m = 1429, x = 0.48, y = 0.43, sec = 1, note = "He stands outside the abbey, by the road." },
    { k = "obj", q = 99783, text = "Kill 15 Kobold Vermin behind the abbey and in the fields north of it", match = "Vermin", target = "Kobold Vermin", zone = "Northshire Valley", m = 1429, x = 0.47, y = 0.36, r = 40, sec = 1, note = "They are all round the field." },
    { k = "obj", q = 99783, text = "Collect 8 Candles", match = "Candle", m = 1429, x = 0.47, y = 0.36, r = 40, sec = 1 },
    { k = "turnin", q = 99783, name = "A Threat Within", npc = "Marshal McBride", m = 1429, x = 0.49, y = 0.42, sec = 1 },
  } }
  local ok, err = pcall(ForeverRouteTest.withWorld, route, function(w)
    local card = ForeverRouteCard
    local cur = card.cur
    ns.db.targetPos = nil
    card:Show(); ns.db.cardPos = { "ABS", 100, 900 }; ns.Card.ApplyPos()
    local wrapped, both, bars = false, false, false
    local function check(what)
      cur.dist:SetText("1234 yd")
      local links = {}
      for name, b in pairs({ ["not doing this quest"] = cur.nope, ["giver doesn't offer it"] = cur.notOffered }) do if b:IsShown() then links[name] = box(b) end end
      assertNotNil(links["not doing this quest"], what .. ": no 'not doing this quest' on a quest step")
      -- icons, not words: no bigger than the tool row's height, a tooltip that says what each does, the X in red
      -- ("not just giant text, red x and tooltips seem more useful here" - tester)
      for name, b in pairs({ ["not doing this quest"] = cur.nope, ["giver doesn't offer it"] = cur.notOffered }) do
        if b:IsShown() then
          must(b:GetWidth() <= ns.Card.TOOL + 0.5 and b:GetHeight() <= ns.Card.TOOL + 0.5, what .. ": '" .. name .. "' is " .. b:GetWidth() .. " wide, not an icon")
          must(type(b.tip) == "table" and #b.tip >= 2 and #b.tip[2] > 20, what .. ": '" .. name .. "' has no tooltip that explains it")
          if cur.map:IsShown() then must(math.abs(b:GetTop() - cur.map:GetTop()) < 0.5, what .. ": '" .. name .. "' is not in the row with Map") end
        end
      end
      local r, g = cur.nope.icon:GetVertexColor()
      must(r > 0.9 and g < 0.5, what .. ": the 'not doing this quest' X is not red")
      local others = { title = box(cur.titleText), distance = box(cur.dist) }
      if (cur.detail:GetText() or "") ~= "" then others.detail = box(cur.detail) end
      if cur.map:IsShown() then others.Map = box(cur.map) end
      if (cur.note:GetText() or "") ~= "" then others.note = box(cur.note) end
      for k = 1, cur.nbars do others["objective bar " .. k] = box(cur.bars[k]); others["the count of objective " .. k] = box(cur.bars[k].value) end
      if ForeverRouteTargetButton:IsShown() then others["the Target button"] = box(ForeverRouteTargetButton) end
      local C, K = box(cur), box(card)
      for name, L in pairs(links) do
        for other, O in pairs(others) do
          if overlap(L, O) then error(what .. ": '" .. name .. "' (" .. boxText(L) .. ") lies over " .. other .. " (" .. boxText(O) .. ")", 0) end
        end
        if L.l < C.l - 0.5 or L.r > C.r + 0.5 or L.b < K.b - 0.5 or L.t > K.t + 0.5 then error(what .. ": '" .. name .. "' (" .. boxText(L) .. ") sticks out of the card (" .. boxText(K) .. ")", 0) end
      end
      if links["giver doesn't offer it"] then
        both = true
        if overlap(links["not doing this quest"], links["giver doesn't offer it"]) then error(what .. ": the two links lie over each other", 0) end
      end
      if cur.titleText:GetStringHeight() > 24 then wrapped = true end
      if cur.nbars > 0 then bars = true end
    end
    for _, width in ipairs({ 280, 360, 520 }) do
      for _, scale in ipairs({ 0.6, 1, 2.5 }) do
        ns.db.cardWidth, ns.db.uiScale = width, scale
        ns.Fire("FR_SETTINGS"); w:wait(0.1)
        w.quests[99783] = nil; ns.Engine.Refresh(); cardOn()
        assertEquals(1, w:shown())
        check("a pick-up, card " .. width .. " wide at scale " .. scale)
        onQuest(w); cardOn()
        assertEquals(2, w:shown())
        check("an objective, card " .. width .. " wide at scale " .. scale)
      end
    end
    must(wrapped, "no title ran to a second line: the test checks nothing about one")
    must(both, "'giver doesn't offer it' never showed")
    must(bars, "no objective bar ever showed")
  end, { anyTarget = true })
  ns.db.cardWidth, ns.db.uiScale, ns.db.cardPos, ns.db.targetPos = sv.w, sv.ui, sv.pos, sv.tp
  ns.Fire("FR_SETTINGS")
  if ns.Card.ApplyPos then ns.Card.ApplyPos() end
  if not ok then error(err, 0) end
end)

test("saved data stays small: no companion -> no walking trails or learning recorded, old ones cleared; trails capped overall", function()
  local sv = { byChar = ForeverRouteByChar, trail = ForeverRouteDB.trailData, learn = ForeverRouteDB.learn, cap = ns.Trails.TOTAL_BYTES }
  local ok, err = pcall(function()
    -- with the companion's plan file: kept
    ForeverRouteByChar = { ["Someone-Realm"] = function() end }
    assertTrue(ns.HasCompanion())
    ForeverRouteDB.trailData = { [1453] = { "0.1,0.1;0.2,0.2;0.3,0.3" } }; ForeverRouteDB.learn = { pace = { { k = "Kill", need = 5, sec = 60 } } }
    assertEquals(0, ns.Storage.Clean()); assertNotNil(ForeverRouteDB.trailData)
    -- an addon-site install: nothing to read them, so they go
    ForeverRouteByChar = nil
    assertTrue(not ns.HasCompanion())
    assertTrue(ns.Storage.Clean() > 0)
    assertNil(ForeverRouteDB.trailData, "trails kept without the companion"); assertNil(ForeverRouteDB.learn, "learning kept without the companion")
    -- all trails together under the cap: the biggest map's oldest go first
    ForeverRouteByChar = { ["Someone-Realm"] = function() end }
    local long = string.rep("0.1234,0.5678;", 50)
    ForeverRouteDB.trailData = { [1453] = { long, long, long, long }, [1429] = { long } }
    ns.Trails.TOTAL_BYTES = #long * 3
    local left = ns.Trails.Trim()
    assertTrue(left <= ns.Trails.TOTAL_BYTES, "over the cap: " .. left)
    assertEquals(2, #ForeverRouteDB.trailData[1453]); assertEquals(1, #ForeverRouteDB.trailData[1429])
    -- sizes for /fr storage
    assertTrue(#ns.Storage.Parts() > 0)
  end)
  ForeverRouteByChar, ForeverRouteDB.trailData, ForeverRouteDB.learn, ns.Trails.TOTAL_BYTES = sv.byChar, sv.trail, sv.learn, sv.cap
  if not ok then error(err, 0) end
end)

-- ---- scale and readability (a tester at 3840x1600 with ElvUI's UI scale 0.48: one pixel per UI unit, so our size-9
-- to 11 text was 9-11 px tall, and only the card and the arrow could be scaled) ----
local function withScreen(physH, uiScale, fn)
  local Style = ns.Style
  local sv = { phys = GetPhysicalScreenSize, scale = UIParent:GetScale(), ui = ns.db.uiScale, card = ns.db.scale, arrow = ns.db.arrowScale, off = ns.db.hintScaleOff }
  GetPhysicalScreenSize = function() return physH * 2, physH end
  UIParent:SetScale(uiScale)
  ns.db.uiScale, ns.db.scale, ns.db.arrowScale, ns.db.hintScaleOff = nil, 1, 1, nil
  Style.ApplyScale()
  local ok, err = pcall(fn, Style)
  GetPhysicalScreenSize = sv.phys
  UIParent:SetScale(sv.scale)
  ns.db.uiScale, ns.db.scale, ns.db.arrowScale, ns.db.hintScaleOff = sv.ui, sv.card, sv.arrow, sv.off
  ns.Fire("FR_SETTINGS")
  if ForeverRouteScaleBar then ForeverRouteScaleBar:Hide() end
  if not ok then error(err, 0) end
end
local function near(a, b, what) if math.abs(a - b) > 0.002 then error(what .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 0) end end

test("Scale: our frames follow the game's UI scale (children of UIParent, nothing ignores it), at any UI scale", function()
  for _, ui in ipairs({ 1, 0.48, 0.65 }) do
    withScreen(1600, ui, function()
      for _, name in ipairs({ "ForeverRouteCard", "ForeverRouteList", "ForeverRoutePaths", "ForeverRouteTargetButton", "ForeverRouteItemButton" }) do
        local fr = _G[name]
        assertNotNil(fr, name .. " is missing")
        if fr:GetParent() ~= UIParent then error(name .. " is not a child of UIParent", 0) end
        if fr.IsIgnoringParentScale and fr:IsIgnoringParentScale() then error(name .. " ignores the game's UI scale", 0) end
      end
      near(ForeverRouteCard:GetEffectiveScale(), UIParent:GetEffectiveScale(), "the card's effective scale at UI scale " .. ui)
      near(ForeverRouteList:GetEffectiveScale(), UIParent:GetEffectiveScale(), "the list's effective scale at UI scale " .. ui)
    end)
  end
end)

test("Scale: one Forever Route scale for the card, the arrow, the list and every window; card and arrow keep their own on top", function()
  withScreen(1600, 0.48, function(Style)
    ns.db.uiScale = 1.4; ns.db.scale = 1.5; ns.db.arrowScale = 2
    ns.Fire("FR_SETTINGS")
    near(ForeverRouteCard:GetScale(), 1.4 * 1.5, "the card (scale x card scale)")
    if ForeverRouteArrow then near(ForeverRouteArrow:GetScale(), 1.4 * 2, "the arrow (scale x arrow scale)") end
    local n = 0
    for _, name in ipairs({ "ForeverRouteList", "ForeverRoutePaths", "ForeverRouteDungeons", "ForeverRouteLogCheck", "ForeverRouteReport", "ForeverRouteNews", "ForeverRouteOptionsWindow" }) do
      local fr = _G[name]
      if fr then n = n + 1; near(fr:GetScale(), 1.4, name) end
    end
    assertTrue(n >= 4, "only " .. n .. " of the windows exist to be checked")
    -- the bars under the card are its children: they follow it
    if ForeverRouteHintBar then near(ForeverRouteHintBar:GetEffectiveScale(), ForeverRouteCard:GetEffectiveScale(), "the hint bar") end
    -- back to 1: everything as before
    ns.db.uiScale = nil; ns.db.scale = 1; ns.Fire("FR_SETTINGS")
    near(ForeverRouteCard:GetScale(), 1, "the card after going back"); near(ForeverRouteList:GetScale(), 1, "the list after going back")
    -- out of range is clamped
    ns.db.uiScale = 9; ns.Fire("FR_SETTINGS"); near(Style.UIScale(), Style.SCALE_MAX, "an absurd scale")
  end)
end)

test("Scale: the Target and item buttons keep the card's size and their place above it when the Forever Route scale changes", function()
  local sv = { pos = ns.db.targetPos, card = ns.db.cardPos }
  local ok, err = pcall(ForeverRouteTest.withWorld, buttonRoute(), function(w)
    withScreen(1600, 0.48, function()
      local t, item, card = ForeverRouteTargetButton, ForeverRouteItemButton, ForeverRouteCard
      ns.db.targetPos = nil
      onQuest(w)
      for _, s in ipairs({ 0.6, 1, 1.4, 2.5 }) do
        -- (the place in screen units: the game multiplies a frame's offsets by its scale)
        local top = UIParent:GetHeight() - 100
        ns.db.cardPos = { "ABS", 100, top }
        ns.db.uiScale = s; ns.Fire("FR_SETTINGS"); w:wait(0.1)
        cardOn()
        near(t:GetEffectiveScale(), card:GetEffectiveScale(), "the Target button's effective scale at " .. s)
        near(item:GetEffectiveScale(), card:GetEffectiveScale(), "the use-item button's effective scale at " .. s)
        local C = box(card)
        must(math.abs(C.l - 100) < 0.6 and math.abs(C.t - top) < 0.6, "the card moved with the scale: " .. boxText(C) .. " at " .. s)
        aboveCard("at scale " .. s)
        local T, I = box(t), box(item)
        local S = card:GetEffectiveScale() / UIParent:GetEffectiveScale()
        must(math.abs((T.r - T.l) - ns.Card.TARGET_W * S) < 0.6, "the Target button is " .. (T.r - T.l) .. " wide at scale " .. s)
        must(item:IsShown() and not overlap(I, C) and math.abs(I.l - (T.r + ns.Card.SECURE_GAP * S)) < 0.6, "the use-item button (" .. boxText(I) .. ") is not next to the Target button (" .. boxText(T) .. ") at scale " .. s)
        -- a spot you dragged it to stays the same spot on the screen at any scale
        ns.db.targetPos = { 640, 320 }; ns.Card.PlaceSecure()
        T = box(t)
        must(math.abs(T.l - 640) < 0.6 and math.abs(T.t - 320) < 0.6, "the dragged spot moved with the scale: " .. boxText(T) .. " at " .. s)
        ns.db.targetPos = nil
      end
    end)
  end, { anyTarget = true })
  ns.db.targetPos, ns.db.cardPos = sv.pos, sv.card
  if ns.Card.ApplyPos then ns.Card.ApplyPos() end
  if not ok then error(err, 0) end
end)

test("Scale: a window never grows past the screen", function()
  withScreen(768, 1, function(Style) -- 768 units tall: the smallest screen there is
    ns.db.uiScale = 2.5; ns.Fire("FR_SETTINGS")
    local l = ForeverRouteList
    l:Hide(); l:Show()
    assertTrue(l:GetHeight() * l:GetScale() <= UIParent:GetHeight() + 0.5, "the route list is taller than the screen: " .. l:GetHeight() * l:GetScale() .. " of " .. UIParent:GetHeight())
    assertTrue(l:GetWidth() * l:GetScale() <= UIParent:GetWidth() + 0.5, "the route list is wider than the screen")
    l:Hide()
  end)
end)

test("Scale: a bigger scale is suggested only where text is small, offered once in a bar, applied on a click, never by itself", function()
  -- the default UI scale: 2560x1440 (1.875 px per unit) and 1920x1080 (1.41): nothing to suggest
  withScreen(1440, 1, function(Style) assertNil(Style.SuggestScale(), "suggested at 1440p"); assertNil(ns.Hints.ScaleDue()); assertTrue(not ns.Hints.CheckScale(), "bar at 1440p") end)
  withScreen(1080, 1, function(Style) assertNil(Style.SuggestScale(), "suggested at 1080p"); assertTrue(not ns.Hints.CheckScale(), "bar at 1080p") end)
  -- the tester: 3840x1600, ElvUI's UI scale 0.48 = one pixel per unit
  withScreen(1600, 0.48, function(Style)
    near(Style.PxPerUnit(), 1.0, "pixels per unit at 1600 / 0.48")
    near(Style.SuggestScale(), 1.4, "the suggestion at one pixel per unit")
    near(ForeverRouteCard:GetScale(), 1, "the card was scaled without being asked")
    assertTrue(ns.Hints.CheckScale(), "no bar on the tester's screen"); assertTrue(ForeverRouteScaleBar:IsShown())
    assertNil(ns.db.uiScale, "showing the bar changed the scale")
    -- the click
    ForeverRouteScaleBar.go:GetScript("OnClick")(ForeverRouteScaleBar.go)
    near(ns.db.uiScale, 1.4, "the scale after the click"); near(ForeverRouteCard:GetScale(), 1.4, "the card after the click"); near(ForeverRouteList:GetScale(), 1.4, "the list after the click")
    assertTrue(not ForeverRouteScaleBar:IsShown(), "the bar stayed"); assertTrue(not ns.Hints.CheckScale(), "offered again after a scale was chosen")
    near(Style.PxPerUnit(ForeverRouteCard), 1.4, "the card's pixels per unit after the click")
  end)
  -- dismissed: for good, and nothing changed
  withScreen(1600, 0.48, function()
    ns.db.hintScaleOff = true
    assertTrue(not ns.Hints.CheckScale(), "dismissed, but shown again"); assertNil(ns.db.uiScale)
  end)
  -- the card already scaled up by hand (Card scale 1.5): no nagging
  withScreen(1600, 0.48, function() ns.db.scale = 1.5; ns.Fire("FR_SETTINGS"); assertTrue(not ns.Hints.CheckScale(), "offered although the card is already 1.5x") end)
  -- 4K with a pixel-perfect UI scale (ElvUI holds it at 0.4): suggested, inside the slider's range
  withScreen(2160, 0.4, function(Style) local s = Style.SuggestScale(); assertNotNil(s); assertTrue(s >= 1.05 and s <= Style.SCALE_MAX, "suggestion out of range: " .. tostring(s)) end)
end)

test("Scale: /fr scale shows, sets, takes the suggestion and resets", function()
  withScreen(1600, 0.48, function(Style)
    local said = {}
    local svp = ns.Print; ns.Print = function(m) said[#said + 1] = m end
    local ok, err = pcall(function()
      SlashCmdList["FOREVERROUTE"]("scale"); assertNil(ns.db.uiScale, "/fr scale alone changed it")
      assertTrue(said[1] and said[1]:find("1600", 1, true) and said[1]:find("0.480", 1, true) and said[1]:find("suggested", 1, true), "/fr scale said: " .. tostring(said[1]))
      SlashCmdList["FOREVERROUTE"]("scale 1.25"); near(ns.db.uiScale, 1.25, "/fr scale 1.25"); near(ForeverRouteList:GetScale(), 1.25, "the list after /fr scale 1.25")
      SlashCmdList["FOREVERROUTE"]("scale auto"); near(ns.db.uiScale, 1.4, "/fr scale auto")
      SlashCmdList["FOREVERROUTE"]("scale reset"); assertNil(ns.db.uiScale, "/fr scale reset")
    end)
    ns.Print = svp
    if not ok then error(err, 0) end
  end)
end)

test("Readable: no text of ours under size 10 (map pin numbers aside), secondary text has enough contrast", function()
  local Style = ns.Style
  local function size(font) local _, s = font:GetFont(); return s end
  near(size(Style.Font(9)), 10, "Style.Font(9)"); near(size(Style.Font(8, "OUTLINE")), 10, "Style.Font(8, OUTLINE)"); near(size(Style.Font(11)), 11, "Style.Font(11)")
  near(size(Style.Font(8, nil, true)), 8, "a map pin's number (tiny)")
  -- every text on the card and in the route list
  local seen, small = 0, nil
  local function walk(fr, depth)
    for _, r in ipairs({ fr:GetRegions() }) do
      if r.GetFont and r.GetText then local _, s = r:GetFont(); if s then seen = seen + 1; if s < 9.99 then small = small or (tostring(r:GetText()) .. " at " .. s) end end end
    end
    if depth < 6 then for _, ch in ipairs({ fr:GetChildren() }) do walk(ch, depth + 1) end end
  end
  walk(ForeverRouteCard, 0); walk(ForeverRouteList, 0)
  assertTrue(seen > 10, "found only " .. seen .. " texts to check")
  if small then error("text under size 10: " .. small, 0) end
  -- contrast against the panel fill (WCAG relative luminance): small text wants 4.5:1; dim was 4.2:1
  local function lum(c) local function l(v) return v <= 0.03928 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4 end return 0.2126 * l(c[1]) + 0.7152 * l(c[2]) + 0.0722 * l(c[3]) end
  local function ratio(a, b) local x, y = lum(a) + 0.05, lum(b) + 0.05; return x > y and x / y or y / x end
  local C = Style.C
  for _, bg in ipairs({ C.bg, C.bg2 }) do
    assertTrue(ratio(C.dim, bg) >= 6, "dim text contrast " .. ratio(C.dim, bg)); assertTrue(ratio(C.sub, bg) >= 9, "sub text contrast " .. ratio(C.sub, bg))
    assertTrue(ratio(C.sub, bg) > ratio(C.dim, bg) + 2 and ratio(C.text, bg) > ratio(C.sub, bg) + 2, "text, sub and dim are no longer three distinct steps")
  end
  -- the dim written into lines of text is the same dim
  assertEquals("|cff8e99ad", Style.Hex(C.dim))
end)

----------------------------------------------------------------------------------------------------------------
-- A step in your own zone goes through the trip planner too: a flight you know that lands much nearer the spot is
-- offered when it clearly beats the walk (reported from Darkshire with a hand-in at Sven's camp, the far west end of
-- Duskwood: the card said walk; Sentinel Hill is a short walk from that border).
----------------------------------------------------------------------------------------------------------------
-- the real maps (the planner's zone bounds) and the real network, at a level that is safe in Duskwood
local function shortcutWorld(fn)
  local HBD = LibStub("HereBeDragons-2.0")
  local B = ns.TravelData.BOUNDS
  local sv = { conv = HBD.GetWorldCoordinatesFromZone, pos = ns.State.Position, taxi = ns.State.knownTaxi, info = C_Map.GetMapInfo, data = ForeverRouteData,
    lvl = UnitLevel, inn = ns.Travel.HearthInn, onTaxi = UnitOnTaxi, flight = ns.FLIGHT, saves = ns.Travel.SHORTCUT_SAVES, share = ns.Travel.SHORTCUT_SHARE, slower = ns.Travel.SHORTCUT_SLOWER }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) local b = B[m]; if not b then return nil end return b[1] + x * (b[2] - b[1]), b[3] + y * (b[4] - b[3]), b[5] end
  local names = { [1431] = "Duskwood", [1436] = "Westfall", [1433] = "Redridge Mountains", [1429] = "Elwynn Forest", [1453] = "Stormwind City", [1444] = "Feralas" }
  C_Map.GetMapInfo = function(m) return names[m] and { name = names[m] } or (sv.info and sv.info(m)) end
  UnitLevel = function() return 28 end
  UnitOnTaxi = function() return false end
  ns.Travel.HearthInn = function() return nil end
  ns.FLIGHT = ns.FLIGHT_BY.Alliance
  local w = { at = { 1431, 0.7749, 0.4429 } } -- beside Felicia Maline, Darkshire's flight master
  ns.State.Position = function() return w.at[1], w.at[2], w.at[3] end
  local ok, err = pcall(fn, w)
  HBD.GetWorldCoordinatesFromZone, ns.State.Position, ns.State.knownTaxi, C_Map.GetMapInfo, ForeverRouteData = sv.conv, sv.pos, sv.taxi, sv.info, sv.data
  UnitLevel, ns.Travel.HearthInn, UnitOnTaxi, ns.FLIGHT, ns.Travel.SHORTCUT_SAVES, ns.Travel.SHORTCUT_SHARE, ns.Travel.SHORTCUT_SLOWER = sv.lvl, sv.inn, sv.onTaxi, sv.flight, sv.saves, sv.share, sv.slower
  if not ok then error(err, 0) end
end
local function sven() return { k = "turnin", q = 164, name = "Deliveries to Sven", npc = "Sven Yorgen", m = 1431, x = 0.0778, y = 0.3407, zone = "Duskwood", r = 6 } end

test("same zone: Darkshire to Sven's camp flies to Sentinel Hill and walks back across the border", function()
  shortcutWorld(function(w)
    ns.State.knownTaxi = { ["Darkshire, Duskwood"] = true, ["Sentinel Hill, Westfall"] = true, ["Stormwind, Elwynn"] = true }
    local s = sven()
    ForeverRouteData = { id = "t", steps = { s } }
    local t = ns.Engine.TravelFor(s)
    assertNotNil(t, "no trip: the card would say walk")
    assertTrue(t.shortcut == true)
    assertEquals("fly", t.how)
    -- the arrow goes to Darkshire's flight master first
    assertEquals(1431, t.m); assertTrue(math.abs(t.x - 0.7749) < 0.001 and math.abs(t.y - 0.4429) < 0.001)
    assertTrue(t.legs[1].text:find("Fly to Westfall", 1, true) ~= nil, t.legs[1].text)
    assertTrue(t.legs[1].text:find("quicker than walking", 1, true) ~= nil, t.legs[1].text)
    assertEquals("ride", t.legs[2].how)
    assertTrue(t.legs[2].text:find("Sven Yorgen", 1, true) ~= nil, t.legs[2].text)
    -- and it is a clear win, not a coin flip
    local _, secs, walk = ns.Travel.Shortcut({ m = 1431, x = 0.7749, y = 0.4429 }, { m = 1431, x = 0.0778, y = 0.3407 })
    assertTrue(secs <= walk - 45, "flight " .. tostring(secs) .. " s, walk " .. tostring(walk) .. " s")
    assertTrue(secs <= walk * 0.85)
  end)
end)

test("same zone: no flight when you lack the flight path, when the step is near, or once you have walked most of the way", function()
  shortcutWorld(function(w)
    -- Sentinel Hill not known: nothing lands nearer than you are
    ns.State.knownTaxi = { ["Darkshire, Duskwood"] = true, ["Stormwind, Elwynn"] = true, ["Lakeshire, Redridge"] = true }
    local s = sven(); ForeverRouteData = { id = "t", steps = { s } }
    local t0 = ns.Engine.TravelFor(s)
    if t0 then error("offered without the Sentinel Hill flight path: " .. tostring(t0.text), 0) end
    ns.State.knownTaxi = { ["Darkshire, Duskwood"] = true, ["Sentinel Hill, Westfall"] = true }
    -- a step in Darkshire, and one in the middle of the zone: a walk
    local near = { k = "turnin", q = 66, name = "The Legend of Stalvan", npc = "Clerk Daltry", m = 1431, x = 0.7254, y = 0.4687, zone = "Duskwood" }
    assertNil(ns.Engine.TravelFor(near))
    local mid = { k = "obj", q = 95, text = "middle of Duskwood", m = 1431, x = 0.4985, y = 0.7771, zone = "Duskwood" }
    assertNil(ns.Engine.TravelFor(mid))
    -- Sven again, but you are already at Raven Hill: walking on is quicker than going back
    w.at = { 1431, 0.20, 0.50 }
    assertNil(ns.Engine.TravelFor(sven()))
    -- a route's own "Fly to Duskwood" step is done on arrival, never a trip inside the zone
    assertNil(ns.Engine.TravelFor({ k = "fly", to = 1431, dest = "Duskwood", text = "Duskwood" }))
    -- your hearthstone is never spent on a walk inside one zone (bound in Darkshire, standing at Sven's camp)
    w.at = { 1431, 0.0778, 0.3407 }
    ns.State.knownTaxi = { ["Darkshire, Duskwood"] = true } -- (with Sentinel Hill too, the flight back east is offered: the same trip the other way)
    ns.Travel.HearthInn = function() return { m = 1431, x = 0.7386, y = 0.4440, name = "Innkeeper Trelayne", bind = "Darkshire" } end
    assertNil(ns.Engine.TravelFor({ k = "turnin", q = 66, name = "The Legend of Stalvan", npc = "Clerk Daltry", m = 1431, x = 0.7254, y = 0.4687, zone = "Duskwood" }))
  end)
end)

test("same zone: the flight has to win by a margin, and the walk it is held against is the better of two guesses", function()
  shortcutWorld(function(w)
    ns.State.knownTaxi = { ["Darkshire, Duskwood"] = true, ["Sentinel Hill, Westfall"] = true }
    local from, to = { m = 1431, x = 0.7749, y = 0.4429 }, { m = 1431, x = 0.0778, y = 0.3407 }
    local legs, secs, walk = ns.Travel.Shortcut(from, to)
    assertNotNil(legs)
    local _, foot = ns.Travel.Plan({ m = 1431, x = 0.7749, y = 0.4429 }, { m = 1431, x = 0.0778, y = 0.3407 }, { ground = true })
    assertNotNil(foot); assertTrue(walk <= foot + 0.001, "the walk is the planner's own time on foot at most")
    -- on foot only: no flight leg in a ground plan
    local g = ns.Travel.Plan({ m = 1431, x = 0.7749, y = 0.4429 }, { m = 1431, x = 0.0778, y = 0.3407 }, { ground = true })
    for _, l in ipairs(g) do assertEquals("ride", l.how) end
    -- ask for more than the flight saves in time spent playing (its time on foot, and its time in the air at
    -- AFK_WEIGHT): walk
    local _, s2, afk = ns.Travel.Plan({ m = 1431, x = 0.7749, y = 0.4429 }, { m = 1431, x = 0.0778, y = 0.3407 }, { hearth = false })
    local playing = (s2 - afk) + afk * ns.Travel.AFK_WEIGHT
    ns.Travel.SHORTCUT_SAVES = (walk - playing) + 5
    assertNil(ns.Travel.Shortcut({ m = 1431, x = 0.7600, y = 0.4900 }, { m = 1431, x = 0.0778, y = 0.3407 })) -- (another spot: what was decided for a spot holds there)
  end)
end)

test("same zone: a flight that is about as quick as the walk but keeps you off your feet is taken - flying is time away, walking is not (the player)", function()
  shortcutWorld(function(w)
    ns.State.knownTaxi = { ["Darkshire, Duskwood"] = true, ["Sentinel Hill, Westfall"] = true }
    local from, to = { m = 1431, x = 0.7749, y = 0.4429 }, { m = 1431, x = 0.0778, y = 0.3407 }
    local _, walk = ns.Travel.Plan({ m = from.m, x = from.x, y = from.y }, { m = to.m, x = to.x, y = to.y }, { ground = true })
    local _, secs, afk = ns.Travel.Plan({ m = from.m, x = from.x, y = from.y }, { m = to.m, x = to.x, y = to.y }, { hearth = false })
    assertTrue(afk > 0, "the trip has a flight in it")
    local playing = (secs - afk) + afk * ns.Travel.AFK_WEIGHT
    -- a margin the clock time doesn't make but the time spent playing does: the flight, said as "less on foot"
    ns.Travel.SHORTCUT_SHARE = 0
    ns.Travel.SHORTCUT_SAVES = math.max(1, ((walk - secs) + (walk - playing)) / 2)
    if walk - secs < ns.Travel.SHORTCUT_SAVES then
      local legs = ns.Travel.Shortcut({ m = from.m, x = from.x, y = from.y }, { m = to.m, x = to.x, y = to.y })
      assertNotNil(legs, "a flight that saves time spent playing, not clock time, is taken")
      assertTrue(legs[1].text:find("less on foot", 1, true) ~= nil, legs[1].text)
    end
    -- but not one much slower on the clock than the walk
    ns.Travel.SHORTCUT_SAVES = 1
    ns.Travel.SHORTCUT_SLOWER = (secs / walk) - 1.05
    assertNil(ns.Travel.Shortcut({ m = from.m, x = 0.7700, y = 0.4600 }, { m = to.m, x = to.x, y = to.y }))
  end)
end)

test("same zone: asked again from the same spot, nothing is planned twice; a short walk plans nothing at all", function()
  shortcutWorld(function(w)
    ns.State.knownTaxi = { ["Darkshire, Duskwood"] = true, ["Sentinel Hill, Westfall"] = true }
    local plans, real = 0, ns.Travel.Plan
    ns.Travel.Plan = function(...) plans = plans + 1; return real(...) end
    local ok, err = pcall(function()
      local to = function() return { m = 1431, x = 0.0778, y = 0.3407 } end
      local a = ns.Travel.Shortcut({ m = 1431, x = 0.7700, y = 0.4600 }, to())
      assertNotNil(a); assertTrue(plans > 0)
      local n = plans
      local b = ns.Travel.Shortcut({ m = 1431, x = 0.7701, y = 0.4601 }, to()) -- a step further: the same 40 yd cell
      assertTrue(a == b, "the same legs"); assertEquals(n, plans)
      -- a step in sight
      assertNil(ns.Travel.Shortcut({ m = 1431, x = 0.7700, y = 0.4600 }, { m = 1431, x = 0.70, y = 0.47 })); assertEquals(n, plans)
      -- a long walk with no second flight path: nothing a flight could do
      ns.State.knownTaxi = { ["Darkshire, Duskwood"] = true }
      assertNil(ns.Travel.Shortcut({ m = 1431, x = 0.7700, y = 0.4600 }, to())); assertEquals(n, plans)
    end)
    ns.Travel.Plan = real
    if not ok then error(err, 0) end
  end)
end)

test("same zone: when the flight stops being worth it, card and arrow change together", function()
  local route = { id = "sc", title = "sc", sections = { { title = "Duskwood" } }, steps = {
    { id = 1, k = "turnin", q = 164, name = "Deliveries to Sven", npc = "Sven Yorgen", m = 1431, x = 0.0778, y = 0.3407, zone = "Duskwood", r = 6, sec = 1 },
  } }
  local svInn, svInfo = ns.Travel.HearthInn, C_Map.GetMapInfo
  ns.Travel.HearthInn = function() return nil end
  local names = { [1431] = "Duskwood", [1436] = "Westfall" }
  C_Map.GetMapInfo = function(m) return names[m] and { name = names[m] } or (svInfo and svInfo(m)) end
  local ok, err = pcall(withWorld, route, function(w)
    w:knows({ "Darkshire, Duskwood", "Sentinel Hill, Westfall" })
    w.quests[164] = { on = true, complete = true, objectives = {} }
    w:go(1431, 0.76, 0.45) -- Darkshire
    local HBD = LibStub("HereBeDragons-2.0")
    ns.Engine.UpdateFocus(HBD:GetPlayerWorldPosition()) -- what the arrow does once a second
    ns.Arrow.SetTarget(ns.Engine.Shown(), true)
    local t = ns.Arrow.Current()
    assertEquals("fly", t.leg); assertTrue(math.abs(t.x - 0.7749) < 0.001, "the arrow points at the flight master")
    assertTrue(ns.Engine.TravelFor(route.steps[1]).shortcut)
    -- walked west instead: past the middle of the zone the walk wins; the arrow lets go of the flight master
    w:go(1431, 0.30, 0.45)
    assertNil(ns.Engine.TravelFor(route.steps[1]))
    ns.Engine.UpdateFocus(HBD:GetPlayerWorldPosition()) -- what the arrow does once a second
    t = ns.Arrow.Current()
    assertNil(t.leg); assertTrue(math.abs(t.x - 0.0778) < 0.001, "the arrow points at Sven")
    -- and back at Darkshire it is offered again
    w:go(1431, 0.76, 0.45)
    ns.Engine.UpdateFocus(HBD:GetPlayerWorldPosition())
    assertEquals("fly", ns.Arrow.Current().leg)
  end, { at = { m = 1431, x = 0.60, y = 0.45, level = 28 } })
  ns.Travel.HearthInn, C_Map.GetMapInfo = svInn, svInfo
  if not ok then error(err, 0) end
end)

test("flight points: one of a zone's two flight paths is not both (Feralas: Thalanaar, not Feathermoon)", function()
  shortcutWorld(function(w)
    local K = ns.Travel.KnowsFlightPoint
    ns.State.knownTaxi = { ["Thalanaar, Feralas"] = true }
    assertTrue(K(1444, "Thyssiana")); assertFalse(K(1444, "Fyldren Moonfeather"))
    ns.State.knownTaxi = { ["Thalanaar, Feralas"] = true, ["Feathermoon, Feralas"] = true }
    assertTrue(K(1444, "Thyssiana")); assertTrue(K(1444, "Fyldren Moonfeather"))
    -- names the data does not know (another language): the zone's name decides, as before
    ns.State.knownTaxi = { ["Somewhere, Feralas"] = true }
    assertTrue(K(1444, "Thyssiana")); assertTrue(K(1444, "Fyldren Moonfeather"))
    ns.State.knownTaxi = {}
    assertFalse(K(1444, "Thyssiana")); assertFalse(K(1431, "Felicia Maline"))
    ns.State.knownTaxi = { ["Darkshire, Duskwood"] = true }
    assertTrue(K(1431, "Felicia Maline")); assertTrue(K(1431))
  end)
end)

test("flight points: every flight master has its flight map name, once; Mount Hyjal's two serve both factions", function()
  for side, byMap in pairs(ns.FLIGHT_BY) do
    local seen = {}
    for m, list in pairs(byMap) do
      for _, f in ipairs(list) do
        assertTrue(type(f[4]) == "string" and f[4] ~= "", side .. " " .. m .. " " .. tostring(f[3]) .. " has no flight point name")
        assertNil(seen[f[4] .. "|" .. f[3]], side .. ": " .. f[4] .. " is listed twice")
        seen[f[4] .. "|" .. f[3]] = true
      end
    end
  end
  for _, side in ipairs({ "Alliance", "Horde" }) do
    local hyjal, n = ns.FLIGHT_BY[side][2482], {}
    assertNotNil(hyjal, side .. " has no Mount Hyjal flight points")
    for _, f in ipairs(hyjal) do n[f[4]] = true end
    assertTrue(n["Summit of Eternity, Mount Hyjal"] and n["Tainted Foothills, Mount Hyjal"], side .. " lacks one of Mount Hyjal's flight points")
    assertEquals(1, #ns.FLIGHT_BY[side][2548]) -- Riverglades: one flight master, not one per spawn point
  end
  assertNil(ns.FLIGHT_BY.Alliance[1431][2]) -- Duskwood has Darkshire and nothing else (no Raven Hill flight point in the client)
end)

test("quest automation (a toggle, off by default): accepts route quests only, hands in finished ones with no reward choice, Shift skips", function()
  local sv = { on = ns.db.autoQuest, gq = GetQuestID, acc = AcceptQuest, comp = CompleteQuest, rew = GetQuestReward, ch = GetNumQuestChoices, can = IsQuestCompletable, shift = IsShiftKeyDown, idx = C_QuestLog.GetLogIndexForQuestID, auto = QuestGetAutoAccept, nope = ns.char.nope, data = ForeverRouteData }
  local calls = {}
  local ok, err = pcall(function()
    ForeverRouteData = { id = "aq", title = "aq", sections = { { title = "x" } }, steps = { { k = "accept", q = 783, name = "A Threat Within", sec = 1 } } }
    ns.Fire("FR_ROUTE_CHANGED")
    AcceptQuest = function() calls[#calls + 1] = "accept" end
    CompleteQuest = function() calls[#calls + 1] = "complete" end
    GetQuestReward = function(i) calls[#calls + 1] = "reward" .. tostring(i) end
    IsShiftKeyDown = function() return false end
    QuestGetAutoAccept = function() return false end
    C_QuestLog.GetLogIndexForQuestID = function(q) return q == 783 and 3 or nil end
    -- off by default: nothing happens
    ns.db.autoQuest = nil
    GetQuestID = function() return 999 end
    assertTrue(not ns.AutoQuest.Detail(), "acted with the option off")
    ns.db.autoQuest = true
    -- a quest the route doesn't pick up: left alone
    assertTrue(not ns.AutoQuest.Detail(), "accepted a quest that isn't on the route")
    -- one it does (not in the log yet)
    C_QuestLog.GetLogIndexForQuestID = function() return nil end
    GetQuestID = function() return 783 end
    assertTrue(ns.AutoQuest.Detail()); assertEquals("accept", calls[#calls])
    -- marked "won't do": left alone
    ns.char.nope = { [783] = true }; ns.Fire("FR_ROUTE_CHANGED")
    assertTrue(not ns.AutoQuest.Detail(), "accepted a quest you won't do"); ns.char.nope = sv.nope
    -- hand in: finished and in the log
    C_QuestLog.GetLogIndexForQuestID = function(q) return q == 783 and 3 or nil end
    IsQuestCompletable = function() return true end
    assertTrue(ns.AutoQuest.Progress()); assertEquals("complete", calls[#calls])
    -- a repeatable turn-in that isn't in your log: never
    GetQuestID = function() return 7813 end
    assertTrue(not ns.AutoQuest.Progress(), "handed in a quest that isn't in the log")
    -- rewards: one or none taken, a choice waits for you
    GetNumQuestChoices = function() return 1 end; assertTrue(ns.AutoQuest.Complete()); assertEquals("reward1", calls[#calls])
    GetNumQuestChoices = function() return 0 end; assertTrue(ns.AutoQuest.Complete()); assertEquals("reward0", calls[#calls])
    local n = #calls
    GetNumQuestChoices = function() return 3 end; assertTrue(not ns.AutoQuest.Complete(), "picked a reward for you"); assertEquals(n, #calls)
    -- Shift: you do it yourself
    IsShiftKeyDown = function() return true end
    GetQuestID = function() return 783 end; C_QuestLog.GetLogIndexForQuestID = function() return nil end
    assertTrue(not ns.AutoQuest.Detail(), "Shift did not skip it")
  end)
  ns.db.autoQuest, GetQuestID, AcceptQuest, CompleteQuest, GetQuestReward, GetNumQuestChoices, IsQuestCompletable, IsShiftKeyDown, C_QuestLog.GetLogIndexForQuestID, QuestGetAutoAccept, ns.char.nope, ForeverRouteData = sv.on, sv.gq, sv.acc, sv.comp, sv.rew, sv.ch, sv.can, sv.shift, sv.idx, sv.auto, sv.nope, sv.data
  ns.Fire("FR_ROUTE_CHANGED")
  if not ok then error(err, 0) end
end)

test("scrollbars you can use: the route list's and the quest log check's take a drag or a click (they were drawings only)", function()
  ns.Fire("FR_TOGGLE_LIST")
  local L = ForeverRouteList or (ns.List and ns.List.Frame and ns.List.Frame())
  local sv = ForeverRouteData
  local ok, err = pcall(function()
    -- a route long enough to scroll
    local steps = {}
    for i = 1, 80 do steps[i] = { k = "accept", q = 90000 + i, name = "Quest " .. i, m = 1429, x = 0.4, y = 0.4, sec = 1, lvl = 1 } end
    ForeverRouteData = { id = "sb", title = "sb", sections = { { title = "x" } }, steps = steps }
    ns.Engine.Refresh(); ns.List.Draw()
    local f = L or _G["ForeverRouteList"]
    assertNotNil(f and f.grip, "the route list has no scrollbar to grab")
    assertTrue(f.grip:IsMouseEnabled(), "the scrollbar takes no mouse")
    assertTrue(f.grip:GetWidth() >= 10, "too thin to aim at")
    -- the grip scrolls the list: to the end and back
    f.grip.SetFraction(1)
    local last = f.offset
    assertTrue(last > 0, "dragging to the bottom did not scroll")
    f.grip.SetFraction(0)
    assertEquals(0, f.offset, "dragging to the top did not scroll back")
    f.grip.SetFraction(0.5)
    assertTrue(f.offset > 0 and f.offset < last, "the middle is not the middle")
  end)
  ForeverRouteData = sv; ns.Engine.Refresh()
  if ForeverRouteList then ForeverRouteList:Hide() end
  if not ok then error(err, 0) end
  -- the quest log check too
  ns.Fire("FR_TOGGLE_LOGCHECK")
  local g = ForeverRouteLogCheck and ForeverRouteLogCheck.grip
  if ForeverRouteLogCheck then assertNotNil(g, "the quest log check has no scrollbar to grab"); ForeverRouteLogCheck:Hide() end
end)

test("the card hangs from its top - never dragged or placed by an older version too - so a step that changes in a fight leaves the Target button where it belongs, and no row of the card runs under it", function()
  local sv = { pos = ns.db.targetPos, card = ns.db.cardPos, combat = InCombatLockdown }
  local ok, err = pcall(ForeverRouteTest.withWorld, buttonRoute(), function(w)
    local t, card = ForeverRouteTargetButton, ForeverRouteCard
    ns.db.targetPos = nil
    -- never dragged: the default place hangs from the top (it hung from its middle: every change of height moved its top)
    ns.db.cardPos = nil; ns.Card.ApplyPos()
    cardOn()
    must(tostring((card:GetPoint(1))):find("^TOP") ~= nil, "a card that was never dragged is anchored by its " .. tostring((card:GetPoint(1))))
    local top = card:GetTop()
    card:SetHeight(card:GetHeight() + 120)
    must(math.abs(card:GetTop() - top) < 0.5, "growing a card that was never dragged moved its top")
    -- a place saved by an older version (by its middle): the same place, hung from the top from now on
    ns.db.cardPos = { "CENTER", "CENTER", -150, 60 }; ns.Card.ApplyPos()
    assertEquals("TOPLEFT", (card:GetPoint(1)), "a card placed by an older version is not hung from its top")
    assertEquals("ABS", ns.db.cardPos[1], "its place is not kept in screen units")
    local mid = (box(card).l + box(card).r) / 2
    must(math.abs(mid - (UIParent:GetWidth() / 2 - 150 * card:GetScale())) < 1, "re-anchoring moved the card sideways")
    top = card:GetTop()
    card:SetHeight(card:GetHeight() + 120)
    must(math.abs(card:GetTop() - top) < 0.5, "growing the card moved its top")
    -- a fight: the step changes to one with objective bars (a taller card), the button can't move
    cardOn()
    aboveCard("before the fight")
    local was = box(t)
    InCombatLockdown = function() return true end
    onQuest(w)
    ns.Card.Fill(); ns.Card.Layout(); ns.Card.PlaceSecure()
    InCombatLockdown = sv.combat
    must(card.cur.nbars >= 1, "the step in the fight has no objective bars")
    local now = box(t)
    must(math.abs(now.l - was.l) < 0.01 and math.abs(now.t - was.t) < 0.01, "the Target button moved in a fight")
    aboveCard("after the step changed in a fight")
    for k = 1, card.cur.nbars do must(not overlap(now, box(card.cur.bars[k])), "objective bar " .. k .. " runs under the Target button") end
    must(not overlap(now, box(card.cur.titleText)) and not overlap(now, box(card.prog)), "the Target button is over the card's title or progress line")
    assertNil(card.cur.btnY, "the card still keeps a row for the buttons")
  end, { anyTarget = true })
  InCombatLockdown = sv.combat
  ns.db.targetPos, ns.db.cardPos = sv.pos, sv.card
  if ns.Card.ApplyPos then ns.Card.ApplyPos() end
  if not ok then error(err, 0) end
end)

test("built-in plans from the faction addon: only your plan's text becomes code, the others are never run, and the text is let go", function()
  local sv = { load = C_AddOns.LoadAddOn, starter = ForeverRouteStarter, fac = UnitFactionGroup }
  local ok, err = pcall(function()
    ForeverRouteStarter = {}
    local loaded = {}
    UnitFactionGroup = function() return "Alliance" end
    C_AddOns.LoadAddOn = function(name)
      loaded[#loaded + 1] = name
      if name == "ForeverRoute_Plans_Alliance" then
        ForeverRoutePlanSources = {
          ["gnome-warlock"] = "ForeverRouteStarter = ForeverRouteStarter or {}; ForeverRouteStarter['gnome-warlock'] = function() ForeverRouteBundleRan = true end",
          ["human-mage"] = "ForeverRouteOtherPlanRan = true",
        }
      end
      return true
    end
    ForeverRouteOtherPlanRan = nil
    assertTrue(ns.LoadStarter("gnome-warlock"), "your plan did not load from the faction addon")
    assertEquals("ForeverRoute_Plans_Alliance", loaded[1], "loaded " .. tostring(loaded[1]) .. " first")
    assertEquals("function", type(ForeverRouteStarter["gnome-warlock"]))
    assertNil(ForeverRouteOtherPlanRan, "another race's plan was run")
    assertNil(ForeverRoutePlanSources, "the other plans' text was kept")
    -- an older install: no faction addon, the per-plan one still works
    loaded = {}
    C_AddOns.LoadAddOn = function(name) loaded[#loaded + 1] = name; if name == "ForeverRoute_Starter_dwarf_hunter" then ForeverRouteStarter["dwarf-hunter"] = function() end end; return true end
    assertTrue(ns.LoadStarter("dwarf-hunter"), "the per-plan addon of an older install no longer loads")
  end)
  C_AddOns.LoadAddOn, ForeverRouteStarter, UnitFactionGroup = sv.load, sv.starter, sv.fac
  ForeverRoutePlanSources = nil
  if not ok then error(err, 0) end
end)

test("the Forever Route scale slider applies when you let go (dragging it resized the window under the cursor and it ran to its end)", function()
  ns.Fire("FR_OPEN_OPTIONS")
  local panel = ForeverRouteOptions
  local s = panel and panel.scaleSlider
  assertNotNil(s, "no scale slider")
  local before = ns.db.uiScale
  local fired = 0
  local sv = ns.Fire
  local ok, err = pcall(function()
    ns.Fire = function(ev, ...) if ev == "FR_SETTINGS" then fired = fired + 1 end; return sv(ev, ...) end
    s:GetScript("OnMouseDown")(s)
    s:SetValue(1.4); s:SetValue(1.6)
    assertEquals(0, fired, "the scale changed while dragging")
    assertEquals(before, ns.db.uiScale, "the setting changed while dragging")
    s:GetScript("OnMouseUp")(s)
    assertEquals(1, fired, "letting go did not apply it once")
    assertTrue(math.abs((ns.db.uiScale or 0) - 1.6) < 0.001, "not the value let go at")
    -- the wheel or the keys (no drag): straight away
    s:SetValue(1.2); assertEquals(2, fired)
  end)
  ns.Fire = sv
  ns.db.uiScale = before; ns.Fire("FR_SETTINGS")
  if ForeverRouteOptionsWindow then ForeverRouteOptionsWindow:Hide() end
  if not ok then error(err, 0) end
end)

test("the card stays on the screen when the scale changes, an off-screen card comes back by itself, /fr card reset", function()
  local sv = { pos = ns.db.cardPos, ui = ns.db.uiScale, sc = ns.db.scale }
  local ok, err = pcall(function()
    local f = ForeverRouteCard
    f:Show(); ns.db.cardPos = { "ABS", 200, 500 }; ns.Card.ApplyPos() -- (room to grow: at the right edge the screen clamp moves it)
    ns.Card.AnchorTop()
    assertEquals("ABS", ns.db.cardPos[1], "the place is not kept in screen units")
    local s0 = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local left0 = f:GetLeft() * s0
    -- a bigger scale: the same place on the screen, still on it
    ns.db.uiScale = 1.2; ns.Fire("FR_SETTINGS"); ns.Style.ApplyScale(); ns.Card.ApplyPos()
    local s1 = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
    assertTrue(math.abs(f:GetLeft() * s1 - left0) < 2, "the card moved on the screen when the scale changed")
    assertTrue(ns.Card.OnScreen(), "the card went off the screen")
    -- a saved place that is off the screen: back at the default place
    ns.db.cardPos = { "ABS", 99999, 99999 }; ns.Card.ApplyPos()
    assertTrue(ns.Card.OnScreen(), "an off-screen card stayed off the screen")
    -- /fr card reset: normal size, default place, shown
    f:Hide(); ns.db.hidden = true
    SlashCmdList["FOREVERROUTE"]("card reset")
    assertTrue(f:IsShown(), "/fr card reset did not show the card"); assertNil(ns.db.uiScale); assertNil(ns.db.cardPos)
  end)
  ns.db.cardPos, ns.db.uiScale, ns.db.scale = sv.pos, sv.ui, sv.sc; ns.Fire("FR_SETTINGS")
  if not ok then error(err, 0) end
end)

-- The planned path (the plan's own waypoints, from where the plan expected you to come from) and the live line (Nav.lua,
-- from where you stand). A tester: "occasionally it throws a random path on the map that flashes for a few seconds and
-- then goes away".
local function plannedRoute(m, wp, x, y)
  return { id = "pp", title = "pp", sections = { { title = "x" } }, steps = {
    { id = 1, k = "goto", text = "To the far end", m = m, x = x, y = y, r = 8, sec = 1, wp = wp },
    { id = 2, k = "goto", text = "And back", m = m, x = 0.70, y = 0.47, r = 8, sec = 1 },
  } }
end
local function pathWorld(route, at, fn)
  local sv = { path = ns.db.pathLine }
  ns.db.pathLine = true
  local ok, err = pcall(withWorld, route, function(w)
    ns.Nav.Want(nil); ns.Arrow.SetTarget(w:shown(), true) -- a fresh target (an earlier test may have left the same one)
    fn(w)
  end, { at = at, anyTarget = true })
  ns.db.pathLine = sv.path
  ns.Nav.Want(nil); ns.Pins.Update(true)
  if not ok then error(err, 0) end
end

test("planned path: where there is no walk map it is drawn only while you are on it, from where you are - not from where the plan expected you, to be taken away a moment later", function()
  -- Duskwood has no walk map: the plan's path runs west along the road from Darkshire
  local wp = "0.7500,0.4800,0;0.7000,0.4700,0;0.6000,0.4500,0;0.5000,0.4200,0"
  pathWorld(plannedRoute(1431, wp, 0.40, 0.40), { m = 1431, x = 0.50, y = 0.90 }, function(w)
    -- far south of the path: while the live line is looked for, and once it is known there is none - nothing
    ns.Pins.Update(true)
    assertEquals(0, ns.Pins.PathDots(), "a path is drawn while the live line is still being looked for")
    ns.Nav.Settle()
    assertNil(ns.Nav.PathFor(ns.Arrow.Current().key), "a live line in a zone with no walk map")
    must(not ns.Nav.Coming(), "a live line is said to be coming in a zone with no walk map")
    assertEquals(-1, ns.Pins.OnPlanned(w:shown()), "far from the planned path, but taken to be on it")
    assertEquals(0, ns.Pins.PathDots(), "far from the planned path, it is drawn anyway (from where the plan expected you)")
    ns.Pins.Update(true)
    assertEquals(0, ns.Pins.PathDots(), "far from the planned path, a refresh draws it")
    -- on the road, at the plan's third point: the path from here on, not the part behind you
    w:go(1431, 0.60, 0.45); ns.Nav.Settle(); ns.Pins.Update(true)
    local n = ns.Pins.PathDots()
    must(n >= 10, "on the planned path, but only " .. n .. " dots of it are drawn")
    must(n <= 30, "on the planned path, " .. n .. " dots: the part behind you is drawn too (the whole path has about 37)")
    -- the arrow's own word on it agrees (it comes every second or two as you walk): the same line stays
    ns.Fire("FR_PATHPROGRESS", w:shown(), ns.Pins.OnPlanned(w:shown()))
    must(math.abs(ns.Pins.PathDots() - n) <= 1, "the arrow's word on where you are changed the line: " .. n .. " dots, then " .. ns.Pins.PathDots())
    -- the arrow turns to something else (a new target): the old path goes at once, nothing until the new one is known
    local t = ns.Arrow.Current()
    ns.Nav.Want({ key = "elsewhere", wx = t.wx + 300, wy = t.wy + 300, inst = t.winst, m = 1431 })
    assertEquals(0, ns.Pins.PathDots(), "the old target's planned path stays on the map after the target changed")
    ns.Nav.Want(nil); ns.Arrow.SetTarget(w:shown(), true); ns.Nav.Settle(); ns.Pins.Update(true)
    must(ns.Pins.PathDots() >= 10, "back on the step, the planned path is not drawn again")
    -- on a flight there is nothing to walk: no path (it came back for the whole flight); landing brings it back
    w:taxi(true)
    must(ns.Arrow.Current() == nil, "the arrow has a target on a flight")
    assertEquals(0, ns.Pins.PathDots(), "the planned path is drawn during a flight")
    w:taxi(false); ns.Nav.Settle()
    must(ns.Pins.PathDots() >= 10, "after landing on the planned path it is not drawn")
    -- off the road again: gone
    w:go(1431, 0.60, 0.80); ns.Nav.Settle(); ns.Pins.Update(true)
    assertEquals(0, ns.Pins.PathDots(), "walked off the planned path, and it is still drawn")
  end)
end)

test("planned path: never drawn while a live line is on its way or drawn - not at a loading screen, not when the target changes", function()
  -- Stormwind has a walk map; the plan's path starts right where you stand (so only the live line keeps it away)
  local route = { id = "pl", title = "pl", sections = { { title = "Stormwind" } }, steps = {
    { id = 1, k = "goto", text = "To the Keep", m = 1453, x = 0.800, y = 0.380, r = 8, sec = 1, wp = "0.6610,0.7080,0;0.7000,0.6000,0;0.7500,0.5000,0" },
    { id = 2, k = "goto", text = "Back to the Trade District", m = 1453, x = 0.661, y = 0.708, r = 8, sec = 1, wp = "0.8000,0.3800,0;0.7500,0.5000,0;0.7000,0.6000,0" },
  } }
  pathWorld(route, { m = 1453, x = 0.661, y = 0.708 }, function(w)
    must(ns.Pins.OnPlanned(w:shown()) >= 1, "the test's planned path does not start where you stand")
    -- the line is being found
    ns.Pins.Update(true)
    must(ns.Pins.LiveComing(), "no live line on its way in Stormwind")
    assertEquals(0, ns.Pins.PathDots(), "the planned path is drawn while the live line is being found")
    -- a loading screen in between: the line waits for the game to say where you are
    ns.Fire("PLAYER_ENTERING_WORLD")
    must(ns.Nav.Live().waiting == true, "the live line does not wait at a loading screen")
    ns.Pins.Update(true)
    assertEquals(0, ns.Pins.PathDots(), "the planned path is drawn at a loading screen, until the live line is found again")
    ns.Fire("FR_PATHPROGRESS", w:shown(), 1)
    assertEquals(0, ns.Pins.PathDots(), "the arrow's word on the planned path draws it while the live line waits")
    ns.Nav.Settle()
    local P = ns.Nav.PathFor(ns.Arrow.Current().key)
    must(P ~= nil and ns.Pins.Line() ~= nil and ns.Pins.Line().P == P, "no live line drawn once it was found")
    assertEquals(0, ns.Pins.PathDots(), "the planned path is drawn next to the live line")
    -- a loading screen with the line drawn: it stays, the planned path stays away
    ns.Fire("PLAYER_ENTERING_WORLD"); ns.Pins.Update(true)
    assertEquals(0, ns.Pins.PathDots(), "the planned path comes back at a loading screen")
    ns.Nav.Settle()
    -- the next step: the old line goes, and nothing is drawn until the new line is ready
    ns.Engine.Skip()
    assertEquals(2, w:shown())
    must(ns.Arrow.Current().index == 2 and ns.Nav.PathFor(ns.Arrow.Current().key) == nil, "the new target already has a line")
    assertNil(ns.Pins.Line(), "the old target's line is still drawn")
    assertEquals(0, ns.Pins.PathDots(), "the planned path of the new step is drawn while its live line is being found")
    ns.Pins.Update(true)
    assertEquals(0, ns.Pins.PathDots(), "a refresh draws the planned path while the live line is being found")
    ns.Nav.Settle()
    local P2 = ns.Nav.PathFor(ns.Arrow.Current().key)
    must(P2 ~= nil and P2 ~= P and ns.Pins.Line() ~= nil and ns.Pins.Line().P == P2, "the new target's live line is not drawn")
    assertEquals(0, ns.Pins.PathDots())
  end)
end)

-- a route through two zones with a trip between: Duskwood (two quests), a flight, Redridge
local function twoZoneRoute()
  return { id = "tz", title = "tz", meta = { startLevel = 21, endLevel = "30 (62%)", hours = 10 }, sections = { { title = "Darkshire" }, { title = "Lakeshire" } }, steps = {
    { id = 1, k = "accept", q = 201, name = "Wolves", npc = "Lars", zone = "Duskwood", m = 1431, x = 0.75, y = 0.48, r = 6, sec = 1, lvl = 21 },
    { id = 2, k = "accept", q = 203, name = "Spiders", npc = "Lars", zone = "Duskwood", m = 1431, x = 0.75, y = 0.48, r = 6, sec = 1, lvl = 21 },
    { id = 3, k = "obj", q = 201, text = "Kill 5 Wolf", match = "Wolf", zone = "Duskwood", m = 1431, x = 0.40, y = 0.40, r = 60, sec = 1, lvl = 21 },
    { id = 4, k = "turnin", q = 201, name = "Wolves", npc = "Lars", zone = "Duskwood", m = 1431, x = 0.75, y = 0.48, r = 6, sec = 1, lvl = 22 },
    { id = 5, k = "fly", dest = "Redridge Mountains", to = 1433, text = "Redridge Mountains", sec = 2 },
    { id = 6, k = "accept", q = 202, name = "Gnolls", npc = "Marshal", zone = "Redridge Mountains", m = 1433, x = 0.30, y = 0.45, r = 6, sec = 2, lvl = 23 },
  } }
end

test("card footer: where you go next and after how much here - not the plan's levels ('planned for level 33 · plan goes to level 43' was meaningless - tester)", function()
  ForeverRouteTest.withState({}, function()
    ForeverRouteData = twoZoneRoute()
    ns.Engine.Refresh()
    assertEquals("Next zone: " .. ns.Style.ShortZone("Redridge Mountains") .. ", after 2 quests here", ns.Card.FooterText(1))
    -- a trip says where it goes on the card itself: no footer line
    assertEquals("", ns.Card.FooterText(5))
    -- the plan's last zone
    assertEquals("Last zone on this plan", ns.Card.FooterText(6))
    -- a dungeon route has its own way back: nothing
    ForeverRouteData.dungeon = true
    assertEquals("", ns.Card.FooterText(1))
    ForeverRouteData.dungeon = nil
    -- what the card shows: no level talk
    ForeverRouteData = twoZoneRoute(); ns.Engine.Refresh(); ns.Card.Update()
    local t = ForeverRouteCard.eta:GetText() or ""
    must(not t:find("level", 1, true) and not t:find("planned", 1, true), "the footer still talks about plan levels: " .. t)
  end)
  ns.Card.Update()
end)

test("route list header: the level the plan ends at, the time left and the steps done; when and from what it was planned only in its tooltip", function()
  -- (tester: "Level 33 to 43 (62%) · ~39.3 h · 26 of 893 done · planned 8 h ago from your 23:47 save" - meaningless)
  local m = { startLevel = 33, endLevel = "43 (62%)", hours = 39.3 }
  local t = ns.List.MetaText(m, 26, 893)
  assertEquals("To level 43  ·  about 38 h left  ·  26 of 893 steps done", t)
  must(not t:find("save", 1, true) and not t:find("planned", 1, true) and not t:find("%%"), "jargon in the header: " .. t)
  assertEquals("To level 30  ·  about 4.5 h left  ·  5 of 10 steps done", ns.List.MetaText({ endLevel = "30 (10%)", hours = 9 }, 5, 10))
  assertEquals("To level 30  ·  about 30 min left  ·  9 of 10 steps done", ns.List.MetaText({ endLevel = 30, hours = 5 }, 9, 10))
  assertEquals("3 of 10 steps done", ns.List.MetaText(nil, 3, 10))
  -- the tooltip: when the companion planned it, and from which save
  local sv = { plan = ForeverRoutePlan, key = ns.planKey }
  local ok, err = pcall(function()
    ns.planKey = nil
    ForeverRoutePlan = { generated = time() - 3 * 3600, fromSave = time() - 4 * 3600 }
    local tip = ns.List.MetaTip()
    assertEquals("Planned 3 h ago", tip[1])
    must(tip[2] and tip[2]:find("saved", 1, true), "the tooltip doesn't say which save it was planned from")
    -- a built-in plan: which build of it (what a bug report needs)
    ns.planKey = { starter = "X" }
    local stamps = ForeverRouteStarterStamp
    ForeverRouteStarterStamp = { X = "plans 2026-11-11 · QuestieDB 1.0.14 · planner abc1234" }
    tip = ns.List.MetaTip()
    ForeverRouteStarterStamp = stamps
    assertEquals("Built-in plan", tip[1]); assertEquals("plans 2026-11-11 · QuestieDB 1.0.14 · planner abc1234", tip[2])
  end)
  ForeverRoutePlan, ns.planKey = sv.plan, sv.key
  if not ok then error(err, 0) end
end)

test("Map opens the step's destination, not where you stand: a trip opens the zone it goes to and flashes its first stop; the flash waits until the pin is on the screen", function()
  ForeverRouteTest.withState({}, function()
    ForeverRouteData = twoZoneRoute()
    ns.Engine.Refresh()
    -- a step with a spot: its map and its own pin
    local m, pin = ns.MapSpot(3)
    assertEquals(1431, m); assertEquals(3, pin)
    -- a trip: the zone it goes to (it was the flight master in the zone you are in), the first stop there flashes
    m, pin = ns.MapSpot(5)
    assertEquals(1433, m); assertEquals(6, pin)
    -- a stop whose place nobody knows: its zone, nothing to flash
    ForeverRouteData.steps[3].unknown = true
    m, pin = ns.MapSpot(3)
    assertEquals(1431, m); assertNil(pin)
    -- no map at all
    ForeverRouteData.steps[2] = { id = 2, k = "note", text = "read this", sec = 1 }
    assertNil((ns.MapSpot(2)))
  end)
  -- the flash: a pin the map hasn't shown yet doesn't use it up; it plays once the pin shows
  local used = ns.Pins._used
  local played = 0
  local shown = false
  local fake = { where = "world", index = 4242, IsVisible = function() return shown end,
    blink = { Stop = function() end, Play = function() played = played + 1 end } }
  local sv = C_Timer.After
  local timers = {}
  C_Timer.After = function(_, f) timers[#timers + 1] = f end
  local ok, err = pcall(function()
    used[#used + 1] = fake
    must(not ns.Pins.Blink(4242), "it blinked a pin not on the screen")
    assertEquals(0, played)
    must(#timers == 1, "no second look for a pin not on the screen yet")
    shown = true
    table.remove(timers, 1)()
    assertEquals(1, played)
    assertEquals(0, #timers)
    -- never shown: it gives up (no flash long after)
    shown, played, timers = false, 0, {}
    C_Timer.After = function(_, f) timers[#timers + 1] = f end
    ns.Pins.Blink(4242)
    local n = 0
    while #timers > 0 and n < 100 do n = n + 1; table.remove(timers, 1)() end
    must(n < ns.Pins.BLINK_TRIES + 1, "the flash kept looking for its pin: " .. n .. " times")
    assertEquals(0, played)
  end)
  C_Timer.After = sv
  for k = #used, 1, -1 do if used[k] == fake then table.remove(used, k) end end
  if not ok then error(err, 0) end
end)
