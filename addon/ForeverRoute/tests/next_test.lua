-- The live solver's picks (Next.lua over Horizon.lua) in the places the old reordering rules were written for, and in
-- the interruptions WoW brings: a trip to town with full bags, a detour to group for a dungeon.
local ns = ForeverRoute
local withState = ForeverRouteTest.withState
local HBD = LibStub("HereBeDragons-2.0")

-- a world where 1% of a map is 35 yd, everything on one continent
local function inWorld(fn)
  local realConv, realPos = HBD.GetWorldCoordinatesFromZone, ns.State.Position
  -- (made-up quests: the real quest data's prerequisites for those numbers don't apply - tester3_test checks them)
  local realPre = ns.QUEST_PRE; ns.QUEST_PRE = {}
  local ok, err = pcall(withState, {}, function()
    HBD.GetWorldCoordinatesFromZone = function(_, mx, my, m) return mx * 3500, my * 3500, 0 end
    fn()
  end)
  HBD.GetWorldCoordinatesFromZone, ns.State.Position = realConv, realPos
  ns.QUEST_PRE = realPre
  ns.Engine.focus, ns.Engine.pos = nil, nil
  if not ok then error(err, 0) end
end
-- stand at a spot: the world position the arrow measures and the map position the game says agree
local function at(mx, my, dx, m)
  m = m or 1437
  local x, y, inst = HBD:GetWorldCoordinatesFromZone(mx, my, m)
  ns.State.Position = function() return m, mx + (dx or 0) / 3500, my end
  ns.Engine.UpdateFocus(x + (dx or 0), y, inst); ns.Engine.Refresh()
end
local function quests(ready, onLog)
  ns.State.OnQuest = function(id) return onLog[id] or ready[id] or false end
  ns.State.IsCompleted = function() return false end
  ns.State.Quest = function(id)
    if ready[id] then return { on = true, complete = true, objectives = {} } end
    if onLog[id] then return { on = true, objectives = { { text = "Thing: 0/5", finished = false, have = 0, need = 5 } } } end
    return { on = false, objectives = {} }
  end
end

test("next: at the NPC of a finished quest the plan hands in much later - hand it in now, while you're here", function()
  inWorld(function()
    local list = { { id = 1, k = "accept", q = 901, name = "Far Planned", m = 1437, x = 0.60, y = 0.30, r = 6, sec = 1 } }
    for k = 2, 40 do list[k] = { id = k, k = "accept", q = 901000 + k, name = "Filler " .. k, m = 1437, x = 0.62, y = 0.32, r = 6, sec = 1 } end
    list[41] = { id = 41, k = "turnin", q = 98221, name = "From the Ashes", npc = "Captain Stoutfist", m = 1437, x = 0.0986, y = 0.5749, r = 6, sec = 1 }
    -- (Menethil: a town the plan stops at a lot)
    for k = 42, 45 do list[k] = { id = k, k = "accept", q = 902000 + k, name = "Town " .. k, m = 1437, x = 0.099, y = 0.576, r = 6, sec = 1 } end
    ForeverRouteData = { id = "n1", title = "n1", sections = { { title = "x" } }, steps = list }
    quests({ [98221] = true }, {})
    at(0.0986, 0.5749, 3)
    assertEquals(41, ns.Engine.current, "the hand-in next to you")
    assertEquals(1, ns.Engine.planned)
    assertTrue(ns.Next.Reason(41):find("while you're here", 1, true) ~= nil, ns.Next.Reason(41))
  end)
end)

test("next: a finished quest's hand-in across the continent isn't worth the trip - the plan goes on (no Stormwind for one hand-in)", function()
  inWorld(function()
    local list = {
      { id = 1, k = "accept", q = 901, name = "Here", m = 1437, x = 0.50, y = 0.50, r = 6, sec = 1 },
      { id = 2, k = "obj", q = 901, text = "Kill 5 Thing", match = "Thing", m = 1437, x = 0.52, y = 0.50, r = 40, sec = 1 },
      -- picked up off the plan, finished, its hand-in put in by the route 1200 yd away
      { id = 3, k = "turnin", q = 950, name = "Far Delivery", m = 1437, x = 0.85, y = 0.85, r = 6, sec = 1, inserted = true, xp = 300 },
      { id = 4, k = "turnin", q = 901, name = "Here", m = 1437, x = 0.50, y = 0.50, r = 6, sec = 1 },
    }
    ForeverRouteData = { id = "n2", title = "n2", sections = { { title = "x" } }, steps = list }
    quests({ [950] = true }, {})
    at(0.50, 0.50, 5)
    assertEquals(1, ns.Engine.current)
    local later = ns.Next.Deferred()
    assertTrue(#later == 1 and later[1] == "Far Delivery", "the far hand-in wasn't left for later: " .. table.concat(later, ","))
  end)
end)

test("next: back in town with full bags (or grouping up for a dungeon) - the town's hand-ins now, then the plan from there", function()
  inWorld(function()
    local list = {
      { id = 1, k = "obj", q = 901, text = "Kill 8 Croc", match = "Croc", m = 1437, x = 0.65, y = 0.45, r = 60, sec = 1 },
      { id = 2, k = "turnin", q = 901, name = "Crocs", m = 1437, x = 0.10, y = 0.57, r = 6, sec = 1 },
      { id = 3, k = "accept", q = 902, name = "Next Thing", m = 1437, x = 0.66, y = 0.46, r = 6, sec = 1 },
    }
    for k = 4, 30 do list[k] = { id = k, k = "accept", q = 901000 + k, name = "Filler " .. k, m = 1437, x = 0.70, y = 0.50, r = 6, sec = 1 } end
    list[31] = { id = 31, k = "turnin", q = 960, name = "Town Errand", m = 1437, x = 0.105, y = 0.565, r = 6, sec = 1 }
    for k = 32, 35 do list[k] = { id = k, k = "accept", q = 902000 + k, name = "Town " .. k, m = 1437, x = 0.104, y = 0.566, r = 6, sec = 1 } end
    ForeverRouteData = { id = "n3", title = "n3", sections = { { title = "x" } }, steps = list }
    quests({ [960] = true }, { [901] = true })
    -- out in the croc marsh: the crocs
    at(0.65, 0.45)
    assertEquals(1, ns.Engine.current)
    -- bags full: back to Menethil to sell - the finished town quest's hand-in is right here
    at(0.105, 0.565, 4)
    assertEquals(31, ns.Engine.current, "in town with a finished quest for the NPC beside you")
    -- handed in: the plan again, from where you are
    quests({}, { [901] = true }); ns.State.IsCompleted = function(q) return q == 960 end
    at(0.105, 0.565, 4)
    assertEquals(1, ns.Engine.current)
  end)
end)

test("next: standing in a town, its flight path and pick-ups come before a step across the zone", function()
  inWorld(function()
    ns.State.knownTaxi = {}
    ForeverRouteData = { id = "n4", steps = {
      { k = "accept", q = 226, name = "Wolves at Our Heels", m = 1431, x = 0.077, y = 0.332, sec = 1 },
      { k = "fp", npc = "Felicia Maline", m = 1431, x = 0.7749, y = 0.4429, zone = "Duskwood", sec = 2 },
      { k = "accept", q = 163, name = "Raven Hill", m = 1431, x = 0.7534, y = 0.4875, sec = 2 },
    } }
    quests({}, {})
    local x, y, inst = HBD:GetWorldCoordinatesFromZone(0.776, 0.442, 1431)
    ns.Engine.UpdateFocus(x, y, inst); ns.Engine.Refresh()
    assertTrue(ns.Engine.current == 2 or ns.Engine.current == 3, "walked across the zone first: " .. tostring(ns.Engine.current))
  end)
end)

test("next: never picks a pick-up whose earlier chain quest isn't handed in (Chef Grual)", function()
  inWorld(function()
    local unl = ForeverRouteUnlocks
    ForeverRouteUnlocks = { [5] = { 93 } }
    ForeverRouteData = { id = "n5", steps = {
      { k = "accept", q = 226, name = "Wolves at Our Heels", m = 1431, x = 0.077, y = 0.332, sec = 1 },
      { k = "accept", q = 93, name = "Dusky Crab Cakes", m = 1431, x = 0.7375, y = 0.4348, sec = 2 },
    } }
    quests({}, {})
    local x, y, inst = HBD:GetWorldCoordinatesFromZone(0.74, 0.44, 1431)
    ns.Engine.UpdateFocus(x, y, inst); ns.Engine.Refresh()
    local before = ns.Engine.current
    ns.State.IsCompleted = function(q) return q == 5 end
    ns.Engine.pos = nil; ns.Engine.UpdateFocus(x + 31, y, inst); ns.Engine.Refresh()
    local after = ns.Engine.current
    ForeverRouteUnlocks = unl
    assertEquals(1, before, "Chef Grual has nothing yet")
    assertEquals(2, after, "Growling Gut handed in: now he offers it, and he's right here")
  end)
end)

test("next: farming the plan's own step, a later step whose circle you wander into doesn't take over", function()
  inWorld(function()
    local scales = 2
    ForeverRouteData = { id = "n6", title = "n6", sections = { { title = "x" } }, steps = {
      { id = 1, k = "obj", q = 98072, text = "Collect 8 Pristine Crimson Scale", match = "Pristine Crimson Scale", m = 1437, x = 0.649, y = 0.464, r = 90, sec = 1 },
      { id = 2, k = "obj", q = 465, text = "Collect 5 Far Thing", match = "Far Thing", m = 1437, x = 0.20, y = 0.464, r = 90, sec = 1 },
    } }
    ns.State.OnQuest = function(id) return id == 98072 or id == 465 end
    ns.State.IsCompleted = function() return false end
    ns.State.Quest = function(id)
      if id == 98072 then return { on = true, objectives = { { text = "Pristine Crimson Scale: " .. scales .. "/8", finished = false, have = scales, need = 8 } } } end
      if id == 465 then return { on = true, objectives = { { text = "Far Thing: 0/5", finished = false, have = 0, need = 5 } } } end
      return { on = false, objectives = {} }
    end
    at(0.649, 0.464)
    assertEquals(1, ns.Engine.current)
    ns.Fire("FR_STATE"); scales = 3; ns.Fire("FR_STATE") -- loot counting for the plan's step
    at(0.20, 0.464)                                       -- in the far step's circle, still looting scales
    assertEquals(1, ns.Engine.current)
  end)
end)

test("next: a small gain doesn't flip the card back and forth (hysteresis)", function()
  inWorld(function()
    ForeverRouteData = { id = "n7", title = "n7", sections = { { title = "x" } }, steps = {
      { id = 1, k = "accept", q = 1, name = "A", m = 1437, x = 0.50, y = 0.50, r = 6, sec = 1 },
      { id = 2, k = "accept", q = 2, name = "B", m = 1437, x = 0.53, y = 0.50, r = 6, sec = 1 },
      { id = 3, k = "accept", q = 3, name = "C", m = 1437, x = 0.60, y = 0.50, r = 6, sec = 1 },
    } }
    quests({}, {})
    at(0.515, 0.50)
    local first = ns.Engine.current
    -- a few yards each way: the card stays
    for _, dx in ipairs({ 6, -6, 8, -4 }) do
      ns.Engine.pos = nil
      at(0.515, 0.50, dx)
      assertEquals(first, ns.Engine.current, "flipped at " .. dx)
    end
  end)
end)

test("next: off, the plan's order and the old reordering are back", function()
  inWorld(function()
    local was = ns.db.smartNext
    ns.db.smartNext = false
    local list = { { id = 1, k = "accept", q = 901, name = "Far Planned", m = 1437, x = 0.60, y = 0.30, r = 6, sec = 1 } }
    list[2] = { id = 2, k = "accept", q = 902, name = "Here", m = 1437, x = 0.10, y = 0.57, r = 6, sec = 1 }
    ForeverRouteData = { id = "n8", title = "n8", sections = { { title = "x" } }, steps = list }
    quests({}, {})
    ns.Engine.Refresh()
    local cur = ns.Engine.current
    ns.db.smartNext = was
    assertEquals(1, cur)
  end)
end)

test("chains: a link below you is kept while the chain leads to quests still worth XP; a chain gray all the way goes", function()
  inWorld(function()
    local unl, lvl = ForeverRouteUnlocks, UnitLevel
    UnitLevel = function() return 40 end
    ForeverRouteUnlocks = { [501] = { 502, 503 }, [601] = { 602 } }
    ForeverRouteData = { id = "c1", title = "c1", sections = { { title = "x" } }, steps = {
      { id = 1, k = "accept", q = 501, name = "Chain Start", level = 30, m = 1437, x = 0.5, y = 0.5, r = 6, sec = 1 },
      { id = 2, k = "accept", q = 502, name = "Chain Middle", level = 33, m = 1437, x = 0.5, y = 0.5, r = 6, sec = 1 },
      { id = 3, k = "accept", q = 503, name = "Chain Finale", level = 38, m = 1437, x = 0.5, y = 0.5, r = 6, sec = 1 },
      { id = 4, k = "accept", q = 601, name = "Gray Start", level = 28, m = 1437, x = 0.5, y = 0.5, r = 6, sec = 1 },
      { id = 5, k = "accept", q = 602, name = "Gray End", level = 30, m = 1437, x = 0.5, y = 0.5, r = 6, sec = 1 },
    } }
    quests({}, {})
    local keepStart = ns.Engine.Outlevelled(ForeverRouteData.steps[1])
    local dropGray = ns.Engine.Outlevelled(ForeverRouteData.steps[4])
    UnitLevel, ForeverRouteUnlocks = lvl, unl
    assertTrue(not keepStart, "a level-30 chain start at 40, its finale level 38: cut")
    assertTrue(dropGray, "a chain of quests all far below you: kept")
  end)
end)

test("next: bags nearly full - a vendor goes into the way where it costs least, and the errand line says which and when", function()
  inWorld(function()
    local sv = { vendors = ns.VENDORS, free = ns.Errands.FreeSlots, dur = ns.Errands.Durability }
    local ok, err = pcall(function()
      ns.VENDORS = { [1437] = { { 0.51, 0.50, "Neal Allen", "General Goods", true }, { 0.90, 0.90, "Far Seller", "Trade Goods" } } }
      ns.Errands.Durability = function() return 1 end
      ForeverRouteData = { id = "v1", title = "v1", sections = { { title = "x" } }, steps = {
        { id = 1, k = "accept", q = 1, name = "A", m = 1437, x = 0.50, y = 0.50, r = 6, sec = 1 },
        { id = 2, k = "accept", q = 2, name = "B", m = 1437, x = 0.70, y = 0.50, r = 6, sec = 1 },
      } }
      quests({}, {})
      ns.Errands.FreeSlots = function() return 20 end
      at(0.50, 0.50, 3)
      assertNil(ns.Next.vendor, "a vendor with bags to spare")
      ns.Errands.FreeSlots = function() return 1 end
      ns.Engine.pos = nil
      at(0.50, 0.50, 4)
      assertTrue(ns.Next.vendor ~= nil and ns.Next.vendor.v[3] == "Neal Allen", "the vendor 35 yd away, not the far one")
      assertEquals(1, ns.Engine.current, "the card still shows the plan's step")
      local line = ns.Errands.Current()
      assertTrue(line and line:find("Neal Allen", 1, true) ~= nil, tostring(line))
    end)
    ns.VENDORS, ns.Errands.FreeSlots, ns.Errands.Durability = sv.vendors, sv.free, sv.dur
    if not ok then error(err, 0) end
  end)
end)

test("next: out in the field a lone finished hand-in waits for the hub - unless its chain goes on right there", function()
  inWorld(function()
    local unl = ForeverRouteUnlocks
    local list = {
      { id = 1, k = "obj", q = 901, text = "Kill 8 Croc", match = "Croc", m = 1437, x = 0.65, y = 0.45, r = 60, sec = 1 },
      { id = 2, k = "accept", q = 902, name = "Next Thing", m = 1437, x = 0.30, y = 0.30, r = 6, sec = 1 },
    }
    for k = 3, 30 do list[k] = { id = k, k = "accept", q = 901000 + k, name = "Filler " .. k, m = 1437, x = 0.70, y = 0.50, r = 6, sec = 1 } end
    -- a farmer in the field with a finished quest; later the plan's chain quest from him
    list[31] = { id = 31, k = "turnin", q = 970, name = "Field Errand", m = 1437, x = 0.40, y = 0.40, r = 6, sec = 1 }
    list[32] = { id = 32, k = "accept", q = 971, name = "Field Errand II", m = 1437, x = 0.40, y = 0.40, r = 6, sec = 1 }
    ForeverRouteData = { id = "f1", title = "f1", sections = { { title = "x" } }, steps = list }
    quests({ [970] = true }, { [901] = true })
    ForeverRouteUnlocks = {}
    at(0.40, 0.40, 3)
    local lone = ns.Engine.current
    ForeverRouteUnlocks = { [970] = { 971 } }
    ns.Engine.pos = nil
    at(0.40, 0.40, 40) -- (a step away: a new solve)
    local chained = ns.Engine.current
    local why = ns.Next.Reason(31)
    ForeverRouteUnlocks = unl
    assertTrue(lone ~= 31, "a lone hand-in in the field was taken early")
    assertEquals(31, chained, "the chain goes on right here: hand it in and take the next")
    assertTrue(why:find("chain", 1, true) ~= nil, why)
  end)
end)

test("next: a hand-in run at a hub is named on the card - how many and about how much XP", function()
  inWorld(function()
    local list = {}
    for k = 1, 4 do list[k] = { id = k, k = "turnin", q = 800 + k, name = "Done " .. k, level = UnitLevel("player"), m = 1437, x = 0.105 + k * 0.001, y = 0.565, r = 6, sec = 1 } end
    list[5] = { id = 5, k = "accept", q = 899, name = "Next", m = 1437, x = 0.60, y = 0.30, r = 6, sec = 1 }
    ForeverRouteData = { id = "b1", title = "b1", sections = { { title = "x" } }, steps = list }
    quests({ [801] = true, [802] = true, [803] = true, [804] = true }, {})
    at(0.106, 0.565)
    local run = ns.Next.Batch(ns.Engine.current)
    assertTrue(run ~= nil and run.n == 4 and run.xp > 0, "no hand-in run named")
  end)
end)

test("next: why not that step? - the route list says what doing it first would cost", function()
  inWorld(function()
    ForeverRouteData = { id = "w1", title = "w1", sections = { { title = "x" } }, steps = {
      { id = 1, k = "accept", q = 1, name = "Here", m = 1437, x = 0.50, y = 0.50, r = 6, sec = 1 },
      { id = 2, k = "accept", q = 2, name = "Far", m = 1437, x = 0.90, y = 0.90, r = 6, sec = 1 },
      { id = 3, k = "accept", q = 3, name = "Here too", m = 1437, x = 0.51, y = 0.50, r = 6, sec = 1 },
    } }
    quests({}, {})
    at(0.50, 0.50, 2)
    local best = ns.Engine.current
    assertTrue(ns.Next.WhyNot(best):find("best next step", 1, true) ~= nil)
    local far = ns.Next.WhyNot(2)
    assertTrue(far and far:find("min longer", 1, true) ~= nil, tostring(far))
    assertNil(ns.Next.WhyNot(99))
  end)
end)

test("next: \"not now\" on a while-you're-here hand-in - the plan's step comes back; walk on and it's offered again", function()
  inWorld(function()
    local list = { { id = 1, k = "accept", q = 901, name = "Far Planned", m = 1437, x = 0.60, y = 0.30, r = 6, sec = 1 } }
    for k = 2, 40 do list[k] = { id = k, k = "accept", q = 901000 + k, name = "Filler " .. k, m = 1437, x = 0.62, y = 0.32, r = 6, sec = 1 } end
    list[41] = { id = 41, k = "turnin", q = 98221, name = "From the Ashes", npc = "Captain Stoutfist", m = 1437, x = 0.0986, y = 0.5749, r = 6, sec = 1 }
    for k = 42, 45 do list[k] = { id = k, k = "accept", q = 902000 + k, name = "Town " .. k, m = 1437, x = 0.099, y = 0.576, r = 6, sec = 1 } end
    ForeverRouteData = { id = "n9", title = "n9", sections = { { title = "x" } }, steps = list }
    quests({ [98221] = true }, {})
    ns.Next.dismissed = {}
    at(0.0986, 0.5749, 3)
    assertEquals(41, ns.Engine.current, "the hand-in next to you")
    assertTrue(ns.Next.CanDismiss(41))
    assertTrue(not ns.Next.CanDismiss(1), "the plan's own step can't be put off")
    assertTrue(ns.Next.Dismiss(41))
    assertEquals(1, ns.Engine.current, "not now: the plan's step")
    at(0.0990, 0.5752, 3)
    assertEquals(1, ns.Engine.current, "still here: it stays off")
    -- walk away (out of DISMISS_YD) and come back: offered again
    at(0.40, 0.45)
    at(0.0986, 0.5749, 3)
    assertEquals(41, ns.Engine.current, "back after moving on: offered again")
    ns.Next.dismissed = {}
  end)
end)

test("next: in a capital, its finished hand-ins come before the plan's trip out, wherever they are in the city (Stormwind, tester)", function()
  inWorld(function()
    -- the plan: off to the Wetlands; A Noble Brew's hand-in in the Mage Quarter comes much later
    local list = { { id = 1, k = "accept", q = 87318, name = "Hearts of the Lost", npc = "Corma Villard", m = 1437, x = 0.50, y = 0.13, r = 6, sec = 1 } }
    for k = 2, 40 do list[k] = { id = k, k = "accept", q = 903000 + k, name = "Wetlands " .. k, m = 1437, x = 0.52, y = 0.15, r = 6, sec = 1 } end
    list[41] = { id = 41, k = "turnin", q = 335, name = "A Noble Brew", npc = "Zardeth of the Black Claw", m = 1453, x = 0.4014, y = 0.8531, r = 6, sec = 1, level = 30 }
    ForeverRouteData = { id = "n-city", title = "n-city", sections = { { title = "x" } }, steps = list }
    quests({ [335] = true }, {})
    local realLevel = UnitLevel; UnitLevel = function() return 32 end
    local ok, err = pcall(function() -- (the sim's character is 70: a level 30 quest would be gray)
    -- at the Stormwind flight master: the hand-in is ~1100 yd off here, far over the "while you're here" distance
    at(0.713, 0.722, 0, 1453)
    assertEquals(41, ns.Engine.current, "the city hand-in before leaving town")
    assertTrue(ns.Next.Reason(41):find("comes back here", 1, true) ~= nil, ns.Next.Reason(41))
    -- the same hand-in, but you're out in the Wetlands: no trip back to Stormwind for it
    at(0.52, 0.15, 0, 1437)
    assertEquals(1, ns.Engine.current, "out of town: the plan")
    end)
    UnitLevel = realLevel
    if not ok then error(err, 0) end
  end)
end)

test("next: already where the plan goes after its trip (flew on ahead) - quest here first, the trip waits (Wetlands, tester)", function()
  inWorld(function()
    local list = {
      { id = 1, k = "fly", to = 1453, dest = "Stormwind", text = "Stormwind", sec = 1 },
      { id = 2, k = "turnin", q = 335, name = "A Noble Brew", m = 1453, x = 0.40, y = 0.85, r = 6, sec = 1 },
      { id = 3, k = "fly", to = 1437, dest = "Wetlands", text = "Wetlands", sec = 2 },
    }
    for k = 4, 12 do list[k] = { id = k, k = "accept", q = 904000 + k, name = "Wetlands " .. k, m = 1437, x = 0.10 + k * 0.002, y = 0.60, r = 6, sec = 2 } end
    ForeverRouteData = { id = "n-rejoin", title = "n-rejoin", sections = { { title = "x" }, { title = "y" } }, steps = list }
    quests({ [335] = true }, {})
    at(0.11, 0.60, 0, 1437)
    assertTrue(ns.Engine.current >= 4, "questing here, not the flight back: " .. tostring(ns.Engine.current))
    assertEquals(1, ns.Engine.planned, "the trip is still the plan's step (it comes back once these are done)")
    assertTrue(ns.Next.Reason(ns.Engine.current):find("here already", 1, true) ~= nil, ns.Next.Reason(ns.Engine.current))
    -- somewhere the plan doesn't go next (Duskwood): the trip stands
    at(0.50, 0.50, 0, 1431)
    assertEquals(1, ns.Engine.current, "elsewhere: the plan's trip")
  end)
end)

test("next: you just arrived where the plan comes back to later (hearthed to Stormwind; the plan goes to Ironforge first and hearths back for the hand-ins) - the later visit now, its trip goes", function()
  inWorld(function()
    local realLevel = UnitLevel; UnitLevel = function() return 33 end
    local ok, err = pcall(function()
      local list = {
        { id = 1, k = "fly", to = 1455, dest = "Ironforge", text = "Ironforge", sec = 1 },
        { id = 2, k = "accept", q = 905001, name = "Ironforge Errand", m = 1455, x = 0.30, y = 0.30, r = 6, sec = 1 },
        { id = 3, k = "turnin", q = 905001, name = "Ironforge Errand", m = 1455, x = 0.31, y = 0.30, r = 6, sec = 1 },
        { id = 4, k = "hearth", dest = "Stormwind", sec = 2 },
        { id = 5, k = "turnin", q = 905002, name = "Ready One", m = 1453, x = 0.40, y = 0.85, r = 6, sec = 2 },
        { id = 6, k = "accept", q = 905003, name = "Its Next Part", m = 1453, x = 0.40, y = 0.85, r = 6, sec = 2 },
        { id = 7, k = "turnin", q = 905003, name = "Its Next Part", m = 1453, x = 0.77, y = 0.49, r = 6, sec = 2 },
        { id = 8, k = "turnin", q = 905004, name = "Ready Two", m = 1453, x = 0.50, y = 0.45, r = 6, sec = 2 },
        { id = 9, k = "fly", to = 1431, dest = "Duskwood", text = "Duskwood", sec = 3 },
      }
      for k = 10, 30 do list[k] = { id = k, k = "accept", q = 906000 + k, name = "Duskwood " .. k, m = 1431, x = 0.75, y = 0.45, r = 6, sec = 3 } end
      ForeverRouteData = { id = "n-visit", title = "n-visit", sections = { { title = "a" }, { title = "b" }, { title = "c" } }, steps = list }
      quests({ [905002] = true, [905004] = true }, {})
      at(0.56, 0.74, 0, 1453) -- in Stormwind, just hearthed
      local c = ns.Engine.current
      assertTrue(c == 5 or c == 8, "a Stormwind hand-in first, not the flight to Ironforge: " .. tostring(c))
      assertTrue(ns.Next.Reason(c):find("comes back here", 1, true) ~= nil, ns.Next.Reason(c))
      -- the same, but the plan's Stormwind visit also has work to do (it happens anyway): the plan's order stands
      table.insert(list, 6, { id = 0, k = "obj", q = 905009, text = "Kill 10 Rats", m = 1453, x = 0.6, y = 0.6, r = 40, sec = 2 })
      for k, s in ipairs(list) do s.id = k end
      ns.Engine.Refresh()
      at(0.56, 0.74, 5, 1453)
      assertEquals(1, ns.Engine.current, "the visit happens anyway: the flight to Ironforge")
    end)
    UnitLevel = realLevel
    if not ok then error(err, 0) end
  end)
end)

-- One price for "now or later" (Next.Prize, Next.DeferCost): coming back later is priced by the plan's real way, not
-- by a straight line between its steps. The plan's worlds below: towns it was at before (Thorium Point, Darkshire:
-- hubs, four steps each), then Southshore, a flight to Duskwood, and Raven Hill - 1,500 yd west of where the flight
-- lands. Thorium Point lies under the straight line from Southshore to Duskwood (the Engine.InsertStop case, de03647),
-- but the flight passes nothing: a hand-in there is never on the way, so it is worth its XP. One beside the Darkshire
-- flight master is on the way - the walk from where you land to Raven Hill starts there - though no stop of the plan
-- is anywhere near it: only the trip's own walk (Travel.Plan's landing, P) puts it on the way.
local function deferWorld(steps, fn, at)
  local sv = { info = C_Map.GetMapInfo, routes = ns.DungeonRoutes, flight = ns.FLIGHT }
  local names = { [1424] = "Hillsbrad Foothills", [1427] = "Searing Gorge", [1428] = "Burning Steppes", [1431] = "Duskwood", [1433] = "Redridge Mountains" }
  C_Map.GetMapInfo = function(m) local i = (sv.info and sv.info(m)) or {}; if names[m] then return { mapID = m, name = names[m], mapType = i.mapType, parentMapID = i.parentMapID } end return i end
  ns.DungeonRoutes = function() return {} end
  local A = ns.FLIGHT_BY.Alliance
  ns.FLIGHT = { [1424] = A[1424], [1427] = A[1427], [1428] = A[1428], [1431] = A[1431], [1433] = A[1433] }
  for i, s in ipairs(steps) do s.id = i; s.sec = 1 end
  local route = { id = "defer", title = "defer", sections = { { title = "Defer" } }, steps = steps }
  local ok, err = pcall(ForeverRouteTest.withWorld, route, function(w)
    w:knows({ "Southshore, Hillsbrad", "Darkshire, Duskwood", "Thorium Point, Searing Gorge" })
    fn(w, ForeverRouteData.steps)
  end, { anyTarget = true, at = at or { m = 1424, x = 0.5052, y = 0.5183, level = 30 } })
  C_Map.GetMapInfo, ns.DungeonRoutes, ns.FLIGHT = sv.info, sv.routes, sv.flight
  ns.Next._askLeft(nil)
  if not ok then error(err, 0) end
end
-- four steps at one place: a hub (Next.HUB_STEPS), where a finished quest's hand-in is offered whenever you pass
local function hub(out, q, m, x, y)
  for k = 0, 1 do
    out[#out + 1] = { k = "accept", q = q + k, name = "Hub " .. (q + k), npc = "Hub", m = m, x = x, y = y, r = 6, level = 30 }
    out[#out + 1] = { k = "turnin", q = q + k, name = "Hub " .. (q + k), npc = "Hub", m = m, x = x, y = y, r = 6, level = 30 }
  end
end

test("next: leaving a stop for later is priced by the plan's real trip - a flight passes nothing under it, and the walk from where it lands passes the Darkshire flight master (Thorium Point, Darkshire)", function()
  local tp = ns.FLIGHT_BY.Alliance[1427][1]
  local steps = {}
  hub(steps, 905301, 1427, tp[1], tp[2])
  hub(steps, 905311, 1431, 0.7760, 0.4440)
  steps[#steps + 1] = { k = "fly", to = 1424, dest = "Hillsbrad Foothills", text = "Hillsbrad Foothills" }
  steps[#steps + 1] = { k = "accept", q = 98219, name = "The Shamed Lieutenant", npc = "Lieutenant Farren Orinelle", m = 1424, x = 0.5146, y = 0.5839, r = 6, level = 30 }
  local from = #steps
  steps[#steps + 1] = { k = "fly", to = 1431, dest = "Duskwood", text = "Duskwood" }
  steps[#steps + 1] = { k = "obj", q = 905399, text = "Raven Hill", match = "Raven Hill", m = 1431, x = 0.20, y = 0.55, r = 60, work = 60 }
  deferWorld(steps, function(w, list)
    local under = { k = "turnin", q = 905301, name = "Under the Line", level = 30, m = 1427, x = tp[1], y = tp[2], r = 6 }
    local landing = { k = "turnin", q = 905311, name = "Where You Land", level = 30, m = 1431, x = 0.7760, y = 0.4440, r = 6 }
    assertTrue(ns.Next._isHub(list, under) and ns.Next._isHub(list, landing), "the test's premise: both hand-ins are at hubs")
    local P = ns.Next._wpos
    -- (the straight line from Southshore to Raven Hill passes near Thorium Point: a straight-line price was a small detour)
    local a, b, s = P(list[from]), P(list[#list]), P(under)
    local straight = math.sqrt((a[1] - s[1]) ^ 2 + (a[2] - s[2]) ^ 2) + math.sqrt((s[1] - b[1]) ^ 2 + (s[2] - b[2]) ^ 2) - math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2)
    assertTrue(straight < 1500, "the test's premise: Thorium Point is near the straight line (" .. math.floor(straight) .. " yd out of the way)")
    -- (and no stop of the plan from Southshore on is near the Darkshire flight master: only the trip's walk is)
    local l = P(landing)
    for j = from, #list do local t = P(list[j]); if t then assertTrue(t[3] ~= l[3] or math.sqrt((t[1] - l[1]) ^ 2 + (t[2] - l[2]) ^ 2) > 1200, "the test's premise: step " .. j .. " is near the landing") end end
    -- the trip is asked: count it, and see where it lands
    local calls, plan = 0, ns.Travel.Plan
    ns.Travel.Plan = function(...) calls = calls + 1; return plan(...) end
    local d = ns.Next.DeferCost(list, landing, from)
    ns.Travel.Plan = plan
    assertTrue(calls > 0, "the plan's trip was never asked (Travel.Plan)")
    assertTrue(d < ns.Next.SERVICE.turnin + ns.Next.CARRY + 30, "beside the flight master the plan lands at: on the way (" .. tostring(d) .. " s)")
    assertEquals(d, ns.Next.Prize(list, landing, from), "a stop the plan comes by is worth leaving for then: the trip back, not its XP")
    assertEquals(math.huge, ns.Next.DeferCost(list, under, from), "the flight passes Thorium Point: the plan never comes by")
    local pays = ns.Engine.QuestXP(30, 30) / (UnitXPMax("player") / 5400)
    assertTrue(math.abs(ns.Next.Prize(list, under, from) - pays) < 1, "never on the way: worth its XP")
    -- (where you stand doesn't move a price: it is the plan's, and a price that moved would flip the card)
    w:go(1431, 0.70, 0.50)
    assertEquals(d, ns.Next.DeferCost(list, landing, from))
    -- a stop that isn't a hand-in at a hub is never offered on a pass: the walk past it is no second chance
    local field = { k = "obj", q = 905398, text = "Beside the flight master", m = 1431, x = 0.7760, y = 0.4440, r = 30 }
    assertEquals(math.huge, ns.Next.DeferCost(list, field, from), "an objective in open country: the plan never offers it again")
  end)
end)

-- Across the plan's own hearth the way is the hearth: the walk to wherever you cast it (no way back - you hearth from
-- there), then on from the inn the plan bound you at. The trip planner without the hearthstone would fly from
-- Southshore, and price a stop 300 yd east of the plan's last Southshore step as the walk there and back to the
-- flight master.
test("next: leaving a stop for later across the plan's hearth - the walk before it, one way, and from the inn on", function()
  local steps = {}
  steps[#steps + 1] = { k = "bind", name = "Scarlet Raven Inn", npc = "Innkeeper Trelayne", m = 1431, x = 0.7395, y = 0.4446, r = 6 }
  hub(steps, 905321, 1424, 0.6083, 0.5839)
  hub(steps, 905331, 1431, 0.40, 0.48)
  steps[#steps + 1] = { k = "fly", to = 1424, dest = "Hillsbrad Foothills", text = "Hillsbrad Foothills" }
  steps[#steps + 1] = { k = "accept", q = 98219, name = "The Shamed Lieutenant", npc = "Lieutenant Farren Orinelle", m = 1424, x = 0.5146, y = 0.5839, r = 6, level = 30 }
  local from = #steps
  steps[#steps + 1] = { k = "hearth", text = "Darkshire", dest = "Darkshire" }
  steps[#steps + 1] = { k = "obj", q = 905399, text = "Raven Hill", match = "Raven Hill", m = 1431, x = 0.20, y = 0.55, r = 60, work = 60 }
  deferWorld(steps, function(w, list)
    local P = ns.Next._wpos
    local east = { k = "turnin", q = 905321, name = "East of Southshore", level = 30, m = 1424, x = 0.6083, y = 0.5839, r = 6 }
    local a, s = P(list[from]), P(east)
    local walk = math.sqrt((a[1] - s[1]) ^ 2 + (a[2] - s[2]) ^ 2)
    local function want() return ns.Next.SERVICE.turnin + ns.Next.CARRY + walk * 1.25 / ns.Travel.Speed() end
    assertTrue(math.abs(ns.Next.DeferCost(list, east, from) - want()) < 1, "the walk there, one way, before the hearth: " .. ns.Next.DeferCost(list, east, from) .. " s, not " .. want())
    -- after the hearth: the walk from the inn to Raven Hill passes a hub half way
    local mid = { k = "turnin", q = 905331, name = "On the Way West", level = 30, m = 1431, x = 0.40, y = 0.48, r = 6 }
    assertTrue(ns.Next.DeferCost(list, mid, from) < ns.Next.SERVICE.turnin + ns.Next.CARRY + 60, "on the walk from the inn: on the way")
    -- the price follows your speed: mounted at 40 the walk is shorter (and remembered under the speed it was priced at)
    w:ding(40)
    assertTrue(math.abs(ns.Next.DeferCost(list, east, from) - want()) < 1, "priced again at the mounted speed")
  end)
end)

-- A price still missing a trip (a solve's searches are bounded, Next.ASK_PER_PICK) is taken as "the plan comes by" -
-- never as "it never does", which would send you off for it on a guess - and is asked again next time.
test("next: a price still missing its trip is taken as on the way until it is priced, and not remembered", function()
  local steps = {}
  hub(steps, 905311, 1431, 0.7760, 0.4440)
  steps[#steps + 1] = { k = "fly", to = 1424, dest = "Hillsbrad Foothills", text = "Hillsbrad Foothills" }
  steps[#steps + 1] = { k = "accept", q = 98219, name = "The Shamed Lieutenant", npc = "Lieutenant Farren Orinelle", m = 1424, x = 0.5146, y = 0.5839, r = 6, level = 30 }
  local from = #steps
  steps[#steps + 1] = { k = "fly", to = 1431, dest = "Duskwood", text = "Duskwood" }
  steps[#steps + 1] = { k = "obj", q = 905399, text = "Raven Hill", match = "Raven Hill", m = 1431, x = 0.20, y = 0.55, r = 60, work = 60 }
  deferWorld(steps, function(w, list)
    -- (a hand-in at the Darkshire hub: only the walk from where the flight lands passes it, and that trip is not priced yet)
    local landing = { k = "turnin", q = 905311, name = "Where You Land", level = 30, m = 1431, x = 0.7760, y = 0.4440, r = 6 }
    ns.Next._askLeft(0)
    assertEquals(ns.Next.SERVICE.turnin + ns.Next.CARRY, ns.Next.DeferCost(list, landing, from), "no search left: on the way, for now")
    ns.Next._askLeft(nil)
    local d = ns.Next.DeferCost(list, landing, from)
    assertTrue(d >= ns.Next.SERVICE.turnin + ns.Next.CARRY and d < math.huge, "priced once it may ask")
  end)
end)

-- What a quest pays (Next.BehindPrize): Engine.QuestXP at your level - a quest far below you still pays its cut (gray
-- mobs give nothing; gray quests don't) - less the work still to do for it: only the objectives your log doesn't have
-- finished, and the walk on to the hand-in only after work whose length is known.
test("next: a quest's price - its XP even when gray, less only the objectives still to do", function()
  local steps = {
    { k = "accept", q = 905401, name = "Two Things", npc = "Giver", m = 1431, x = 0.70, y = 0.45, r = 6, level = 30 },
    { k = "obj", q = 905401, text = "Thing A", match = "Thing A", m = 1431, x = 0.60, y = 0.45, r = 30, work = 100, walk = 200 },
    { k = "obj", q = 905401, text = "Thing B", match = "Thing B", m = 1431, x = 0.50, y = 0.45, r = 30, work = 50, walk = 300 },
    { k = "turnin", q = 905401, name = "Two Things", npc = "Giver", m = 1431, x = 0.70, y = 0.45, r = 6, level = 30, walk = 400 },
    { k = "accept", q = 905402, name = "Old Errand", npc = "Giver", m = 1431, x = 0.70, y = 0.45, r = 6, level = 10 },
    { k = "accept", q = 905403, name = "No Numbers", npc = "Giver", m = 1431, x = 0.70, y = 0.45, r = 6, level = 30 },
    { k = "obj", q = 905403, text = "Thing C", match = "Thing C", m = 1431, x = 0.60, y = 0.45, r = 30 },
    { k = "turnin", q = 905403, name = "No Numbers", npc = "Giver", m = 1431, x = 0.70, y = 0.45, r = 6, level = 30, walk = 400 },
  }
  deferWorld(steps, function(w, list)
    local rate = UnitXPMax("player") / 5400
    local spd = ns.Travel.Speed()
    local function prize(j, L) return ns.Next.BehindPrize(list, list[j], L) end
    -- both objectives to do: their work, their walks and the walk on to the hand-in
    assertTrue(math.abs(prize(1, 30) - (ns.Engine.QuestXP(30, 30) / rate - 150 - (200 + 300 + 400) * 1.25 / spd)) < 0.5, "both to do: " .. prize(1, 30))
    -- one done in your log: only the other's
    w:quest(905401, { on = true, objectives = { { text = "Thing A: 1/1", finished = true, have = 1, need = 1 }, { text = "Thing B: 0/1", finished = false, have = 0, need = 1 } } })
    assertTrue(math.abs(prize(1, 30) - (ns.Engine.QuestXP(30, 30) / rate - 50 - (300 + 400) * 1.25 / spd)) < 0.5, "one to do: " .. prize(1, 30))
    -- work not known (a plan made before steps carried it): the flat guess, and no walk on that isn't known either
    assertTrue(math.abs(prize(6, 30) - (ns.Engine.QuestXP(30, 30) / rate - ns.Next.BEHIND_WORK)) < 0.5, "work not known: " .. prize(6, 30))
    -- a level 10 quest at 16 is gray, and still pays its cut (80%)
    w:ding(16)
    rate = UnitXPMax("player") / 5400
    assertTrue(ns.Engine.QuestXP(10, 16) > 0)
    assertTrue(math.abs(prize(5, 16) - (ns.Engine.QuestXP(10, 16) / rate - ns.Next.BEHIND_WORK)) < 0.5, "gray, still paid: " .. prize(5, 16))
  end, { m = 1431, x = 0.70, y = 0.45, level = 30 })
end)
