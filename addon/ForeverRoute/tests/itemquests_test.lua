-- Quests an item starts (ItemQuests.lua): offered on the card when the item is in your bags and the quest is yours to
-- take; once taken, its objectives and hand-in are fitted into the route (Engine.SideStops).
local ns = ForeverRoute
local withWorld = ForeverRouteTest.withWorld

local BOTTLE, NOTE = 594, 4098        -- Message in a Bottle, from a Carefully Folded Note (level 45, either side)
local GORDUNNI, SCROLL = 2978, 9370   -- The Gordunni Scroll: Horde only
local TOOLS, TOOLS_ITEM = 86613, 278049 -- Excavation Tools (Loch Modan, Alliance, level 18): an objective and a hand-in

-- a short Loch Modan route
local function lochRoute(lvl)
  local s = {
    { k = "accept", q = 901, name = "Errand", npc = "Someone", m = 1432, x = 0.35, y = 0.47, r = 6, sec = 1, lvl = lvl },
    { k = "obj", q = 901, text = "Kill 5 Trogg", match = "Trogg", m = 1432, x = 0.60, y = 0.60, r = 60, sec = 1, lvl = lvl },
    { k = "turnin", q = 901, name = "Errand", npc = "Someone", m = 1432, x = 0.35, y = 0.47, r = 6, sec = 1, lvl = lvl },
    { k = "accept", q = 902, name = "Digging", npc = "Digger", m = 1432, x = 0.66, y = 0.64, r = 6, sec = 1, lvl = lvl },
    { k = "turnin", q = 902, name = "Digging", npc = "Digger", m = 1432, x = 0.66, y = 0.64, r = 6, sec = 1, lvl = lvl },
  }
  for i, t in ipairs(s) do t.id = i end
  return { id = "loch", title = "loch", sections = { { title = "Thelsamar" } }, steps = s }
end

-- bags you fill by hand: bag 0, one item per slot; info[item] = what the game says of it (a table, as newer clients
-- answer), or nothing
local function withBags(fn, level)
  local sv = { c = C_Container, side = UnitFactionGroup, why = ForeverRouteDB.why }
  local bag, info = {}, {}
  C_Container = {
    GetContainerNumSlots = function(b) return b == 0 and 16 or 0 end,
    GetContainerItemID = function(b, s) return b == 0 and bag[s] or nil end,
    GetContainerItemQuestInfo = function(b, s)
      local it = b == 0 and bag[s]
      if not it then return { isQuestItem = false } end
      return info[it] or { isQuestItem = true }
    end,
  }
  UnitFactionGroup = function() return "Alliance" end
  ForeverRouteDB.why = {}
  local function put(...) wipe(bag); for k, it in ipairs({ ... }) do bag[k] = it end; return ns.ItemQuests.Scan() end
  local ok, err = pcall(withWorld, lochRoute(level), function(w) fn(w, put, info) end, { at = { m = 1432, x = 0.35, y = 0.47, level = level } })
  C_Container, UnitFactionGroup, ForeverRouteDB.why = sv.c, sv.side, sv.why
  wipe(bag); ns.ItemQuests.Scan() -- (an empty bag: no offer left for the next test)
  if not ok then error(err, 0) end
end

test("item quest data: Message in a Bottle starts from the Carefully Folded Note and is handed in to Princess Poobah", function()
  local d = ns.ITEM_QUESTS and ns.ITEM_QUESTS[BOTTLE]
  assertNotNil(d, "Message in a Bottle is not in the item quest data")
  assertEquals("Message in a Bottle", d.n); assertEquals("Carefully Folded Note", d.it[NOTE])
  assertEquals("Princess Poobah", d.e[1]); assertEquals(1434, d.e[2])
  for q, e in pairs(ns.ITEM_QUESTS) do
    assertTrue(type(e.n) == "string" and type(e.l) == "number" and type(e.r) == "number" and type(e.xp) == "number", "item quest " .. q)
    assertTrue(type(e.it) == "table" and next(e.it) ~= nil, "item quest " .. q .. ": no item starts it")
    for _, o in ipairs(e.o or {}) do assertTrue(type(o[2]) == "string" and type(o[3]) == "table" and type(o[3][1]) == "number", "item quest " .. q .. ": objective") end
  end
end)

test("item quest: the note you just looted is offered on the card, with the use-item button set to it", function()
  withBags(function(w, put)
    assertNil(put(), "an offer with empty bags")
    local o = put(NOTE)
    assertNotNil(o, "Message in a Bottle was not offered")
    assertEquals(BOTTLE, o.q); assertEquals(NOTE, o.item); assertTrue(o.fresh, "it was just looted")
    local text = ns.ItemQuests.Text(o)
    assertTrue(text:find("Message in a Bottle starts from the Carefully Folded Note you just looted - use it", 1, true) ~= nil, text)
    -- the card's use-item button starts it (the step on show has no item of its own)
    local b = _G.ForeverRouteItemButton
    if b and b.GetAttribute then assertEquals("item:" .. NOTE, b:GetAttribute("item")) end
    -- the why log says so
    local said
    for _, e in ipairs(ForeverRouteDB.why) do if e.k == "itemquest" and e.x:find("Message in a Bottle", 1, true) then said = e.x end end
    assertNotNil(said, "nothing in the why log")
    -- "x": not offered again
    ns.ItemQuests.Dismiss()
    assertNil(ns.ItemQuests.Current()); assertNil(put(NOTE))
    -- carried from before the addon looked: "in your bags"
    ns.char.itemQuestNo = nil
    o = put(NOTE)
    assertNotNil(o)
    assertTrue(ns.ItemQuests.Text(o):find("in your bags", 1, true) ~= nil, ns.ItemQuests.Text(o))
  end, 45)
end)

test("item quest: not offered when done, in your log, not doing, gray, the other side's, or the game says you have it", function()
  withBags(function(w, put, info)
    assertNotNil(put(NOTE), "the control: it is offered")
    w.quests[BOTTLE] = { done = true }; assertNil(put(NOTE), "done"); w.quests[BOTTLE] = nil
    w.quests[BOTTLE] = { on = true, objectives = {} }; assertNil(put(NOTE), "in your log"); w.quests[BOTTLE] = nil
    ns.char.nope = { [BOTTLE] = true }; assertNil(put(NOTE), "you said you won't do it"); ns.char.nope = nil
    -- the game's own answer: the quest the item starts is one you have
    info[NOTE] = { isQuestItem = true, questID = BOTTLE, isActive = true }; assertNil(put(NOTE), "the game says it's active"); info[NOTE] = nil
    w.level = 60; assertNil(put(NOTE), "a level 45 quest is gray at 60")
    w.level = 44; assertNil(put(NOTE), "it needs level 45")
    w.level = 45
    assertNotNil(put(NOTE), "back once it's yours to take")
    -- the Gordunni Scroll is a Horde quest
    assertNil(put(SCROLL), "the other side's quest")
    assertEquals(BOTTLE, put(SCROLL, NOTE).q)
  end, 45)
end)

test("item quest: once taken, its objective becomes a stop on your route and its hand-in follows when it's finished", function()
  withBags(function(w, put)
    local o = put(TOOLS_ITEM)
    assertNotNil(o, "Excavation Tools was not offered"); assertEquals(TOOLS, o.q)
    local savedEnders = ForeverRouteEnders
    ForeverRouteEnders = {} -- (a plan with no hand-in spot for it: the item quest data's own)
    local ok, err = pcall(function()
      -- you use the item: the quest is in your log
      w:quest(TOOLS, { on = true, objectives = { { text = "Excavation Tools: 0/1", finished = false, have = 0, need = 1 } } })
      ns.Fire("QUEST_ACCEPTED", TOOLS)
      assertTrue(ns.char.side and ns.char.side[TOOLS], "the quest you took is not remembered")
      assertNil(put(TOOLS_ITEM), "still offered once taken")
      assertTrue(ns.Engine.SideStops(), "no stop was added for its objective")
      local obj
      for _, s in ipairs(ForeverRouteData.steps) do if s.q == TOOLS and s.k == "obj" then obj = s end end
      assertNotNil(obj, "no objective stop")
      assertEquals("Excavation Tools", obj.match); assertEquals(1432, obj.m); assertTrue(obj.inserted and obj.side)
      assertTrue(obj.note:find("the quest your Excavation Tools started", 1, true) ~= nil, obj.note)
      assertTrue(not ns.Engine.SideStops(), "asked again, it added another")
      -- finished: its hand-in, at Prospector Ironband
      w:quest(TOOLS, { on = true, complete = true, objectives = { { text = "Excavation Tools: 1/1", finished = true, have = 1, need = 1 } } })
      assertTrue(ns.Engine.SideStops(), "no hand-in was added")
      local hand
      for _, s in ipairs(ForeverRouteData.steps) do if s.q == TOOLS and s.k == "turnin" then hand = s end end
      assertNotNil(hand, "no hand-in stop")
      assertEquals("Prospector Ironband", hand.npc); assertEquals(1432, hand.m)
    end)
    ForeverRouteEnders = savedEnders
    if not ok then error(err, 0) end
  end, 18)
end)
