-- Checkpoints of the simulated player (tests/_ckpt.lua, _player.lua; tools/simckpt.js): the state written at a leg
-- boundary comes back the same, and a run resumed from one ends where the full run ends.
local ns = ForeverRoute
local CK = ForeverRouteCkpt

test("checkpoint: a state round-trips, shared tables stay shared", function()
  local shared = { a = 1 }
  local root = { s = "line\nnext \"quoted\" \\ back", n = 1794439431, f = 0.1 + 0.2, neg = -3.25, big = 2 ^ 53, inf = 1 / 0,
    t = true, [5] = "five", [true] = "yes", list = { 1, 2, 3 }, one = shared, two = shared, deep = { deeper = { shared } } }
  root.self = root
  local text, lost = CK.encode(root)
  assertEquals(0, #lost)
  local d = assert(CK.decode(text))
  assertEquals(root.s, d.s); assertEquals(root.n, d.n); assertEquals(root.f, d.f); assertEquals(root.neg, d.neg)
  assertEquals(root.big, d.big); assertEquals(1 / 0, d.inf); assertEquals(true, d.t); assertEquals("five", d[5]); assertEquals("yes", d[true])
  assertEquals(3, #d.list)
  assertTrue(d.one == d.two and d.deep.deeper[1] == d.one, "shared tables are one table again")
  assertTrue(d.self == d, "a table that holds itself")
  -- what can't be written is listed, not silently dropped
  local _, lost2 = CK.encode({ fn = function() end, ok = 1 })
  assertEquals(1, #lost2)
  assertTrue(lost2[1]:find("fn", 1, true) ~= nil, lost2[1])
  -- the plan's stamp and path id swapped for the new plan's, as values and as keys
  local s = CK.subst({ ran = { ["accept:1#1"] = 111 }, title = "path:A", progress = { ["path:A"] = { x = 1 } } }, { [111] = 222, ["path:A"] = "path:B" })
  assertEquals(222, s.ran["accept:1#1"]); assertEquals("path:B", s.title); assertNotNil(s.progress["path:B"]); assertNil(s.progress["path:A"])
  assertEquals('{"a":[1,2],"b":"x\\"y","c":true}', CK.json({ a = { 1, 2 }, b = 'x"y', c = true }))
  assertNil(CK.decode("return 1 +"))
end)

-- a small plan in Duskwood and Redridge: six quests, then a flight, then four more
local function route()
  local steps = {}
  local function add(s) s.id = #steps + 1; steps[#steps + 1] = s end
  for q = 1, 6 do
    local x = 0.30 + q * 0.05
    add({ k = "accept", q = 300 + q, name = "Q" .. q, npc = "Giver", m = 1431, x = 0.75, y = 0.48, r = 6, sec = 1, lvl = 20 + q })
    add({ k = "obj", q = 300 + q, text = "Kill 5 Wolf" .. q, match = "Wolf" .. q, m = 1431, x = x, y = 0.40, r = 40, sec = 1, lvl = 20 + q })
    add({ k = "turnin", q = 300 + q, name = "Q" .. q, npc = "Giver", m = 1431, x = 0.75, y = 0.48, r = 6, sec = 1, lvl = 20 + q })
  end
  add({ k = "fly", dest = "Redridge Mountains", to = 1433, text = "Redridge Mountains", sec = 2, lvl = 27 })
  for q = 7, 10 do
    local x = 0.20 + q * 0.04
    add({ k = "accept", q = 300 + q, name = "Q" .. q, npc = "Marshal", m = 1433, x = 0.30, y = 0.45, r = 6, sec = 2, lvl = 20 + q })
    add({ k = "obj", q = 300 + q, text = "Kill 5 Gnoll" .. q, match = "Gnoll" .. q, m = 1433, x = x, y = 0.60, r = 40, sec = 2, lvl = 20 + q })
    add({ k = "turnin", q = 300 + q, name = "Q" .. q, npc = "Marshal", m = 1433, x = 0.30, y = 0.45, r = 6, sec = 2, lvl = 20 + q })
  end
  return { id = "path:Duskwood-Redridge", title = "test", meta = { legs = "Duskwood > Redridge" },
    sections = { { title = "Darkshire", zone = "Duskwood" }, { title = "Lakeshire", zone = "Redridge Mountains" } }, steps = steps }
end

test("checkpoint: a run resumed at a leg ends where the full run ends", function()
  local tmp = os.getenv and (os.getenv("TEMP") or os.getenv("TMP"))
  if not (tmp and io and io.open) then return end -- (no folder to write to: nothing to check)
  local prefix = "frckpt-test-" .. tostring(math.floor((GetTime() % 1) * 1e6)) .. "-"
  local saved = { routes = ForeverRouteRoutes, data = ForeverRouteData }
  local function play(opts)
    local r = route()
    ForeverRouteRoutes = { r }
    local res = ForeverRoutePlayer.play(r, opts)
    -- (the profile is timings - every line of it goes, however many the profiler prints)
    local kept = {}
    for line in (ForeverRoutePlayer.summary(res, "clean") .. "\n"):gmatch("(.-)\n") do
      if not (line:find("profile:", 1, true) or line:find("time in:", 1, true) or line:find("asked by:", 1, true) or line:find("slowest steps:", 1, true)) then kept[#kept + 1] = line end
    end
    return res, table.concat(kept, "\n")
  end
  local function ck(resume) return { bounds = { 7, 14, 22 }, nsteps = 31, look = 2, dir = tmp, prefix = prefix, resume = resume } end
  local ok, err = pcall(function()
    local full, fullSum = play({ persona = "skip", seed = 3, ckpt = ck() })
    local meta2 = CK.read(tmp .. "/" .. prefix .. "002.lua")
    if not meta2 then error("the run wrote the checkpoint of leg 2 (" .. tostring(full.ckpt) .. ", " .. full.played .. " played, current " .. tostring(ns.Engine.current) .. ")", 0) end
    local res, sum = play({ persona = "skip", seed = 3, ckpt = ck(tmp .. "/" .. prefix .. "002.lua") })
    assertTrue(tostring(res.ckpt):find("^resumed from leg 2") ~= nil, tostring(res.ckpt))
    assertEquals(fullSum, sum, "the resumed run reports what the full run did")
    assertEquals(full.played, res.played)
    -- a checkpoint that can't be read: played from level 1, and said so. (Its findings are not compared: two runs from
    -- level 1 in one session can differ - the addon keeps some state of its own between them, and GetTime is real time)
    local f = io.open(tmp .. "/" .. prefix .. "bad.lua", "wb"); f:write("-- META {}\nreturn (\n-- end\n"); f:close()
    local res2 = play({ persona = "skip", seed = 3, ckpt = ck(tmp .. "/" .. prefix .. "bad.lua") })
    assertTrue(tostring(res2.ckpt):find("played from level 1") ~= nil, tostring(res2.ckpt))
    assertEquals(full.played, res2.played)
  end)
  for _, n in ipairs({ "001", "002", "003", "bad" }) do os.remove(tmp .. "/" .. prefix .. n .. ".lua") end
  ForeverRouteRoutes, ForeverRouteData = saved.routes, saved.data
  if not ok then error(err, 0) end
end)
