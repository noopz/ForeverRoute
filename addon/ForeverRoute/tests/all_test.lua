-- Forever Route test suite (runs in wow-ui-sim: wow-sim run-tests ForeverRoute)
local ns = ForeverRoute

local KINDS = { accept = 1, turnin = 1, obj = 1, ["goto"] = 1, fly = 1, fp = 1, hearth = 1, bind = 1, train = 1, grind = 1, note = 1, bonus = 1 }
local withState, withWorld = ForeverRouteTest.withState, ForeverRouteTest.withWorld


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

test("never accepts or hands in quests by itself", function()
  local calls = 0
  local saved = { AcceptQuest = AcceptQuest, CompleteQuest = CompleteQuest, GetQuestReward = GetQuestReward }
  AcceptQuest = function() calls = calls + 1 end; CompleteQuest = AcceptQuest; GetQuestReward = AcceptQuest
  for _, ev in ipairs({ "GOSSIP_SHOW", "QUEST_GREETING", "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE" }) do ns.Fire(ev) end
  AcceptQuest, CompleteQuest, GetQuestReward = saved.AcceptQuest, saved.CompleteQuest, saved.GetQuestReward
  assertEquals(0, calls)
  assertNil(ns.db.autoQuest)
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

test("routed arrow: follows the path, carries on from a shortcut, knows when you're off it", function()
  local follow = ns.Arrow._follow
  -- an L-shaped path from (0,0): east to a corner at (100,0), then north to the target at (100,100), 20 yd up
  local function P() return { pts = { { 0, 0, 0 }, { 100, 0, 0 }, { 100, 100, 20 } }, rem = { 200, 100, 0 }, cursor = 1, z0 = 0, z1 = 20 } end
  local p = P()
  local aim, walk, off = follow(p, 10, 2)            -- on the first leg: aim at the corner, never diagonally across
  assertEquals(100, aim[1]); assertEquals(0, aim[2])
  assertTrue(math.abs(walk - 190) < 2)
  assertTrue(off < 3)
  local aim2 = follow(p, 98, 60)                     -- took a shortcut and came out on the second leg: carry on from there
  assertEquals(100, aim2[2])
  assertEquals(2, p.cursor)
  local aim3 = follow(p, 100, 10)                    -- doesn't go back to the first leg once past it
  assertEquals(100, aim3[2])
  local _, _, off4 = follow(P(), 40, 60)             -- wandered off into the field
  assertTrue(off4 > 45)
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
  ns.State.Position, HBD.GetPlayerWorldPosition, GetTime, ForeverRouteDB.trailData = saved.pos, saved.wp, saved.t, saved.trails
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

test("the target button sits above the card and targets the NPC by name", function()
  assertNotNil(ForeverRouteTargetButton)
  assertEquals("HIGH", ForeverRouteTargetButton:GetFrameStrata())
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

test("live reordering: follows the step you're at, holds it, then goes back to the plan", function()
  local HBD = LibStub("HereBeDragons-2.0")
  withState({ [602] = { on = true, objectives = { { text = "Murloc slain: 2/7", finished = false, have = 2, need = 7 } } } }, function()
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
    ns.Engine.UpdateFocus(x + 5, y, inst)        -- standing among the murlocs
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

test("live reordering: a finished quest whose hand-in is right here is handed in now, however late the plan has it", function()
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
  end)
  HBD.GetWorldCoordinatesFromZone = realConv
  ns.Engine.focus = nil
  if not ok then error(err, 0) end
end)

test("live reordering: a step your kills count for stays shown while you farm far from its marker, until the kills stop", function()
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
    ns.Engine.UpdateFocus(x + 5, y, inst)        -- focus moves the card to the murlocs: step 1 is untouched
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

test("save nudge: shows on a flight after a few minutes played, not on foot, not when dismissed", function()
  local sv = { taxi = UnitOnTaxi, after = ns.Card.SAVE_AFTER }
  local ok, err = pcall(function()
    ns.Card.SAVE_AFTER = -1; ns.Card.saveDismissed = nil
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
  UnitOnTaxi, ns.Card.SAVE_AFTER, ns.Card.saveDismissed = sv.taxi, sv.after, nil
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

test("live reorder: standing in a town, its flight path and pick-ups come before a step across the zone", function()
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

test("live reorder: never jumps to a pick-up whose earlier chain quest isn't handed in (Chef Grual)", function()
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
    assertEquals("Ride to Ashenvale", title())
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
    assertTrue(not ns.Travel.Through(w(0.30, 0.22), w(0.30, 0.40))) -- far west of it
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
    assertEquals(1, #asked); assertEquals("ForeverRoute_Starter_nightelf_druid", asked[1])
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
