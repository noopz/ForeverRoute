-- What to do next, decided by the live solver (Horizon.lua) over the stops that could come next. The plan scan
-- (Engine.Compute) still says which steps are done, waiting or out; this picks, among the next ones you can do and the
-- finished quests whose hand-in is near, the one that makes the whole way from here shortest - and says why when it
-- isn't the plan's next step. It replaces the old reordering rules ("you are standing at it", "ready close by"), each
-- with its own radius: they're all one question here, answered in seconds.
--
-- WoW's interruptions need no rules of their own: you went off to group for a dungeon, or back to town because your bags
-- were full - the solve starts from where you are, the hand-ins in that town are a few seconds away (done now: "while
-- you're here"), and the plan's next stops pull you back to the route after.
local _, ns = ...
local Next = {}
ns.Next = Next
local HBD = LibStub("HereBeDragons-2.0")

Next.WINDOW = 14        -- planned stops the solve looks at
Next.SCAN = 90          -- steps scanned for them
Next.NEAR_READY = 500   -- yards: finished quests further than this are left to the plan
Next.MARGIN = 40        -- seconds: a new pick must beat keeping the current one by this much (no flip-flopping)
Next.CARRY = 30         -- seconds: what carrying a finished quest costs (a log slot, the risk it goes gray)
Next.BEHIND_YD = 2000   -- yards: a pick-up the built-in plan passed as behind you, this close and still worth XP, is offered
Next.BEHIND_MAX = 6     -- ...the nearest this many
Next.HOLD_NEAR = 400    -- yards: a prize this close can come before the plan's trip or grind step
Next.BEHIND_WORK = 150  -- seconds: the work one of its objectives is taken to be (and the way to it)
Next.RESOLVE = 2        -- seconds: re-solve at least this often while things change
Next.SERVICE = { accept = 8, turnin = 10, obj = 90, fp = 15, train = 40, bind = 15, ["goto"] = 5 }
-- (a "go to" step - a dungeon run, a place to be - is a commitment, not a stop to fit in: it stays where the plan has it)
Next.KIND = { accept = true, turnin = true, obj = true, fp = true, train = true, bind = true }
Next.TRIP = { fly = true, hearth = true, boat = true }
-- what a vendor visit is worth by free bag slots (seconds): at 0 every kill's loot is lost
Next.BAG_PRIZE = { [0] = 900, [1] = 500, [2] = 300, [3] = 200, [4] = 120, [5] = 80, [6] = 50 }
Next.REPAIR_AT = 0.35 -- gear durability below this: a repairer is worth a stop too

function Next.Enabled() return ns.db and ns.db.smartNext ~= false end

local worldOf = setmetatable({}, { __mode = "k" })
local function wpos(s)
  if not (s and s.m and s.x and s.y) or s.unknown then return nil end
  local w = worldOf[s]
  if w == nil then local x, y, inst = HBD:GetWorldCoordinatesFromZone(s.x, s.y, s.m); w = x and { x, y, inst } or false; worldOf[s] = w end
  return w or nil
end
Next._wpos = wpos

-- seconds from place a to place b ({ w = {x, y, inst}, m, x, y }): a straight line at your speed with a little extra for
-- the way round things; far or across the sea, the trip planner's own estimate (flights, boats, your hearthstone)
-- A far leg's time comes from the trip planner (Travel.Plan, a search over flights, boats, rides: ~30 ms), so it is asked
-- once per place you set out from and ZONE you go to - the trip to the first stop in that zone - and any other stop in the
-- same zone adds its straight-line distance from that one. Asked for every far stop on every refresh, it was 90% of the
-- addon's time (34,000 searches in one simulated 1-60, ten times slower than before). "From" is a step of the plan, or
-- where you stand to the nearest 250 yd. Remembered until you learn a flight path.
local zoneMemo, zoneTaxi, startKeys = setmetatable({}, { __mode = "k" }), nil, 0
local function travelSecs(a, b)
  local wa, wb = a.w, b.w
  if not (wa and wb) then return 600 end
  local speed = (ns.Travel and ns.Travel.Speed and ns.Travel.Speed()) or 7
  local function straight(p, q) return math.sqrt((p[1] - q[1]) ^ 2 + (p[2] - q[2]) ^ 2) * 1.25 / speed end
  -- (the same zone, or near: the walk. Within a zone the trip planner nearly always says "walk" too - asked for every
  -- far stop in a big zone it was 1,500 of 1,650 searches in a simulated 600 steps; a flight across one zone is the
  -- card's own shortcut check, Travel.Shortcut)
  if wa[3] == wb[3] then
    local yd = math.sqrt((wa[1] - wb[1]) ^ 2 + (wa[2] - wb[2]) ^ 2)
    if yd < 900 or (a.m and a.m == b.m) or not (ns.Travel and ns.Travel.Plan) then return yd * 1.25 / speed end
  end
  local n = 0; for _ in pairs((ns.State and ns.State.knownTaxi) or {}) do n = n + 1 end
  if zoneTaxi ~= n then zoneMemo = setmetatable({}, { __mode = "k" }); zoneTaxi, startKeys = n, 0 end
  local from = a.st or ("at:" .. math.floor(wa[1] / 250) .. ":" .. math.floor(wa[2] / 250) .. ":" .. tostring(wa[3]))
  -- (another zone: one trip per zone, plus the walk from its first stop; the same zone: each far stop on its own - a
  -- remembered stop on the far side of a big zone would make a nearer one look as far as that, and then some)
  local to = (a.m and b.m and a.m ~= b.m) and b.m or b.st or b
  local row = zoneMemo[from]
  local e = row and row[to]
  if e then return e.secs + ((to == b.m and e.w[3] == wb[3]) and straight(e.w, wb) or 0) end
  local v = 1800 -- (no way known: as good as unreachable for a window)
  if ns.Travel and ns.Travel.Plan and a.m and b.m then
    local ok, legs, secs = pcall(ns.Travel.Plan, { m = a.m, x = a.x, y = a.y }, { m = b.m, x = b.x, y = b.y })
    if ok and legs and secs then v = secs end
  end
  do
    if not row then
      -- (places you stood at are kept up to 400, then forgotten: steps are kept as long as the plan is)
      if not a.st then startKeys = startKeys + 1; if startKeys > 400 then zoneMemo = setmetatable({}, { __mode = "k" }); startKeys = 0 end end
      row = {}; zoneMemo[from] = row
    end
    row[to] = { secs = v, w = wb }
  end
  return v
end
Next._travel = travelSecs

-- your XP per second: what an hour of levelling at your level makes (a level about every 1.5 h around the middle)
local function rate()
  local need = (UnitXPMax and UnitXPMax("player")) or 10000
  return math.max(1, need / 5400)
end

-- what coming back for a finished quest later costs, in seconds: the hand-in, carrying it, and the detour from the
-- plan's own way to its NPC (none when the plan stops there anyway)
local function laterCost(list, j)
  local s = list[j]
  local w = wpos(s)
  local cost = (Next.SERVICE.turnin or 10) + Next.CARRY
  if not w then return cost end
  local prev, nxt
  for k = j - 1, math.max(1, j - 30), -1 do if wpos(list[k]) then prev = list[k]; break end end
  for k = j + 1, math.min(#list, j + 30) do if wpos(list[k]) then nxt = list[k]; break end end
  local function d(a, b) local A, B = wpos(a), wpos(b); if not (A and B) or A[3] ~= B[3] then return nil end return math.sqrt((A[1] - B[1]) ^ 2 + (A[2] - B[2]) ^ 2) end
  local dp, dn, pn = prev and d(prev, s), nxt and d(s, nxt), prev and nxt and d(prev, nxt)
  if dp and dn and pn then
    local speed = (ns.Travel and ns.Travel.Speed and ns.Travel.Speed()) or 7
    cost = cost + math.max(0, dp + dn - pn) * 1.25 / speed
  end
  return cost
end
Next._laterCost = laterCost

-- A hub: a place the plan stops at a lot (a town) - Next.HUB_STEPS steps within Next.HUB_YD of it. Hand-ins there are
-- welcome any time; out in the field one is only taken early when its chain goes on right there. The rest wait for the
-- plan's visit to the hub: questing a long while in a good order and then handing in a pile at once, the XP bar
-- climbing and climbing, is the loop WoW is built around - the guide sets it up rather than chipping it away.
Next.HUB_YD, Next.HUB_STEPS, Next.CHAIN_YD = 70, 4, 150
local hubMemo = setmetatable({}, { __mode = "k" })
local function isHub(list, s)
  local m = hubMemo[s]
  if m ~= nil and m.list == list then return m.hub end
  local w, n = wpos(s), 0
  if w then
    for _, t in ipairs(list) do
      local tw = wpos(t)
      if tw and tw[3] == w[3] and (tw[1] - w[1]) ^ 2 + (tw[2] - w[2]) ^ 2 <= Next.HUB_YD ^ 2 then n = n + 1; if n >= Next.HUB_STEPS then break end end
    end
  end
  hubMemo[s] = { list = list, hub = n >= Next.HUB_STEPS }
  return n >= Next.HUB_STEPS
end
Next._isHub = isHub
-- does handing this in open a quest whose pick-up is right there (the chain goes on: hand in, take the next)?
local acceptIdx = setmetatable({}, { __mode = "k" })
local function chainsOnHere(list, s)
  local deps = s.q and ForeverRouteUnlocks and ForeverRouteUnlocks[s.q]
  local w = wpos(s)
  if not (deps and w) then return false end
  local idx = acceptIdx[list]
  if not idx then idx = {}; for _, t in ipairs(list) do if t.k == "accept" and t.q and not idx[t.q] then idx[t.q] = t end end; acceptIdx[list] = idx end
  for _, d in ipairs(deps) do
    local a = idx[d]
    local aw = a and wpos(a)
    if aw and aw[3] == w[3] and (aw[1] - w[1]) ^ 2 + (aw[2] - w[2]) ^ 2 <= Next.CHAIN_YD ^ 2 then return true end
  end
  return false
end
Next._chainsOnHere = chainsOnHere

-- what a quest you'd take up again is worth, in seconds: its XP at your rate, less its likely work (Next.BEHIND_WORK a
-- plan objective step). Shared with tools/replay.js's "leaves work" check, so the check and the pick can't disagree.
local objCount = setmetatable({}, { __mode = "k" })
function Next.BehindPrize(list, s, L)
  local E = ns.Engine
  if not (E.QuestXP and s and s.q and tonumber(s.level)) then return 0 end
  local c = objCount[list]
  if not c then c = {}; for _, t in ipairs(list) do if t.k == "obj" and t.q then c[t.q] = (c[t.q] or 0) + 1 end end; objCount[list] = c end
  return E.QuestXP(s.level, L) / rate() - Next.BEHIND_WORK * (c[s.q] or 1)
end

local last -- { sig, at, pick, res }
-- -> the step index to show, or nil (the plan's own next step stands)
function Next.Pick(planned)
  local E, St = ns.Engine, ns.State
  local list = ForeverRouteData and ForeverRouteData.steps
  if not (Next.Enabled() and planned and list and list[planned] and ns.Horizon) then Next.res = nil; return nil end
  local d = ForeverRouteData
  if d.dungeon or d.special then Next.res = nil; return nil end
  -- on the way somewhere (the plan's next step is the trip: Fly to Wetlands), the trip is the step - the card says where
  -- you're going - unless something close by is worth doing first (a quest still worth XP right here, a hand-in in
  -- this town): the solve runs over the stops past the trip and those, and only such a prize takes the card
  local onTrip = Next.TRIP[list[planned].k]
  local holdPlanned = onTrip -- (the plan's step stays on the card unless a prize close by comes first)
  local holdAt = onTrip and planned or nil -- (the step that stays: the trip, or a grind / note the window stopped at)
  -- where you are: the position the once-a-second check measured, when it's fresh; else ask
  local px, py, pinst
  local ep = E.pos
  if ep and GetTime and GetTime() - (ep[4] or 0) < 3 then px, py, pinst = ep[1], ep[2], ep[3] else px, py, pinst = HBD:GetPlayerWorldPosition() end
  if not px then return nil end
  local load = (St.LogCount and St.LogCount()) or 0
  local cap = (St.MaxLog and St.MaxLog()) or 25
  local roomInLog = load < cap -- (a full log: no pick-up is a candidate at all)
  local here = ns.State.Position and { ns.State.Position() } or {}
  local bags = ns.Errands and ns.Errands.FreeSlots and ns.Errands.FreeSlots() or -1
  local sig = table.concat({ planned, #list, load, math.floor(px / 15), math.floor(py / 15), pinst or 0, tostring(d), math.min(bags, 7) }, ":")
  local now = GetTime and GetTime() or 0
  if last and last.sig == sig and now - last.at < Next.RESOLVE and last.pick and list[last.pick] and E.Status(last.pick) == "todo" then return last.pick end

  local stops, byStep, count, scanEnd = {}, {}, 0, planned
  local function add(j, extra)
    local s = list[j]
    local w = wpos(s)
    -- (an objective takes what the planner expects it to - s.work, its kills and drops at their rates; the flat guess
    -- only for a plan made before steps carried it)
    local service = (s.k == "obj" and tonumber(s.work)) or Next.SERVICE[s.k] or 15
    local stop = { id = j, step = j, st = s, w = w, m = s.m, x = s.x, y = s.y, service = service,
      load = (s.k == "accept" and 1) or (s.k == "turnin" and -1) or 0 }
    for k, v in pairs(extra or {}) do stop[k] = v end
    stops[#stops + 1] = stop; byStep[j] = stop
    return stop
  end
  -- the plan's next stops you can do now (a step that isn't a place - grind to a level, a note - ends the window there:
  -- it is done where it stands in the plan)
  for j = planned, math.min(#list, planned + Next.SCAN) do
    local s = list[j]
    local st = E.Status(j)
    scanEnd = j
    if st == "todo" then
      -- (a pick-up whose earlier chain quest isn't handed in is not offered yet: Chef Grual has nothing until Jitters'
      -- Growling Gut is in - it waits where the plan has it)
      if Next.KIND[s.k] and wpos(s) and (s.k ~= "accept" or ((not E.Available or E.Available(j)) and roomInLog)) then
        -- an off-plan stop the route only took in (a finished quest's hand-in, a side quest's objective): a prize, not a
        -- must - worth what its XP would take you to earn, or the trip back for it later
        if s.inserted then
          -- (a hand-in whose NPC the plan comes back to - a capital, a hub - waits for that visit like any other: worth only
          -- the trip back it saves. One the plan never passes again is worth its XP: left, it would be lost. Ironforge
          -- from the Burning Steppes for one hand-in was the first kind valued as the second)
          -- (what it pays at YOUR level: a gray quest's hand-in is worth next to nothing, however much it paid once)
          local Lnow = (UnitLevel and UnitLevel("player")) or 1
          local xp = (E.QuestXP and tonumber(s.level)) and E.QuestXP(s.level, Lnow) or tonumber(s.xp) or ((UnitXPMax and UnitXPMax("player") or 10000) * 0.04)
          local passesLater = s.k == "turnin" and isHub(list, s)
          add(j, { prize = (s.k == "turnin" and not passesLater) and (xp / rate()) or laterCost(list, j), opt = true })
        else
          add(j, { plan = j })
          count = count + 1
        end
        if count >= Next.WINDOW then break end
      elseif Next.TRIP[s.k] then
        if count == 0 and not holdAt then holdAt = j end -- (the trip comes before any stop: it's what's next)
      else
        -- (a grind, a note, a dungeon run - a step with no place first: it stays the plan's step, unless a prize close by
        -- is worth doing before it - a quest worth XP right here beats grinding)
        if count == 0 then holdPlanned = true; holdAt = holdAt or j end
        break
      end
    end
  end
  -- quests the built-in plan passed as behind you (you joined it further on) that are right here and still worth XP at
  -- your level: a pick-up worth its XP at your rate, less its likely work - the solve takes it when that beats the plan's
  -- way on. Taken, the quest is yours, and its objectives and hand-in come back to the route by themselves (a quest in
  -- your log is never behind you). A level 40 standing at Indurium (level 39) was sent away: the plan does it at 38.
  if E.BehindYou and E.QuestXP then
    local L = (UnitLevel and UnitLevel("player")) or 1
    -- (the nearest Next.BEHIND_MAX of them within Next.BEHIND_YD: the solve weighs the way there against what they pay)
    local found = {}
    for j = 1, #list do
      local s = list[j]
      if roomInLog and s.k == "accept" and s.q and tonumber(s.level) and s.level >= L - 4 and s.level <= L + 2 and not byStep[j] then
        local w = wpos(s)
        local d2 = w and w[3] == pinst and (w[1] - px) ^ 2 + (w[2] - py) ^ 2
        if d2 and d2 <= Next.BEHIND_YD ^ 2 and not St.OnQuest(s.q) and not St.IsCompleted(s.q)
          and E.BehindYou(s) and (not E.Available or E.Available(j)) and not (ns.char and ns.char.nope and ns.char.nope[s.q]) then
          local prize = Next.BehindPrize(list, s, L)
          if prize > 0 then found[#found + 1] = { j = j, d2 = d2, prize = prize } end
        end
      end
    end
    table.sort(found, function(a, b) return a.d2 < b.d2 end)
    for k = 1, math.min(Next.BEHIND_MAX, #found) do add(found[k].j, { prize = found[k].prize, opt = true, behind = true }) end
  end
  -- finished quests whose hand-in is further on in the plan but near you now: a prize worth the trip back it saves
  for j = scanEnd + 1, #list do
    local s = list[j]
    if s.k == "turnin" and s.q and St.QuestReady(s.q) and not byStep[j] then
      local w = wpos(s)
      -- (and still worth XP: a gray quest's hand-in is no prize - it goes with the plan, or not at all)
      local Lp = (UnitLevel and UnitLevel("player")) or 1
      local worthXP = not (E.QuestXP and tonumber(s.level)) or E.QuestXP(s.level, Lp) >= 0.3 * E.QuestXP(s.level, s.level)
      if w and w[3] == pinst and (w[1] - px) ^ 2 + (w[2] - py) ^ 2 <= Next.NEAR_READY ^ 2 and E.Status(j) == "todo" and worthXP
        and (isHub(list, s) or chainsOnHere(list, s)) then
        add(j, { prize = laterCost(list, j), opt = true, early = true, chain = not isHub(list, s) or nil })
      end
    end
  end
  -- your bags filling up (or gear wearing out): the vendors of this map as prizes, worth more the closer you are to
  -- looting nothing - the solve fits the visit in where it costs least (a town you pass anyway), and the card's errand
  -- line says which vendor and when (Errands.lua)
  Next.vendor = nil
  local E2 = ns.Errands
  local free = E2 and E2.FreeSlots and E2.FreeSlots()
  local dur = E2 and E2.Durability and E2.Durability()
  local bagPrize = free and Next.BAG_PRIZE[math.max(0, free)] or 0
  local repairPrize = (dur and dur < Next.REPAIR_AT) and (120 + 600 * (Next.REPAIR_AT - dur) / Next.REPAIR_AT) or 0
  local vm = here and here[1]
  if (bagPrize > 0 or repairPrize > 0) and vm and ns.VENDORS and ns.VENDORS[vm] then
    local near = {}
    for vi, v in ipairs(ns.VENDORS[vm]) do
      local vx, vy, vinst = HBD:GetWorldCoordinatesFromZone(v[1], v[2], vm)
      if vx and vinst == pinst then near[#near + 1] = { vi = vi, v = v, d = (vx - px) ^ 2 + (vy - py) ^ 2, w = { vx, vy, vinst } } end
    end
    table.sort(near, function(a, b) return a.d < b.d end)
    for k = 1, math.min(3, #near) do
      local n = near[k]
      local prize = bagPrize + (n.v[5] and repairPrize or 0)
      if prize > 0 then
        stops[#stops + 1] = { id = "vendor" .. n.vi, vendor = n.v, w = n.w, m = vm, x = n.v[1], y = n.v[2], service = 25, load = 0, prize = prize, opt = true }
      end
    end
  end
  -- pick-up before objectives before hand-in, among the stops in the window
  local acceptOf, objsOf = {}, {}
  for _, st in ipairs(stops) do
    local s = st.step and list[st.step] -- (a vendor is no step of the plan)
    if s and s.q then
      if s.k == "accept" then acceptOf[s.q] = st.id
      elseif s.k == "obj" then objsOf[s.q] = objsOf[s.q] or {}; table.insert(objsOf[s.q], st.id) end
    end
  end
  for _, st in ipairs(stops) do
    local s = st.step and list[st.step]
    if s and s.q and (s.k == "obj" or s.k == "turnin") then
      local needs = {}
      if acceptOf[s.q] then needs[#needs + 1] = acceptOf[s.q] end
      if s.k == "turnin" then for _, o in ipairs(objsOf[s.q] or {}) do needs[#needs + 1] = o end end
      st.needs = needs
    end
  end
  -- the plan's first stop past the window: where the window leads on to
  local anchor
  for j = scanEnd + 1, math.min(#list, scanEnd + 40) do
    local w = wpos(list[j])
    if w and E.Status(j) ~= "done" then local s = list[j]; anchor = { w = w, st = s, m = s.m, x = s.x, y = s.y }; break end
  end
  local start = { w = { px, py, pinst }, m = here[1], x = here[2], y = here[3] }
  -- the plan's own step stands - unless it's a stop the route only took in (the solve didn't think it worth it) or isn't
  -- one you can do now (a hand-in not finished yet): then the step that holds (the trip, the grind), or the plan's next
  -- one you can do
  local function keepPlanned()
    -- (a hand-in you can't do yet stays: the card says what it needs - "Not finished" with the objective bars)
    if list[planned].inserted then
      local alt = holdAt
      if not alt then for j = planned + 1, math.min(#list, planned + Next.SCAN) do if not list[j].inserted and E.Status(j) == "todo" then alt = j; break end end end
      return alt
    end
    return nil
  end
  if #stops == 0 then Next.res = nil; return keepPlanned() end
  local P = { start = start, stops = stops, anchor = anchor, travel = travelSecs, load = load,
    cap = (C_QuestLog and C_QuestLog.GetMaxNumQuestsCanAccept and C_QuestLog.GetMaxNumQuestsCanAccept()) or 25 }
  P.cap = cap
  Next.lastP, Next.lastBy, Next.whyNotMemo = P, byStep, {} -- (for Next.WhyNot: "why not that step?")
  local res = ns.Horizon.Solve(P)
  -- (a vendor isn't a step of the plan: the card shows the plan's next step and its errand line says the vendor - now,
  -- or after the stops before it)
  local function firstStep(r)
    local first, fs
    for k, s in ipairs(r.seq or {}) do
      if s.vendor and not Next.vendor then Next.vendor = { v = s.vendor, before = k - 1 } end
      if s.step and not first then first, fs = s.step, s end
    end
    return first, fs
  end
  local pick, pst = firstStep(res)
  if pst then res.first = pst end
  -- the plan's next step is a trip: it stays on the card unless the pick is a prize close by (worth doing before you go)
  -- (a prize comes before the trip or grind only when it is close by: where you stand, Next.HOLD_NEAR)
  local closePrize = pst and pst.opt and pst.w and pst.w[3] == pinst and (pst.w[1] - px) ^ 2 + (pst.w[2] - py) ^ 2 <= Next.HOLD_NEAR ^ 2
  if (holdPlanned or count == 0) and not closePrize then
    local opts = 0
    for _, st in ipairs(stops) do if st.opt then opts = opts + 1 end end
    if opts > 0 and ns.Why then ns.Why("next", "kept the plan's step " .. planned .. ": " .. opts .. " stop(s) close by weighed, none worth doing before it") end
    Next.res = res; last = { sig = sig, at = now, res = res }
    return keepPlanned()
  end
  -- hysteresis: the step on the card stays unless the new pick beats keeping it by Next.MARGIN seconds
  -- (not for a stop you're passing anyway - a finished quest's hand-in right here: that one is said at once, an interrupt
  -- on the way, not a change of course)
  local passing = res.first and res.first.opt
  local keep = not passing and last and last.pick and byStep[last.pick] and last.pick ~= pick and list[last.pick]
  if keep then
    P.first = last.pick
    local kept = ns.Horizon.Solve(P)
    if kept.first and res.score - kept.score < Next.MARGIN then Next.vendor = nil; local kp, kst = firstStep(kept); if kst then kept.first = kst end; res, pick = kept, kp or last.pick end
  end
  Next.res = res
  last = { sig = sig, at = now, pick = pick, res = res }
  if pick and pick ~= planned and ns.Why then
    local s = list[pick]
    ns.Why("next", "step " .. pick .. " (" .. tostring(s.name or s.k) .. ") before the plan's step " .. planned .. ": " .. Next.Reason(pick))
  end
  -- a quest the plan passed as behind you, picked up again here: it's on your route now (Engine.BehindYou)
  Next.taken = (pick and byStep[pick] and byStep[pick].behind) and list[pick] or nil
  return pick
end

-- why a step picked out of plan order, in words
function Next.Reason(i)
  local res = Next.res
  local st
  for _, s in ipairs((res and res.seq) or {}) do if s.step == i then st = s; break end end
  if not st then return "" end
  if st.behind then return "right here and still worth XP at your level (the plan has it earlier)" end
  if st.early and st.chain then return "the chain goes on right here - hand it in and take the next" end
  if st.early then return "while you're here - it saves coming back for it later" end
  if st.opt then return "a quest you picked up on the way, handed in where it costs least" end
  return "on the way - the whole route from here is shorter this way"
end

-- the finished quests left for later (the card's "later" line): their names
function Next.Deferred()
  local out = {}
  for _, s in ipairs((Next.res and Next.res.skipped) or {}) do
    local st = ForeverRouteData and ForeverRouteData.steps and ForeverRouteData.steps[s.step]
    if st and st.k == "turnin" and st.name then out[#out + 1] = st.name end
  end
  return out
end

-- the hand-in run at a hub: the finished quests you can hand in where this step is (Next.HUB_YD) - how many, and about
-- how much XP. The card says it when there are a few: the big moment of the loop, worth naming.
-- -> { n, xp } or nil
function Next.Batch(i)
  local list = ForeverRouteData and ForeverRouteData.steps
  local s = list and list[i]
  local w = s and wpos(s)
  if not (w and s.k == "turnin") then return nil end
  local E, St = ns.Engine, ns.State
  local L = (UnitLevel and UnitLevel("player")) or 1
  local n, xp, seen = 0, 0, {}
  for j, t in ipairs(list) do
    if t.k == "turnin" and t.q and not seen[t.q] and St.QuestReady(t.q) then
      local tw = wpos(t)
      if tw and tw[3] == w[3] and (tw[1] - w[1]) ^ 2 + (tw[2] - w[2]) ^ 2 <= Next.HUB_YD ^ 2 and E.Status(j) == "todo" then
        seen[t.q] = true
        n = n + 1
        xp = xp + ((E.QuestXP and tonumber(t.level)) and E.QuestXP(t.level, L) or 0)
      end
    end
  end
  if n < 3 then return nil end
  return { n = n, xp = math.floor(xp / 50 + 0.5) * 50 }
end

-- "Why not that step next?" - contrastive, the way people ask: the last solve's window scored again with that step
-- forced first, against the best. -> a line for the route list's tooltip, or nil (not in the window the solve looked at)
function Next.WhyNot(i)
  local P, by, res = Next.lastP, Next.lastBy, Next.res
  if not (P and by and res and by[i] and ns.Horizon) then return nil end
  if res.first and res.first.step == i then return "The best next step from where you are." end
  local memo = Next.whyNotMemo or {}
  local v = memo[i]
  if v == nil then
    local was = P.first
    P.first = i
    local forced = ns.Horizon.Solve(P)
    P.first = was
    v = (forced.first and forced.score > -math.huge) and math.max(0, res.score - forced.score) or false
    memo[i] = v
  end
  if v == false then return "Can't come next: something before it has to be done first (or your log is full)." end
  local min = math.floor(v / 60 + 0.5)
  if min < 1 then return "Next instead: about the same - less than a minute in it." end
  return string.format("Next instead: about %d min longer on the way from here.", min)
end
