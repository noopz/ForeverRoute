-- Inside a dungeon: which one (by the instance id - there are no coordinates in there), what the quest log has for it,
-- and the card's dungeon state (Dungeon.lua, DungeonQuests.lua, UI/Card.lua).
local ns = ForeverRoute
local withState = ForeverRouteTest.withState

-- you, somewhere: inst = the instance map id UnitPosition gives (nil x/y/z inside), name = what GetInstanceInfo calls
-- it, hidden = the game hides its yes/no about being in an instance (ns.Is reads that as no)
local function where(o, fn)
  local sv = { pos = UnitPosition, inst = IsInInstance, info = GetInstanceInfo, lvl = UnitLevel, side = UnitFactionGroup, class = UnitClass }
  UnitPosition = function() if o.inst and o.inst > 1 then return nil, nil, nil, o.inst end return 100, 200, 0, o.inst or 0 end
  IsInInstance = function() if o.hidden then return nil end return o.name ~= nil, o.name and "party" or "none" end
  GetInstanceInfo = function() return o.name, o.name and "party" or "none", 1, "Normal", 5, 0, false, o.infoId or o.inst or 0 end
  UnitLevel = function() return o.level or 30 end
  UnitFactionGroup = function() return o.side or "Alliance" end
  UnitClass = function() return "Warlock", "WARLOCK", 9 end
  local ok, err = pcall(fn)
  UnitPosition, IsInInstance, GetInstanceInfo, UnitLevel, UnitFactionGroup, UnitClass = sv.pos, sv.inst, sv.info, sv.lvl, sv.side, sv.class
  pcall(ns.Dungeon.Check) -- back out: the card, arrow and pins follow
  if not ok then error(err, 0) end
end

test("dungeon data: instance ids name the dungeons, and each quest done inside knows its dungeon", function()
  assertEquals("City of Dalaran", ns.DUNGEONS[2959])
  assertEquals("The Deadmines", ns.DUNGEONS[36])
  assertEquals(2959, ns.Dungeon.OfQuest(92456)) -- A Green Sample
  assertEquals(36, ns.Dungeon.OfQuest(166))     -- The Defias Brotherhood
  -- filed under the Deadmines, but its cards drop in the mine before the portal: not an inside quest
  assertEquals(nil, ns.Dungeon.OfQuest(168))
  -- the continents are not dungeons
  assertEquals(nil, ns.DUNGEONS[0]); assertEquals(nil, ns.DUNGEONS[1])
end)

test("which dungeon: by the instance id, with no coordinates and the game's yes/no hidden", function()
  where({ inst = 2959, hidden = true }, function()
    local name, id = ns.Dungeon.Here()
    assertEquals("City of Dalaran", name); assertEquals(2959, id)
    assertEquals(2959, select(2, ns.Dungeon.Inside()))
    assertTrue(ns.Engine.InDungeon("City of Dalaran"))
    assertFalse(ns.Engine.InDungeon("The Deadmines"))
  end)
  -- out in the world
  where({ inst = 0 }, function() assertEquals(nil, ns.Dungeon.Here()); assertEquals(nil, ns.Dungeon.Inside()); assertFalse(ns.Engine.InDungeon("City of Dalaran")) end)
  where({ inst = 1 }, function() assertEquals(nil, ns.Dungeon.Here()) end)
end)

test("which dungeon: the id from GetInstanceInfo when UnitPosition gives none, else the instance's name", function()
  where({ infoId = 48, name = "Blackfathom Deeps" }, function()
    local sv = UnitPosition
    UnitPosition = function() return nil end
    local name, id = ns.Dungeon.Here()
    UnitPosition = sv
    assertEquals("Blackfathom Deeps", name); assertEquals(48, id)
  end)
  -- no id anywhere: the game's name for it, matched to the dungeon we know ("Deadmines" is The Deadmines)
  where({ name = "Deadmines" }, function()
    local name, id = ns.Dungeon.Here()
    assertEquals("The Deadmines", name); assertEquals(36, id)
    assertTrue(ns.Engine.InDungeon("The Deadmines"))
  end)
  -- an instance the table doesn't have: its name, no id - and no dungeon card
  where({ name = "Warsong Gulch" }, function()
    local name, id = ns.Dungeon.Here()
    assertEquals("Warsong Gulch", name); assertEquals(nil, id)
    assertEquals(nil, ns.Dungeon.Inside())
  end)
end)

test("which dungeon: a hidden instance id is not read", function()
  local sv = issecretvalue
  where({ inst = 2959, hidden = true }, function()
    issecretvalue = function(v) return v == 2959 end
    local ok, name = pcall(ns.Dungeon.Here)
    issecretvalue = sv
    assertTrue(ok); assertEquals(nil, name)
  end)
  issecretvalue = sv
end)

local DALARAN = {
  [92456] = { on = true, objectives = { { text = "Fel Infused Blossom: 0/1", finished = false, have = 0, need = 1 } } },
  [92489] = { on = true, complete = true, objectives = { { text = "Arcane Remnant slain: 8/8", finished = true, have = 8, need = 8 } } },
  [201] = { on = true, objectives = { { text = "Wolf slain: 1/5", finished = false, have = 1, need = 5 } } }, -- not a dungeon quest
}

test("a dungeon's quests: the ones in your log with their progress, unfinished first; the ones you didn't bring", function()
  withState(DALARAN, function()
    where({ inst = 2959, level = 30, side = "Alliance" }, function()
      local st = ns.Dungeon.State(2959)
      assertEquals(2, #st.quests)
      assertEquals(92456, st.quests[1].q); assertEquals("A Green Sample", st.quests[1].name); assertFalse(st.quests[1].ready)
      assertEquals(0, st.quests[1].objectives[1].have); assertEquals(1, st.quests[1].objectives[1].need)
      assertEquals(92489, st.quests[2].q); assertTrue(st.quests[2].ready)
      assertEquals(1, st.done); assertEquals(2, st.total)
      -- Starving Arcane (Alliance, level 24, nothing needed first) was there to take; the Horde's quests are not yours,
      -- and Heart of Disruption needs a quest you haven't done
      local missed = {}
      for _, e in ipairs(st.missed) do missed[e.q] = e end
      assertNotNil(missed[92457]); assertTrue(missed[92457].from:find("Modera", 1, true) ~= nil)
      assertEquals(nil, missed[96986]); assertEquals(nil, missed[92458]); assertEquals(nil, missed[92456])
    end)
    -- too low for them: nothing was missed
    where({ inst = 2959, level = 12, side = "Alliance" }, function() assertEquals(0, #ns.Dungeon.State(2959).missed) end)
    -- a quest you said you're not doing is not a missed one
    where({ inst = 2959, level = 30, side = "Alliance" }, function()
      ns.char.nope = { [92457] = true }
      for _, e in ipairs(ns.Dungeon.State(2959).missed) do if e.q == 92457 then error("a dropped quest listed as not picked up", 0) end end
      ns.char.nope = nil
    end)
  end)
end)

test("the card inside a dungeon: the dungeon, its quests with live bars, no arrow or pins - and the plan's card again outside", function()
  local quests = {}
  for k, v in pairs(DALARAN) do quests[k] = v end
  withState(quests, function()
    local sv = { pins = ns.db.pins, arrow = ns.db.arrow, collapsed = ns.db.collapsed }
    ns.db.pins, ns.db.arrow, ns.db.collapsed = true, true, false
    ForeverRouteData = { id = "dg", title = "dg", sections = { { title = "Darkshire", zone = "Duskwood" } }, steps = {
      { id = 1, k = "turnin", q = 201, name = "Gather Rot Blossoms", npc = "Abercrombie", m = 1431, x = 0.28, y = 0.31, r = 6, sec = 1 },
      { id = 2, k = "goto", text = "Go somewhere", m = 1431, x = 0.5, y = 0.5, sec = 1 },
    } }
    local card = ForeverRouteCard
    -- (drawn by hand: a step-done animation left over from another test would hold the card back)
    local function draw() ns.Engine.Refresh(); ns.Card.Fill(); ns.Card.Layout() end
    local function plainTitle() return ns.Card.Plain(card.cur.titleText:GetText() or "") end
    local ok, err = pcall(function()
      where({ inst = 0 }, function()
        ns.Dungeon.Check(); draw()
        assertTrue(plainTitle():find("Gather Rot Blossoms", 1, true) ~= nil)
      end)
      where({ inst = 2959, hidden = true, level = 30 }, function()
        ns.Dungeon.Check() -- walked in (the game's zone events run this)
        draw()
        assertEquals("City of Dalaran", plainTitle())
        assertTrue(ns.Card.Plain(card.title:GetText()):find("CITY OF DALARAN", 1, true) ~= nil)
        assertEquals("1/2", card.count:GetText())
        -- the unfinished quest: its name above a bar with the live count; the finished one ticked in the note
        assertEquals(1, card.cur.nbars)
        assertTrue(card.cur.bars[1]:IsShown())
        assertEquals("Fel Infused Blossom", card.cur.bars[1].label:GetText())
        assertEquals("0/1", card.cur.bars[1].value:GetText())
        assertTrue(ns.Card.Plain(card.cur.headAt[1]:GetText()):find("A Green Sample", 1, true) ~= nil)
        local note = ns.Card.Plain(card.cur.note:GetText() or "")
        assertTrue(note:find("Power Overwhelming", 1, true) ~= nil and note:find("done", 1, true) ~= nil)
        assertTrue(note:find("Not picked up", 1, true) ~= nil and note:find("Starving Arcane", 1, true) ~= nil)
        -- nothing to point at: no arrow, no pins; done / skip would act on a step that isn't on show
        assertEquals(nil, ns.Arrow.Current()); assertEquals(nil, ns.Pins.First())
        assertFalse(card.btn.done:IsShown()); assertFalse(card.btn.skip:IsShown())
        -- the plan's step waits in the timeline
        assertEquals(1, card.rows[1].index)
        -- progress inside: the bar moves, and a finished quest is ticked
        quests[92456] = { on = true, complete = true, objectives = { { text = "Fel Infused Blossom: 1/1", finished = true, have = 1, need = 1 } } }
        draw()
        assertEquals(0, card.cur.nbars); assertEquals("2/2", card.count:GetText())
        assertTrue(ns.Card.Plain(card.cur.detail:GetText()):find("All 2 quests", 1, true) ~= nil)
        -- looking at another step of the plan still works in there
        ns.Engine.view = 2; ns.Card.Fill()
        assertTrue(plainTitle():find("Go somewhere", 1, true) ~= nil)
        ns.Engine.view = nil
      end)
      -- out again (where() ran the check): the plan's card, header and arrow are back
      draw()
      assertTrue(plainTitle():find("Gather Rot Blossoms", 1, true) ~= nil)
      assertTrue(ns.Card.Plain(card.title:GetText()):find("DARKSHIRE", 1, true) ~= nil)
      assertEquals(0, card.cur.nbars)
      assertTrue(card.btn.done:IsShown())
    end)
    ns.db.pins, ns.db.arrow, ns.db.collapsed = sv.pins, sv.arrow, sv.collapsed
    if not ok then error(err, 0) end
  end)
  pcall(ns.Dungeon.Check); ns.Engine.Refresh()
end)

test("a Run step for a dungeon is done once you're inside it, told by the instance id alone", function()
  withState({ [166] = { on = true, objectives = { { text = "Head of VanCleef: 0/1", finished = false } } } }, function()
    ns.State.OnQuest = function(id) return id == 166 end
    ns.char.ranRun = nil
    ForeverRouteData = { id = "d", title = "d", sections = { { title = "x" } }, steps = {
      { id = 1, k = "goto", text = "Run The Deadmines", m = 1436, x = 0.426, y = 0.718, r = 25, sec = 1 },
      { id = 2, k = "obj", q = 166, text = "Collect Head of VanCleef (in The Deadmines)", sec = 1 },
    } }
    where({ inst = 0 }, function() assertEquals("todo", ns.Engine.Status(1)) end)
    where({ inst = 36, hidden = true }, function() assertEquals("done", ns.Engine.Status(1)) end)
    where({ inst = 43, hidden = true }, function() assertEquals("todo", ns.Engine.Status(1)) end)
  end)
end)
