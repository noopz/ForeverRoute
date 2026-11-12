-- The live solver's picks (Next.lua over Horizon.lua) in the places the old reordering rules were written for, and in
-- the interruptions WoW brings: a trip to town with full bags, a detour to group for a dungeon.
local ns = ForeverRoute
local withState = ForeverRouteTest.withState
local HBD = LibStub("HereBeDragons-2.0")

-- a world where 1% of a map is 35 yd, everything on one continent
local function inWorld(fn)
  local realConv, realPos = HBD.GetWorldCoordinatesFromZone, ns.State.Position
  local ok, err = pcall(withState, {}, function()
    HBD.GetWorldCoordinatesFromZone = function(_, mx, my, m) return mx * 3500, my * 3500, 0 end
    fn()
  end)
  HBD.GetWorldCoordinatesFromZone, ns.State.Position = realConv, realPos
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
    for k = 2, 40 do list[k] = { id = k, k = "accept", q = 1000 + k, name = "Filler " .. k, m = 1437, x = 0.62, y = 0.32, r = 6, sec = 1 } end
    list[41] = { id = 41, k = "turnin", q = 98221, name = "From the Ashes", npc = "Captain Stoutfist", m = 1437, x = 0.0986, y = 0.5749, r = 6, sec = 1 }
    -- (Menethil: a town the plan stops at a lot)
    for k = 42, 45 do list[k] = { id = k, k = "accept", q = 2000 + k, name = "Town " .. k, m = 1437, x = 0.099, y = 0.576, r = 6, sec = 1 } end
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
    for k = 4, 30 do list[k] = { id = k, k = "accept", q = 1000 + k, name = "Filler " .. k, m = 1437, x = 0.70, y = 0.50, r = 6, sec = 1 } end
    list[31] = { id = 31, k = "turnin", q = 960, name = "Town Errand", m = 1437, x = 0.105, y = 0.565, r = 6, sec = 1 }
    for k = 32, 35 do list[k] = { id = k, k = "accept", q = 2000 + k, name = "Town " .. k, m = 1437, x = 0.104, y = 0.566, r = 6, sec = 1 } end
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
    for k = 3, 30 do list[k] = { id = k, k = "accept", q = 1000 + k, name = "Filler " .. k, m = 1437, x = 0.70, y = 0.50, r = 6, sec = 1 } end
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
    for k = 2, 40 do list[k] = { id = k, k = "accept", q = 1000 + k, name = "Filler " .. k, m = 1437, x = 0.62, y = 0.32, r = 6, sec = 1 } end
    list[41] = { id = 41, k = "turnin", q = 98221, name = "From the Ashes", npc = "Captain Stoutfist", m = 1437, x = 0.0986, y = 0.5749, r = 6, sec = 1 }
    for k = 42, 45 do list[k] = { id = k, k = "accept", q = 2000 + k, name = "Town " .. k, m = 1437, x = 0.099, y = 0.576, r = 6, sec = 1 } end
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
