-- Simulated player: plays a whole plan in the test world (_harness.lua withWorld: the real addon code, a fake game
-- around it) the way a player would - walks to each step, accepts, does objectives, hands in, flies, sails, binds,
-- levels as the plan expects - and only clicks the step done when nothing else would finish it. At every step the
-- harness checks that the card, the arrow and the first map pin agree, and any error the addon logs fails the run.
-- What the player ran into is returned as findings:
--   tick      a step it had to click done (the game would not finish it: the route can't tell when it's done)
--   back      a step it had already done came back on the card
--   stuck     clicking it done did not move the card on
-- Personas change how it plays: skip (skips some steps), fast (levels ahead of the plan, as in a group), slow
-- (levels behind), die (dies now and then), reload (the addon reloads mid-route), secret (the game hides answers, as
-- in dungeons). Random choices come from a seeded generator, so a run is repeatable.
-- usage: ForeverRoutePlayer.play(route, { persona = "clean", seed = 1, from = 1, to = nil, startLevel = 1 })
--        -> { played, actions, findings = { { kind, step, k, text } }, counts = { kind = n } }
local ns = ForeverRoute

local function rng(seed)
  local s = seed or 1
  return function(n) s = (s * 1103515245 + 12345) % 2147483648; return n and (s % n) + 1 or s / 2147483648 end
end

-- profiling: the addon's heavy functions, timed while the player plays (calls, total and worst ms), and the slowest
-- steps - the sim is where performance problems show before they reach the game (a hostile-town check on every road of
-- every trip once made the card 4x slower)
local clock = (os and os.clock and function() return os.clock() * 1000 end) or debugprofilestop
local PROFILED = { { "Engine", "Refresh" }, { "Engine", "Compute" }, { "Engine", "TravelFor" }, { "Engine", "UpdateFocus" }, { "Travel", "Plan" },
  { "Card", "Fill" }, { "Card", "Layout" }, { "Arrow", "SetTarget" }, { "Pins", "Update" }, { "Learn", "ZoneTick" } }
local function profileOn(prof)
  local saved = {}
  for _, p in ipairs(PROFILED) do
    local mod = ns[p[1]]
    local f = mod and mod[p[2]]
    if type(f) == "function" then
      local name = p[1] .. "." .. p[2]
      saved[#saved + 1] = { mod, p[2], f }
      local st = { n = 0, ms = 0, max = 0 }; prof.fn[name] = st
      mod[p[2]] = function(...)
        local t0 = clock()
        local a, b, c, d = f(...)
        local dt = clock() - t0
        st.n = st.n + 1; st.ms = st.ms + dt; if dt > st.max then st.max = dt end
        return a, b, c, d
      end
    end
  end
  return function() for _, s in ipairs(saved) do s[1][s[2]] = s[3] end end
end

local function play(route, opts)
  opts = opts or {}
  local prof = { fn = {}, steps = {} }
  local profileOff = profileOn(prof)
  local tStart = clock()
  local persona = opts.persona or "clean"
  local rand = rng(opts.seed)
  local steps = route.steps
  local out = { played = 0, actions = 0, findings = {}, counts = {}, prof = prof }
  -- a progress log, one line per action, flushed as it goes (opts.logFile): when a run hangs, its last lines say where
  local logf = opts.logFile and io and io.open and io.open(opts.logFile, "w")
  local function log(fmt, ...) if logf then logf:write(string.format("%.0f ", clock() - tStart) .. string.format(fmt, ...) .. "\n"); logf:flush() end end
  out.log = log
  local function find(kind, i, extra)
    local s = steps[i] or {}
    out.counts[kind] = (out.counts[kind] or 0) + 1
    if #out.findings < 200 then out.findings[#out.findings + 1] = { kind = kind, step = i, k = s.k, text = (s.name or s.text or s.dest or s.npc or "") .. (extra and (" - " .. extra) or "") } end
  end
  -- where the player starts: the first step with a place
  local first = steps[opts.from or 1]
  for j = opts.from or 1, #steps do if steps[j].m and steps[j].x then first = steps[j]; break end end
  local start = { m = first.m or 1426, x = first.x or 0.5, y = first.y or 0.5, level = opts.startLevel or 1, quests = {} }
  local sv = { savedChar = ForeverRouteChar, bind = GetBindLocation, isv = issecretvalue, afk = UnitIsAFK, char = ns.char, inst = IsInInstance, info = GetInstanceInfo, count = ns.GetItemCount, ts = IsTradeskillTrainer }
  -- the game around the player: the dungeon you're in, what's in your bags, what kind of trainer you talk to
  local inside, bags = nil, {}
  IsInInstance = function() return inside ~= nil, inside and "party" or "none" end
  GetInstanceInfo = function() return inside end
  ns.GetItemCount = function(id) return bags[id] or 0 end
  IsTradeskillTrainer = function() return false end
  local bindName, bindAt = nil, nil
  GetBindLocation = function() return bindName end
  local secretOn = false
  local SECRET = {}
  if persona == "secret" then
    issecretvalue = function(v) return v == SECRET end
    UnitIsAFK = function() return secretOn and SECRET or false end
  end
  local ok, err = pcall(ForeverRouteTest.withWorld, route, function(w)
    -- the flight paths you know live in your saved data (State.lua keeps ns.char.knownTaxi as the same table)
    ns.State.knownTaxi = {}; ns.char.knownTaxi = ns.State.knownTaxi
    local Q = w.quests
    local done = {} -- steps the player finished
    local level = start.level
    local function setLevel(L) if L and L > level then level = L; w:ding(L) end end
    -- travel the player does, timed: riding at your speed (Travel.Speed: mounted from 40), flights at flight speed,
    -- boats a fixed crossing; rides through the other faction's towns counted
    local HBD = LibStub("HereBeDragons-2.0")
    local function wpos(m, x, y) local a, b, c = HBD:GetWorldCoordinatesFromZone(x, y, m); if a then return { a, b, c } end end
    out.travel = { rideSec = 0, flySec = 0, boatSec = 0, flights = 0, boats = 0, hostile = 0, learned = 0 }
    local function move(m, x, y, how)
      local a, b = wpos(w.m, w.x, w.y), wpos(m, x, y)
      if a and b and a[3] == b[3] then
        local yd = math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2)
        if how == "fly" then out.travel.flySec = out.travel.flySec + yd / (ns.Travel.FLY or 22)
        elseif how == "boat" then out.travel.boatSec = out.travel.boatSec + (ns.Travel.BOAT or 120)
        else
          out.travel.rideSec = out.travel.rideSec + yd / ns.Travel.Speed()
          if ns.Travel.Through and ns.Travel.Through(a, b) then out.travel.hostile = out.travel.hostile + 1 end
        end
      elseif how == "boat" then out.travel.boatSec = out.travel.boatSec + (ns.Travel.BOAT or 120) end
      w:go(m, x, y)
    end
    local function goTo(s)
      if s.m and s.x then move(s.m, s.x, s.y or 0.5, "ride") end
    end
    -- backtracking: hubs are where the plan picks up and hands in (3+ accept/turn-in steps within HUB_YD); the rest
    -- is out in the wild. Going back to a wild spot you'd worked and left (WILD_YD cells, after being AWAY_YD away)
    -- is a wild revisit; leaving a hub for one thing far out and coming back is a thin trip. Back to a hub for hand-ins
    -- is the good pattern, not counted.
    local HUB_YD, WILD_YD, AWAY_YD = 80, 150, 300
    local hubs = {}
    do
      local pts = {}
      for _, t in ipairs(steps) do if (t.k == "accept" or t.k == "turnin") and t.m and t.x then local wp = wpos(t.m, t.x, t.y); if wp then pts[#pts + 1] = wp end end end
      for _, a in ipairs(pts) do
        local n = 0
        for _, b in ipairs(pts) do if a[3] == b[3] and math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2) < HUB_YD then n = n + 1 end end
        if n >= 3 then hubs[#hubs + 1] = a end
      end
    end
    local function atHub(wp) for _, h in ipairs(hubs) do if h[3] == wp[3] and math.sqrt((h[1] - wp[1]) ^ 2 + (h[2] - wp[2]) ^ 2) < HUB_YD then return true end end return false end
    out.back = { revisits = 0, thin = 0, wild = 0, excursions = 0 }
    local cells, lastWild, trip = {}, nil, nil -- cell -> { left = true once you were AWAY_YD away }
    local function noteAction(i, s)
      local wp = wpos(w.m, w.x, w.y); if not wp then return end
      if atHub(wp) then
        if trip and trip.n >= 1 then out.back.excursions = out.back.excursions + 1; if trip.n == 1 and trip.far then out.back.thin = out.back.thin + 1; find("thin", trip.step, "one thing out in the wild, then back") end end
        trip = { n = 0, far = false }
      else
        out.back.wild = out.back.wild + 1
        if trip then trip.n = trip.n + 1; trip.step = trip.step or i end
        local key = wp[3] .. ":" .. math.floor(wp[1] / WILD_YD) .. ":" .. math.floor(wp[2] / WILD_YD)
        local c = cells[key]
        if c and c.left then out.back.revisits = out.back.revisits + 1; find("revisit", i, "back to a wild spot worked earlier (step " .. c.first .. ")"); c.left = false end
        cells[key] = c or { first = i, at = wp }
        lastWild = key
      end
      -- every wild spot you are now far from has been left
      for _, c in pairs(cells) do if not c.left and c.at[3] == wp[3] and math.sqrt((c.at[1] - wp[1]) ^ 2 + (c.at[2] - wp[2]) ^ 2) > AWAY_YD then c.left = true end end
      if trip and not atHub(wp) then for _, h in ipairs(hubs) do if h[3] == wp[3] and math.sqrt((h[1] - wp[1]) ^ 2 + (h[2] - wp[2]) ^ 2) > AWAY_YD then trip.far = true end end end
    end
    local function learnFP(zone, npc)
      if not zone then return end
      local k = (npc or "FP") .. ", " .. zone
      if not ns.State.knownTaxi[k] then ns.State.knownTaxi[k] = true; out.travel.learned = out.travel.learned + 1 end
    end
    -- getting to a step in another zone the way the card says: the live trip's first leg, again and again (you only
    -- fly between flight paths you've learned; you start with none and walk)
    local function followTrip(s)
      for _ = 1, 60 do
        local trip = ns.Engine.TravelFor(s)
        local l = trip and trip.legs and trip.legs[1]
        if not l or trip.how == "aboard" then return true end
        if l.fp then learnFP(l.fp.zone, l.fp.npc) end -- "get the X flight path from Y there first"
        log("  trip leg %s -> %s %s,%s: %s", tostring(l.how), tostring(l.m), tostring(l.x), tostring(l.y), tostring(l.text))
        local nextLeg = trip.legs[2]
        local land = nextLeg and nextLeg.sm and { nextLeg.sm, nextLeg.sx, nextLeg.sy } or (s.m and s.x and { s.m, s.x, s.y }) or nil
        if l.how == "ride" or l.how == "via" then
          if not (l.m and l.x) then return false end
          local before = w.m .. w.x .. w.y
          move(l.m, l.x, l.y, "ride")
          if before == w.m .. w.x .. w.y then return false end -- the trip points where you stand: stuck
        elseif l.how == "fly" then
          if l.m and l.x then move(l.m, l.x, l.y, "ride") end -- to the flight master
          if not land then return false end
          w:taxi(true); move(land[1], land[2], land[3], "fly"); w:taxi(false); out.travel.flights = out.travel.flights + 1
        elseif l.how == "boat" then
          if l.m and l.x then move(l.m, l.x, l.y, "ride") end -- to the pier
          if not land then return false end
          w:board(true); move(land[1], land[2], land[3], "boat"); w:board(false); out.travel.boats = out.travel.boats + 1
        elseif l.how == "hearth" then
          ns.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 8690)
          if bindAt and bindAt.m then w:go(bindAt.m, bindAt.x or 0.5, bindAt.y or 0.5) elseif land then w:go(land[1], land[2], land[3]) end
        elseif l.how == "spell" then
          -- a class teleport (Teleport: Moonglade, Teleport: Ironforge): you land where the next leg starts
          if not land then return false end
          local before = w.m .. w.x .. w.y
          w:go(land[1], land[2], land[3])
          if before == w.m .. w.x .. w.y then return false end
        else
          return false
        end
      end
      return false
    end
    local function objectivesOf(q)
      -- the quest's objectives as the game would list them: one per objective step of that quest in the route
      local list = {}
      for _, t in ipairs(steps) do
        -- the game's wording: a kill/collect objective names the mob or item (the planner's match word); others are
        -- the task without its verb ("Read the Lay of Ameth'Aran" -> "Lay of Ameth'Aran read")
        local raw = tostring(t.text or "objective")
        -- only a verb goes ("Eastern Tower Ablaze" is already the game's wording: dropping "Eastern" made four
        -- objectives read the same)
        local verb, rest = raw:match("^(%a+) (.+)$")
        local VERBS = { use = 1, read = 1, open = 1, place = 1, find = 1, explore = 1, investigate = 1, locate = 1, free = 1, loot = 1, speak = 1, talk = 1, light = 1, burn = 1, search = 1, collect = 1, kill = 1, destroy = 1, plant = 1, visit = 1 }
        local txt = t.match or ((verb and VERBS[verb:lower()]) and ((rest:match("^the (.+)$") or rest) .. " done") or raw)
        if t.k == "obj" and t.q == q then list[#list + 1] = { text = txt .. ": 0/1", finished = false, step = t } end
      end
      return list
    end
    local function quest(q) return Q[q] end
    local function refreshComplete(q)
      local e = Q[q]; if not e then return end
      local all = true
      for _, o in ipairs(e.objectives) do if not o.finished then all = false end end
      e.complete = all
    end
    local guard, lastShown, sameCount = 0, nil, 0
    local shownCount = {}
    while true do
      guard = guard + 1
      if guard > #steps * 4 + 50 then find("stuck", lastShown or 0, "gave up after " .. guard .. " actions"); break end
      local i = ns.Engine.Shown()
      if not i or (opts.to and i > opts.to) then break end
      local s = steps[i]
      local tStep = clock()
      if done[i] then find("back", i) end
      -- the same step on the card again and again: a loop (two steps undoing each other) - report it and stop
      shownCount[i] = (shownCount[i] or 0) + 1
      if shownCount[i] > 6 then find("loop", i, "shown " .. shownCount[i] .. " times"); log("loop at step %d", i); break end
      if i == lastShown then sameCount = sameCount + 1 else sameCount = 0 end
      lastShown = i
      if sameCount >= 2 then
        -- acting on it changed nothing: click it done, as a player would
        find("tick", i, "nothing the player did finished it"); log("tick %d %s", i, tostring(s.k))
        ns.Engine.MarkDone(i); done[i] = true
        if ns.Engine.Shown() == i then find("stuck", i); ns.Engine.Skip(i) end
      else
        out.actions = out.actions + 1
        -- the persona's habits
        if persona == "skip" and rand(12) == 1 and s.k ~= "turnin" then ns.Engine.Skip(i); done[i] = true
        elseif persona == "die" and rand(25) == 1 then
          ns.Fire("PLAYER_DEAD"); w:wait(30)
          lastShown = nil -- a death isn't a try at the step
        elseif persona == "reload" and rand(40) == 1 then
          -- /reload: the saved tables are the ones the addon was using (ForeverRouteChar is ns.char), the plan is
          -- loaded again from its file and your path picked again, the quest log is the game's
          ForeverRouteChar = ns.char
          ns.Fire("ADDON_LOADED", "ForeverRoute"); ns.Fire("PLAYER_LOGIN"); w:wait(5)
          lastShown = nil
        else
          if persona == "secret" then secretOn = rand(3) == 1 end
          local k = s.k
          -- in another zone: get there the way the card says first
          local away = (k == "fly" and s.to and s.to ~= w.m) or (s.m and s.x and s.m ~= w.m and k ~= "hearth")
          if away and not followTrip(s) then find("trip", i, "the card's trip did not get there from map " .. tostring(w.m)) end
          -- out of the dungeon once its steps are behind you
          local insideStep = inside and k == "obj" and tostring(s.text or ""):find("(in " .. inside .. ")", 1, true)
          -- halfdungeon: a drop that won't drop - give up and leave (half the time)
          if insideStep and persona == "halfdungeon" and tostring(s.text):find("^Collect") and rand(2) == 1 then insideStep = false; log("gave up on %s", tostring(s.text)) end
          if inside and not insideStep then
            local name = inside
            inside = nil; ns.Fire("ZONE_CHANGED_NEW_AREA"); w:wait(2)
            -- rerun: back in twice more for the dungeon's mob XP (+50% in dungeons on Forever), a level a run
            if persona == "rerun" then
              for _ = 1, 2 do inside = name; ns.Fire("ZONE_CHANGED_NEW_AREA"); w:wait(2); inside = nil; ns.Fire("ZONE_CHANGED_NEW_AREA"); w:wait(2); setLevel(level + 1) end
              log("ran %s twice more", name)
            end
          end
          if inside and not insideStep then goTo(s) end
          if k == "accept" then
            goTo(s)
            if not Q[s.q] then Q[s.q] = { on = true, complete = false, objectives = objectivesOf(s.q) }; refreshComplete(s.q); if #Q[s.q].objectives == 0 then Q[s.q].complete = true end end
            w:quest(s.q, Q[s.q])
          elseif k == "obj" then
            goTo(s)
            local e = quest(s.q)
            if e then
              for _, o in ipairs(e.objectives) do if o.step == s then o.finished = true; o.text = o.text:gsub("0/1$", "1/1") end end
              refreshComplete(s.q); w:quest(s.q, e)
            end
          elseif k == "turnin" then
            goTo(s)
            local e = quest(s.q)
            if e then for _, o in ipairs(e.objectives) do o.finished = true end; e.complete = true end
            Q[s.q] = { on = false, done = true, objectives = {} }
            w:quest(s.q, Q[s.q])
          elseif k == "fly" and s.to then
            -- the trip above should have brought you; if not, you are carried there (and it's a finding)
            if w.m ~= s.to then
              local fm = ns.FLIGHT and ns.FLIGHT[s.to] and ns.FLIGHT[s.to][1]
              w:go(s.to, fm and fm[1] or 0.5, fm and fm[2] or 0.5)
            end
          elseif k == "fp" then
            -- talk to the flight master: you learn the path, and the flight map opens
            goTo(s)
            learnFP(s.zone, s.npc)
            ns.Fire("FR_TAXI_OPENED"); ns.Engine.Refresh()
          elseif k == "bind" then
            goTo(s)
            bindName = s.bind or s.zone; bindAt = { m = s.m, x = s.x, y = s.y }
            ns.Fire("HEARTHSTONE_BOUND"); w:wait(1)
          elseif k == "hearth" then
            ns.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 8690)
            if bindAt and bindAt.m then w:go(bindAt.m, bindAt.x or 0.5, bindAt.y or 0.5) else goTo(s) end
          elseif k == "train" then
            goTo(s); ns.Fire("TRAINER_SHOW"); ns.Fire("TRAINER_CLOSED"); ns.Engine.Refresh()
          elseif k == "goto" and tostring(s.text or ""):match("^Run (.+)$") and persona == "nodungeon" then
            ns.Engine.Skip(i); done[i] = true; log("skipped the dungeon %s", tostring(s.text))
          elseif k == "goto" and tostring(s.text or ""):match("^Run (.+)$") then
            -- the instance's own name (the step says "Run The Stockade with a group"; plans before the dungeon field)
            goTo(s); inside = s.dungeon or tostring(s.text):match("^Run (.-) with a group") or tostring(s.text):match("^Run (.+)$"); ns.Fire("ZONE_CHANGED_NEW_AREA"); w:wait(2)
          elseif k == "bonus" then
            goTo(s); if s.item then bags[s.item] = 1 end; ns.Fire("BAG_UPDATE"); ns.Engine.Refresh()
          elseif k == "grind" then
            setLevel((s.level or level) + 1)
          else
            goTo(s) -- goto, note: be there; the player clicks it done if nothing else does
          end
        end
        if ns.Engine.Status(i) == "done" or ns.Engine.Shown() ~= i then done[i] = true; out.played = out.played + 1; if s.k == "obj" or s.k == "accept" or s.k == "turnin" then noteAction(i, s) end end
        -- level as the plan expects at this step (a group levels faster, a slow player slower)
        local planned = s.lvl and (s.lvl + (persona == "fast" and 2 or persona == "slow" and -1 or 0)) or nil
        if planned then setLevel(planned) end
        prof.steps[#prof.steps + 1] = { i = i, k = s.k, text = s.name or s.text or "", ms = clock() - tStep }
        log("step %d %s %s | level %d map %s | %.0f ms | shown now %s", i, tostring(s.k), tostring(s.name or s.text or s.dest or ""), level, tostring(w.m), clock() - tStep, tostring(ns.Engine.Shown()))
        -- memory: the Lua heap (this addon, the bot and the plan) every 200 steps, after a full collection - what is
        -- still held, not garbage waiting (the simulator's own memory is sampled from outside)
        if i % 200 == 0 then
          local okB, before = pcall(collectgarbage, "count"); pcall(collectgarbage, "collect")
          local okA, after = pcall(collectgarbage, "count")
          if okB and okA then log("mem step %d: Lua heap %.1f MB (%.1f MB before a collection)", i, after / 1024, before / 1024) end
        end
      end
    end
  end, { at = start, anyTarget = true })
  profileOff(); prof.wallMs = clock() - tStart
  if logf then logf:write("end\n"); logf:close() end
  GetBindLocation, issecretvalue, UnitIsAFK, ns.char = sv.bind, sv.isv, sv.afk, sv.char
  ForeverRouteChar = sv.savedChar
  IsInInstance, GetInstanceInfo, ns.GetItemCount, IsTradeskillTrainer = sv.inst, sv.info, sv.count, sv.ts
  if not ok then error(err, 0) end
  return out
end

-- one line per finding kind, with the first few examples
local function summary(r, name)
  local L = { string.format("%s: played %d steps in %d actions", name or "run", r.played, r.actions) }
  local t = r.travel
  local P = r.prof
  if P and P.wallMs then
    L[#L + 1] = string.format("  profile: %.1f s for %d actions (%.0f ms each)", P.wallMs / 1000, r.actions, P.wallMs / math.max(1, r.actions))
    local fns = {}; for name, st in pairs(P.fn) do if st.n > 0 then fns[#fns + 1] = { name, st } end end
    table.sort(fns, function(a, b) return a[2].ms > b[2].ms end)
    local parts = {}
    for k = 1, math.min(8, #fns) do local f = fns[k]; parts[#parts + 1] = string.format("%s %dx %.0f ms (worst %.1f)", f[1], f[2].n, f[2].ms, f[2].max) end
    L[#L + 1] = "    time in: " .. table.concat(parts, "; ")
    table.sort(P.steps, function(a, b) return a.ms > b.ms end)
    local slow = {}
    for k = 1, math.min(5, #P.steps) do local s = P.steps[k]; slow[#slow + 1] = string.format("#%d %s %s %.0f ms", s.i, tostring(s.k), tostring(s.text):sub(1, 30), s.ms) end
    L[#L + 1] = "    slowest steps: " .. table.concat(slow, "; ")
  end
  local b = r.back
  if b then L[#L + 1] = string.format("  backtracking: %d wild revisits, %d thin trips (of %d trips out from a hub), %d steps out in the wild", b.revisits, b.thin, b.excursions, b.wild) end
  if t then L[#L + 1] = string.format("  travel: riding %.1f h, flying %.1f h (%d flights), boats %d; %d flight paths learned; %d rides through the other faction's towns",
    t.rideSec / 3600, t.flySec / 3600, t.flights, t.boats, t.learned, t.hostile) end
  local by = {}
  for _, f in ipairs(r.findings) do by[f.kind] = by[f.kind] or {}; if #by[f.kind] < 6 then table.insert(by[f.kind], "#" .. f.step .. " " .. tostring(f.k) .. " " .. f.text) end end
  for kind, n in pairs(r.counts) do L[#L + 1] = string.format("  %s x%d: %s", kind, n, table.concat(by[kind] or {}, "; ")) end
  return table.concat(L, "\n")
end

ForeverRoutePlayer = { play = play, summary = summary }
