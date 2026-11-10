-- Step engine: decides which step is current from live quest state, like a hand-written guide's conditions.
-- Steps (from Route.lua): { id, k = kind, q = questID, name, npc, m = uiMapID, x, y (0-1), r = arrive radius, match = objective
--   text, text, note, warn, minLevel, level, lvl (planned level here), xp, to (destination map), bind, fp, item, target, sec }
local _, ns = ...
local Engine = {}
ns.Engine = Engine
local State

Engine.current = nil  -- index of the first step that still needs doing
Engine.view = nil     -- an earlier/later step being looked at (Back, list); never changes progress
local quiet = true    -- no completion animation for the catch-up refresh at login

local function steps() return ForeverRouteData and ForeverRouteData.steps or {} end
-- Ticks and skips are stored against the step itself, not its number: kind + quest + what it targets, plus which
-- occurrence it is. Regenerating the route shifts step numbers; these keys stay on the same step.
local keyCache = setmetatable({}, { __mode = "k" })
function Engine.Key(i)
  local list = steps()
  local c = keyCache[list]
  if not c then
    c = {}; local seen = {}
    for j, s in ipairs(list) do
      local base = (s.k or "?") .. ":" .. tostring(s.q or "") .. ":" .. tostring(s.match or s.text or s.dest or s.name or s.npc or s.fp or s.bind or "")
      seen[base] = (seen[base] or 0) + 1
      c[j] = base .. "#" .. seen[base]
    end
    keyCache[list] = c
  end
  return c[i]
end
local function key(i) return Engine.Key(i) end

-- noElim: without the elimination pass (it asks about the quest's other steps, which would ask about this one)
function Engine.ObjectiveFor(step, noElim)
  State = State or ns.State
  local q = State.Quest(step.q)
  if not q or not q.on then return nil end
  if step.match then
    -- the exact name first ("Murloc slain" for "Murloc"), then any objective containing it: "Murloc" alone matched
    -- "Murloc Streamrunner slain" and the card waited on the wrong objective
    local m = step.match:lower()
    local loose
    for _, o in ipairs(q.objectives) do
      local t = o.text:lower()
      if t:sub(1, #m) == m and (t:sub(#m + 1, #m + 1) == ":" or t:sub(#m + 1, #m + 6) == " slain") then return o end
      if not loose and t:find(m, 1, true) then loose = o end
    end
    if loose then return loose end
  end
  if step.o and q.objectives[step.o] then return q.objectives[step.o] end
  -- no match word from the planner (objects to use, places to explore: the quest data has no text the game shows for
  -- them): the objective sharing the most distinctive words with the step ("Read the Lay of Ameth'Aran" -> "Lay of
  -- Ameth'Aran read"), when exactly one does best. Otherwise the card couldn't tell that objective was done and sat on
  -- it until the whole quest was (you ticked it by hand).
  if not step.match and step.text then
    local want = Engine.Words(step.text)
    local best, bestN, tie = nil, 0, false
    for _, o in ipairs(q.objectives) do
      local n = 0
      for w in pairs(Engine.Words(o.text)) do if want[w] then n = n + 1 end end
      if n > bestN then best, bestN, tie = o, n, false elseif n == bestN and n > 0 then tie = true end
    end
    if best and not tie then return best end
  end
  if not noElim and not step.match and step.text then
    -- by elimination: every other objective of the quest belongs to another step of the route ("Explore" says
    -- nothing; Alther's Mill's other objective is "Use Tarantula Egg"): the one left is this step's
    local claimed, list = {}, steps()
    for _, j in ipairs(Engine.ObjStepsOf(step.q)) do
      local t = list[j]
      if t ~= step then local o2 = (t.match or Engine.Words(t.text) and next(Engine.Words(t.text))) and Engine.ObjectiveFor(t, true) or nil; if o2 then claimed[o2] = true end end
    end
    local left
    for _, o in ipairs(q.objectives) do if not claimed[o] then if left then return nil end; left = o end end
    return left
  end
end
-- the words that tell objectives apart (not "the", "of", the verb, or counts)
local COMMON = { the = 1, ["and"] = 1, ["for"] = 1, ["from"] = 1, ["with"] = 1, ["into"] = 1, ["your"] = 1, use = 1, read = 1, free = 1, locate = 1,
  collect = 1, kill = 1, investigate = 1, explore = 1, find = 1, slain = 1, ["get"] = 1, bring = 1, place = 1, open = 1 }
function Engine.Words(t)
  local out = {}
  if type(t) ~= "string" then return out end
  for w in t:lower():gmatch("[%a'][%a']+") do if #w > 2 and not COMMON[w] then out[w] = true end end
  return out
end

-- dungeons: a "Run <X> with a group" step and the objective steps done inside ("Collect 10 Twilight Pendant (in
-- Blackfathom Deeps)"). Once you've been inside (any visit is your run - ns.char.dungeonsVisited) or skipped the run,
-- what's left inside waits ("later") instead of holding up the card: half a run (drops that didn't drop), skipping
-- dungeons, or running one twice all leave the route moving. Back inside, it's current again.
function Engine.RunDungeon(s) return s and s.k == "goto" and (s.dungeon or tostring(s.text or ""):match("^Run (.-) with a group") or tostring(s.text or ""):match("^Run (.+)$")) or nil end
function Engine.InsideOf(s) return s and s.k == "obj" and tostring(s.text or ""):match("%(in (.-)%)$") or nil end
-- each quest's objective steps, by index - built once per step list (a hand-in's check scanned the whole plan for
-- every unfinished hand-in: on a 2300-step plan that was most of a refresh)
local objIndex, objIndexFor, objIndexN = nil, nil, 0
function Engine.ObjStepsOf(q)
  local list = steps()
  if objIndexFor ~= list or objIndexN ~= #list then
    objIndex, objIndexFor, objIndexN = {}, list, #list
    for j, t in ipairs(list) do if t.k == "obj" and t.q then local l = objIndex[t.q]; if not l then l = {}; objIndex[t.q] = l end; l[#l + 1] = j end end
  end
  return objIndex[q] or {}
end
-- a visit marks one Run step (ns.char.ranRun[key]): the first one of that dungeon not run or skipped yet - a second
-- planned run of the same dungeon later on the route stays to do
-- the mark is for the plan you were on (its stamp): a new plan made after the run (the planner saw drops still missing -
-- 5 of 8 brain stems - and planned another run) has a run of its own to do
local function planStamp() return (ForeverRoutePlan and ForeverRoutePlan.generated) or (ForeverRouteData and ForeverRouteData.id) or 0 end
local function ran(i) local v = ns.char.ranRun and ns.char.ranRun[key(i)]; return v ~= nil and v == planStamp() end
-- the Run step an inside objective belongs to: the nearest one before it for that dungeon
local function runFor(j, name)
  local list = steps()
  for i = j - 1, 1, -1 do local d = Engine.RunDungeon(list[i]); if d and Engine.SamePlace(d, name) then return i end end
end
-- an inside objective (step j) waits for now: its run is done or skipped, and you're not in that dungeon
function Engine.DungeonLater(name, j)
  if not name or Engine.InDungeon(name) then return false end
  local r = j and runFor(j, name)
  return r and (ran(r) or ns.char.skipped[key(r)] or false) or false
end
local function recordDungeon()
  if not ns.Is(IsInInstance) then return end
  local okI, name = pcall(GetInstanceInfo)
  if not (okI and type(name) == "string" and not (issecretvalue and issecretvalue(name))) then return end
  -- the run the card shows, if it's this dungeon's; else the first of its runs not done yet (one already passed - you
  -- went ahead of it - is not the run you're starting: marking it once took the card back to two old runs)
  ns.char.ranRun = ns.char.ranRun or {}
  local shown = Engine.Shown and Engine.Shown()
  local list = steps()
  local s0 = shown and list[shown]
  local d0 = s0 and Engine.RunDungeon(s0)
  if d0 and Engine.SamePlace(d0, name) and not ran(shown) then ns.char.ranRun[key(shown)] = planStamp(); return end
  for i, s in ipairs(list) do
    local d = Engine.RunDungeon(s)
    if d and Engine.SamePlace(d, name) and not ran(i) and not ns.char.skipped[key(i)] and Engine.Status(i) ~= "done" then
      ns.char.ranRun[key(i)] = planStamp()
      return
    end
  end
end
Engine.RecordDungeon = recordDungeon
ns.On("ZONE_CHANGED_NEW_AREA", function() pcall(recordDungeon) end)
ns.On("PLAYER_ENTERING_WORLD", function() pcall(recordDungeon) end)

-- status: "done", "todo", "blocked" (quest not in log), "wait" (level too low), "notready" (turn-in with objectives left),
-- "later" (left for your next run of a dungeon you've been in or skipped: passed over, like "wait")
-- a quest more than this many levels below you is left out: tools/campaign.js plans each zone with
-- minQuestLevel = level - 6 (it never sends you to one), and the route in game drops the same ones
Engine.OUTLEVEL = 6
-- are you bound at this bind step's place? (the bind's own name, the zone, or the map you were on when you bound)
function Engine.BoundAt(s, b)
  if not b then return false end
  if (s.bind and b == s.bind) or Engine.SamePlace(b, s.zone) then return true end
  local at = ns.char and ns.char.boundAt
  return at and at.name == b and at.m == s.m or false
end
-- the level a training stop is for: "level 8/10 spells" -> 10
function Engine.TrainLevel(s)
  if s.until_ then return tonumber(s.until_) end
  local best
  for n in tostring(s.text or ""):gmatch("%d+") do n = tonumber(n); if not best or n > best then best = n end end
  return best
end
function Engine.Outlevelled(s)
  State = State or ns.State
  if not (s and s.q and tonumber(s.level) and s.level > 0) then return false end
  local lvl = UnitLevel("player") or 1
  return s.level < lvl - Engine.OUTLEVEL and not State.OnQuest(s.q) and not State.IsCompleted(s.q)
end
-- a hand-in you've outgrown: the quest is finished in your log, far below you (Messenger to Westfall at 26: 250 XP),
-- and opens nothing on the route (ForeverRouteUnlocks) - not worth the trip, on any plan (the built-in one from level 1
-- most of all: no planner reworks it for you). A stop added because it's right on the way stays.
function Engine.GrayHandIn(s)
  State = State or ns.State
  if not (s and s.k == "turnin" and s.q and not s.inserted and tonumber(s.level) and s.level > 0) then return false end
  if s.level >= (UnitLevel("player") or 1) - Engine.OUTLEVEL then return false end
  if not State.QuestReady(s.q) then return false end
  for _, d in ipairs((ForeverRouteUnlocks and ForeverRouteUnlocks[s.q]) or {}) do if not State.IsCompleted(d) then return false end end
  return true
end
-- a breadcrumb whose quest is already yours (in your log or done): the game no longer offers it - The Corruption
-- Abroad from Argos Nightwhisper, with Researching the Corruption in your log (ns.BREADCRUMBS, Breadcrumbs.lua)
function Engine.Breadcrumbed(s)
  State = State or ns.State
  local to = s and s.q and ns.BREADCRUMBS and ns.BREADCRUMBS[s.q]
  if not to or State.OnQuest(s.q) or State.IsCompleted(s.q) then return false end
  for _, t in ipairs(to) do if State.OnQuest(t) or State.IsCompleted(t) then return true end end
  return false
end
local function statusRaw(i)
  State = State or ns.State
  local s = steps()[i]
  if not s then return "done" end
  local id = key(i)
  if ns.char.manualDone[id] or ns.char.skipped[id] then return "done" end
  if s.q and ns.char.nope and ns.char.nope[s.q] then return "done" end -- you said you're not doing this quest
  -- the game did not offer it to you (Availability.lua): off the route until you level up or it is offered
  if s.q and ns.Avail and ns.Avail.Unavailable(s.q) and not State.OnQuest(s.q) and not State.IsCompleted(s.q) then return "done" end
  -- far below you and not in your log: off the route (all its steps), the same cut the planner makes - so a plan made
  -- for someone lower (the built-in plan from level 1, or yours after a dungeon run) passes over what you've outgrown,
  -- and a trip to a zone with nothing left for you is passed too (the "went ahead" rule below)
  if Engine.Outlevelled(s) or Engine.GrayHandIn(s) or Engine.Breadcrumbed(s) then return "done" end
  local k = s.k
  if k == "accept" then
    if State.OnQuest(s.q) or State.IsCompleted(s.q) then return "done" end
    if s.minLevel and UnitLevel("player") < s.minLevel then return "wait" end
    return "todo"
  elseif k == "turnin" then
    if State.IsCompleted(s.q) then return "done" end
    if not State.OnQuest(s.q) then return "blocked" end
    if not State.QuestReady(s.q) then
      -- all that's unfinished is inside a dungeon you've run or skipped: it waits, the card moves on
      local list, inside, outside = steps(), false, false
      for _, j in ipairs(Engine.ObjStepsOf(s.q)) do
        local t = list[j]
        if j ~= i and Engine.Status(j) ~= "done" then
          if Engine.DungeonLater(Engine.InsideOf(t), j) then inside = true else outside = true end
        end
      end
      if inside and not outside then return "later" end
      return "notready"
    end
    return "todo"
  elseif k == "obj" then
    if State.IsCompleted(s.q) then return "done" end
    if not State.OnQuest(s.q) then return "blocked" end
    if State.QuestReady(s.q) then return "done" end
    local o = Engine.ObjectiveFor(s)
    if o and o.finished then return "done" end
    if Engine.DungeonLater(Engine.InsideOf(s), i) then return "later" end
    return "todo"
  elseif k == "grind" then
    local lvl = UnitLevel("player")
    if lvl > (s.level or 0) or (lvl == (s.level or 0) and UnitXP("player") >= (s.xp or 0)) then return "done" end
    return "todo"
  elseif k == "fp" then
    if s.fp and State.knownTaxi[s.fp] then return "done" end
    if s.zone and Engine.KnowsFlightIn(s.zone) then return "done" end
  elseif k == "bind" then
    local b = GetBindLocation and GetBindLocation()
    if Engine.BoundAt(s, b) then return "done" end
    -- bound at a later bind stop of the route: that one replaced this one - never back to rebind here (binding in
    -- Menethil once sent you back across the sea to Auberdine's inn, and from there back to Menethil's)
    local list = steps()
    for j = i + 1, #list do local t = list[j]; if t.k == "bind" and Engine.BoundAt(t, b) then return "done" end end
  elseif k == "bonus" then
    -- a book / collectible: done once it's in your bags or the books addon has it as found
    if s.item and ns.GetItemCount and (ns.GetItemCount(s.item, true) or 0) > 0 then return "done" end
    local found = HandyNotes_ForeverBooksCharDB and HandyNotes_ForeverBooksCharDB.collected
    if s.book and type(found) == "table" and found[s.book] then return "done" end
  elseif k == "train" then
    if s.until_ and UnitLevel("player") < s.until_ then return "wait" end
    -- a later training stop on the route is already due at your level: that visit covers this one (a plan made for
    -- someone lower lists every stop from level 2)
    local lvl, list = UnitLevel("player") or 1, steps()
    for j = i + 1, #list do
      local t = list[j]
      if t.k == "train" then local L = Engine.TrainLevel(t); if L and L <= lvl then return "done" end end
    end
  end
  -- "Run <dungeon>": done while you're inside that dungeon (the entrance check can't see you once you're in, and a
  -- reload inside would otherwise leave it stuck). Leave early and it comes back.
  if k == "goto" and s.text then
    local dname = Engine.RunDungeon(s)
    -- inside: the run you're on is done - the first of that dungeon's runs not run yet; a second and third XP run
    -- stay to do (all of them read done while inside, so the card ran ahead to the next zone mid-run)
    if dname and Engine.InDungeon(dname) then
      -- the run you're on is the one going in marked (recordDungeon); none marked yet (you were inside when the plan
      -- loaded): the first of that dungeon's runs not run yet
      if ran(i) then return "done" end
      local list, marked, first = steps(), false, nil
      for j = 1, #list do
        local d2 = Engine.RunDungeon(list[j])
        if d2 and Engine.SamePlace(d2, dname) then
          if ran(j) then marked = true elseif not first and not ns.char.skipped[key(j)] then first = j end
        end
      end
      if not marked and first == i then return "done" end
      -- any other run of it: the usual rules (one passed by "you went ahead" stays passed)
    end
    -- been in it (this run, or one before): done; or nothing you're on is left inside: done
    if dname and ran(i) then return "done" end
    -- (a run for its XP - s.xpRun - has nothing to do inside: only going in, or skipping it, passes it)
    if dname and not s.xpRun then
      local list, left = steps(), false
      for j = i + 1, #list do local t = list[j]; local x = Engine.InsideOf(t); if x and Engine.SamePlace(x, dname) and State.OnQuest(t.q) and Engine.Status(j) ~= "done" then left = true; break end end
      if not left then return "done" end
    end
  end
  -- goto / fly / hearth / note: completed by events, arrival or a click, or passed: if the next few quest steps
  -- after it are already done (you went ahead, or did things in another order), the travel was clearly made
  if (k == "goto" or k == "fly" or k == "hearth" or k == "note" or k == "fp" or k == "bind" or k == "train" or k == "bonus") and not (k == "fly" and ns.ChoiceFor and ns.ChoiceFor(i)) then
    local list, seen, done = steps(), 0, 0
    for j = i + 1, math.min(#list, i + 15) do
      local t = list[j]
      if t.k == "turnin" or t.k == "obj" then -- real progress only: accepts can be done long before you get there
        seen = seen + 1
        if Engine.Status(j) == "done" then done = done + 1 else break end
        if seen >= 2 then break end
      end
    end
    if seen >= 2 and done == seen then return "done" end
  end
  return "todo"
end
-- during a refresh (and the card / list redraw it triggers) each step's status is worked out once and reused
local batch = nil
function Engine.Status(i)
  if batch then local c = batch[i]; if c then return c end end
  local st = statusRaw(i)
  if batch then batch[i] = st end
  return st
end
function Engine.IsDone(i) return Engine.Status(i) == "done" end

function Engine.Compute()
  -- the first step you can act on now. A step that needs a higher level ("wait") or a quest that isn't in your log
  -- ("blocked") doesn't hold up the route: it is passed over and comes back as soon as it can be done.
  local list, fallback = steps(), nil
  for i = 1, #list do
    local st = Engine.Status(i)
    if st ~= "done" then
      if st == "wait" or st == "blocked" or st == "later" then fallback = fallback or i else return i end
    end
  end
  return fallback
end
function Engine.InDungeon(name)
  if not (IsInInstance and GetInstanceInfo) then return false end
  local inside = ns.Is(IsInInstance)
  if not inside then return false end
  local iname = GetInstanceInfo()
  return iname and Engine.SamePlace(iname, name) or false
end
-- "Stormwind City" vs "Stormwind", "Lakeshire" vs "Redridge Mountains": loose place-name match
local function norm(x) return (x or ""):lower():gsub(" city$", ""):gsub("^the ", "") end
function Engine.SamePlace(a, b)
  if not a or not b then return false end
  local A, B = norm(a), norm(b)
  return A == B or A:find(B, 1, true) ~= nil or B:find(A, 1, true) ~= nil
end
-- a known flight path in this zone: node names look like "Sentinel Hill, Westfall" / "Lakeshire, Redridge"
function Engine.KnowsFlightIn(zone)
  State = State or ns.State
  local z = norm(zone); local first = z:match("^(%S+)")
  for name in pairs(State.knownTaxi or {}) do
    local n = name:lower()
    if n:find(z, 1, true) or (first and #first >= 5 and n:find(first, 1, true)) then return true end
  end
  return false
end

function Engine.Upcoming(from, n)
  local out, list = {}, steps()
  for i = (from or 0) + 1, #list do
    if #out >= n then break end
    if not Engine.IsDone(i) then out[#out + 1] = i end
  end
  return out
end

function Engine.Progress()
  local list = steps(); local done = 0
  for i = 1, #list do if Engine.IsDone(i) then done = done + 1 end end
  return done, #list
end

function Engine.Shown() return Engine.view or Engine.current end
-- progress through the zone you're in: the stretch between the travel steps around the shown step
function Engine.LegProgress(i)
  local list = steps(); i = i or Engine.Shown()
  if not i or not list[i] then return 0, 0, nil end
  local a, b = i, i
  while a > 1 and list[a].k ~= "fly" do a = a - 1 end
  if list[a].k == "fly" and a < i then a = a + 1 end
  while b < #list and list[b + 1].k ~= "fly" do b = b + 1 end
  local done = 0
  for j = a, b do if Engine.IsDone(j) then done = done + 1 end end
  local zone = list[i].zone or (list[a] and list[a].zone)
  return done, b - a + 1, zone
end

-- objective steps done in the same spot right after this one: shown together on the card
function Engine.Group(i)
  local list, out = steps(), {}
  local s = list[i]
  if not s or s.k ~= "obj" then return out end
  for j = i + 1, math.min(#list, i + 8) do
    local t = list[j]
    if t.k ~= "obj" or t.m ~= s.m or math.abs((t.x or 0) - (s.x or 0)) > 0.02 or math.abs((t.y or 0) - (s.y or 0)) > 0.02 then break end
    if not Engine.IsDone(j) then out[#out + 1] = j end
  end
  return out
end

function Engine.Refresh()
  local outer = batch == nil
  if outer then batch = {} else wipe(batch) end -- a nested refresh follows a change: start the reuse over
  local t0 = outer and debugprofilestop and debugprofilestop()
  local ok, err = pcall(Engine.RefreshInner)
  if outer then batch = nil end
  if t0 then ns.Time("refresh", debugprofilestop() - t0) end
  if not ok then error(err, 0) end
end
-- the login catch-up stays quiet; tests switch it to see the completion cue
function Engine.SetQuiet(q) local was = quiet; quiet = q and true or false; return was end
function Engine.RefreshInner()
  local before = Engine.current
  local beforeStep = before and steps()[before]
  Engine.current = Engine.Compute()
  -- already standing in a travel step's destination (switched routes there, logged in there, rode in): it's done
  for _ = 1, 5 do
    local s = Engine.current and steps()[Engine.current]
    if not (s and s.k == "fly" and s.to and Engine.InZone and Engine.InZone(s.to)) then break end
    ns.char.manualDone[key(Engine.current)] = true
    if batch then wipe(batch) end
    Engine.current = Engine.Compute()
  end
  -- live reordering: a later step you're working on or standing at is shown first (see Engine.UpdateFocus)
  Engine.planned = Engine.current
  local fi = Engine.focus
  if fi and fi ~= Engine.current then
    local st = Engine.Status(fi)
    if st == "todo" and fi > (Engine.current or 0) then Engine.current = fi else Engine.focus = nil end
  end
  if Engine.view and Engine.view == Engine.current then Engine.view = nil end
  -- the "done" cue only when the step you were on really got done: the current step also moves when live reordering
  -- picks another step, when you abandon a quest, when a level-up opens an earlier step, or after a jump
  if before and Engine.current ~= before and not quiet and beforeStep then
    local list, at = steps(), before
    if list[at] ~= beforeStep then at = nil; for j, t in ipairs(list) do if t == beforeStep then at = j; break end end end -- a stop was inserted before it, or another route
    -- skipped or "not doing" isn't done: no tick for those either
    local dropped = ns.char.skipped[key(at or 0) or ""] or (beforeStep.q and ns.char.nope and ns.char.nope[beforeStep.q])
    if at and Engine.Status(at) == "done" and not dropped then ns.Fire("FR_STEP_DONE", at) end
  end
  ns.Fire("FR_STEP", Engine.Shown())
end

-- history entries let Undo restore accidental skips/dones; one entry may cover several steps
local function remember(kind, ids) table.insert(ns.char.history, { kind = kind, ids = ids }); if #ns.char.history > 50 then table.remove(ns.char.history, 1) end end

function Engine.MarkDone(i)
  i = i or Engine.Shown(); local id = key(i); if not id then return end
  ns.char.manualDone[id] = true
  remember("done", { id })
  Engine.view = nil
  Engine.Refresh()
end
function Engine.Skip(i)
  i = i or Engine.Shown(); local s = steps()[i]; if not s then return end
  local ids = { key(i) }
  ns.char.skipped[key(i)] = true
  -- skipping a quest you don't have: its later objective / turn-in steps go too
  State = State or ns.State
  if s.q and (s.k == "accept" or not State.OnQuest(s.q)) and not State.IsCompleted(s.q) then
    for j = i + 1, #steps() do local t = steps()[j]; if t.q == s.q and not ns.char.skipped[key(j)] then ns.char.skipped[key(j)] = true; ids[#ids + 1] = key(j) end end
  end
  remember("skip", ids)
  Engine.view = nil
  Engine.Refresh()
end
function Engine.Undo()
  local h = table.remove(ns.char.history)
  if not h then ns.Print("nothing to undo."); return end
  for _, id in ipairs(h.ids) do ns.char.skipped[id] = nil; ns.char.manualDone[id] = nil end
  for _, q in ipairs(h.nope or {}) do if ns.char.nope then ns.char.nope[q] = nil end end
  Engine.view = nil
  Engine.Refresh()
  ns.Print(h.kind == "skip" and "skip undone." or h.kind == "nope" and "back on your route." or "undone.")
end
-- look at the previous step (view only; progress is unchanged)
function Engine.Back()
  local cur = Engine.Shown() or (#steps() + 1)
  if cur <= 1 then return end
  Engine.view = cur - 1
  ns.Fire("FR_STEP", Engine.view)
end
function Engine.Forward()
  if not Engine.view then return end
  local nxt = Engine.view + 1
  Engine.view = (Engine.current and nxt < Engine.current) and nxt or nil
  ns.Fire("FR_STEP", Engine.Shown())
end
-- jump: backwards = view it; forwards = skip what's in between (undoable)
function Engine.Jump(i)
  local list = steps()
  if not list[i] then return end
  if not Engine.current or i <= Engine.current then
    Engine.view = (i ~= Engine.current) and i or nil
    ns.Fire("FR_STEP", Engine.Shown())
    return
  end
  local ids = {}
  for j = Engine.current, i - 1 do if not Engine.IsDone(j) then local id = key(j); ns.char.skipped[id] = true; ids[#ids + 1] = id end end
  remember("skip", ids)
  Engine.view = nil
  Engine.Refresh()
end

function Engine.Arrived(i)
  local s = steps()[i]
  if s and s.k == "goto" and i == Engine.current then Engine.MarkDone(i) end
end

local function currentStep() local i = Engine.current; return i, i and steps()[i] end
local function nearCurrent(kind, within)
  -- the first not-done step of this kind among the next few (lets you do things a little early)
  local i = Engine.current
  if not i then return nil end
  for j = i, math.min(#steps(), i + (within or 0)) do
    local s = steps()[j]
    if s.k == kind and not Engine.IsDone(j) then return j end
  end
end

ns.On("FR_STATE", function() Engine.Refresh() end)
ns.On("PLAYER_ENTERING_WORLD", function()
  quiet = true
  C_Timer.After(1, function() Engine.Refresh() end)
  C_Timer.After(3, function() Engine.Refresh(); quiet = false end)
end)
ns.On("PLAYER_XP_UPDATE", function() local _, s = currentStep(); if s and s.k == "grind" then Engine.Refresh() end end)
-- fly steps carry no coordinates, so the arrow and pins point at the nearest flight master in your zone (FlightMasters.lua)
local function inZone(to)
  local m = ns.State.Position()
  local guard = 0
  while m and guard < 6 do
    if m == to then return true end
    local info = C_Map.GetMapInfo(m); m = info and info.parentMapID; guard = guard + 1
  end
  return false
end
-- where a travel step without coordinates should point: the flight master in the zone you're in
function Engine.TravelTarget(s)
  if not s or s.x or s.k ~= "fly" then return nil end
  local m, px, py = ns.State.Position()
  local plan = Engine.TravelPlan(s)
  if plan and (plan.ride or not plan.via or plan.via == m) then return plan.m, plan.x, plan.y, nil end
  local list = m and ns.FLIGHT and ns.FLIGHT[m]
  if not list then return nil end
  local best, bd
  for _, fm in ipairs(list) do
    local d = (px and py) and ((fm[1] - px) ^ 2 + (fm[2] - py) ^ 2) or 0
    if not bd or d < bd then best, bd = fm, d end
  end
  return m, best[1], best[2], best[3]
end
-- how to get to a travel step's destination, from the flight paths you actually have. Aims at the first stop there
-- (where you're really going), and compares riding straight there with flying: walk to a flight master on your map,
-- the flight, then walk from where you land. nil = just fly as usual.
-- -> { ride = true (ride straight there) | via = uiMap to fly to first, viaName, m, x, y = where to go, stop = step }
Engine.FLIGHT_YARDS = 700 -- a flight costs about this much walking (take-off, the flight, landing)
local function stepIndex(s) for j, t in ipairs(steps()) do if t == s then return j end end end
local function firstStop(s)
  if s._stop then return s._stop end
  local i = stepIndex(s); if not i then return nil end
  local list = steps()
  for j = i + 1, #list do
    local t = list[j]
    if t.k == "fly" or t.k == "hearth" then return nil end
    if t.m and t.x and t.m == s.to then return t end
  end
end
function Engine.TravelPlan(s)
  local HBD = LibStub("HereBeDragons-2.0")
  if not (s and s.k == "fly" and s.to and not s.boat and ns.FLIGHT and HBD) then return nil end
  local destName = s.dest or s.text
  if not destName then return nil end
  local fm = ns.FLIGHT[s.to] and ns.FLIGHT[s.to][1]
  local stop = firstStop(s)
  local tx, ty = (stop and stop.x) or (fm and fm[1]) or 0.5, (stop and stop.y) or (fm and fm[2]) or 0.5
  local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(tx, ty, s.to)
  if not wx then return nil end
  local d = function(ax, ay, bx, by) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end
  local pm, px, py = ns.State.Position()
  local hx, hy, hinst
  if pm and px then hx, hy, hinst = HBD:GetWorldCoordinatesFromZone(px, py, pm) end
  local rideYd = (hx and hinst == inst) and d(hx, hy, wx, wy) or nil
  -- the nearest flight master on your map (where a flight would start)
  local startYd
  for _, f in ipairs((pm and ns.FLIGHT[pm]) or {}) do
    local fx, fy, finst = HBD:GetWorldCoordinatesFromZone(f[1], f[2], pm)
    if fx and hx and finst == hinst then local dd = d(hx, hy, fx, fy); if not startYd or dd < startYd then startYd = dd end end
  end
  local plan = { m = s.to, x = tx, y = ty, stop = stop }
  if Engine.KnowsFlightIn(destName) then
    -- you can fly right there: only worth riding if the first stop is closer than the flight would make it
    if not (rideYd and fm) then return nil end
    local lx, ly = HBD:GetWorldCoordinatesFromZone(fm[1], fm[2], s.to)
    local flyYd = (startYd or 0) + Engine.FLIGHT_YARDS + (lx and d(lx, ly, wx, wy) or 0)
    if rideYd < flyYd then plan.ride = true; plan.yards = rideYd; return plan end
    return nil
  end
  -- no flight path there: fly to the one you have that lands closest to the first stop, unless riding is shorter
  local best
  for m, list in pairs(ns.FLIGHT) do
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(m)
    if info and info.name and m ~= s.to and Engine.KnowsFlightIn(info.name) then
      local fx, fy, finst = HBD:GetWorldCoordinatesFromZone(list[1][1], list[1][2], m)
      if fx and finst == inst then
        local dd = d(fx, fy, wx, wy)
        if not best or dd < best.d then best = { d = dd, m = m, name = info.name } end
      end
    end
  end
  if best and best.m ~= pm and not (rideYd and rideYd <= (startYd or 0) + Engine.FLIGHT_YARDS + best.d) then plan.via, plan.viaName = best.m, best.name
  else plan.ride = true; plan.yards = rideYd end
  return plan
end

-- any step in another zone than you: how to get there.
-- -> nil (same zone, or unknown), or { how = "fly" | "via" | "ride", m, x, y = where the arrow points now,
--    text = what to do, fm = flight master name when the arrow points at one }
-- the same trip is asked for by the card, the arrow and the pins on every refresh: worked out once for the same step and
-- the same situation (where you are to a few yards, your level, the flight paths you know, flying or sailing, your
-- hearthstone, the trip you're on). A trip took ~15 ms; three of them made up most of a refresh on a long plan.
local tripMemo = {}
local function tripKey(s)
  local pm, px, py = ns.State.Position()
  local n = 0; for _ in pairs((ns.State and ns.State.knownTaxi) or {}) do n = n + 1 end
  local okB, b = pcall(GetBindLocation)
  return table.concat({ tostring(pm), px and math.floor(px * 400) or "-", py and math.floor(py * 400) or "-", UnitLevel("player") or 0, n,
    tostring(ns.Is(UnitOnTaxi, "player")), tostring(ns.Arrow and ns.Arrow.aboard), tostring(okB and b), tostring(Engine.lastTripStep == s), (ns.char and ns.char.boundAt and ns.char.boundAt.m) or "-" }, "|")
end
function Engine.TravelFor(s)
  if not s then return nil end
  local k = tripKey(s)
  local m = tripMemo[s]
  if m and m.k == k then return m.v end
  local v = Engine.TravelForUncached(s)
  tripMemo[s] = { k = k, v = v }
  return v
end
function Engine.TravelForUncached(s)
  if not s or s.k == "hearth" then return nil end
  -- on a flight the taxi is taking you: nothing to plan from the sky. (Crossing a zone mid-air would otherwise
  -- plan a fresh trip from wherever you are above the ground - "Ride to Wetlands", an arrow at some town below.)
  -- The way on is planned again when you land.
  if ns.Is(UnitOnTaxi, "player") then
    local l = { how = "onflight", text = "On the flight - sit tight, the way on is planned when you land" }
    return { how = "aboard", text = l.text, legs = { l } }
  end
  if s.boat then
    -- the route's own "Boat to X" step, once the ship has sailed: the pier is behind you, nothing to point at
    -- until you land (the step ticks on arrival)
    if ns.Arrow and ns.Arrow.aboard then
      local l = { how = "aboard", text = "On the boat to " .. ((s.text or ""):match("^Boat to (.+)$") or s.dest or "the other side") .. " - sit tight" }
      return { how = "aboard", text = l.text, legs = { l } }
    end
    -- not sailing yet: in the pier's zone the step's own pier is the target (nil below); from anywhere else, the
    -- way to that pier is planned like any other stop (not a straight line from Goldshire or the tram)
    if not (s.m and s.x) then return nil end
  end
  local pm, px, py = ns.State.Position()
  -- another continent: boats, flights you know and rides, as one planned trip (ns.Travel)
  local HBD = LibStub("HereBeDragons-2.0")
  if pm and px and ns.Travel then
    local tm, tx, ty, tname
    if s.k == "fly" and s.to and not s.boat then
      local st = firstStop(s); local fm = ns.FLIGHT and ns.FLIGHT[s.to] and ns.FLIGHT[s.to][1]
      tm, tx, ty, tname = s.to, (st and st.x) or (fm and fm[1]) or 0.5, (st and st.y) or (fm and fm[2]) or 0.5, s.dest or s.text
    elseif s.m and s.x then tm, tx, ty, tname = s.m, s.x, s.y, s.zone end
    if tm then
      local a1, a2, ai = HBD:GetWorldCoordinatesFromZone(px, py, pm)
      local b1, b2, bi = HBD:GetWorldCoordinatesFromZone(tx, ty, tm)
      -- somewhere no trip can start from (on the Deeprun Tram, in a dungeon) and the step is out in the world: the trip
      -- you were on carries on (the tram leg is under way); with none, it is planned when you come out. A trip planned
      -- from here would start from coordinates that mean nothing outside (it pointed "down 98 yd" from the tram).
      if pm ~= tm and ns.Travel.OnNetwork and not ns.Travel.OnNetwork(pm, px, py) and not (a1 and b1 and ai == bi) then
        local last = Engine.lastTripStep == s and Engine.lastTrip
        if last and last[1] then
          local legs = {}
          for k, l in ipairs(last) do legs[k] = l end
          if ns.Travel.IsTram(legs[1]) then legs[1] = { how = "aboard", text = (legs[1].text:gsub("^Take the", "On the")) .. " - sit tight" } end
          return { how = "aboard", text = ns.Travel.Describe(legs), legs = legs }
        end
        local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(pm)
        local l = { how = "aboard", text = "In " .. ((info and info.name) or "here") .. ": the way on is planned when you come out" }
        return { how = "aboard", text = l.text, legs = { l } }
      end
      -- any other zone (or continent): the trip planner weighs riding, your flight paths and boats together
      if a1 and b1 and (ai ~= bi or pm ~= tm) then
        local legs = ns.Travel.Plan({ m = pm, x = px, y = py }, { m = tm, x = tx, y = ty, name = tname })
        if legs and legs[1] then
          -- already on the boat of the first leg: that leg is done, sit tight
          if legs[1].how == "boat" and ns.Arrow and ns.Arrow.aboard then
            local dest = legs[1].text:match(".* to (.+)$") or "the other side" -- the last "to": the boat's destination
            legs[1] = { how = "aboard", text = "On the boat to " .. dest .. " - sit tight" }
            return { how = "aboard", text = ns.Travel.Describe(legs), legs = legs }
          end
          -- which step it is for: a trip worked out for a step you only looked at must not teach the boat's pier
          Engine.lastTrip, Engine.lastTripStep = legs, s
          local text = ns.Travel.Describe(legs)
          if ns.Why then ns.Why("travel", "to " .. (tname or "another continent") .. ": " .. text) end
          return { how = legs[1].how, m = legs[1].m, x = legs[1].x, y = legs[1].y, text = text, legs = legs }
        end
      end
    end
  end
  if not (s.m and s.x) or s.k == "fly" then return nil end
  if not pm or pm == s.m then return nil end
  local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(s.m)
  local destName = (info and info.name) or s.zone or "there"
  local plan = Engine.TravelPlan({ k = "fly", to = s.m, dest = destName, text = destName, _stop = s })
  local function atFlightMaster(goal)
    local list = ns.FLIGHT and ns.FLIGHT[pm]; if not list then return nil end
    local best, bd; for _, f in ipairs(list) do local dd = (f[1] - px) ^ 2 + (f[2] - py) ^ 2; if not bd or dd < bd then best, bd = f, dd end end
    local m, x, y, fm = pm, best[1], best[2], best[3]
    return { how = "fly", m = m, x = x, y = y, fm = fm, text = "Fly to " .. goal .. (fm and (" - flight master " .. fm) or "") }
  end
  if not plan then return atFlightMaster(destName) end -- you have its flight path and flying is quicker
  if plan.ride then return { how = "ride", m = s.m, x = s.x, y = s.y, text = "Ride to " .. destName .. (plan.yards and (" - " .. ns.Style.Distance(plan.yards)) or "") } end
  if plan.via and plan.via ~= pm then
    local t = atFlightMaster(plan.viaName); if t then t.how = "via"; t.text = "No " .. destName .. " flight path yet: fly to " .. plan.viaName .. ", then ride" .. (t.fm and (" (flight master " .. t.fm .. ")") or "") end
    return t
  end
  return { how = "ride", m = s.m, x = s.x, y = s.y, text = "Ride to " .. destName }
end

-- arriving in the destination zone completes a fly step, however you got there (flew, rode, or were already there)
Engine.InZone = inZone
local function travelDone()
  local i, s = currentStep()
  if s and s.k == "fly" and s.to and inZone(s.to) then Engine.MarkDone(i) end
end
ns.On("ZONE_CHANGED_NEW_AREA", function() C_Timer.After(1, function() travelDone(); Engine.Refresh() end) end)
ns.On("PLAYER_ENTERING_WORLD", function() C_Timer.After(4, travelDone) end)
ns.On("HEARTHSTONE_BOUND", function()
  -- remember where you bound (the map you were on and the name the game gives it); every hearth step on that map
  -- counts as done while you stay bound there
  local m = ns.State.Position()
  ns.char.boundAt = { m = m, name = GetBindLocation and GetBindLocation() or nil }
  C_Timer.After(0.5, function() ns.char.boundAt.name = GetBindLocation and GetBindLocation() or ns.char.boundAt.name; Engine.Refresh() end)
  Engine.Refresh()
end)
-- opening a flight map ticks a "get the flight path" step only at that flight master (same map) - not when you
-- open the map somewhere else to fly toward it (the zone check in the step status covers learning it normally)
ns.On("FR_TAXI_OPENED", function()
  local j = nearCurrent("fp", 3); if not j then return end
  local s = steps()[j]; local m = ns.State.Position()
  if s and (not s.m or s.m == m) then Engine.MarkDone(j) end
end)
-- once: undo "got the flight path" ticks from before that fix, where you still have no flight path in that zone
ns.On("FR_LOADED", function()
  if ns.char.fixFpTicks then return end
  ns.char.fixFpTicks = true
  C_Timer.After(2, function()
    local undone = 0
    for i, s in ipairs(steps()) do
      local k = s.k == "fp" and key(i)
      if k and ns.char.manualDone[k] and s.zone and not Engine.KnowsFlightIn(s.zone) then ns.char.manualDone[k] = nil; undone = undone + 1 end
    end
    if undone > 0 then ns.Print("Un-ticked " .. undone .. " \"get the flight path\" step" .. (undone == 1 and "" or "s") .. " you don't actually have yet."); Engine.Refresh() end
  end)
end)
-- hearthstone cast: complete a hearth step
ns.On("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
  if unit ~= "player" then return end
  if spellID == 8690 then local j = nearCurrent("hearth", 1); if j then Engine.MarkDone(j) end end
end)
-- landing from a flight: complete a fly step (if it names a destination map, be in it)
local onTaxi = false
ns.On("PLAYER_CONTROL_LOST", function() C_Timer.After(0.5, function() onTaxi = ns.Is(UnitOnTaxi, "player") end) end)
ns.On("PLAYER_CONTROL_GAINED", function()
  if not onTaxi then return end
  onTaxi = false
  local j = nearCurrent("fly", 1)
  if j then
    local s = steps()[j]
    local m = ns.State.Position()
    if not s.to or s.to == m or (C_Map.GetMapInfo(m) and C_Map.GetMapInfo(m).parentMapID == s.to) then Engine.MarkDone(j) end
  end
end)
-- class trainer visits complete a train step (profession trainers don't)
local atClassTrainer = false
ns.On("TRAINER_SHOW", function() atClassTrainer = not (IsTradeskillTrainer and IsTradeskillTrainer()) end)
ns.On("TRAINER_CLOSED", function()
  if not atClassTrainer then return end
  atClassTrainer = false
  local j = nearCurrent("train", 4); if j then Engine.MarkDone(j) end
end)

----------------------------------------------------------------------------------------------------------------
-- Live reordering: follow what you're actually doing. Among the next few steps (same map), a later one is shown
-- first when your kills / loot count for it, when you're standing in its area, or when the planned step is far and
-- it's right here. Nothing is skipped: once it's done, the planned order comes back. It holds until done or until
-- you walk well away, so it doesn't flicker.
----------------------------------------------------------------------------------------------------------------
local HBD = LibStub("HereBeDragons-2.0")
local worldOf = setmetatable({}, { __mode = "k" })
local function wpos(s)
  if not (s and s.m and s.x) then return nil end
  local w = worldOf[s]
  if w == nil then local x, y, inst = HBD:GetWorldCoordinatesFromZone(s.x, s.y, s.m); w = x and { x, y, inst } or false; worldOf[s] = w end
  return w or nil
end
local function distTo(s, px, py, pinst) local w = wpos(s); if not w or w[3] ~= pinst then return nil end return math.sqrt((w[1] - px) ^ 2 + (w[2] - py) ^ 2) end
local WINDOW = 10
Engine.READY_AHEAD = 150 -- how far down the route a finished quest's hand-in is looked for, while you're near its NPC
Engine.READY_NEAR = 120  -- yards: near enough to hand it in now
local lastHave = {}   -- [step key] = objective count last seen
local progressAt = {} -- [step key] = GetTime() when that count last went up
Engine.PROGRESS_HOLD = 90 -- a focus your kills made holds this long after the last one, wherever you are

-- kind: "area" (you're standing at it / it's right next to you) or "progress" (your kills / loot count for it).
-- They're held differently in UpdateFocus: kill spots are often wider than the one marker the planner picks.
local function setFocus(i, why, kind)
  if Engine.focus == i then return end
  Engine.focus, Engine.focusWhy = i, kind or "area"
  local s = steps()[i]
  if ns.Why and s then ns.Why("reorder", "now on step " .. i .. " (" .. (s.name or s.text or s.k) .. "): " .. (why or "")) end
  Engine.Refresh()
end

-- called by the arrow driver about once a second with your position
-- can you do this step right now? A pick-up whose earlier chain quest isn't handed in yet isn't offered (Chef Grual
-- has nothing until Jitters' Growling Gut is in), and a hand-in needs the quest in your log
local prereqOf
function Engine.Available(j)
  local s = steps()[j]
  if not s or not s.q or s.q <= 0 then return true end
  State = State or ns.State
  if s.k == "turnin" then return State.OnQuest(s.q) and true or false end
  if s.k ~= "accept" then return true end
  if prereqOf == nil or prereqOf.src ~= ForeverRouteUnlocks then
    prereqOf = { src = ForeverRouteUnlocks }
    for p, list in pairs(ForeverRouteUnlocks or {}) do for _, d in ipairs(list) do prereqOf[d] = prereqOf[d] or {}; table.insert(prereqOf[d], p) end end
  end
  for _, p in ipairs(prereqOf[s.q] or {}) do if not State.IsCompleted(p) then return false end end
  return true
end
function Engine.UpdateFocus(px, py, pinst)
  if Engine.view or not px then return end
  local planned = Engine.planned or Engine.current
  if not planned then return end
  local list = steps()
  -- hold the current focus while it's open and you're still near it - or, when your kills / loot made it, while they
  -- keep counting (however far from its marker you farm)
  if Engine.focus then
    local s = list[Engine.focus]
    local d = s and distTo(s, px, py, pinst)
    if s and Engine.Status(Engine.focus) == "todo" then
      if not d or d <= (s.r or 40) + 80 then return end
      local at = Engine.focusWhy == "progress" and progressAt[key(Engine.focus)]
      if at and GetTime() - at <= Engine.PROGRESS_HOLD then return end
    end
    Engine.focus, Engine.focusWhy = nil, nil
  end
  local ps = list[planned]
  local dP = ps and distTo(ps, px, py, pinst)
  if dP and dP <= (ps.r or 40) + 10 then return end -- you're at the planned step: nothing to do
  local inArea, near, nearD
  for _, j in ipairs(Engine.Upcoming(planned, WINDOW)) do
    local s = list[j]
    if Engine.Status(j) == "todo" and (s.k == "obj" or s.k == "accept" or s.k == "turnin" or s.k == "fp") and Engine.Available(j) then
      local d = distTo(s, px, py, pinst)
      if d then
        if d <= (s.r or 40) and (not inArea or (s.k == "obj" and list[inArea].k ~= "obj")) then inArea = j end
        if d < 120 and (not nearD or d < nearD) then near, nearD = j, d end
      end
    end
  end
  local pick = inArea
  if not pick and near and dP and dP > 200 and nearD < dP * 0.4 then pick = near end
  local why = inArea and "you are standing at it" or "it is right next to you and your planned step is far away"
  -- a quest already done (or a delivery, done as you take it) whose hand-in is right here, though the plan hands it
  -- in much later: hand it in while you're here, not on a trip back (Menethil: the plan sent you to one hand-in and
  -- walked past five finished ones it had for later)
  if not pick then
    State = State or ns.State
    local best, bestD
    -- (cheap checks first - this runs every second: a hand-in, its quest ready in your log, near you - then its status)
    for j = planned + 1, math.min(#list, planned + Engine.READY_AHEAD) do
      local s = list[j]
      if s.k == "turnin" and s.q and s.q > 0 and State.QuestReady(s.q) then
        local d = distTo(s, px, py, pinst)
        if d and d <= Engine.READY_NEAR and (not dP or d < dP) and (not bestD or d < bestD) and Engine.Status(j) == "todo" then best, bestD = j, d end
      end
    end
    if best then pick, why = best, "it is ready to hand in and you are right here" end
  end
  if pick then setFocus(pick, why) end
end

-- kills / loot counting for a later objective: that's what you're doing
ns.On("FR_STATE", function()
  local planned = Engine.planned or Engine.current
  if not planned or Engine.view then return end
  local list = steps()
  for _, j in ipairs(Engine.Upcoming(planned, WINDOW)) do
    local s = list[j]
    if s.k == "obj" then
      local o = Engine.ObjectiveFor(s)
      local k = key(j)
      if o and o.have then
        if lastHave[k] and o.have > lastHave[k] and not o.finished then
          progressAt[k] = GetTime()
          if Engine.focus == j then Engine.focusWhy = "progress" -- shown for being here, now also counting: hold it as such
          elseif j ~= Engine.current then setFocus(j, "you are making progress on it", "progress") end
        end
        lastHave[k] = o.have
      end
    end
  end
end)
ns.On("FR_ROUTE_CHANGED", function() Engine.focus = nil; wipe(lastHave); wipe(progressAt) end)

----------------------------------------------------------------------------------------------------------------
-- Adding a stop (like adding a stop in a maps app): a quest you finished that the route has no hand-in for gets one,
-- slotted into the cheapest gap between two neighbouring stops - cost d(a,X) + d(X,b) - d(a,b) - or made the very next
-- step if "from where you are" is the cheapest gap. One pass over the stops; no replan. Only after the current step,
-- and only on a stretch of the route on the hand-in NPC's map. Hand-in spots: ForeverRouteEnders from the plan.
----------------------------------------------------------------------------------------------------------------
local function wd(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2) end

function Engine.InsertStop(new, px, py, pinst, opts)
  opts = opts or {}
  local list = steps()
  local cur = Engine.current
  if not cur then return nil end
  local from = math.max(cur, opts.minIndex or cur)
  local X = wpos(new); if not X then return nil end
  -- gaps: (you -> current step) when you're on the same map, then each pair of neighbouring stops after it
  local best, bestCost
  local prev, prevI = nil, nil
  if px and pinst == X[3] and from == cur then prev = { px, py, pinst } end
  -- chained stops start after a given step: the gap right after it counts too
  if from > cur and list[from - 1] then local w = wpos(list[from - 1]); if w and w[3] == X[3] then prev = w end end
  -- riding the current travel step (no flight path there yet): the road from you to the first stop at the other end
  -- is a real stretch - a stop on it goes before the travel step, i.e. you do it on the way
  local ride = nil
  if prev and from == cur and list[cur] and list[cur].k == "fly" and Engine.TravelPlan then -- not for stops that must come after an earlier one
    local plan = Engine.TravelPlan(list[cur])
    local m = ns.State.Position()
    -- only a real ride: if the trip there involves boats or flights, stops at the other end go after the travel step
    local trip = Engine.TravelFor and Engine.TravelFor(list[cur])
    local riding = not trip or (trip.how == "ride" and not (trip.legs and #trip.legs > 1))
    if riding and plan and (plan.ride or not plan.via or plan.via == m) then ride = prev end
  end
  for i = from, #list do
    local s = list[i]
    if s.k == "fly" or s.k == "hearth" then prev = nil -- a flight in between: the gap doesn't count
    else
      local w = wpos(s)
      if w and w[3] == X[3] then
        if ride then
          local c = wd(ride, X) + wd(X, w) - wd(ride, w)
          if not bestCost or c < bestCost then bestCost, best = c, cur end -- before the travel step: on the way
          ride = nil
        end
        -- never between two steps at the same NPC (turn in to Takar, accept from Takar): do both while you are there
        local split = list[i - 1] and list[i - 1].npc and list[i - 1].npc == s.npc
        if prev and not split then
          local c = wd(prev, X) + wd(X, w) - wd(prev, w)
          if not bestCost or c < bestCost then bestCost, best = c, i end -- insert before step i
        end
        prev = w
      end
    end
  end
  -- after the last stop on that map, as the next one (if there was a stretch there at all)
  if not best and prev then best = #list + 1 end
  if not best then return nil end
  Engine.lastInsertCost = bestCost
  if opts.maxCost and (bestCost or math.huge) > opts.maxCost then return nil end
  -- the current step stays current: a stop that goes "before the current step" becomes the step right after it,
  -- unless it\x27s cheapest to do first, in which case it\x27s inserted at the current position (shown next)
  -- the stop belongs to the stretch it lands in: the hub of the step it goes before (or the one before it, at the end).
  -- Whatever sec it carried (a copy from another side trip points into that trip's sections) would put the wrong hub
  -- on the card and a stray header in the list.
  local around = list[best] or list[best - 1]
  if around then new.sec = around.sec end
  table.insert(list, best, new)
  -- everything after it moved down one: step numbers, and the "where next?" choices (they are kept by position)
  for i = best, #list do list[i].id = i end
  local d = ForeverRouteData
  if d and list == d.steps then for _, c in ipairs(d.choices or {}) do if c.at and c.at >= best then c.at = c.at + 1 end end end
  if ns.Why then ns.Why("insert", "added " .. (new.k or "") .. " " .. (new.name or "") .. " as step " .. best .. " (" .. (opts.why or "you finished it; this is where it costs least") .. ")") end
  keyCache[list] = nil
  if Engine.focus and Engine.focus >= best then Engine.focus = Engine.focus + 1 end
  if Engine.view and Engine.view >= best then Engine.view = Engine.view + 1 end
  return best
end

-- side trips merge: the next stops of unfinished side trips (class quests, the sleeping bag), where they cost least,
-- if the detour is small. On a side trip, the other side trips join it; on your leveling path they join it too, but
-- only where the path really passes by (the player's choice, 2026-11-08: fold them in, and keep them as side trips)
Engine.MERGE_MAX_YARDS = 3000
Engine.MERGE_PATH_YARDS = 600
Engine.FP_DETOUR_YARDS = 600
function Engine.MergeSideTrips()
  local d = ForeverRouteData
  -- the flag lives on the step list: switching to the trip again unpacks a fresh list, which needs merging again
  if not (d and d.steps) or d.steps._merged or not ns.DungeonRoutes then return false end
  if d.branch or (d.dungeon and not d.special) then return false end -- a dungeon route stays about its dungeon
  local maxCost = d.special and Engine.MERGE_MAX_YARDS or Engine.MERGE_PATH_YARDS
  d.steps._merged = true
  State = State or ns.State
  local px, py, pinst = HBD:GetPlayerWorldPosition()
  local added = 0
  -- what the route already does (the planner puts some of these quests in your path itself): never twice
  local onRoute
  local function index() -- rebuilt after each insert: later steps move down one
    onRoute = {}
    for i, s in ipairs(d.steps) do if s.q and s.q > 0 and not onRoute[s.k .. ":" .. s.q] then onRoute[s.k .. ":" .. s.q] = i end end
  end
  index()
  for _, r in ipairs(ns.DungeonRoutes()) do
    if r.special and r.id ~= d.id and (UnitLevel("player") or 1) >= (tonumber(r.needsLevel) or 1) then
      local minI = Engine.current or 1
      for _, s in ipairs(ns.Steps(r)) do
        local skip = s.k == "fly" or s.k == "hearth" or not (s.q and s.q > 0 and s.m and s.x)
          or State.IsCompleted(s.q) or (s.k == "accept" and State.OnQuest(s.q)) or onRoute[s.k .. ":" .. s.q]
        -- a chain step the route already has: the rest of the chain goes after it
        local there = s.q and onRoute[s.k .. ":" .. s.q]
        if there then minI = math.max(minI, there + 1) end
        if not skip then
          local copy = {}; for k, v in pairs(s) do copy[k] = v end
          copy.inserted, copy.id, copy.wp = true, nil, nil
          copy.note = "On the way: " .. (r.dungeonName or r.title) .. "."
          local at = Engine.InsertStop(copy, px, py, pinst, { minIndex = minI, maxCost = maxCost, why = "on the way for " .. (r.dungeonName or r.title) })
          if not at then
            if ns.Why then ns.Why("merge", "left " .. (copy.k or "") .. " " .. (copy.name or "") .. " (" .. (r.dungeonName or r.title) .. ") for later: " .. (Engine.lastInsertCost and string.format("a %d yd detour, over the %d yd limit", Engine.lastInsertCost, Engine.MERGE_MAX_YARDS) or "another continent or nowhere near this trip")) end
            break -- the rest of that chain waits
          end
          minI = at + 1; added = added + 1; index()
        end
      end
    end
  end
  -- flight paths you do not have, close to the trip (a small detour now saves trips later)
  local have = {}; for _, s in ipairs(steps()) do if s.k == "fp" and s.m then have[s.m] = true end end
  for m, list in pairs(ns.FLIGHT or {}) do
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(m)
    local zn = info and info.name
    if zn and not have[m] and not Engine.KnowsFlightIn(zn) then
      local f = list[1]
      local at = Engine.InsertStop({ k = "fp", npc = f[3], m = m, x = f[1], y = f[2], zone = zn, r = 8, inserted = true, note = "A flight path you do not have yet - saves trips later." }, px, py, pinst, { maxCost = Engine.FP_DETOUR_YARDS, why = "a flight path close to this trip" })
      if at then added = added + 1 end
    end
  end
  if added > 0 then ns.Print(added .. " stop" .. (added == 1 and "" or "s") .. " added on the way: other side trips and flight paths you do not have (see the list).") end
  return added > 0
end
ns.On("FR_ROUTE_CHANGED", function() C_Timer.After(0.6, function() if Engine.MergeSideTrips() then Engine.Refresh() end end) end)
ns.On("FR_LOADED", function() C_Timer.After(3.5, function() if Engine.MergeSideTrips() then Engine.Refresh() end end) end)

-- the hand-in spots (ForeverRouteEnders) of the quests in your log: the list covers every quest you could take
-- (~1000), so walk your log (at most 40) and look each one up instead of asking the game about all of them
function Engine.LogEnders()
  local enders = ForeverRouteEnders
  if not enders then return {} end
  local inLog = {}
  Engine.logLevels = {} -- quest level by id, for the gray check below
  local n = C_QuestLog and C_QuestLog.GetNumQuestLogEntries and select(2, pcall(C_QuestLog.GetNumQuestLogEntries))
  if type(n) == "number" and n > 0 and C_QuestLog.GetInfo then
    for i = 1, n do
      local ok, info = pcall(C_QuestLog.GetInfo, i)
      if ok and info and not info.isHeader and info.questID and enders[info.questID] then inLog[info.questID] = enders[info.questID]; Engine.logLevels[info.questID] = info.level end
    end
    return inLog
  end
  return enders -- no quest log to read (tests): every spot, each checked with QuestReady
end
-- finished quests in your log with no hand-in on the route: add one where it costs least
-- how far out of the way (yards, there and back) a gray hand-in may take you: about a 20-second walk
Engine.GRAY_DETOUR_YD = 150
local function applyInserts()
  local list = steps()
  if not (ForeverRouteEnders and ForeverRouteData and #list > 0) then return false end
  -- side trips (special rewards, dungeon routes) are their own short list: your leveling path handles the extras
  if ForeverRouteData.dungeon or ForeverRouteData.special then return false end
  local have = {}
  for _, s in ipairs(list) do if s.k == "turnin" and s.q then have[s.q] = true end end
  local px, py, pinst = HBD:GetPlayerWorldPosition()
  local added = false
  for q, e in pairs(Engine.LogEnders()) do
    if not have[q] and not (ns.char.nope and ns.char.nope[q]) and ns.State.QuestReady(q) and not ns.State.IsCompleted(q) then
      local step = { k = "turnin", q = q, name = e.name, npc = e.npc, m = e.m, x = e.x, y = e.y, r = 6, inserted = true,
        note = "Added: you finished this one on the way." }   -- its sec comes from where InsertStop puts it
      -- a gray quest (Messenger to Westfall at 26: 250 XP) gets a stop only right on the way: never a detour for it
      local ql, me = Engine.logLevels and Engine.logLevels[q], UnitLevel and UnitLevel("player")
      local okG, green = pcall(function() return GetQuestGreenRange and GetQuestGreenRange() end)
      local gray = type(ql) == "number" and type(me) == "number" and (me - ql) > ((okG and type(green) == "number" and green) or 8)
      local opts = gray and { maxCost = Engine.GRAY_DETOUR_YD, why = "gray, but right on the way" } or nil
      if Engine.InsertStop(step, px, py, pinst, opts) then added = true; have[q] = true end
    end
  end
  return added
end
Engine.ApplyInserts = applyInserts
ns.On("FR_STATE", function() if applyInserts() then Engine.Refresh() end end)
ns.On("FR_LOADED", function() C_Timer.After(3, function() if applyInserts() then Engine.Refresh() end end) end)
ns.On("FR_ROUTE_CHANGED", function() C_Timer.After(0.5, function() if applyInserts() then Engine.Refresh() end end) end)

----------------------------------------------------------------------------------------------------------------
-- "Not doing this quest": drops it from the route (all its steps), from future plans (the planner reads the list),
-- and from stop insertion. If later quests on the route need it (ForeverRouteUnlocks from the plan), you're warned
-- first and they go too. Undo brings everything back.
----------------------------------------------------------------------------------------------------------------
local function questName(q)
  for _, s in ipairs(steps()) do if s.q == q and s.name then return s.name end end
  local e = ForeverRouteEnders and ForeverRouteEnders[q]
  return e and e.name or ("quest " .. q)
end
-- the quests on the route that come after this one in its chain (and aren't done yet)
function Engine.Dependents(q)
  local out = {}
  for _, d in ipairs((ForeverRouteUnlocks and ForeverRouteUnlocks[q]) or {}) do
    if not ns.State.IsCompleted(d) and not (ns.char.nope and ns.char.nope[d]) then out[#out + 1] = d end
  end
  return out
end
function Engine.NopeNow(qs)
  ns.char.nope = ns.char.nope or {}
  for _, q in ipairs(qs) do ns.char.nope[q] = true end
  table.insert(ns.char.history, { kind = "nope", ids = {}, nope = qs })
  Engine.view = nil
  Engine.Refresh()
  ns.Print(questName(qs[1]) .. (#qs > 1 and (" and " .. (#qs - 1) .. " quest" .. (#qs > 2 and "s" or "") .. " after it") or "") .. ": not doing. Dropped from your route and future plans. Undo brings it back.")
end
-- you abandoned these on the quest log check's advice (not on your route, or gray by then): the route stops sending
-- you back to pick them up, and the planner leaves them out. Undo brings them back; so does taking the quest again.
-- (A plain abandon in the game's quest log still sends you back: that's how a failed escort is taken again.)
function Engine.Abandoned(qs, why)
  ns.char.nope = ns.char.nope or {}
  for _, q in ipairs(qs) do ns.char.nope[q] = true; if ns.Why then ns.Why("abandon", questName(q) .. ": abandoned from the quest log check (" .. (why or "not worth doing") .. "); dropped from the route") end end
  table.insert(ns.char.history, { kind = "nope", ids = {}, nope = qs })
  if #ns.char.history > 50 then table.remove(ns.char.history, 1) end
  Engine.Refresh()
end
-- taking a quest you had dropped means you want it after all
ns.On("QUEST_ACCEPTED", function(a, b)
  local q = type(b) == "number" and b or a -- (questID) on this client, (logIndex, questID) on older ones
  if q and ns.char and ns.char.nope and ns.char.nope[q] then
    ns.char.nope[q] = nil
    if ns.Why then ns.Why("abandon", questName(q) .. ": you took it again; back on your route") end
  end
end)
-- the quest giver has nothing for you (no window opens, so the addon can't see it): this quest leaves your route
-- until your next level, then it's tried again - its chain stays (Availability.lua; the planner reads the same record)
function Engine.NotOffered(q)
  local s = steps()[Engine.Shown() or 0]
  if not q then q = s and s.q end
  if not q or q <= 0 or not ns.Avail then return end
  ns.Avail.NotOffered(q, (s and s.q == q and s.npc) or "the quest giver", s and s.q == q and s.name or nil)
  Engine.Refresh()
end
function Engine.Nope(q)
  if not q then local s = steps()[Engine.Shown() or 0]; q = s and s.q end
  if not q or q <= 0 then ns.Print("no quest on this step."); return end
  local deps = Engine.Dependents(q)
  if #deps == 0 then Engine.NopeNow({ q }); return end
  local names = {}
  for k, d in ipairs(deps) do if k <= 8 then names[#names + 1] = questName(d) end end
  if #deps > 8 then names[#names + 1] = "... and " .. (#deps - 8) .. " more" end
  local dlg = StaticPopup_Show("FOREVERROUTE_NOPE", questName(q), table.concat(names, "\n"))
  if dlg then local all = { q }; for _, d in ipairs(deps) do all[#all + 1] = d end; dlg.data = all end
end
StaticPopupDialogs["FOREVERROUTE_NOPE"] = {
  text = "Not doing %s?\n\nIt is part of a chain. These come after it on your route and would be dropped too:\n\n%s",
  button1 = "Drop them all", button2 = "Keep", timeout = 0, whileDead = true, hideOnEscape = true,
  OnAccept = function(self, data) if data then Engine.NopeNow(data) end end,
}
