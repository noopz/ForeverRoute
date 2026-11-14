-- The live "what next": a small solve over the stops that could come next, from where you really are, re-run when
-- something changes - not a fixed list patched by rules. (docs/research/live-routing.md has the why and the sources.)
--
-- The problem is a pickup-and-delivery problem with prizes, re-solved on a rolling horizon. In one currency, seconds:
--   * The plan's next stops (planned) must all be done; only their order is open. A window is scored by the time it
--     takes plus the time to finish the rest of the window's planned stops in plan order from where it ends, and
--     then on to the anchor (the plan's first stop past the window). That is the true length of the route from here,
--     so reordering is only chosen when it really is shorter - the plan stays the guidance, and is the cost-to-go.
--   * Other stops are optional prizes: a finished quest's hand-in that isn't the plan's, a side quest's objective,
--     a pick-up next to you, an errand. Each says what doing it now is worth (prize, seconds): for a hand-in, the
--     time it would cost to come back for it later (the detour from your route to the NPC, and the hand-in itself).
--     Next to you that is a lot more than it costs now - "while you're here: hand in X" - and across the world it
--     is much less - never "all the way to Stormwind for one hand-in". No rule of its own: arithmetic.
--   * Straying from the plan's order costs a little (stability): each planned stop passed over, Horizon.STABILITY
--     seconds. A guide that reshuffles for a few seconds saved is no guide.
--   * Your quest log is the vehicle's capacity: a pick-up is +1, a hand-in -1, never over cap. Pick-up before
--     objectives before hand-in (needs).
--
-- The search is a beam over sequences of up to K stops with states merged (restricted dynamic programming: two
-- sequences that did the same stops and stand at the same last one are one state - keep the better), keeping the best
-- B per depth. Small and bounded (K ~6 of N ~24 candidates): a few ms.
local _, ns = ...
local Horizon = {}
if type(ns) == "table" then ns.Horizon = Horizon end

Horizon.K = 6            -- stops looked ahead
Horizon.B = 60           -- partial routes kept per depth
Horizon.STABILITY = 45   -- seconds charged for each planned stop passed over (out of plan order)...
Horizon.STABLE_NEAR = 60 -- ...in full for a stop this many seconds away or more, less for nearer ones: doing what's
                         -- right here isn't the confusing kind of out of order - being sent somewhere else is
Horizon.MAX_CANDIDATES = 30

local huge = math.huge

-- problem:
--   start    where you are (passed to travel() as the first place of the first leg)
--   stops    { id, service = seconds, load = +1 | -1 | 0, plan = index in the plan (a planned stop: must be done)
--              or prize = seconds (an optional stop: what doing it now is worth), needs = { stop ids before it } }
--   anchor   optional place the window leads on to (the plan's next stop past it)
--   travel   function(a, b) -> seconds between two places; memoised here
--   load, cap   quests in your log now, and the most it holds
--   K, B, stability   optional overrides
--   first    optional stop id the window must start with (to score keeping the current target: hysteresis)
-- -> { seq = { stops }, score = -(seconds to finish) + prizes, first = the stop to do now (nil: nothing to do) }
function Horizon.Solve(P)
  local stops = P.stops or {}
  local n = #stops
  local K, B = P.K or Horizon.K, P.B or Horizon.B
  local stab = P.stability or Horizon.STABILITY
  local cap, load0 = P.cap or 25, P.load or 0
  local idx = {}
  for i, s in ipairs(stops) do idx[s.id] = i end
  local ANCHOR = n + 1
  -- travel, memoised by index (0: the start, n+1: the anchor)
  local tmemo = {}
  local function place(i) if i == 0 then return P.start elseif i == ANCHOR then return P.anchor else return stops[i] end end
  local function trip(i, j)
    if j == ANCHOR and P.anchor == nil then return 0 end
    local k = i * 4096 + j
    local v = tmemo[k]
    if v == nil then v = P.travel(place(i), place(j)) or huge; tmemo[k] = v end
    return v
  end
  local need, bit, bit2, planned = {}, {}, {}, {}
  for i, s in ipairs(stops) do
    bit[i] = 2 ^ (i - 1); bit2[i] = bit[i] * 2
    local list = {}
    for _, id in ipairs(s.needs or {}) do if idx[id] then list[#list + 1] = idx[id] end end
    need[i] = list
    if s.plan then planned[#planned + 1] = i end
  end
  table.sort(planned, function(a, b) return stops[a].plan < stops[b].plan end)
  local np0 = #planned
  -- the rest of the window's planned stops from last, then on to the anchor: in plan order, except that a stop that
  -- can't be done yet (its pick-up not done, the log full) gives way to the first one that can - the way you'd
  -- follow the plan. -> seconds, and the order (when asked for)
  -- (one pass in plan order: a stop that can't be done yet waits aside and goes as soon as it can - after each stop
  -- taken, the waiting ones are tried again, earliest first)
  -- (it runs for every partial route the search keeps - thousands a solve - so its helpers are made once, here, and
  -- share the state of the one tail being worked out: tt, tat, tm, tld, torder, tnp)
  local pending = {}
  local tt, tat, tm, tld, torder, tnp = 0, 0, 0, 0, nil, 0
  local function can(j)
    if tld + (stops[j].load or 0) > cap then return false end
    local nj = need[j]
    for k = 1, #nj do local q = nj[k]; if (tm % bit2[q]) < bit[q] then return false end end
    return true
  end
  local function take(j)
    tt = tt + trip(tat, j) + (stops[j].service or 0)
    tat, tm, tld = j, tm + bit[j], tld + (stops[j].load or 0)
    if torder then torder[#torder + 1] = j end
  end
  local function drain()
    local k = 1
    while k <= tnp do
      if can(pending[k]) then take(table.remove(pending, k)); tnp = tnp - 1; k = 1 else k = k + 1 end
    end
  end
  local function tail(mask, last, load, order)
    tt, tat, tm, tld, torder, tnp = 0, last, mask, load, order, 0
    for x = 1, np0 do
      local j = planned[x]
      if (tm % bit2[j]) < bit[j] then
        if can(j) then take(j); if tnp > 0 then drain() end else tnp = tnp + 1; pending[tnp] = j end
      end
    end
    if tnp > 0 then drain() end
    torder = nil
    if tnp > 0 then for k = tnp, 1, -1 do pending[k] = nil end; return huge end -- (stops that can never be done: infeasible)
    return tt + trip(tat, ANCHOR)
  end
  -- the planned stops a stop passes over (out of plan order): of those before it in the plan (rank[i] of them, the
  -- first of planned), the ones not done yet. Counted per node once (pre[k]: of the first k planned, how many are not
  -- done) rather than per stop tried from it.
  local rank, pre, preFor = {}, { [0] = 0 }, nil
  for i, s in ipairs(stops) do
    if s.plan then
      local r = 0
      for x = 1, np0 do if stops[planned[x]].plan < s.plan then r = r + 1 else break end end
      rank[i] = r
    end
  end

  -- a node: { mask, last, worth (prizes - time - penalties so far), load, up (the node it grew from), first (its first
  -- stop) }. Its stops in order are read back through up only for the best one: copying them into every node tried was
  -- a table per candidate.
  -- (a node's key - its stops done and the last one - is a number when it fits one exactly: a string per candidate was
  -- much of a solve's time)
  local numKey = n <= 47
  local root = { mask = 0, last = 0, worth = 0, load = load0 }
  local function score(nd) return nd.worth - tail(nd.mask, nd.last, nd.load) end
  local best, bestScore = root, score(root)
  if P.first then best, bestScore = nil, -huge end
  local layer = { root }
  local stableNear = P.stableNear or Horizon.STABLE_NEAR
  for depth = 1, math.min(K, n) do
    local byKey, keys = {}, {}
    for _, nd in ipairs(layer) do
      local ndMask = nd.mask
      preFor = nil
      for i = 1, n do
        if (ndMask % bit2[i]) < bit[i] and (depth > 1 or not P.first or stops[i].id == P.first) then
          local s = stops[i]
          local ok = true
          local ni = need[i]
          for k = 1, #ni do local j = ni[k]; if (ndMask % bit2[j]) < bit[j] then ok = false; break end end
          local ld = nd.load + (s.load or 0)
          if ok and ld <= cap then
            local t = trip(nd.last, i)
            if t < huge then
              local near = math.min(1, t / stableNear)
              local po = 0
              if s.plan then
                if preFor ~= nd then
                  preFor = nd
                  for x = 1, np0 do local j = planned[x]; pre[x] = pre[x - 1] + (((ndMask % bit2[j]) < bit[j]) and 1 or 0) end
                end
                po = pre[rank[i]]
              end
              local worth = nd.worth + (s.prize or 0) - t - (s.service or 0) - stab * near * po
              local mask = ndMask + bit[i]
              local key
              if numKey then key = mask * (n + 1) + i else key = mask .. ":" .. i end
              local old = byKey[key]
              if not old or worth > old.worth then
                if not old then keys[#keys + 1] = key end
                byKey[key] = { mask = mask, last = i, worth = worth, load = ld, up = nd, first = nd.first or i }
              end
            end
          end
        end
      end
    end
    local nxt = {}
    for _, key in ipairs(keys) do local nd = byKey[key]; nd.score = score(nd); nxt[#nxt + 1] = nd end
    if #nxt == 0 then break end
    table.sort(nxt, function(a, b)
      if a.score ~= b.score then return a.score > b.score end
      return (stops[a.first].plan or huge) < (stops[b.first].plan or huge) -- ties: plan order
    end)
    while #nxt > B do nxt[#nxt] = nil end
    if nxt[1].score > bestScore then best, bestScore = nxt[1], nxt[1].score end
    layer = nxt
  end
  if not best then return { seq = {}, score = -huge } end
  -- the whole window: the stops the search chose, then the rest as the plan has them (the way tail() costed it)
  local order = {}
  do
    local chain, nd = {}, best
    while nd and nd.up do chain[#chain + 1] = nd.last; nd = nd.up end
    for q = #chain, 1, -1 do order[#order + 1] = chain[q] end
  end
  local chosen = #order
  tail(best.mask, best.last, best.load, order)
  local seq = {}
  for q, i in ipairs(order) do seq[q] = stops[i] end
  -- the stops left out (prizes not worth it now): for the card's "later" line
  local inSeq, skipped = {}, {}
  for _, i in ipairs(order) do inSeq[i] = true end
  for i, s in ipairs(stops) do if not inSeq[i] then skipped[#skipped + 1] = s end end
  return { seq = seq, score = bestScore, first = seq[1], chosen = chosen, skipped = skipped }
end

return Horizon
