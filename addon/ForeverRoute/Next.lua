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
Next.NEAR_READY = 500   -- yards: finished quests further than this are left to the plan (a bound on the candidates: Next.Prize decides)
Next.MARGIN = 40        -- seconds: a new pick must beat keeping the current one by this much (no flip-flopping)
Next.CARRY = 30         -- seconds: what carrying a finished quest costs (a log slot, the risk it goes gray)
Next.BEHIND_YD = 2000   -- yards: a pick-up the built-in plan passed as behind you, this close, is a candidate (Next.Prize decides)
Next.BEHIND_MAX = 6     -- ...the nearest this many
Next.HOLD_NEAR = 400    -- yards: a prize this close can come before the plan's trip or grind step
Next.BEHIND_WORK = 150  -- seconds: an objective's work and the way to it, for a step that doesn't carry the planner's (s.work)
Next.DISMISS_SECS = 900 -- "not now" on a while-you're-here stop: it stays off for this long...
Next.DISMISS_YD = 500    -- ...or until you are this far from where you said it
Next.dismissed = {}      -- step index -> { t, x, y, inst }: where and when
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
-- where you stand to the nearest 250 yd. Remembered until you learn a flight path, mount up or level (priceSig).
local function speedNow() return (ns.Travel and ns.Travel.Speed and ns.Travel.Speed()) or 7 end
local function knownTaxiCount() local n = 0; for _, _ in pairs((ns.State and ns.State.knownTaxi) or {}) do n = n + 1 end; return n end
-- what a remembered trip or price depends on besides the plan: the flight paths you know, your speed (a mount at 40)
-- and your level (the trip planner keeps you out of zones far above you). Taken once a solve (Next.Pick) - not by
-- walking your flight paths on every price; outside a solve, each time.
local sigNow
local function priceSig()
  return sigNow or (knownTaxiCount() .. ":" .. speedNow() .. ":" .. ((UnitLevel and UnitLevel("player")) or 1))
end
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
  local n = priceSig()
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

-- ---------------------------------------------------------------------------------------------------------------
-- Now or later: one price for every stop the solve may take out of the plan's order (a finished quest's hand-in the
-- plan has further on, a stop the route took in, a quest behind you, a later visit to where you are):
--   prize = the least of what it pays (its quest's XP at your rate, less the work still between you and that XP) and
--           what leaving it for later costs (Next.DeferCost: the plan comes back for it - the stop itself, carrying the
--           quest, and the detour from the plan's own way to it there).
-- A stop the plan comes back to is worth that detour and no more: never "all the way to Ironforge from the Burning
-- Steppes for one hand-in". One it never comes back to is worth its XP: left, it is lost. A gray quest pays a little
-- either way (Engine.QuestXP). Earlier each of these had a formula of its own (a hub test for "the plan passes
-- again", 30% of the XP for "still worth it", 150 s an objective), and the detour was a straight line between the
-- step's two plan neighbours: riding speed across a zone the plan flies over, and nothing at all when a neighbour was
-- in another instance.
-- The detour here is the plan's real way: within a zone the walk (as the solve prices it, travelSecs); where the plan
-- flies, sails or rides across zones (Travel.Plan, without your hearthstone) the walks at each end of that trip - to
-- the flight master or the plan's own pier, and from where you land; and across one of the plan's hearths, the walk
-- before it (you hearth from wherever you are) and the walk from the inn it bound you at. Thorium Point lies under
-- the straight line from Southshore to Duskwood; the trip does not pass it (de03647: the same fix for
-- Engine.InsertStop's gaps, in yards).
-- A later pass counts only where the solve would offer the stop then: a hand-in at a hub or where its chain goes on,
-- within Next.NEAR_READY of the way (Next.Pick's rule). Any other stop is done at its own place in the plan or not at
-- all - a pass through open country beside it is no second chance.
-- None of it depends on where you stand, only on the plan, the flight paths you know, your speed and level: a prize
-- that moved as you walked would flip the card (prizes skip the hysteresis, Next.MARGIN).
-- ---------------------------------------------------------------------------------------------------------------
Next.DEFER_CELL = 400   -- yards: the grid the plan's way is indexed by
Next.DEFER_ENOUGH = 60  -- seconds: a gap this cheap found among the walks - the far trips needn't be asked
Next.DEFER_FAR = 3      -- trip-planner searches one stop's price may start (the soonest far gaps; remembered ones are free)
-- trip-planner searches (~30 ms each) all the prices of one solve may start: learning a flight path forgets every
-- remembered trip, and fifteen candidates asking four each was a frame of 1-2 s. A price still missing a search is
-- asked again on the next solve, and meanwhile taken as "the plan comes by" - a stop is never sent for on a guess.
Next.ASK_PER_PICK = 4
local huge = math.huge
local function yd(p, q) return math.sqrt((p[1] - q[1]) ^ 2 + (p[2] - q[2]) ^ 2) end
-- the detour (seconds) of stopping at p on the walk x -> y, and how near that walk comes to p (yards); nil when they
-- aren't in one world
local function segDetour(x, y, p)
  if not (x and y and p) or x[3] ~= p[3] or y[3] ~= p[3] then return nil end
  local dx, dy = y[1] - x[1], y[2] - x[2]
  local l2 = dx * dx + dy * dy
  local t = l2 > 0 and math.max(0, math.min(1, ((p[1] - x[1]) * dx + (p[2] - x[2]) * dy) / l2)) or 0
  return math.max(0, yd(x, p) + yd(p, y) - yd(x, y)) * 1.25 / speedNow(), yd(p, { x[1] + dx * t, x[2] + dy * t })
end
-- the searches left in this solve (nil: no bound - outside a solve): true takes one
local askLeft
local function mayAsk()
  if askLeft == nil then return true end
  if askLeft <= 0 then return false end
  askLeft = askLeft - 1
  return true
end
Next._askLeft = function(n) askLeft = n end -- (tests: a solve's bound, outside one)
-- The plan's trip between two of its stops (step tables) that are far apart: its seconds, and the walk at each end -
-- D, where it leaves the walk (the flight master, the pier), and P, where it comes back to it (where you land); or
-- ride = true for one long ride. false: no way known. Remembered per pair of steps until the flight paths you know,
-- your speed or your level change (priceSig). ask = false: only what is remembered (nil: not priced yet).
local tripMemo, tripSig = setmetatable({}, { __mode = "k" }), nil
local function farTrip(a, b, ask)
  local sig = priceSig()
  if tripSig ~= sig then tripMemo = setmetatable({}, { __mode = "k" }); tripSig = sig end
  local row = tripMemo[a]
  local e = row and row[b]
  if e ~= nil or not ask then return e end
  e = false
  if ns.Travel and ns.Travel.Plan then
    local ok, legs, secs = pcall(ns.Travel.Plan, { m = a.m, x = a.x, y = a.y }, { m = b.m, x = b.x, y = b.y }, { hearth = false })
    if ok and legs and secs then
      e = { secs = secs }
      local function w(m, x, y) if not (m and x and y) then return nil end local wx, wy, wi = HBD:GetWorldCoordinatesFromZone(x, y, m); return wx and { wx, wy, wi } or nil end
      local allRide = true
      for _, l in ipairs(legs) do if l.how ~= "ride" then allRide = false end end
      if allRide then e.ride = true
      else
        -- (the first leg that isn't a ride starts where the walk ends: a flight master or a pier; a teleport has no walk)
        for _, l in ipairs(legs) do if l.how ~= "ride" then if l.how == "fly" or l.how == "boat" then e.D = w(l.sm, l.sx, l.sy) end break end end
        local L = legs[#legs]
        if #legs > 1 and L.how == "ride" then e.P = w(L.sm, L.sx, L.sy) end
      end
    end
  end
  -- (no trip found, in one world: the plan gets there somehow - priced as the ride, not as unreachable; the plan's own
  -- order says it goes)
  local A, B = not e and wpos(a), not e and wpos(b)
  if A and B and A[3] == B[3] then e = { secs = yd(A, B) * 1.25 / speedNow(), ride = true } end
  if not row then row = {}; tripMemo[a] = row end
  row[b] = e
  return e
end
-- seconds the plan takes from its stop a to its stop b (step tables): the walk, or the trip when they are far apart.
-- ask = false: a far trip not priced yet is nil, and true second
local function planSecs(a, b, ask)
  local A, B = wpos(a), wpos(b)
  if not (A and B) then return nil end
  if A[3] == B[3] and (a.m == b.m or yd(A, B) < 900) then return yd(A, B) * 1.25 / speedNow() end
  local e = farTrip(a, b, ask ~= false)
  if e == nil then return nil, true end
  return e and e.secs or nil
end
Next._planSecs = planSecs

-- The plan's way, indexed: its located stops in order (travel steps are no stops), the gaps between them - with the
-- plan's own trip steps in each: a hearth (the walk before it, then from the inn the plan bound you at) or a boat
-- (its pier is where the walk ends) - and a grid of the gaps by the cells their walks pass. A far gap's walks are
-- known only once its trip is (Travel.Plan), so until then it is indexed along the walks to every flight master and
-- pier of its two maps (Travel.Ports) - one of them is where the trip leaves and lands - and once priced, along its
-- own. Built once per plan list and length (a stop the route inserts makes a new one). Its stops are step tables, so a
-- price survives the plan moving on.
local wayMemo = setmetatable({}, { __mode = "k" })
local function walkable(a, b) return a.w[3] == b.w[3] and (a.st.m == b.st.m or yd(a.w, b.w) < 900) end
local function way(list)
  local W = wayMemo[list]
  if W and W.n == #list then return W end
  W = { n = #list, stops = {}, at = {}, gaps = {}, grid = {}, ver = 0 }
  local trips, bind = {}, nil
  for j, s in ipairs(list) do
    if Next.TRIP[s.k] then trips[#trips + 1] = s
    else
      local w = wpos(s)
      if w then
        local e = { j = j, st = s, w = w }
        local k = #W.stops
        if k > 0 then
          local g = { a = W.stops[k], b = e }
          for _, t in ipairs(trips) do if t.k == "hearth" then g.hearth = bind end end
          -- (a hearth to an inn the plan never bound you at: where it lands isn't known - the trip planner's way)
          if not g.hearth and trips[1] and trips[1].boat then g.pier = wpos(trips[1]) end
          W.gaps[k] = g
        end
        W.stops[k + 1] = e
        if not W.at[s] then W.at[s] = k + 1 end
        if s.k == "bind" then bind = e end
        trips = {}
      end
    end
  end
  local C = Next.DEFER_CELL
  local function put(w, k)
    local key = math.floor(w[1] / C) .. ":" .. math.floor(w[2] / C) .. ":" .. tostring(w[3])
    local c = W.grid[key]
    if not c then c = {}; W.grid[key] = c end
    if c[#c] ~= k then c[#c + 1] = k end
  end
  -- (a walk across a zone passes the cells between its ends: a stop half way along is on the way)
  local function line(x, y, k)
    put(x, k); put(y, k)
    if x[3] ~= y[3] then return end
    local n = math.floor(yd(x, y) / (C / 2))
    for t = 1, n do put({ x[1] + (y[1] - x[1]) * t / (n + 1), x[2] + (y[2] - x[2]) * t / (n + 1), x[3] }, k) end
  end
  W.line = line
  local ports = (ns.Travel and ns.Travel.Ports) or function() return {} end
  local function leg(x, y, k, pier)
    if walkable(x, y) then line(x.w, y.w, k); return end
    put(x.w, k); put(y.w, k)
    if pier then line(x.w, pier, k) else for _, p in ipairs(ports(x.st.m)) do if p[3] == x.w[3] then line(x.w, p, k) end end end
    for _, p in ipairs(ports(y.st.m)) do if p[3] == y.w[3] then line(p, y.w, k) end end
  end
  for k, g in ipairs(W.gaps) do
    if g.hearth then put(g.a.w, k); leg(g.hearth, g.b, k)
    else leg(g.a, g.b, k, g.pier) end
  end
  wayMemo[list] = W
  return W
end

local function serviceOf(s) return (s.k == "obj" and tonumber(s.work)) or Next.SERVICE[s.k] or 15 end
-- the cheaper of two (detour, how near) pairs
local function better(d1, n1, d2, n2) if d1 and (not d2 or d1 <= d2) then return d1, n1 end return d2, n2 end
-- the detour (seconds) of fitting a stop at p into the plan's way from stop x to stop y (stops of the way), and how
-- near that way comes to p (yards); ask: the trip planner may be asked (a far trip not priced yet). k: the gap, whose
-- trip's own walks are indexed once known. -> seconds, yards, or nil (no way to fit it there) and true when the trip
-- wasn't priced yet
local function legDetour(W, k, x, y, p, ask, pier)
  if walkable(x, y) then return segDetour(x.w, y.w, p) end
  local e = farTrip(x.st, y.st, false)
  if e == nil and ask and mayAsk() then e = farTrip(x.st, y.st, true) end
  if e == nil then return nil, nil, true end
  if not e then return nil end
  if e.ride then return segDetour(x.w, y.w, p) end
  local D = pier or e.D
  local g = k and W.gaps[k]
  if g and not g.indexed then
    -- (the trip's own walks, along their length: one may start or end off the two maps - a ride to a flight master)
    g.indexed = true
    if D and D[3] == x.w[3] then W.line(x.w, D, k) end
    if e.P and e.P[3] == y.w[3] then W.line(e.P, y.w, k) end
    W.ver = W.ver + 1
  end
  local d1, n1 = segDetour(x.w, D, p)
  local d2, n2 = segDetour(e.P, y.w, p)
  return better(d1, n1, d2, n2)
end
-- the same for a gap of the way (g: { a, b, hearth = the inn's stop, pier })
local function gapDetour(W, k, g, p, ask)
  if not g.hearth then return legDetour(W, k, g.a, g.b, p, ask, g.pier) end
  -- (before the hearth: the walk to it, and you hearth from there - no way back; after it, the way on from the inn)
  local d1, n1
  if g.a.w[3] == p[3] then n1 = yd(g.a.w, p); d1 = n1 * 1.25 / speedNow() end
  local d2, n2, unpriced = legDetour(W, k, g.hearth, g.b, p, ask)
  local d, n = better(d1, n1, d2, n2)
  return d, n, unpriced
end

-- would the solve offer stop s on a later pass of the plan, off its own place? Only a finished quest's hand-in at a
-- hub or where its chain goes on - within this many yards of you (Next.Pick). nil: only its own place counts.
local isHub, chainsOnHere
local function passReach(list, s)
  if s.k == "turnin" and s.q and (isHub(list, s) or chainsOnHere(list, s)) then return Next.NEAR_READY end
  return nil
end

-- What leaving stop s for later costs, in seconds, when the plan goes on from its step `from`: the stop itself, carrying
-- the quest (Next.CARRY), and the cheapest detour from the plan's own way from there on - at its own place in the plan,
-- or at another pass the plan makes by it where the solve would offer it (passReach). math.huge: the plan never comes
-- by again. behind: a stop the plan has passed for good (a quest behind you) - its own place doesn't count.
local deferMemo = setmetatable({}, { __mode = "k" })
function Next.DeferCost(list, s, from, behind)
  local p = wpos(s)
  if not p then return huge end
  local W = way(list)
  local key = from .. ":" .. priceSig() .. ":" .. tostring(behind)
  local m = deferMemo[s]
  if m and m.key == key and m.W == W and m.ver == W.ver then return m.v end
  local best, whole = huge, true -- (whole: every trip it looked at was priced)
  -- (the first stop of the way at or after `from`)
  local lo, hi = 1, #W.stops + 1
  while lo < hi do local mid = math.floor((lo + hi) / 2); if W.stops[mid].j < from then lo = mid + 1 else hi = mid end end
  local first = lo
  -- its own place in the plan: the gap between its neighbours, with the plan's trips on either side of it (a few
  -- hand-ins at one NPC are each other's neighbours)
  local own = not behind and W.at[s]
  if own and W.stops[own].j >= from then
    local a, b = W.stops[own - 1], W.stops[own + 1]
    local d, unpriced, _n
    if a and b then
      local g1, g2 = W.gaps[own - 1], W.gaps[own]
      d, _n, unpriced = gapDetour(W, nil, { a = a, b = b, hearth = g1.hearth or g2.hearth, pier = g1.pier or g2.pier }, p, true)
    elseif a or b then
      -- (the plan ends there, or starts: the way to it)
      d, unpriced = planSecs(a and a.st or s, b and b.st or s, false)
      if d == nil and unpriced and mayAsk() then d, unpriced = planSecs(a and a.st or s, b and b.st or s, true) end
    end
    if unpriced then whole = false end
    if d and d < best then best = d end
  end
  -- another pass of the way from `from` on where it would be offered: the walks first (cheap), then the soonest far trips
  local reach = passReach(list, s)
  if reach then
    local C = Next.DEFER_CELL
    -- (the walks are indexed every half cell: one passing within reach of p has a point in these cells)
    local r = math.floor((reach + C / 4) / C) + 1
    local cx, cy = math.floor(p[1] / C), math.floor(p[2] / C)
    local seen, far = {}, {}
    for dx = -r, r do
      for dy = -r, r do
        for _, k in ipairs(W.grid[(cx + dx) .. ":" .. (cy + dy) .. ":" .. tostring(p[3])] or {}) do
          if not seen[k] and k >= first then
            seen[k] = true
            local g = W.gaps[k]
            if g.a.st ~= s and g.b.st ~= s then
              local d, near, unpriced = gapDetour(W, k, g, p, false)
              if d and near <= reach then if d < best then best = d end elseif unpriced then far[#far + 1] = k end
            end
          end
        end
      end
    end
    if best > Next.DEFER_ENOUGH and #far > 0 then
      table.sort(far)
      for q = 1, math.min(Next.DEFER_FAR, #far) do
        local d, near, unpriced = gapDetour(W, far[q], W.gaps[far[q]], p, true)
        if unpriced then whole = false elseif d and near <= reach and d < best then best = d end
      end
    end
  end
  -- (a price still missing a trip: taken as "the plan comes by" until the next solve prices it, and not remembered)
  local v = best < huge and (serviceOf(s) + Next.CARRY + best) or huge
  if not whole then v = serviceOf(s) + Next.CARRY
  else deferMemo[s] = { key = key, W = W, ver = W.ver, v = v } end
  return v
end

-- the work still between you and a quest's XP, in seconds: its objective steps still to do (the ones the quest log
-- doesn't have finished: their expected work, the planner's s.work - kills and drops at their rates) and the walks the
-- plan makes for them - to each and on to the hand-in (s.walk, yards; the walk on only when the work before it is
-- known). Next.BEHIND_WORK an objective for a plan made before steps carried its work, and for a quest with no
-- objective step on the plan. except: an objective that is the stop itself (the solve charges its work as the stop's
-- own time). Kim'jael Indeed! is four objects looted at one camp, 12 s each: the flat 150 s an objective made it ten
-- minutes of work.
local objWork = setmetatable({}, { __mode = "k" })
local function workOf(list, q, except)
  local c = objWork[list]
  if not c or c.n ~= #list then
    c = { n = #list, by = {}, back = {} }
    for _, t in ipairs(list) do
      if t.k == "obj" and t.q then
        local e = c.by[t.q]; if not e then e = {}; c.by[t.q] = e end
        local known = tonumber(t.work) ~= nil
        e[#e + 1] = { st = t, secs = tonumber(t.work) or Next.BEHIND_WORK, yd = known and tonumber(t.walk) or 0, known = known }
      elseif t.k == "turnin" and t.q and tonumber(t.walk) and not c.back[t.q] then c.back[t.q] = tonumber(t.walk) end
    end
    objWork[list] = c
  end
  local objs = c.by[q]
  if not objs then return Next.BEHIND_WORK end
  local E, St = ns.Engine, ns.State
  if St and St.QuestReady and St.QuestReady(q) then return 0 end -- (all done: the way to the hand-in is the solve's)
  local secs, yards, known = 0, 0, false
  for _, o in ipairs(objs) do
    local ob = o.st ~= except and E.ObjectiveFor and E.ObjectiveFor(o.st)
    if o.st ~= except and not (ob and ob.finished) then
      secs = secs + o.secs; yards = yards + o.yd; known = known or o.known
    end
  end
  if known then yards = yards + (c.back[q] or 0) end
  return secs + yards * 1.25 / speedNow()
end

-- A hub: a place the plan stops at a lot (a town) - Next.HUB_STEPS steps within Next.HUB_YD of it. Hand-ins there are
-- welcome any time; out in the field one is only taken early when its chain goes on right there. The rest wait for the
-- plan's visit to the hub: questing a long while in a good order and then handing in a pile at once, the XP bar
-- climbing and climbing, is the loop WoW is built around - the guide sets it up rather than chipping it away.
Next.HUB_YD, Next.HUB_STEPS, Next.CHAIN_YD = 70, 4, 150
-- A later visit to where you are now (Next.VisitHere): the plan leaves, and comes back here for more - hand-ins, a
-- chain's next part, a trainer. When all of that visit can be done now, doing it now saves the whole trip back. Arriving
-- in Stormwind by hearth with three hand-ins ready while the plan flew to Ironforge first and hearthed back for them
-- ("you've just arrived, hand in what's here") is one case; any town, any way of arriving, is the same rule.
Next.VISIT_SCAN = 250   -- steps ahead looked through for a later visit here
Next.TRIP_MIN = 120     -- a trip back is never valued at less than this (a hearth back costs its hour of cooldown)
-- -> { now = { step indices you can do this moment }, saves = seconds } or nil
function Next.VisitHere(list, planned, from, pm, px, py, pinst)
  if not pm then return nil end
  local E, St = ns.Engine, ns.State
  local TRIP = Next.TRIP
  local Lv = (UnitLevel and UnitLevel("player")) or 1
  local pre = ns.QUEST_PRE or {}
  local function preMet(q, handed)
    local p = pre[q]
    if p then
      for _, x in ipairs(p.g or {}) do if not (St.IsCompleted(x) or handed[x]) then return false end end
      if p.s and #p.s > 0 then local any = false; for _, x in ipairs(p.s) do if St.IsCompleted(x) or handed[x] then any = true; break end end; if not any then return false end end
    end
    for _, x in ipairs(E.PrereqsOf and E.PrereqsOf(q) or {}) do if not (St.IsCompleted(x) or handed[x]) then return false end end
    return true
  end
  -- quests that have work somewhere ahead (an objective step): their hand-in can't follow a pick-up made now
  local work = {}
  for j = from, math.min(#list, from + Next.VISIT_SCAN) do local s = list[j]; if s.k == "obj" and s.q then work[s.q] = true end end
  -- the visits: runs of steps between trips (or map changes); the first one on your map, past the window
  -- (only once the plan has left here - a trip, or steps somewhere else: until then it is still this visit)
  local left = false
  for x = planned, from - 1 do local t = list[x]; if E.Status(x) ~= "done" and (TRIP[t.k] or (t.m and t.m ~= pm)) then left = true; break end end
  local j, last = from, math.min(#list, from + Next.VISIT_SCAN)
  local prevPos -- the last place the plan is at before the visit (for the trip's length)
  while j <= last do
    local s = list[j]
    if TRIP[s.k] or not s.m or s.m ~= pm or not left then
      if E.Status(j) ~= "done" and (TRIP[s.k] or (s.m and s.m ~= pm)) then left = true end
      if s.m and not TRIP[s.k] and E.Status(j) ~= "done" then prevPos = s end
      j = j + 1
    else
      -- a run on your map: j .. k
      local k = j
      while k + 1 <= last and not TRIP[list[k + 1].k] and (not list[k + 1].m or list[k + 1].m == pm) do k = k + 1 end
      local handed, accepted, ok, now, any = {}, {}, true, {}, false
      local load = (St.LogCount and St.LogCount()) or 0
      local cap = (St.MaxLog and St.MaxLog()) or 25
      for x = j, k do
        local t = list[x]
        if E.Status(x) ~= "done" then
          any = true
          local can = true
          if t.minLevel and t.minLevel > Lv then can = false
          elseif t.k == "obj" or t.k == "grind" or t.unknown then can = false -- work, not a stop: the visit is still needed
          elseif t.k == "accept" then
            can = t.q and preMet(t.q, handed) and load < cap
            if can then accepted[t.q] = true; load = load + 1 end
          elseif t.k == "turnin" then
            can = t.q and (St.QuestReady(t.q) or (accepted[t.q] and not work[t.q]))
            if can then handed[t.q] = true; load = load - 1 end
          end
          if not can then ok = false; break end
          -- doable this moment (not after another step of the visit): a stop the solve can take now
          local nowOk = (t.k ~= "accept" or (E.Available and E.Available(x))) and (t.k ~= "turnin" or St.QuestReady(t.q))
          if nowOk and t.m and t.x then now[#now + 1] = x end
        end
      end
      if ok and any and #now > 0 then
        -- the trip it saves: the plan's way into the visit and out of it again, against its way past it - from where
        -- the plan was before it to where it goes after, by the plan's real trips (flights, boats: planSecs). It was a
        -- straight line from the stop before plus a minute, whatever the plan flew, and nothing for the way out.
        local first, lastIn, after
        for x = j, k do local t = list[x]; if wpos(t) and E.Status(x) ~= "done" then first = first or t; lastIn = t end end
        for x = k + 1, math.min(#list, k + Next.VISIT_SCAN) do local t = list[x]; if not TRIP[t.k] and wpos(t) and E.Status(x) ~= "done" then after = t; break end end
        local tin = prevPos and first and planSecs(prevPos, first)
        local saves = tin
        if tin and after and lastIn then
          local tout, past = planSecs(lastIn, after), planSecs(prevPos, after)
          if tout and past then saves = tin + tout - past end
        end
        saves = math.max(Next.TRIP_MIN, saves or Next.TRIP_MIN)
        return { now = now, saves = saves, from = j, to = k }
      end
      if any then return nil end -- the next visit here isn't all doable now: it happens anyway, its stops wait for it
      j = k + 1
    end
  end
  return nil
end
local hubMemo = setmetatable({}, { __mode = "k" })
function isHub(list, s) -- (declared above: passReach)
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
function chainsOnHere(list, s) -- (declared above: passReach)
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

-- what a quest you'd take up again is worth, in seconds: its XP at your rate, less the work still to do for it (its
-- objective steps: workOf). The plan never comes back for it (it is behind you), so this is its whole prize
-- (Next.Prize). Shared with tools/replay.js's "leaves work" check, so the check and the pick can't disagree.
-- (Engine.QuestXP: the game's own cut for a quest far below you - 80% at 6 levels down to 10% at 10 or more. A gray
-- quest still pays that much; it is gray mobs that pay nothing.)
-- is a pick-up the plan passed as behind you a candidate at your level L? Not more than 2 levels above you; how far
-- below is the price's to say (Next.BehindPrize). Shared with tools/replay.js's "behind you" count.
function Next.BehindLevelOk(level, L) return tonumber(level) ~= nil and level <= L + 2 end
function Next.BehindPrize(list, s, L)
  local E = ns.Engine
  if not (E.QuestXP and s and s.q and tonumber(s.level)) then return 0 end
  return E.QuestXP(s.level, L) / rate() - workOf(list, s.q)
end

-- What doing stop s now is worth, in seconds (see "Now or later" above): the least of what its quest pays and what
-- leaving it costs. from: the plan's step the solve starts at; behind: the plan has passed it for good.
-- What it pays: a hand-in, its XP at your level (a gray one a tenth or so); a pick-up, that less the work of its
-- objectives (Next.BehindPrize); an objective, that less the quest's other objectives. A stop of no quest (a flight
-- path the route took in) pays nothing in XP: it is worth the trip back for it, or, when the plan never comes back,
-- the stop and the carrying alone - as before.
function Next.Prize(list, s, from, behind)
  local defer = behind and huge or Next.DeferCost(list, s, from)
  local E = ns.Engine
  local L = (UnitLevel and UnitLevel("player")) or 1
  local pays
  if s.q then
    if s.k == "accept" then pays = Next.BehindPrize(list, s, L)
    else
      local xp = (E.QuestXP and tonumber(s.level)) and E.QuestXP(s.level, L) or tonumber(s.xp) or ((UnitXPMax and UnitXPMax("player") or 10000) * 0.04)
      pays = xp / rate() - (s.k == "obj" and workOf(list, s.q, s) or 0)
    end
  elseif defer == huge then return serviceOf(s) + Next.CARRY
  else return defer end
  return math.min(pays, defer)
end

-- the plan's pick-ups and hand-ins, in order: the scans of a solve over the whole plan for quests behind you and
-- finished ones near you look at these, not at all ~2,500 steps every refresh. Kept per plan list and length (a stop
-- the route inserts makes a new one).
local kindsMemo = setmetatable({}, { __mode = "k" })
local function stepsOfKind(list)
  local c = kindsMemo[list]
  if c and c.n == #list then return c end
  c = { n = #list, accept = {}, turnin = {} }
  for j, s in ipairs(list) do
    if s.k == "accept" then c.accept[#c.accept + 1] = j elseif s.k == "turnin" then c.turnin[#c.turnin + 1] = j end
  end
  kindsMemo[list] = c
  return c
end
-- the first position in idx (ascending step indices) past step j
local function after(idx, j)
  local lo, hi = 1, #idx + 1
  while lo < hi do local mid = math.floor((lo + hi) / 2); if idx[mid] <= j then lo = mid + 1 else hi = mid end end
  return lo
end

local last -- { sig, at, pick, res }
-- a stop you said "not now" to, while it holds: you are still about where you said it, and not long after
local function isDismissed(j, px, py, pinst)
  local d = Next.dismissed[j]
  if not d then return false end
  local now = GetTime and GetTime() or 0
  if now - d.t > Next.DISMISS_SECS or d.inst ~= pinst or (d.x - px) ^ 2 + (d.y - py) ^ 2 > Next.DISMISS_YD ^ 2 then Next.dismissed[j] = nil; return false end
  return true
end
Next.IsDismissed = isDismissed
-- -> the step index to show, or nil (the plan's own next step stands)
-- Already where the plan goes after its next trip (you flew on ahead, or rode somewhere yourself): the plan's steps
-- in the zone you're in come first, the trip and what it was for wait (they are still to do - the card comes back to
-- them once these are done). In Stormwind with hand-ins left, a player flew to the Wetlands; the card kept saying
-- "fly back to Stormwind" while the plan's Wetlands questing was a few steps on - tester.
-- -> the first of Next.REJOIN_MIN or more plan steps in a row on your map, within Next.REJOIN_SCAN steps; or nil
Next.REJOIN_SCAN, Next.REJOIN_MIN = 250, 4
function Next.LocalBlock(list, planned, pm)
  local trip = list[planned]
  if not (pm and trip and trip.to and trip.to ~= pm) then return nil end
  local E = ns.Engine
  local j0, n = nil, 0
  for j = planned + 1, math.min(#list, planned + Next.REJOIN_SCAN) do
    local s = list[j]
    if Next.KIND[s.k] and s.m and E.Status(j) == "todo" then
      if s.m == pm then
        j0 = j0 or j; n = n + 1
        if n >= Next.REJOIN_MIN then return j0 end
      elseif j0 then j0, n = nil, 0 end -- (a few steps here, then away again: not worth leaving the plan for)
    end
  end
  return nil
end

local function pick(planned)
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

  -- (a "not now" ends when you move on: checked every solve, not only when that stop is a candidate again)
  for j in pairs(Next.dismissed) do isDismissed(j, px, py, pinst) end
  local stops, byStep, count, scanEnd = {}, {}, 0, planned
  local function add(j, extra)
    -- (a stop you said "not now" to stays out while you're still here: a plan step waits for its own place in the plan)
    if extra and extra.opt and isDismissed(j, px, py, pinst) then return nil end
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
  -- (you're already where the plan goes after this trip: start from there - see Next.LocalBlock)
  local from = planned
  Next.rejoin = nil
  if onTrip then
    local j0 = Next.LocalBlock(list, planned, here[1])
    if j0 then from = j0; holdPlanned, holdAt = false, nil; Next.rejoin = { at = j0, trip = planned } end
  end
  for j = from, math.min(#list, from + Next.SCAN) do
    local s = list[j]
    local st = E.Status(j)
    scanEnd = j
    if st == "todo" then
      -- (a pick-up whose earlier chain quest isn't handed in is not offered yet: Chef Grual has nothing until Jitters'
      -- Growling Gut is in - it waits where the plan has it)
      if Next.KIND[s.k] and wpos(s) and (s.k ~= "accept" or ((not E.Available or E.Available(j)) and roomInLog)) then
        -- an off-plan stop the route only took in (a finished quest's hand-in, a side quest's objective): a prize, not a
        -- must (Next.Prize). A hand-in whose NPC the plan comes back to - a capital, a hub - waits for that visit like
        -- any other: worth only the trip back it saves. One the plan never passes again is worth its XP at your level:
        -- left, it would be lost. Ironforge from the Burning Steppes for one hand-in was the first kind valued as the
        -- second.
        if s.inserted then
          add(j, { prize = Next.Prize(list, s, planned), opt = true })
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
  -- your level: the plan never comes back for them, so a pick-up is worth its XP at your rate, less the work still to
  -- do for it (Next.Prize, Next.BehindPrize) - the solve takes it when that beats the plan's way on. Taken, the quest is yours, and its objectives and hand-in come back to the route by themselves (a quest in
  -- your log is never behind you). A level 40 standing at Indurium (level 39) was sent away: the plan does it at 38.
  if E.BehindYou and E.QuestXP then
    local L = (UnitLevel and UnitLevel("player")) or 1
    -- (the nearest Next.BEHIND_MAX of them within Next.BEHIND_YD: the solve weighs the way there against what they pay)
    -- (how far below you is the price's to say - what the quest still pays you after its work; a window of its own, 4
    -- levels, left a level 50 sent on past WANTED: Andre Firebeard, 45, 121 yd away and still worth it (fuzz). Above you
    -- at most 2 levels, as before)
    local found = {}
    local accepts = roomInLog and stepsOfKind(list).accept or {}
    for x = 1, #accepts do
      local j = accepts[x]
      local s = list[j]
      if s.q and tonumber(s.level) and Next.BehindLevelOk(s.level, L) and not byStep[j] then
        local w = wpos(s)
        local d2 = w and w[3] == pinst and (w[1] - px) ^ 2 + (w[2] - py) ^ 2
        if d2 and d2 <= Next.BEHIND_YD ^ 2 and not St.OnQuest(s.q) and not St.IsCompleted(s.q) then
          local prize = Next.Prize(list, s, planned, true)
          if prize > 0 and E.BehindYou(s) and (not E.Available or E.Available(j)) and not (ns.char and ns.char.nope and ns.char.nope[s.q]) then
            found[#found + 1] = { j = j, d2 = d2, prize = prize }
          end
        end
      end
    end
    table.sort(found, function(a, b) return a.d2 < b.d2 end)
    for k = 1, math.min(Next.BEHIND_MAX, #found) do add(found[k].j, { prize = found[k].prize, opt = true, behind = true }) end
  end
  -- finished quests whose hand-in is further on in the plan but near you now: a prize worth the trip back it saves
  -- (Next.Prize: the plan's detour to it later; a gray quest's hand-in pays next to nothing - it goes with the plan, or
  -- not at all. That used to be a rule of its own: 30% of the quest's XP.) Next.NEAR_READY only bounds the candidates:
  -- the price decides.
  local turnins = stepsOfKind(list).turnin
  for x = after(turnins, scanEnd), #turnins do
    local j = turnins[x]
    local s = list[j]
    if s.q and St.QuestReady(s.q) and not byStep[j] then
      local w = wpos(s)
      if w and w[3] == pinst and (w[1] - px) ^ 2 + (w[2] - py) ^ 2 <= Next.NEAR_READY ^ 2 and E.Status(j) == "todo"
        and (isHub(list, s) or chainsOnHere(list, s)) then
        add(j, { prize = Next.Prize(list, s, planned), opt = true, early = true, chain = not isHub(list, s) or nil })
      end
    end
  end
  -- a later visit the plan makes to where you are now, all of which you can do now: done now, the trip back for it
  -- goes (a trip to steps that are all done is passed - Engine statusRaw). Worth that trip (Next.VisitHere)
  local visit = Next.VisitHere(list, planned, planned + 1, here[1], px, py, pinst)
  if visit then
    local share = visit.saves / #visit.now
    for _, j in ipairs(visit.now) do
      -- (one of the plan's own next stops already: it may now come before the trip)
      if byStep[j] then byStep[j].visit, byStep[j].early = true, true
      else
        -- (left for the plan's visit it costs the stop, carrying it, and its share of the trip there - the visit's way in
        -- and out is the trip, so it isn't priced again as a detour of its own; its XP isn't at stake: the visit does it)
        add(j, { prize = serviceOf(list[j]) + Next.CARRY + share, opt = true, early = true, visit = true })
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
  local closePrize = pst and pst.w and pst.w[3] == pinst and (pst.visit or (pst.opt and (pst.w[1] - px) ^ 2 + (pst.w[2] - py) ^ 2 <= Next.HOLD_NEAR ^ 2))
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

-- a solve: what its prices depend on is taken once, and the trip-planner searches they may start are bounded
-- (Next.ASK_PER_PICK) - whatever way it ends
function Next.Pick(planned)
  sigNow, askLeft = nil, nil
  sigNow, askLeft = priceSig(), Next.ASK_PER_PICK
  local ok, r = pcall(pick, planned)
  sigNow, askLeft = nil, nil
  if not ok then error(r, 0) end
  return r
end

-- why a step picked out of plan order, in words
function Next.Reason(i)
  local res = Next.res
  local st
  for _, s in ipairs((res and res.seq) or {}) do if s.step == i then st = s; break end end
  if not st then return "" end
  if st.behind then return "right here and still worth XP at your level (the plan has it earlier)" end
  local rj = Next.rejoin
  local L = ForeverRouteData and ForeverRouteData.steps
  if rj and st.step and st.step >= rj.at and L and L[rj.trip] then
    local t = L[rj.trip]
    return "you're here already - the plan quests here next; " .. ((t.dest or t.text) and ("the trip to " .. (t.dest or t.text)) or "the trip") .. " waits"
  end
  if st.early and st.chain then return "the chain goes on right here - hand it in and take the next" end
  if st.early and st.visit then return "the plan comes back here for this later - done now, that trip back goes" end
  if st.early then return "while you're here - it saves coming back for it later" end
  if st.opt then return "a quest you picked up on the way, handed in where it costs least" end
  return "on the way - the whole route from here is shorter this way"
end

-- can the card's step be put off ("not now")? Only a stop the solver took in from where you are - a hand-in while
-- you're here, a quest right behind you, one you picked up on the way - never the plan's own next step.
function Next.CanDismiss(i)
  for _, s in ipairs((Next.res and Next.res.seq) or {}) do if s.step == i then return (s.opt and true) or false end end
  return false
end
-- "not now": the stop leaves the card until you move on or a while passes, and the plan's order stands
function Next.Dismiss(i)
  if not Next.CanDismiss(i) then return false end
  -- (where you are: the position the once-a-second check measured, as the solve uses it)
  local ep = ns.Engine and ns.Engine.pos
  local px, py, pinst
  if ep then px, py, pinst = ep[1], ep[2], ep[3] else px, py, pinst = HBD:GetPlayerWorldPosition() end
  if not px then return false end
  Next.dismissed[i] = { t = GetTime and GetTime() or 0, x = px, y = py, inst = pinst }
  last = nil
  if ns.Engine and ns.Engine.focus == i then ns.Engine.focus, ns.Engine.focusWhy = nil, nil end
  if ns.Engine and ns.Engine.Refresh then ns.Engine.Refresh() end
  return true
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
  for _, j in ipairs(stepsOfKind(list).turnin) do
    local t = list[j]
    if t.q and not seen[t.q] and St.QuestReady(t.q) then
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
