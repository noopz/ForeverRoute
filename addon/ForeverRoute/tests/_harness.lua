-- Shared test harness (loads before the test files: "_" sorts first). withState swaps in a scripted quest state;
-- withWorld runs a small world (position, zones, level, quest log, clock, flights, boats) and checks card, arrow and
-- first pin agree. Used by all_test.lua, the replayed saves (save_*_test.lua) and the live check (tools/live-check.sh).
local ns = ForeverRoute

-- swap in a scripted quest state for engine tests
local function withState(fake, fn)
  local saved = { Quest = ns.State.Quest, IsCompleted = ns.State.IsCompleted, OnQuest = ns.State.OnQuest, QuestReady = ns.State.QuestReady, data = ForeverRouteData, char = ns.char }
  ns.char = { skipped = {}, manualDone = {}, history = {}, progress = {} }
  -- (the position the once-a-second check measured, and the solver's memory: a test starts where it says it is, not
  -- where the last test left the player)
  ns.Engine.pos = nil
  ns.State.Quest = function(id) local q = fake[id]; if not q then return { on = false, objectives = {} } end; return q end
  ns.State.IsCompleted = function(id) return fake[id] and fake[id].done or false end
  local ok, err = pcall(fn)
  ns.State.Quest, ns.State.IsCompleted, ns.State.OnQuest, ns.State.QuestReady, ForeverRouteData, ns.char = saved.Quest, saved.IsCompleted, saved.OnQuest, saved.QuestReady, saved.data, saved.char
  ns.Engine.view = nil
  if not ok then error(err, 0) end
end

-- a small world for scenario tests: where you are (walking, changing zones), your level and your quest log. Every
-- change runs the engine like the game would, then checks that the arrow and the first map pin point at the step the
-- card shows (they once disagreed after zone changes and boats). Maps use the planner's zone bounds (the sim has no
-- map data). Usage: withWorld(route, function(w) w:go(m, x, y); w:quest(id, state); w:ding(level) end)
local function withWorld(route, fn, opts)
  local HBD = LibStub("HereBeDragons-2.0")
  local B = ns.TravelData.BOUNDS
  -- opts.at = { m, x, y, level, quests } starts the world somewhere else (a replayed save)
  local at = opts and opts.at or {}
  local w = { m = at.m or 1431, x = at.x or 0.5, y = at.y or 0.5, level = at.level or 21, quests = at.quests or {} }
  local sv = { zone = HBD.GetPlayerZonePosition, wpos = HBD.GetPlayerWorldPosition, conv = HBD.GetWorldCoordinatesFromZone,
    best = C_Map.GetBestMapForUnit, lvl = UnitLevel, xpmax = UnitXPMax, pins = ns.db.pins, arrow = ns.db.arrow }
  HBD.GetWorldCoordinatesFromZone = function(_, x, y, m) local b = B[m]; if not b then return nil end return b[1] + x * (b[2] - b[1]), b[3] + y * (b[4] - b[3]), b[5] end
  HBD.GetPlayerZonePosition = function() return w.x, w.y, w.m end
  HBD.GetPlayerWorldPosition = function() return HBD:GetWorldCoordinatesFromZone(w.x, w.y, w.m) end
  C_Map.GetBestMapForUnit = function() return w.m end
  UnitLevel = function() return w.level end
  -- the XP a level takes, as the game has it below 60 (the simulator's own character is 70: its bar is not the
  -- world's level, and the live solve prices quests by it - Next.Prize). For every world, not one test: a quest's XP
  -- at your rate is what an offered quest is worth, and with the 70's bar (many times a 21-30 one) every quest was
  -- worth a fraction of what it is to the level the test plays. The side quest tests (A Noble Brew at Zardeth, its
  -- objectives, Brewer's Trade) fail on that bar: their pick-ups priced below their work. No test's threshold was
  -- moved for it. (At 60 and up the game shows no bar to fill: the 59's, so XP still prices as XP.)
  UnitXPMax = function()
    local L = math.max(1, math.min(59, w.level))
    local diff = L <= 28 and 0 or L == 29 and 1 or L == 30 and 3 or L == 31 and 6 or 5 * (L - 30)
    return math.floor(((8 * L) + diff) * (45 + 5 * L) / 100 + 0.5) * 100
  end
  ns.db.pins, ns.db.arrow = true, true
  local checks = { arrow = 0, pins = 0 }
  local function agree(what)
    local i = ns.Engine.Shown()
    local t = ns.Arrow.Current()
    -- (error, not assertEquals: the simulator shows an error's message, and an assert's only as "expected x, got y")
    if i and t then checks.arrow = checks.arrow + 1; if i ~= t.index then error(what .. ": the arrow points at step " .. tostring(t.index) .. ", the card shows " .. i, 0) end end
    local p = ns.Pins.First()
    -- the first pin is the card's step, or - when the card's step has no place (hearth, a trip to a zone) - the next
    -- step that has one: where you're headed
    -- (a step whose work has no place in the quest data, s.unknown, is placeless too: its spot only orders it)
    local function placeless(j) local st = ForeverRouteData and ForeverRouteData.steps and ForeverRouteData.steps[j]; return st and (not (st.m and st.x) or st.unknown) end
    local okPin = (p == i)
    if i and p and p > i then okPin = true; for j = i + 1, p - 1 do if not (placeless(j) or ns.Engine.IsDone(j)) then okPin = false end end; if not placeless(i) then okPin = false end end
    if i and p then checks.pins = checks.pins + 1; if not okPin then error(what .. ": the first pin marks step " .. tostring(p) .. ", the card shows " .. i, 0) end end
  end
  function w:go(m, x, y)
    local changed = m ~= self.m
    self.m, self.x, self.y = m, x, y
    -- a new zone: the game fires the event, and the addon's follow-ups run a moment later (timers)
    if changed then ns.Fire("ZONE_CHANGED_NEW_AREA"); self:wait(2) end
    ns.Engine.Refresh(); agree("after moving to " .. m .. " " .. x .. "," .. y)
  end
  function w:quest(id, q) self.quests[id] = q; ns.Engine.Refresh(); agree("after quest " .. id .. " changed") end
  function w:ding(n) self.level = n; ns.Engine.Refresh(); agree("after reaching level " .. n) end
  function w:shown() return ns.Engine.Shown() end
  -- a virtual clock: C_Timer.After waits for w:wait(seconds) instead of real time
  w.t, w.timers = 0, {}
  sv.after, sv.taxi, sv.known = C_Timer.After, UnitOnTaxi, ns.State.knownTaxi
  C_Timer.After = function(d, f) w.timers[#w.timers + 1] = { at = w.t + (tonumber(d) or 0), f = f } end
  function w:wait(s)
    self.t = self.t + s
    while true do
      local k, best
      for j, tm in ipairs(self.timers) do if tm.at <= self.t and (not best or tm.at < best.at) then k, best = j, tm end end
      if not k then break end
      table.remove(self.timers, k); best.f()
    end
    ns.Engine.Refresh(); agree("after waiting " .. s .. " s")
  end
  -- flights: take off (the game takes control), land (it gives it back)
  w.onTaxi = false
  UnitOnTaxi = function() return w.onTaxi end
  function w:taxi(on)
    self.onTaxi = on
    ns.Fire(on and "PLAYER_CONTROL_LOST" or "PLAYER_CONTROL_GAINED")
    self:wait(1.5)
  end
  function w:knows(list) local t = {}; for _, n in ipairs(list) do t[n] = true end; ns.State.knownTaxi = t end
  -- boats: the arrow notices you are aboard from your speed (fast, not on a flight); this does what that check does
  sv.aboard = ns.Arrow.aboard
  function w:board(on)
    ns.Arrow.aboard = on
    ns.Arrow.SetTarget(ns.Engine.Shown(), true)
    ns.Engine.Refresh(); agree(on and "after boarding" or "after stepping off")
  end
  -- any error the addon logs while this world runs fails the test (guards keep errors from reaching the test
  -- otherwise): a replayed save that hit an error in game keeps failing until it's fixed
  local function errors() local n, last = 0, nil; for _, e in ipairs((ForeverRouteDB and ForeverRouteDB.log) or {}) do n = n + (e.count or 0); if not last or (e.last or 0) >= (last.last or 0) then last = e end end; return n, last end
  -- (w.errs0: a simulated player resumed from a checkpoint puts back the count its run started from)
  w.errs0 = errors()
  local ok, err = pcall(withState, w.quests, function()
    ForeverRouteData = route
    ns.Engine.Refresh(); agree("at the start")
    fn(w)
    local n, last = errors()
    if n > w.errs0 then error("the addon logged an error: " .. tostring(last and last.where) .. ": " .. tostring(last and last.msg), 0) end
    -- the checks must have run, not been skipped because the arrow or pins had nothing (a replayed save may sit on a
    -- step with nothing to point at: opts.anyTarget)
    if not (opts and opts.anyTarget) then
      assertTrue(checks.arrow > 0, "the arrow never had a target to compare")
      assertTrue(checks.pins > 0, "no map pin was ever drawn to compare")
    end
  end)
  HBD.GetPlayerZonePosition, HBD.GetPlayerWorldPosition, HBD.GetWorldCoordinatesFromZone = sv.zone, sv.wpos, sv.conv
  C_Map.GetBestMapForUnit, UnitLevel, UnitXPMax, ns.db.pins, ns.db.arrow = sv.best, sv.lvl, sv.xpmax, sv.pins, sv.arrow
  C_Timer.After, UnitOnTaxi, ns.State.knownTaxi, ns.Arrow.aboard = sv.after, sv.taxi, sv.known, sv.aboard
  if not ok then error(err, 0) end
end

ForeverRouteTest = { withWorld = withWorld, withState = withState }
