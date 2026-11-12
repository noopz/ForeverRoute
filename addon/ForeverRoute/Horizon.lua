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
  local need, bit, planned = {}, {}, {}
  for i, s in ipairs(stops) do
    bit[i] = 2 ^ (i - 1)
    local list = {}
    for _, id in ipairs(s.needs or {}) do if idx[id] then list[#list + 1] = idx[id] end end
    need[i] = list
    if s.plan then planned[#planned + 1] = i end
  end
  table.sort(planned, function(a, b) return stops[a].plan < stops[b].plan end)
  local function has(mask, i) return (mask % (bit[i] * 2)) >= bit[i] end
  -- the rest of the window's planned stops from last, then on to the anchor: in plan order, except that a stop that
  -- can't be done yet (its pick-up not done, the log full) gives way to the first one that can - the way you'd
  -- follow the plan. -> seconds, and the order (when asked for)
  -- (one pass in plan order: a stop that can't be done yet waits aside and goes as soon as it can - after each stop
  -- taken, the waiting ones are tried again, earliest first)
  local pending = {}
  local function tail(mask, last, load, order)
    local t, at, m, ld = 0, last, mask, load
    local np = 0
    local function can(j)
      if ld + (stops[j].load or 0) > cap then return false end
      for _, q in ipairs(need[j]) do if not has(m, q) then return false end end
      return true
    end
    local function take(j)
      t = t + trip(at, j) + (stops[j].service or 0)
      at, m, ld = j, m + bit[j], ld + (stops[j].load or 0)
      if order then order[#order + 1] = j end
    end
    local function drain()
      local k = 1
      while k <= np do
        if can(pending[k]) then take(table.remove(pending, k)); np = np - 1; k = 1 else k = k + 1 end
      end
    end
    for _, j in ipairs(planned) do
      if not has(m, j) then
        if can(j) then take(j); if np > 0 then drain() end else np = np + 1; pending[np] = j end
      end
    end
    if np > 0 then drain() end
    if np > 0 then for k = np, 1, -1 do pending[k] = nil end; return huge end -- (stops that can never be done: infeasible)
    return t + trip(at, ANCHOR)
  end
  local function passedOver(mask, i)
    local p = stops[i].plan
    if not p then return 0 end
    local c = 0
    for _, j in ipairs(planned) do
      if stops[j].plan >= p then break end
      if not has(mask, j) then c = c + 1 end
    end
    return c
  end

  -- a node: { mask, last, worth (prizes - time - penalties so far), load, seq }
  local root = { mask = 0, last = 0, worth = 0, load = load0, seq = {} }
  local function score(nd) return nd.worth - tail(nd.mask, nd.last, nd.load) end
  local best, bestScore = root, score(root)
  if P.first then best, bestScore = nil, -huge end
  local layer = { root }
  for depth = 1, math.min(K, n) do
    local byKey, keys = {}, {}
    for _, nd in ipairs(layer) do
      for i = 1, n do
        if not has(nd.mask, i) and (depth > 1 or not P.first or stops[i].id == P.first) then
          local s = stops[i]
          local ok = true
          for _, j in ipairs(need[i]) do if not has(nd.mask, j) then ok = false; break end end
          local ld = nd.load + (s.load or 0)
          if ok and ld <= cap then
            local t = trip(nd.last, i)
            if t < huge then
              local near = math.min(1, t / (P.stableNear or Horizon.STABLE_NEAR))
              local worth = nd.worth + (s.prize or 0) - t - (s.service or 0) - stab * near * passedOver(nd.mask, i)
              local mask = nd.mask + bit[i]
              local key = mask .. ":" .. i
              local old = byKey[key]
              if not old or worth > old.worth then
                if not old then keys[#keys + 1] = key end
                local seq = {}
                for q = 1, #nd.seq do seq[q] = nd.seq[q] end
                seq[#seq + 1] = i
                byKey[key] = { mask = mask, last = i, worth = worth, load = ld, seq = seq }
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
      return (stops[a.seq[1]].plan or huge) < (stops[b.seq[1]].plan or huge) -- ties: plan order
    end)
    while #nxt > B do nxt[#nxt] = nil end
    if nxt[1].score > bestScore then best, bestScore = nxt[1], nxt[1].score end
    layer = nxt
  end
  if not best then return { seq = {}, score = -huge } end
  -- the whole window: the stops the search chose, then the rest as the plan has them (the way tail() costed it)
  local order = {}
  for q, i in ipairs(best.seq) do order[q] = i end
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
