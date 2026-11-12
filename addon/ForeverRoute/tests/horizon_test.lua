-- The live "what next" solver (Horizon.lua) on made-up worlds: places are { x, y } in yards, travel at 7 yd/s.
local ns = ForeverRoute
local H = ns.Horizon
local function walk(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) / 7 end
local function ids(seq) local o = {}; for i, s in ipairs(seq) do o[i] = s.id end; return table.concat(o, ",") end

test("horizon: a hand-in across the world isn't worth the trip; the plan's next stop is", function()
  local r = H.Solve({
    start = { x = 0, y = 0 }, travel = walk, load = 5, cap = 25,
    stops = {
      { id = "accept A", x = 30, y = 0, service = 5, load = 1, plan = 1 },
      { id = "kill A", x = 120, y = 0, service = 240, plan = 2, needs = { "accept A" } },
      { id = "turnin A", x = 30, y = 0, service = 5, load = -1, plan = 3, needs = { "kill A" } },
      -- finished long ago, its hand-in in Stormwind: 6000 yd away; coming back for it later costs about 2 min
      { id = "turnin SW", x = 0, y = 6000, service = 5, load = -1, prize = 120 },
    },
  })
  assertEquals("accept A", r.first.id)
  assertTrue(not ids(r.seq):find("turnin SW"), "went to Stormwind: " .. ids(r.seq))
end)

test("horizon: while you're here - a hand-in a few yards off is done now", function()
  local r = H.Solve({
    start = { x = 0, y = 0 }, travel = walk, load = 5, cap = 25,
    stops = {
      { id = "accept A", x = 400, y = 0, service = 5, load = 1, plan = 1 },
      { id = "turnin here", x = 10, y = 5, service = 5, load = -1, prize = 120 },
    },
  })
  assertEquals("turnin here", r.first.id, "the hand-in next to you came after a 400-yd walk: " .. ids(r.seq))
end)

test("horizon: plan order is kept unless another order really saves time", function()
  -- A then B as planned; B is 20 yd closer: a few seconds isn't worth leaving the plan's order
  local function solve(bx)
    return H.Solve({
      start = { x = 0, y = 0 }, travel = walk,
      stops = {
        { id = "A", x = 100, y = 0, service = 10, plan = 1 },
        { id = "B", x = bx, y = 0, service = 10, plan = 2 },
      },
      anchor = { x = 200, y = 0 },
    })
  end
  assertEquals("A", solve(90).first.id, "reordered for a few seconds")
  -- B 50 yd back the other way, A and the anchor ahead: B first, then on - going ahead first and back for B is the
  -- longer walk by half a minute
  assertEquals("B", solve(-50).first.id)
  -- B right here and A far ahead with the anchor beyond A: B first saves a whole walk back
  local r = H.Solve({
    start = { x = 0, y = 0 }, travel = walk,
    stops = {
      { id = "A", x = 1000, y = 0, service = 10, plan = 1 },
      { id = "B", x = 5, y = 0, service = 10, plan = 2 },
    },
    anchor = { x = 1100, y = 0 },
  })
  assertEquals("B", r.first.id, "walked 1000 yd and back for plan order")
end)

test("horizon: the quest log's room - a pick-up waits for a hand-in when the log is full", function()
  local r = H.Solve({
    start = { x = 0, y = 0 }, travel = walk, load = 25, cap = 25,
    stops = {
      { id = "accept new", x = 5, y = 0, service = 5, load = 1, plan = 1 },
      { id = "turnin old", x = 50, y = 0, service = 5, load = -1, plan = 2 },
    },
  })
  assertEquals("turnin old", r.first.id)
  assertEquals("turnin old,accept new", ids(r.seq))
end)

test("horizon: pick-up before objectives before hand-in, whatever is nearer", function()
  local r = H.Solve({
    start = { x = 0, y = 0 }, travel = walk,
    stops = {
      { id = "accept", x = 300, y = 0, service = 5, load = 1, plan = 1 },
      { id = "obj", x = 2, y = 0, service = 60, plan = 2, needs = { "accept" } },
      { id = "turnin", x = 300, y = 0, service = 5, load = -1, plan = 3, needs = { "obj" } },
    },
  })
  assertEquals("accept,obj,turnin", ids(r.seq))
end)

test("horizon: nothing worth doing in the window -> the plan's first stop; first= scores keeping a target", function()
  local P = {
    start = { x = 0, y = 0 }, travel = walk,
    stops = { { id = "A", x = 50, y = 0, service = 5, plan = 1 }, { id = "B", x = 60, y = 0, service = 5, plan = 2 } },
  }
  local best = H.Solve(P)
  assertEquals("A", best.first.id)
  P.first = "B"
  local kept = H.Solve(P)
  assertEquals("B", kept.first.id)
  assertTrue(kept.score < best.score, "keeping B first should score lower than the best")
end)

test("horizon: 24 stops, 6 deep - a solve stays quick", function()
  local stops = {}
  for i = 1, 24 do stops[i] = { id = "s" .. i, x = (i * 37) % 400, y = (i * 91) % 400, service = 20, plan = i } end
  local t0 = debugprofilestop and debugprofilestop() or 0
  local r = H.Solve({ start = { x = 0, y = 0 }, travel = walk, stops = stops })
  local ms = (debugprofilestop and debugprofilestop() or 0) - t0
  assertTrue(r.first ~= nil)
  assertTrue(ms < 250, string.format("a solve took %.0f ms", ms))
end)

-- How good is the beam? Against exhaustive search, on random windows. The exhaustive search below tries every order
-- of every subset of the optional stops (all planned ones must be done), with the same rules (pick-up first, log room)
-- and the same objective the solver uses: prizes taken - time - the stability charge for planned stops passed over
-- (scaled by how far the leg goes) - the way on to the anchor. The solver's own whole-window order is scored the same
-- way, and the two compared.
local function evaluate(P, order)
  local stab, near0 = P.stability or H.STABILITY, P.stableNear or H.STABLE_NEAR
  local at, worth, load, done = P.start, 0, P.load or 0, {}
  local planned = {}
  for _, s in ipairs(P.stops) do if s.plan then planned[#planned + 1] = s end end
  for _, s in ipairs(order) do
    for _, n in ipairs(s.needs or {}) do if not done[n] then return nil end end
    load = load + (s.load or 0); if load > (P.cap or 25) then return nil end
    local t = P.travel(at, s)
    local passed = 0
    if s.plan then for _, p in ipairs(planned) do if p.plan < s.plan and not done[p.id] then passed = passed + 1 end end end
    worth = worth + (s.prize or 0) - t - (s.service or 0) - stab * math.min(1, t / near0) * passed
    done[s.id] = true; at = s
  end
  for _, p in ipairs(planned) do if not done[p.id] then return nil end end
  return worth - (P.anchor and P.travel(at, P.anchor) or 0)
end
local function exhaustive(P)
  local best = -math.huge
  local n = #P.stops
  local order, used = {}, {}
  local function rec()
    local v = evaluate(P, order)
    if v and v > best then best = v end
    for i = 1, n do
      if not used[i] then
        used[i] = true; order[#order + 1] = P.stops[i]
        rec()
        order[#order] = nil; used[i] = false
      end
    end
  end
  rec()
  return best
end
local function randomWindow(seed)
  local r = seed
  local function rnd() r = (r * 1103515245 + 12345) % 2147483648; return r / 2147483648 end
  local stops = {}
  -- two planned quests (pick-up, objective, hand-in at the giver) and a lone planned stop
  local q = 0
  for k = 1, 2 do
    q = q + 1
    local gx, gy = rnd() * 600, rnd() * 600
    stops[#stops + 1] = { id = "a" .. k, x = gx, y = gy, service = 8, load = 1, plan = #stops + 1 }
    stops[#stops + 1] = { id = "o" .. k, x = rnd() * 600, y = rnd() * 600, service = 60 + rnd() * 120, plan = #stops + 1, needs = { "a" .. k } }
    stops[#stops + 1] = { id = "t" .. k, x = gx, y = gy, service = 10, load = -1, plan = #stops + 1, needs = { "o" .. k } }
  end
  -- one or two optional prizes (a finished quest's hand-in, worth the trip back it saves)
  for k = 1, 1 + math.floor(rnd() * 2) do stops[#stops + 1] = { id = "p" .. k, x = rnd() * 600, y = rnd() * 600, service = 10, load = -1, prize = 20 + rnd() * 200 } end
  return { start = { x = rnd() * 600, y = rnd() * 600 }, stops = stops, travel = walk, load = math.floor(rnd() * 3), cap = 25, anchor = { x = rnd() * 600, y = rnd() * 600 }, K = #stops, B = 60 }
end

test("horizon: the beam finds the best window - against exhaustive search on 150 random windows", function()
  local worst, sum, exact, n = 0, 0, 0, 150
  for seed = 1, n do
    local P = randomWindow(seed)
    local res = H.Solve(P)
    local got = evaluate(P, res.seq)
    assertTrue(got ~= nil, "seed " .. seed .. ": the solver's order breaks a rule")
    local best = exhaustive(P)
    local gap = (best - got) / math.max(1, math.abs(best))
    if gap < 1e-9 then exact = exact + 1 end
    if gap > worst then worst = gap end
    sum = sum + gap
  end
  print(string.format("horizon vs exhaustive: %d of %d optimal, mean gap %.2f%%, worst %.2f%%", exact, n, 100 * sum / n, 100 * worst))
  -- (measured: optimal in 150 of 150 - held to that: at least 95% exactly optimal, and never more than 1% off)
  assertTrue(exact >= 0.95 * n, string.format("optimal in only %d of %d", exact, n))
  assertTrue(worst < 0.01, string.format("worst gap %.2f%%", 100 * worst))
end)
