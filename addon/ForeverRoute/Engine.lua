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
  local name = ns.Dungeon.Here() -- which dungeon, by its instance id or the game's name for it (Dungeon.lua)
  if not name then return end
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

-- status: "done", "todo", "blocked" (quest not in log), "wait" (level too low), "full" (a pick-up with your quest log
-- full: passed over like "wait", so the card goes to hand-ins and objectives first), "notready" (turn-in with objectives left),
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
-- Your place in the built-in plan. It is one path from level 1 to 60, and every step has a level: the level the plan
-- has you at when you get there (lvl; a step without one - a flight, a flight path, a hearth - takes the level of the
-- next step that has one: travel belongs to what it leads to). What the plan does below your place is behind you:
-- passed, whatever kind of step it is. Your place is the higher of two things:
--   where you joined: someone who meets the plan at 30 (installed the addon then, or came back to it) joins at the
--     trip during which the plan reaches 30. Everything before that trip is behind them for good, quests in their log
--     included - those are theirs to finish or drop, like any quest that is not on the route (a finished one gets a
--     hand-in stop where the route passes its NPC, and the quest log check lists them all). Kept in ns.char.join.
--   JOIN_GAP levels below you: rested XP and dungeons put you ahead of the plan, and up to 3 levels ahead you are
--     still doing what it says. Further ahead than that, what it does down there is passed - but a quest in your log
--     stays, here: you picked it up on the plan.
-- A quest goes as a whole: with its pick-up behind you (and the quest not yours), its other steps are too; a pick-up
-- that needs a quest whose hand-in is behind you is not offered; and a quest in your log goes when something still to
-- do for it lies before the trip you joined at. Your own plan (the companion's) is made from your save: none of this.
-- (A level 30 trying the addon was sent to Redridge for a flight path, to Elwynn for errands, then through Duskwood
-- and Ashenvale: travel steps carried no level, and quests in the log pulled the card back to each of those zones.)
Engine.JOIN_GAP = 3
local planCache = setmetatable({}, { __mode = "k" })
local function isTrip(s) return s.k == "fly" or s.k == "hearth" or s.k == "boat" end
local function planIndex()
  local list = steps()
  local c = planCache[list]
  if c and c.n == #list then return c, list end
  c = { n = #list, idx = {}, eff = {}, accept = {}, turnin = {}, at = {} }
  local nxt
  for i = #list, 1, -1 do
    local s = list[i]
    c.idx[s] = i
    if tonumber(s.lvl) then nxt = s.lvl end
    c.eff[i] = nxt
    if s.q and s.q > 0 then
      if s.k == "accept" then c.accept[s.q] = i elseif s.k == "turnin" and not s.inserted then c.turnin[s.q] = i end -- (the first of each: this runs backwards)
    end
  end
  local last -- the last steps of a plan, with no stamped step after them: the level before
  for i = 1, #list do if c.eff[i] then last = c.eff[i] else c.eff[i] = last end end
  planCache[list] = c
  return c, list
end
-- the level the plan has you at, at step i (nil on a plan without levels)
function Engine.PlanLevel(i) return (planIndex()).eff[i] end
-- the step you joined at: the trip (flight, hearth, boat) into the stretch where the plan first reaches that level,
-- so you start a stretch from its beginning - its pick-ups before the things they are for. nil: nothing to pass
local function joinStep(level)
  local c, list = planIndex()
  local at = c.at[level]
  if at == nil then
    at = false
    for i = 1, #list do
      if tonumber(list[i].lvl) and list[i].lvl >= level then
        at = 1
        for j = i, 1, -1 do if isTrip(list[j]) then at = j; break end end
        break
      end
    end
    c.at[level] = at
  end
  return at or nil
end
-- the level you joined the built-in plan at, and the step that goes with it (nil, nil: you follow it from the start,
-- or it isn't known yet - Engine.FindPlace)
function Engine.Place()
  local key = ns.planKey and ns.planKey.starter
  local j = key and ns.char and ns.char.join
  if Engine.noPlace or not (j and j.plan == key and tonumber(j.level) and j.level > 1) then return nil end
  return j.level, joinStep(j.level)
end
-- Where you start. The trip you join at is the plan at your level; but the plan's stretches of the JOIN_GAP levels
-- before it are still good for you, and one of them may be worth more than that trip from where you stand: someone
-- who meets the plan at 30 in Darkshire has Duskwood's level 27-31 stretch around them, and the plan's own next
-- stretch a flight away. So when you join, each of those stretches (a stretch: the steps between two trips) is priced
-- like the planner prices a zone - the XP of the quests you can still do in it, over the time they take plus the trip
-- there from where you stand - and the best one is where you start (ns.char.join.first), before the trip you joined
-- at. Value decides, not distance: staying put wins only if its quests beat the alternative with its trip.
-- The numbers are rough and say so: quest XP from the quest's level (less for one far below you), a pick-up or hand-in
-- 10 s, an objective 2 min, the walk between steps at running or riding speed, the trip from Travel.Plan.
Engine.START_HORIZON = 3600 -- stretches are compared by the XP they bring in this many seconds (a short one, then the plan)
Engine.START_MIN_TURNINS = 5 -- a stretch with fewer hand-ins is no place to start (the planner's own floor for a zone)
local function firstTrip(c, list)
  if not c.trip1 then c.trip1 = #list + 1; for j = 1, #list do if isTrip(list[j]) then c.trip1 = j; break end end end
  return c.trip1
end
local function stretchEnd(list, from) for j = from + 1, #list do if isTrip(list[j]) then return j - 1 end end return #list end
local function questXP(ql, L)
  local xp = 100 + 60 * ql + 0.9 * ql * ql
  local d = L - ql
  return xp * (d <= 5 and 1 or d == 6 and 0.8 or d == 7 and 0.6 or d == 8 and 0.4 or d == 9 and 0.2 or 0.1)
end
-- the next thing to do for a quest in your log: its first unfinished objective on the route, else its hand-in
local function nextStep(q, c, list)
  if not State.QuestReady(q) then
    for _, j in ipairs(Engine.ObjStepsOf(q)) do
      local o = Engine.ObjectiveFor(list[j])
      if not (o and o.finished) then return j end
    end
    return nil
  end
  return c.turnin[q]
end
-- what a stretch is worth to you now: XP, seconds of work, hand-ins, the first step with a place
function Engine.StretchWorth(from, to)
  State = State or ns.State
  local c, list = planIndex()
  local L = UnitLevel("player") or 1
  local speed = (ns.Travel and ns.Travel.Speed and ns.Travel.Speed()) or 7
  local xp, secs, n, spot = 0, 0, 0, nil
  -- a quest you can do there: in your log with its next step there, or picked up in this stretch with every quest it
  -- needs handed in by then
  local can = {}
  local function doable(q)
    if can[q] == nil then
      local a = c.accept[q]
      if State.OnQuest(q) then
        local n = nextStep(q, c, list)
        can[q] = n ~= nil and n >= from and n <= to
      else
        can[q] = a ~= nil and a >= from and a <= to
      end
      if can[q] and not State.OnQuest(q) then
        for _, p in ipairs(Engine.PrereqsOf(q)) do
          local t = c.turnin[p]
          if not State.IsCompleted(p) and not (t and t >= from and t <= to and (State.OnQuest(p) or (c.accept[p] or 0) >= from)) then can[q] = false; break end
        end
      end
    end
    return can[q]
  end
  for j = from, to do
    local s = list[j]
    local q = s.q and s.q > 0 and s.q or nil
    if q and not State.IsCompleted(q) and not Engine.Outlevelled(s) then
      if doable(q) then
        if not (s.k == "accept" and State.OnQuest(q)) then
          spot = spot or (s.m and s.x and s) or nil
          secs = secs + (tonumber(s.walk) or 80) / speed + (s.k == "obj" and 120 or 10)
          if s.k == "turnin" and tonumber(s.level) and s.level > 0 then xp = xp + questXP(s.level, L); n = n + 1 end
        end
      end
    end
  end
  return xp, secs, n, spot
end
-- the stretch to start in, for someone joining at this level: its first step's key (nil: the trip you joined at), and
-- the stretches priced { from, to, zone, xph, extra (s of travel it adds), work (s), turnins, plan }, best first.
-- Priced: the plan's trip at your level (its XP over its work and the trip there), and every other stretch the plan
-- has within reach of your level - from OUTLEVEL levels below you (the planner's own line for a quest worth doing) up
-- to your level - with START_MIN_TURNINS hand-ins you can still do: its XP over its work and the travel it ADDS (the
-- trip there, then on to the plan's trip, less the trip you'd make anyway). So a stretch around you costs nothing to
-- reach, and one across the world has to be worth the detour.
function Engine.ChooseStart(level)
  State = State or ns.State
  local c, list = planIndex()
  local at = joinStep(level)
  local m, x, y = State.Position()
  if not (at and at > 1 and m and x and ns.Travel and ns.Travel.Plan) then return nil, {} end
  local L = UnitLevel("player") or 1
  local function trip(a, b)
    local ok, _, secs = pcall(ns.Travel.Plan, { m = a.m, x = a.x, y = a.y }, { m = b.m, x = b.x, y = b.y, name = b.zone })
    return ok and tonumber(secs) or nil
  end
  local me = { m = m, x = x, y = y }
  local priced = {}
  -- the plan's trip at your level
  local to = stretchEnd(list, at)
  local xpD, workD, nD, spotD = Engine.StretchWorth(at, to)
  local tripD = spotD and trip(me, spotD)
  if not tripD then return nil, {} end -- no way there from here (or nothing to do there): nothing to compare with
  priced[1] = { from = at, to = to, zone = spotD.zone or list[at].dest or "?", xph = math.floor(xpD / (workD + tripD) * 3600), extra = math.floor(tripD), work = math.floor(workD), turnins = nD, plan = true }
  local function price(from)
    local last = stretchEnd(list, from)
    local xp, work, n, spot = Engine.StretchWorth(from, last)
    if not spot or n < Engine.START_MIN_TURNINS then return end
    local there, on = trip(me, spot), trip(spot, spotD)
    if not (there and on) then return end
    local extra = math.max(0, there + on - tripD)
    priced[#priced + 1] = { from = from, to = last, zone = spot.zone or list[from].dest or "?", xph = math.floor(xp / (work + extra) * 3600), extra = math.floor(extra), work = math.floor(work), turnins = n }
  end
  for j = 1, #list do
    local e = c.eff[j] or 0
    if j > at and e > L then break end
    if j ~= at and (j == 1 or isTrip(list[j])) and e >= L - Engine.OUTLEVEL then price(j) end
  end
  -- compared over the same time (START_HORIZON): a stretch shorter than that is followed by the plan at the plan's own
  -- rate. Rates alone over-praised tiny stretches - five errands in 7 minutes scored 168k XP/h and would beat a real
  -- zone, though they are over before the hour is
  local planRate = priced[1].xph / 3600
  local H = Engine.START_HORIZON
  for _, p in ipairs(priced) do
    local t = p.work + p.extra
    local xp = p.xph / 3600 * t
    p.score = t >= H and p.xph or math.floor((xp + (H - t) * planRate) / H * 3600)
  end
  table.sort(priced, function(a, b) if a.score ~= b.score then return a.score > b.score end return (a.plan and 1 or 0) > (b.plan and 1 or 0) end)
  local best = priced[1]
  if best.plan then return nil, priced end
  return Engine.Key(best.from), priced
end
-- the stretch you start in (nil: none chosen, or it is not on this plan any more): its first and last step
function Engine.FirstStretch()
  local j = ns.char and ns.char.join
  local k = j and ns.planKey and j.plan == ns.planKey.starter and j.first
  if not k or Engine.noPlace then return nil end
  local c, list = planIndex()
  if c.firstKey ~= k then
    c.firstKey, c.firstFrom, c.firstTo = k, false, false
    for i = 1, #list do if Engine.Key(i) == k then c.firstFrom, c.firstTo = i, stretchEnd(list, i); break end end
  end
  return c.firstFrom or nil, c.firstTo or nil
end
-- the zone you are in (nil on a flight, or where the game gives no position): taken once per refresh (Engine.here)
function Engine.HereMap()
  State = State or ns.State
  if ns.Is and UnitOnTaxi and ns.Is(UnitOnTaxi, "player") then return nil end
  local ok, m = pcall(State.Position)
  return ok and m or nil
end
function Engine.BehindYou(s)
  State = State or ns.State
  if Engine.noPlace or not (s and ns.planKey and ns.planKey.starter) then return false end
  local c, list = planIndex()
  local i = c.idx[s]
  if not i then return false end
  local L = UnitLevel("player") or 1
  local _, at = Engine.Place()
  local f1, f2 = nil, nil
  if at then f1, f2 = Engine.FirstStretch() end
  -- before the trip you joined at, and not in the stretch you start in
  local function before(j) return at ~= nil and j < at and not (f1 and j >= f1 and j <= f2) end
  -- below your place: that, or more than JOIN_GAP levels below you (not while you are still in the plan's first
  -- stretch, the start zone: its chains lead out of it, and at 5 nothing of it is behind you)
  local start = at == nil and joinStep(L) == 1
  local function low(j)
    if before(j) then return true end
    local e = c.eff[j]
    return (e and e < L - Engine.JOIN_GAP and not (start and j < firstTrip(c, list))) or false
  end
  local q = s.q and s.q > 0 and s.q or nil
  if not q then
    if low(i) then return true end
    if s.k == "hearth" then
      -- a hearth to an inn the plan bound you at in a part that is behind you: you are not bound there
      for j = i - 1, 1, -1 do
        local t = list[j]
        if t.k == "bind" then return Engine.BehindYou(t) and not Engine.BoundAt(t, GetBindLocation and GetBindLocation()) end
      end
    end
    return false
  end
  if State.IsCompleted(q) then return false end
  if State.OnQuest(q) then
    -- in your log. Following the plan, or picked up since you joined it: the plan's, wherever it leads
    local had = at and ns.char.join and ns.char.join.had
    if s.k == "accept" or s.inserted or not (had and had[q]) then return false end -- (a stop added for it is on your way)
    -- yours from before you joined: on the plan if what is left of it is ahead of you - or it is finished and its
    -- hand-in is in the zone you are in (handed in first: The Night Watch, 19 yd from a level 30 in Darkshire)
    local n = nextStep(q, c, list)
    if not n then return before(i) end
    if not before(n) then return false end
    return not (Engine.here ~= nil and list[n].k == "turnin" and list[n].m == Engine.here)
  end
  if s.k ~= "accept" then
    -- a quest goes as a whole: with its pick-up behind you, its other steps are too
    local a = c.accept[q]
    if a and a ~= i then return Engine.BehindYou(list[a]) end
    return low(i)
  end
  if low(i) then return true end
  -- it needs a quest whose hand-in is behind you: not offered. (ForeverRouteUnlocks is the whole chain before it; it
  -- lists "any one of" with "all of", so a quest with two ways in can be passed here though one of them is done)
  for _, p in ipairs(Engine.PrereqsOf(q)) do
    if not State.IsCompleted(p) then
      local t = c.turnin[p]
      if t and t < i and Engine.BehindYou(list[t]) then return true end
    end
  end
  return false
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
  if Engine.Outlevelled(s) or Engine.GrayHandIn(s) or Engine.Breadcrumbed(s) or Engine.BehindYou(s) then return "done" end
  local k = s.k
  if k == "accept" then
    if State.OnQuest(s.q) or State.IsCompleted(s.q) then return "done" end
    if s.minLevel and UnitLevel("player") < s.minLevel then return "wait" end
    if State.LogFull and State.LogFull() then return "full" end
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
  -- a flight (or hearth) to nothing: every step from it to the next travel is already done - the safety-net pick-up of
  -- a quest you already have (ensure-steps) sat in the Wetlands between two Stormwind stops, and the list read "Fly to
  -- Wetlands, Fly to Stormwind" twice over
  if (k == "fly" or k == "hearth" or k == "boat") and not (ns.ChoiceFor and ns.ChoiceFor(i)) then
    local list, any = steps(), false
    for j = i + 1, math.min(#list, i + 40) do
      local t = list[j]
      if t.k == "fly" or t.k == "hearth" or t.k == "boat" then break end
      any = true
      if Engine.Status(j) ~= "done" then any = nil; break end
    end
    if any then return "done" end
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

-- Finding your place in the built-in plan (see Engine.BehindYou): the first time this character meets it, and again
-- when you come back to it more than JOIN_GAP levels on (the addon was off, or you were on a plan of your own).
-- Where the plan stands for you without any of that - the first step still to do - tells which you are: within
-- JOIN_GAP levels of you, you are following it, and nothing changes; further back, you join at your level.
-- force (/fr rejoin): join at your level whatever the plan says.
function Engine.PlaceDue()
  local key = ns.planKey and ns.planKey.starter
  if not (key and ns.char) then return false end
  -- (on the plan's path only: a side trip or a dungeon route has no levels to tell by)
  local d = ForeverRouteData
  if not d or d.branch or d.dungeon or d.zoneRoute or d.special then return false end
  -- not before the game has told us the quests you've done: on a cold login it may not have yet, and a player
  -- following the plan would read as one joining it (and lose up to JOIN_GAP levels of it, quests in the log too)
  State = State or ns.State
  if (UnitLevel("player") or 1) > 5 then
    if not next(State.completed or {}) and State.RefreshCompleted then State.RefreshCompleted() end
    if not next(State.completed or {}) then return false end
  end
  local j = ns.char.join
  if not (j and j.plan == key) then return true end
  return (UnitLevel("player") or 1) - (tonumber(j.seen) or 0) > Engine.JOIN_GAP
end
-- the quests of the plan that were in your log when you joined it (a join made before this was kept: as of now)
function Engine.JoinHad()
  State = State or ns.State
  local j = ns.char and ns.char.join
  if not (j and ns.planKey and j.plan == ns.planKey.starter and tonumber(j.level) and j.level > 1) or j.had then return end
  local had = {}
  for _, s in ipairs(steps()) do if s.q and s.q > 0 and not had[s.q] and State.OnQuest(s.q) then had[s.q] = true end end
  j.had = had
end
function Engine.FindPlace(force)
  local key = ns.planKey and ns.planKey.starter
  if not (key and ns.char) then return nil end
  local L = UnitLevel("player") or 1
  local old = ns.char.join and ns.char.join.plan == key and ns.char.join or nil
  local level, fresh = L, true
  if not force then
    local saved = batch
    batch, Engine.noPlace = nil, true -- (no reuse: these are the statuses without a place)
    local ok, first = pcall(Engine.Compute)
    batch, Engine.noPlace = saved, nil
    local e = ok and first and Engine.PlanLevel(first)
    -- within JOIN_GAP levels of where the plan stands for you, or the plan reaches your level in its first stretch
    -- (you are still in the start zone): you are following it
    local at = joinStep(L)
    if not e or e >= L - Engine.JOIN_GAP or at == 1 then level, fresh = old and old.level or 0, false end
  end
  if not fresh then
    ns.char.join = { plan = key, level = level, seen = L, first = old and old.first, had = old and old.had }
    if batch then wipe(batch) end
    return level
  end
  -- joining: where to start (Engine.ChooseStart), and the quests you bring along
  local first, priced = nil, {}
  if L > 1 then
    local ok, a, b = pcall(Engine.ChooseStart, L)
    if ok then first, priced = a, b or {} elseif ns.LogError then ns.LogError("join", a) end
  end
  ns.char.join = { plan = key, level = level, seen = L, first = first }
  Engine.JoinHad()
  if batch then wipe(batch) end
  if L > 1 and not (old and old.level == L and old.first == first and not force) then
    local _, at = Engine.Place()
    local function k(n) return string.format("%.1fk", n / 1000) end
    local function one(p) return p.zone .. " (step " .. p.from .. (p.plan and ", the plan's trip at your level" or "") .. "): about " .. k(p.score or p.xph) .. " XP in the next hour - " .. p.turnins .. " hand-ins, " .. math.floor(p.work / 60 + 0.5) .. " min of work, " .. math.floor(p.extra / 60 + 0.5) .. (p.plan and " min to get there" or " min of travel added") end
    local won = priced[1] and ("start in " .. one(priced[1]) .. (priced[2] and ("; next best " .. one(priced[2])) or "; nothing else priced")) or "nothing to price (no position, or no stretch near your level): the plan's trip at your level"
    if ns.Why then ns.Why("join", "joined the built-in plan at level " .. L .. (at and (", its step " .. at) or "") .. ": " .. won) end
    local say = function()
      ns.Print("You join the built-in plan at level " .. L .. ": what it does before that is behind you" .. (at and at > 1 and (" (" .. (at - 1) .. " steps)") or "") .. "."
        .. (first and priced[1] and (" You start in " .. priced[1].zone .. ": worth more from where you stand (about " .. k(priced[1].score or priced[1].xph) .. " XP in the next hour" .. (priced[2] and (" against " .. k(priced[2].score or priced[2].xph) .. " in " .. priced[2].zone) or "") .. ").") or "")
        .. " Quests in your log from the parts behind you are yours to finish or drop - /fr logcheck lists them. (/fr rejoin does this again at your level.)")
    end
    if force then say() else C_Timer.After(7, say) end
  end
  return level
end
function Engine.Rejoin()
  if not (ns.planKey and ns.planKey.starter) then ns.Print("Only on the built-in plan: a plan of your own is made from your save and starts where you are."); return end
  Engine.FindPlace(true)
  Engine.Refresh()
end
-- your level, each time the addon sees you level on the built-in plan: a gap in it is time spent away from the plan
ns.On("PLAYER_LEVEL_UP", function(level)
  local j = ns.char and ns.char.join
  if j and ns.planKey and j.plan == ns.planKey.starter then j.seen = tonumber(level) or UnitLevel("player") or j.seen end
end)
-- not before you are in the world: the quest log and the quests you have done are known from then on
ns.On("PLAYER_ENTERING_WORLD", function() Engine.placeReady = true end)

function Engine.Compute()
  -- the first step you can act on now. A step that needs a higher level ("wait") or a quest that isn't in your log
  -- ("blocked") doesn't hold up the route: it is passed over and comes back as soon as it can be done.
  local list, fallback = steps(), nil
  local skipFrom, skipTo = nil, nil
  do
    local _, at = Engine.Place()
    local f1, f2 = Engine.FirstStretch()
    if at and f1 and f1 > at then
      for i = f1, f2 do
        local st = Engine.Status(i)
        if st ~= "done" and st ~= "wait" and st ~= "blocked" and st ~= "later" then skipFrom, skipTo = at, f1 - 1; break end
      end
    end
  end
  for i = 1, #list do
    local st = (skipFrom and i >= skipFrom and i <= skipTo) and "done" or Engine.Status(i)
    if st ~= "done" then
      if st == "wait" or st == "full" or st == "blocked" or st == "later" then fallback = fallback or i else return i end
    end
  end
  return fallback
end
function Engine.InDungeon(name)
  local here = ns.Dungeon.Here() -- by the instance id, or the game's name for it (Dungeon.lua)
  return here and Engine.SamePlace(here, name) or false
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
  Engine.here = Engine.HereMap() -- the zone you are in, for this refresh (Engine.BehindYou)
  if Engine.placeReady and Engine.PlaceDue() then Engine.FindPlace() end
  if Engine.placeReady then Engine.JoinHad() end
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
  if plan.ride then return { how = "ride", m = s.m, x = s.x, y = s.y, text = ns.RideWord() .. " to " .. destName .. (plan.yards and (" - " .. ns.Style.Distance(plan.yards)) or "") } end
  if plan.via and plan.via ~= pm then
    local t = atFlightMaster(plan.viaName); if t then t.how = "via"; t.text = "No " .. destName .. " flight path yet: fly " .. (t.fm and ("from " .. t.fm .. " ") or "") .. "to " .. plan.viaName .. ", then ride" end
    return t
  end
  return { how = "ride", m = s.m, x = s.x, y = s.y, text = ns.RideWord() .. " to " .. destName }
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
Engine.READY_NEAR = 300  -- yards: near enough that the card takes you there now (the town you are in), when clearly nearer than the plan
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
-- a finished quest whose hand-in is close by, wherever the plan has it: the card's "ready nearby" line (The Hermit was
-- ready with Abercrombie 20 yd away and the card said nothing). Its own check, not the live reordering's - one line you
-- choose from, nothing moves by itself. -> { i, q, name, npc, d } or nil
Engine.READY_LINE_YD = 300 -- within the hold of a chosen hand-in (READY_NEAR + 40)
function Engine.ReadyNearby(px, py, pinst)
  if not px then return nil end
  State = State or ns.State
  local list, shown, best = steps(), Engine.Shown(), nil
  for j, s in ipairs(list) do
    if s.k == "turnin" and s.q and s.q > 0 and j ~= shown and State.QuestReady(s.q) then
      local d = distTo(s, px, py, pinst)
      if d and d <= Engine.READY_LINE_YD and (not best or d < best.d) and Engine.Status(j) == "todo" then best = { i = j, q = s.q, name = s.name, npc = s.npc, d = d } end
    end
  end
  return best
end
-- you picked it ("Do it now"): the card shows it until it's handed in (held like a ready hand-in the card picked)
function Engine.FocusOn(i, why) if i then setFocus(i, why or "you chose it", "ready") end end

-- called by the arrow driver about once a second with your position
-- can you do this step right now? A pick-up whose earlier chain quest isn't handed in yet isn't offered (Chef Grual
-- has nothing until Jitters' Growling Gut is in), and a hand-in needs the quest in your log
local prereqOf
-- the quests that must be handed in before this one is offered (the plan's ForeverRouteUnlocks, turned around)
function Engine.PrereqsOf(q)
  if prereqOf == nil or prereqOf.src ~= ForeverRouteUnlocks then
    prereqOf = { src = ForeverRouteUnlocks }
    for p, list in pairs(ForeverRouteUnlocks or {}) do for _, d in ipairs(list) do prereqOf[d] = prereqOf[d] or {}; table.insert(prereqOf[d], p) end end
  end
  return prereqOf[q] or {}
end
function Engine.Available(j)
  local s = steps()[j]
  if not s or not s.q or s.q <= 0 then return true end
  State = State or ns.State
  if s.k == "turnin" then return State.OnQuest(s.q) and true or false end
  if s.k ~= "accept" then return true end
  for _, p in ipairs(Engine.PrereqsOf(s.q)) do if not State.IsCompleted(p) then return false end end
  return true
end
-- why a step can't be done at this moment, or nil when it can. For the pins: a step you can't act on yet must not
-- look like an instruction (a hand-in pin beside you for a quest you only get two stops from now - "dafuq is up with
-- this turn in"). Returns a reason and, where the route has it, the step that opens this one:
--   "level", nil, N        waits for level N
--   "pickup", j            its quest isn't in your log; step j picks it up
--   "handin", j            a pick-up whose earlier chain quest isn't handed in; step j hands it in
--   "objectives", j        a hand-in with objectives left; step j is the first of them
--   "dungeon", nil, name   left for your next run of that dungeon
--   "full"                 a pick-up while your quest log is full
function Engine.NotYet(i)
  local list = steps()
  local s = list[i]
  if not s then return nil end
  State = State or ns.State
  local st = Engine.Status(i)
  if st == "done" then return nil end
  if st == "wait" then return "level", nil, s.minLevel or s.until_ end
  if st == "full" then return "full" end
  if st == "later" then
    local name = Engine.InsideOf(s)
    if not name then for _, j in ipairs(Engine.ObjStepsOf(s.q)) do name = name or Engine.InsideOf(list[j]) end end
    return "dungeon", nil, name
  end
  if st == "notready" then
    for _, j in ipairs(Engine.ObjStepsOf(s.q)) do if j ~= i and not Engine.IsDone(j) then return "objectives", j end end
    return "objectives"
  end
  -- the step of that kind for that quest still to do: the last one before this step, else the first one after it
  local function opener(kind, q)
    local found
    for j, t in ipairs(list) do
      if t.k == kind and t.q == q and not Engine.IsDone(j) then
        if j < i then found = j elseif not found then return j end
      end
    end
    return found
  end
  if st == "blocked" then return "pickup", opener("accept", s.q) end
  if s.k == "accept" and s.q and s.q > 0 then
    for _, p in ipairs(Engine.PrereqsOf(s.q)) do if not State.IsCompleted(p) then return "handin", opener("turnin", p) end end
  end
  return nil
end
function Engine.UpdateFocus(px, py, pinst)
  if Engine.view or not px then return end
  local planned = Engine.planned or Engine.current
  if not planned then return end
  local list = steps()
  State = State or ns.State
  -- standing at an NPC you can hand a finished quest to: that hand-in, now - wherever the plan has it (From the Ashes
  -- was step 282, out of the reorder's reach, with Captain Stoutfist right there) and over any other step the card
  -- holds (it kept Crocs of the Sky, 40 yd away). Not the planned step itself: that one is shown anyway
  do
    local best, bestD
    for j, s in ipairs(list) do
      if s.k == "turnin" and s.q and s.q > 0 and j ~= planned and State.QuestReady(s.q) then
        local d = distTo(s, px, py, pinst)
        if d and d <= (s.r or 6) + 12 and (not bestD or d < bestD) and Engine.Status(j) == "todo" then best, bestD = j, d end
      end
    end
    if best then
      if Engine.focus ~= best then setFocus(best, "it is ready to hand in and you are at the NPC", "ready") end
      return
    end
  end
  -- hold the current focus while it's open and you're still near it - or, when your kills / loot made it, while they
  -- keep counting (however far from its marker you farm)
  if Engine.focus then
    local s = list[Engine.focus]
    local d = s and distTo(s, px, py, pinst)
    if s and Engine.Status(Engine.focus) == "todo" then
      if not d or d <= (s.r or 40) + 80 then return end
      -- a finished quest's hand-in the card is taking you to: held while you head there (it was picked from up to
      -- READY_NEAR away), until it's handed in
      if Engine.focusWhy == "ready" and d <= Engine.READY_NEAR + 40 and State.QuestReady(s.q) then return end
      local at = Engine.focusWhy == "progress" and progressAt[key(Engine.focus)]
      if at and GetTime() - at <= Engine.PROGRESS_HOLD then return end
    end
    Engine.focus, Engine.focusWhy = nil, nil
  end
  local ps = list[planned]
  local dP = ps and distTo(ps, px, py, pinst)
  if dP and dP <= (ps.r or 40) + 10 then return end -- you're at the planned step: nothing to do
  -- farming the planned kill / loot step: its mobs roam well past the one marker the planner picked (Wetlands: the
  -- Pristine Crimson Scale crocs ran into the War Banners' circle, 100 yd off, and the card jumped there)
  if ps and ps.k == "obj" and dP and dP <= 2 * (ps.r or 40) + 80 then return end
  -- never past a step you are making progress on (its kills / loot counted in the last PROGRESS_HOLD seconds)
  local function busyBefore(j)
    for i = planned, j - 1 do local t = progressAt[key(i)]; if t and GetTime() - t <= Engine.PROGRESS_HOLD then return true end end
    return false
  end
  local inArea, near, nearD
  for _, j in ipairs(Engine.Upcoming(planned, WINDOW)) do
    local s = list[j]
    -- an NPC stop you're standing at (pick-up, hand-in, flight path) - not a kill / loot step: walking through a
    -- quest's circle doesn't mean you're doing it (the Wetlands' circles overlap everywhere, and the card kept
    -- jumping to War Banners); those take over when your kills or loot count for them (FR_STATE below)
    if Engine.Status(j) == "todo" and (s.k == "accept" or s.k == "turnin" or s.k == "fp") and Engine.Available(j) then
      local d = distTo(s, px, py, pinst)
      if d then
        if d <= (s.r or 40) and not inArea then inArea = j end
        if d < 120 and (not nearD or d < nearD) then near, nearD = j, d end
      end
    end
  end
  local pick = inArea
  if not pick and near and dP and dP > 200 and nearD < dP * 0.4 then pick = near end
  if pick and busyBefore(pick) then pick = nil end
  local why = inArea and "you are standing at it" or "it is right next to you and your planned step is far away"
  -- a quest already done (or a delivery, done as you take it) whose hand-in is right here, though the plan hands it
  -- in much later: hand it in while you're here, not on a trip back (Menethil: the plan sent you to one hand-in and
  -- walked past five finished ones it had for later)
  if not pick then
    State = State or ns.State
    local best, bestD
    -- (cheap checks first - this runs every second: a hand-in, its quest ready in your log, near you - then its status)
    for j = planned + 1, #list do
      local s = list[j]
      if s.k == "turnin" and s.q and s.q > 0 and State.QuestReady(s.q) then
        local d = distTo(s, px, py, pinst)
        if d and d <= Engine.READY_NEAR and (not dP or d < dP * 0.8) and (not bestD or d < bestD) and Engine.Status(j) == "todo" then best, bestD = j, d end
      end
    end
    if best then setFocus(best, "it is ready to hand in and it is close by (the plan has it later)", "ready"); return end
  end
  if pick then setFocus(pick, why) end
end

-- kills / loot counting for a later objective: that's what you're doing
ns.On("FR_STATE", function()
  local planned = Engine.planned or Engine.current
  if not planned or Engine.view then return end
  local list = steps()
  -- the planned step too: its loot counting means you're on it (UpdateFocus never jumps past it then), and if the card
  -- had moved on to another step, it comes back
  local js = Engine.Upcoming(planned, WINDOW); table.insert(js, 1, planned)
  for _, j in ipairs(js) do
    local s = list[j]
    if s and s.k == "obj" and not Engine.IsDone(j) then
      local o = Engine.ObjectiveFor(s)
      local k = key(j)
      if o and o.have then
        if lastHave[k] and o.have > lastHave[k] and not o.finished then
          progressAt[k] = GetTime()
          if j == planned then
            if Engine.focus and Engine.focus ~= planned then Engine.focus, Engine.focusWhy = nil, nil; Engine.Refresh() end
          elseif Engine.focus == j then Engine.focusWhy = "progress" -- shown for being here, now also counting: hold it as such
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
-- and only on the stop's continent. Hand-in spots: ForeverRouteEnders from the plan.
-- A gap is priced as a walk only when it is one. The straight-line detour d(a,X) + d(X,b) - d(a,b) means something
-- when you cover a -> b on the ground; when the way from a to b is a flight, a boat or your hearthstone (you are in
-- Southshore and the step is in Duskwood; a hand-in added in another zone), nothing between the two ends is "on the
-- way" - Thorium Point lies under the line from Southshore to Duskwood, and a level 30 was sent there for its flight
-- path as the very next step. Such a gap takes a stop only at one of its ends: there and back from where you leave
-- or from where you arrive, if the stop is ground travel from that end.
----------------------------------------------------------------------------------------------------------------
local function wd(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2) end
-- do you cover a -> b on the ground? The same zone: yes. Another zone: what the trip planner says (ns.Travel.Plan, the
-- one the card's travel line comes from) - rides only. A place whose zone is unknown: no.
local groundMemo = {}
function Engine.OnFoot(am, ax, ay, bm, bx, by)
  if not (am and bm) then return false end
  if am == bm then return true end
  if not (ax and ay and bx and by and ns.Travel and ns.Travel.Plan) then return false end
  local n = 0; for _ in pairs((ns.State and ns.State.knownTaxi) or {}) do n = n + 1 end
  local okB, bind = pcall(GetBindLocation)
  local k = table.concat({ am, math.floor(ax * 400), math.floor(ay * 400), bm, math.floor(bx * 400), math.floor(by * 400), n, UnitLevel("player") or 0, tostring(okB and bind) }, ":")
  local v = groundMemo[k]
  if v == nil then
    local ok, legs = pcall(ns.Travel.Plan, { m = am, x = ax, y = ay }, { m = bm, x = bx, y = by })
    v = ok and type(legs) == "table" and legs[1] ~= nil or false
    if v then for _, l in ipairs(legs) do if l.how ~= "ride" then v = false; break end end end
    groundMemo[k] = v
  end
  return v
end

function Engine.InsertStop(new, px, py, pinst, opts)
  opts = opts or {}
  local list = steps()
  local cur = Engine.current
  if not cur then return nil end
  local from = math.max(cur, opts.minIndex or cur)
  local X = wpos(new); if not X then return nil end
  -- gaps: (you -> current step) when you're on the same map, then each pair of neighbouring stops after it
  local best, bestCost
  local prev = nil -- the near end of the gap: { w = world position, m, x, y = its zone position }
  if px and pinst == X[3] and from == cur then local pm, zx, zy = ns.State.Position(); prev = { w = { px, py, pinst }, m = pm, x = zx, y = zy } end
  -- chained stops start after a given step: the gap right after it counts too
  if from > cur and list[from - 1] then local t = list[from - 1]; local w = wpos(t); if w and w[3] == X[3] then prev = { w = w, m = t.m, x = t.x, y = t.y } end end
  -- opts.onMap: only a gap with an end in that zone (straight lines say nothing across a zone border: mountains)
  local function touches(a, bm) return not opts.onMap or (a and a.m == opts.onMap) or bm == opts.onMap end
  -- what the stop costs in the gap a -> s (nil: this gap can't take it)
  local function gapCost(a, s, w)
    if not touches(a, s.m) then return nil end
    if Engine.OnFoot(a.m, a.x, a.y, s.m, s.x, s.y) then return wd(a.w, X) + wd(X, w) - wd(a.w, w) end
    local c
    if Engine.OnFoot(a.m, a.x, a.y, new.m, new.x, new.y) then c = 2 * wd(a.w, X) end
    if Engine.OnFoot(new.m, new.x, new.y, s.m, s.x, s.y) then local c2 = 2 * wd(X, w); if not c or c2 < c then c = c2 end end
    return c
  end
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
          if touches(ride, s.m) then
            local c = wd(ride.w, X) + wd(X, w) - wd(ride.w, w)
            if not bestCost or c < bestCost then bestCost, best = c, cur end -- before the travel step: on the way
          end
          ride = nil
        end
        -- never between two steps at the same NPC (turn in to Takar, accept from Takar): do both while you are there
        local split = list[i - 1] and list[i - 1].npc and list[i - 1].npc == s.npc
        if prev and not split then
          local c = gapCost(prev, s, w)
          if c and (not bestCost or c < bestCost) then bestCost, best = c, i end -- insert before step i
        end
        prev = { w = w, m = s.m, x = s.x, y = s.y }
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
  if ns.Why then ns.Why("insert", "added " .. (new.k or "") .. " " .. (new.name or (new.k == "fp" and ((new.zone or "?") .. " (" .. tostring(new.npc) .. ")")) or new.npc or "") .. " as step " .. best .. " (" .. (opts.why or "you finished it; this is where it costs least") .. ")") end
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
  -- flight paths you do not have, close to the trip (a small detour now saves trips later): only where the trip has
  -- you in the flight master's own zone, on a stretch you cover on the ground
  local have = {}; for _, s in ipairs(steps()) do if s.k == "fp" and s.m then have[s.m] = true end end
  for m, list in pairs(ns.FLIGHT or {}) do
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(m)
    local zn = info and info.name
    if zn and not have[m] and not Engine.KnowsFlightIn(zn) then
      local f = list[1]
      local at = Engine.InsertStop({ k = "fp", npc = f[3], m = m, x = f[1], y = f[2], zone = zn, r = 8, inserted = true, note = "A flight path you do not have yet - saves trips later." }, px, py, pinst, { maxCost = Engine.FP_DETOUR_YARDS, onMap = m, why = "a flight path close to this trip" })
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
  -- (a hand-in behind you in the built-in plan is not on the route: Engine.BehindYou)
  local behind = {}
  for _, s in ipairs(list) do if s.k == "turnin" and s.q then if Engine.BehindYou(s) then behind[s.q] = true else have[s.q] = true end end end
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
      local opts = gray and { maxCost = Engine.GRAY_DETOUR_YD, why = "gray, but right on the way" }
        or (behind[q] and { maxCost = Engine.MERGE_PATH_YARDS, why = "its hand-in is behind you in the plan, and the route passes by" }) or nil
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
  if e and e.name then return e.name end
  local t = C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(q)
  return t or ("quest " .. q)
end
Engine.QuestName = questName
-- the quests you said you won't do: { q, name, ready }, by name (the quest log check lists them, each with Bring back)
function Engine.Noped()
  local out = {}
  for q, how in pairs((ns.char and ns.char.nope) or {}) do out[#out + 1] = { q = q, name = questName(q), ready = how == "ready" } end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end
-- changed your mind: the quest is back on your route (its steps show again; the next replan plans it)
function Engine.Unnope(q)
  if not (q and ns.char and ns.char.nope and ns.char.nope[q]) then return end
  ns.char.nope[q] = nil
  if ns.Why then ns.Why("abandon", questName(q) .. ": you brought it back; on your route again") end
  Engine.Refresh()
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
  -- "ready": it was already finished when you dropped it (a hand-in you chose to skip) - it stays dropped (FR_STATE below)
  State = State or ns.State
  for _, q in ipairs(qs) do ns.char.nope[q] = State.QuestReady(q) and "ready" or true end
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
  State = State or ns.State
  for _, q in ipairs(qs) do ns.char.nope[q] = State.QuestReady(q) and "ready" or true; if ns.Why then ns.Why("abandon", questName(q) .. ": abandoned from the quest log check (" .. (why or "not worth doing") .. "); dropped from the route") end end
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
-- and so does finishing one you said you wouldn't do, while it was in your log all along (From the Ashes: marked
-- "not doing", then done anyway - no pick-up to notice, and its hand-in stayed off the route)
ns.On("FR_STATE", function()
  if not (ns.char and ns.char.nope and next(ns.char.nope)) then return end
  State = State or ns.State
  local back = false
  for q, how in pairs(ns.char.nope) do
    if how == true and State.OnQuest(q) and State.QuestReady(q) then
      ns.char.nope[q] = nil; back = true
      if ns.Why then ns.Why("abandon", questName(q) .. ": you finished it after all; its hand-in is back on your route") end
    end
  end
  if back then Engine.Refresh() end
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
