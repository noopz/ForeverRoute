-- Forever Route: core namespace, saved settings, events and slash commands.
local ADDON, ns = ...
ForeverRoute = ns
ns.name = ADDON

ns.DEFAULTS = {
  scale = 1.0,
  cardWidth = 360,
  showNext = 3,          -- upcoming steps under the current one
  arrow = true,
  arrowScale = 1.0,
  pins = true,
  pinCount = 4,          -- current + next N-1 on the maps
  pathLine = true,       -- dotted walking path on the world map and minimap
  trails = true,         -- record where you walk in the capital cities (improves city paths)
  locked = false,
  rewardHint = true,     -- highlight the best quest reward
  combatFade = false,    -- fade the card while in combat (off: testers disliked it)
  autoQuest = false,     -- accept route quests and hand in finished ones (no reward choice) by themselves
  markTarget = true,     -- the Target button (and its key) also puts a star on the NPC
}

-- ns.Is(fn, ...): a yes/no question to the game (UnitOnTaxi, UnitIsAFK, IsFlying, IsIndoors...). Forever hides some
-- answers from addons (secret values: in dungeons and in combat); testing one is an error, so a hidden or missing
-- answer counts as "no". Every such question goes through here (install.sh refuses raw calls).
function ns.Is(fn, ...)
  if not fn then return false end
  local ok, v = pcall(fn, ...)
  if not ok or v == nil or (issecretvalue and issecretvalue(v)) then return false end
  return v and true or false
end
local listeners = {}
local function isGameEvent(event)
  if event:find("^FR_") then return false end -- our own messages
  if C_EventUtils and C_EventUtils.IsEventValid then return C_EventUtils.IsEventValid(event) end
  return true
end
-- ns.On("EVENT", fn): pub/sub for our FR_* messages; game events are registered on demand
function ns.On(event, fn)
  if not listeners[event] then
    listeners[event] = {}
    if isGameEvent(event) then pcall(ns.frame.RegisterEvent, ns.frame, event) end
  end
  table.insert(listeners[event], fn)
end
-- Error log: every error in our code is kept (deduplicated, with a count) in ForeverRouteDB.log with what we were doing
-- at the time (route, step, zone, level, build), so it can be read from SavedVariables after a /reload. It also goes to
-- the normal error handler (BugSack), but only the first few times per message, so one bug can't flood the screen.
ns.VERSION = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version") or (GetAddOnMetadata and GetAddOnMetadata(ADDON, "Version")) or "?"
local logged = {}
function ns.LogError(where, err)
  local msg = tostring(err)
  local key = where .. "|" .. msg
  local n = (logged[key] or 0) + 1
  logged[key] = n
  if ForeverRouteDB then
    ForeverRouteDB.log = ForeverRouteDB.log or {}
    local log = ForeverRouteDB.log
    local e
    for _, x in ipairs(log) do if x.key == key then e = x; break end end
    if not e then
      local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
      e = { key = key, where = where, msg = msg, stack = debugstack and debugstack(2, 12, 0) or nil, count = 0,
        first = time and time() or 0, version = ns.VERSION, route = ns.char and ns.char.routeId, step = ns.Engine and ns.Engine.current,
        map = mapID, level = UnitLevel and UnitLevel("player") }
      -- what you were doing: the step on the card, the plan, and the addon's last few decisions (enough to fix most
      -- bugs from the save alone). Gathered under pcall: this runs inside an error already.
      pcall(function()
        local i = ns.Engine and ns.Engine.Shown and ns.Engine.Shown()
        local s = i and ForeverRouteData and ForeverRouteData.steps and ForeverRouteData.steps[i]
        if s then e.shown = string.format("%d %s q%s %s", i, tostring(s.k), tostring(s.q or "-"), tostring(s.text or s.name or ""):sub(1, 60)) end
        e.routeId = ForeverRouteData and ForeverRouteData.id
        e.plan = ForeverRoutePlan and ForeverRoutePlan.generated
        e.combat = InCombatLockdown and InCombatLockdown() or nil
        e.taxi = ns.Is(UnitOnTaxi, "player") or nil
        local w, recent = ForeverRouteDB.why, {}
        if type(w) == "table" then for j = math.max(1, #w - 5), #w do local x = w[j]; if x then recent[#recent + 1] = tostring(x.k) .. ": " .. tostring(x.x):sub(1, 90) end end end
        e.recent = recent
      end)
      table.insert(log, 1, e)
      while #log > 40 do table.remove(log) end
    end
    e.count = e.count + 1; e.last = time and time() or 0
  end
  if n <= 3 then geterrorhandler()(msg) end
end
-- wrap a function so its errors are logged instead of thrown (for OnUpdate scripts and timers)
ns.stats = {} -- name -> { n, total, max } (ms), since the last perf sample
local clock = debugprofilestop
function ns.Time(name, ms)
  local st = ns.stats[name]; if not st then st = { n = 0, total = 0, max = 0 }; ns.stats[name] = st end
  st.n = st.n + 1; st.total = st.total + ms; if ms > st.max then st.max = ms end
end
function ns.Guard(where, fn)
  return function(...)
    local t0 = clock and clock()
    local ok, err = pcall(fn, ...)
    if t0 then ns.Time(where, clock() - t0) end
    if not ok then ns.LogError(where, err) end
    return err
  end
end
function ns.Fire(event, ...)
  for _, fn in ipairs(listeners[event] or {}) do
    local ok, err = pcall(fn, ...)
    if not ok then ns.LogError(event, err) end
  end
end

-- item API: Forever moved these into C_Item (the old globals are gone)
ns.GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
ns.GetItemCount = (C_Item and C_Item.GetItemCount) or GetItemCount
ns.GetItemIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
ns.GetItemStats = (C_Item and C_Item.GetItemStats) or GetItemStats

ns.frame = CreateFrame("Frame")
ns.frame:SetScript("OnEvent", function(_, event, ...) ns.Fire(event, ...) end)
ns.frame:RegisterEvent("ADDON_LOADED")

local function copyDefaults(dst, src)
  for k, v in pairs(src) do
    if dst[k] == nil then dst[k] = type(v) == "table" and CopyTable(v) or v end
  end
end

-- one plan file (Route.lua) for all your characters: each has its own block (ForeverRouteByChar["Name-Realm"]), written
-- by that character's companion; only yours is loaded. An older file with a single plan is used as it is.
-- On a fresh login the name can still read "Unknown" when the addon loads; then the key saved last time is used, and the
-- plan is looked up again at PLAYER_LOGIN.
local function plain(s) return (tostring(s or ""):lower():gsub("[^%w]", "")) end
function ns.CharKey()
  local okN, name = pcall(UnitName, "player")
  local okR, realm = pcall(GetRealmName)
  name = okN and type(name) == "string" and not (issecretvalue and issecretvalue(name)) and name or nil
  realm = okR and type(realm) == "string" and not (issecretvalue and issecretvalue(realm)) and realm or nil
  if not name or name == "" or name == UNKNOWNOBJECT or name == "Unknown" or not realm or realm == "" then
    return ForeverRouteChar and ForeverRouteChar.charKey or nil
  end
  return (name .. "-" .. realm):gsub("%s", "") .. ""
end
-- your block: the exact key, else the same key ignoring case, spaces and punctuation (the planner names blocks after
-- the WTF folder, which can spell the realm differently), else the one block with your name. Never another character's.
function ns.FindMyPlan(key)
  if not key then return nil end
  if ForeverRouteByChar[key] then return ForeverRouteByChar[key], key end
  -- the block this character matched before (the game's realm name can differ from the folder the planner names it after)
  local before = ForeverRouteChar and ForeverRouteChar.planBlock
  if before and ForeverRouteByChar[before] and plain(before:match("^([^-]+)")) == plain(key:match("^([^-]+)")) then return ForeverRouteByChar[before], before end
  local want, wantName = plain(key), plain(key:match("^([^-]+)"))
  local byName, nByName
  for k, f in pairs(ForeverRouteByChar) do
    if plain(k) == want then return f, k end
    if plain(k:match("^([^-]+)")) == wantName then byName, nByName = { f, k }, (nByName or 0) + 1 end
  end
  if nByName == 1 then return byName[1], byName[2] end
end
-- the built-in plan for your race and class (Starter.lua, made by tools/starter.js): followed when there is no plan of
-- your own (an addon-only install, or before the companion has planned for a new character)
-- does this install have the companion? It writes the plan file (Route.lua: ForeverRouteByChar); an addon-site install
-- never has one. What only the companion reads (walking trails, learning) is recorded only then.
function ns.HasCompanion() return type(ForeverRouteByChar) == "table" and next(ForeverRouteByChar) ~= nil end
function ns.StarterKey()
  local okR, _, race = pcall(UnitRace, "player")
  local okC, _, class = pcall(UnitClass, "player")
  if not (okR and okC) or type(race) ~= "string" or type(class) ~= "string" then return nil end
  race = plain(race)
  if race == "scourge" then race = "undead" end -- the game's token for undead; the plans are named undead_<class>
  -- the Horde's Skyborne (Windshaper Skyborne): skybornehorde, told apart by the faction
  if race:find("skyborne", 1, true) then
    local okF, f = pcall(UnitFactionGroup, "player")
    race = (race:find("windshaper", 1, true) or (okF and f == "Horde")) and "skybornehorde" or "skyborne"
  end
  return race .. "-" .. plain(class)
end
-- The built-in plan for your race and class. The plans come as one load-on-demand addon per faction
-- (ForeverRoute_Plans_Alliance / _Horde, tools/bundle-plans.js), each plan as text: only yours is made into code and
-- the rest is let go (51 addons, one per race and class, filled the game's addon list). An older install's per-plan
-- addon (ForeverRoute_Starter_<race>_<class>) still works.
function ns.LoadStarter(sk)
  local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
  if not load then return false end
  local okF, fac = pcall(UnitFactionGroup, "player")
  local sides = (okF and fac == "Horde") and { "Horde", "Alliance" } or { "Alliance", "Horde" }
  for _, side in ipairs(sides) do
    if not (type(ForeverRoutePlanSources) == "table" and ForeverRoutePlanSources[sk]) then pcall(load, "ForeverRoute_Plans_" .. side) end
  end
  local src = type(ForeverRoutePlanSources) == "table" and ForeverRoutePlanSources[sk]
  ForeverRoutePlanSources = nil -- every other plan's text goes
  if src then
    local chunk, err = loadstring(src, "plan " .. sk)
    if chunk then
      local ok, e = pcall(chunk)
      if not ok and ns.LogError then ns.LogError("plan", e) end
    elseif ns.LogError then ns.LogError("plan", err) end
    collectgarbage("collect")
  else
    pcall(load, "ForeverRoute_Starter_" .. sk:gsub("%-", "_"))
  end
  return type(ForeverRouteStarter) == "table" and ForeverRouteStarter[sk] ~= nil
end
function ns.LoadMyPlan()
  local key, f, found
  if type(ForeverRouteByChar) == "table" then
    key = ns.CharKey()
    f, found = ns.FindMyPlan(key)
  elseif ForeverRouteRoutes or ForeverRouteData then
    return true -- an older single-plan file
  end
  ns.planKey = { tried = key, found = found }
  if type(f) == "function" then
    if ForeverRouteChar then ForeverRouteChar.charKey = key; ForeverRouteChar.planBlock = found end
  else
    local sk = ns.StarterKey()
    if sk and not (type(ForeverRouteStarter) == "table" and ForeverRouteStarter[sk]) then ns.LoadStarter(sk) end
    f = type(ForeverRouteStarter) == "table" and sk and ForeverRouteStarter[sk]
    if type(f) ~= "function" then return false end
    ns.planKey.starter = sk
  end
  local ok, err = pcall(f)
  if not ok and ns.LogError then ns.LogError("plan", err) end
  return ok
end
local starterSaid
function ns.StarterNote()
  if starterSaid or not (ns.planKey and ns.planKey.starter) then return end
  starterSaid = true
  C_Timer.After(5, function() ns.Print("No plan of your own for this character yet: following the built-in plan for your race and class (steps you've already done are skipped).") end)
end

-- flight masters and vendors come for both factions (FlightMasters.lua, Vendors.lua: ns.FLIGHT_BY, ns.VENDORS_BY);
-- yours are ns.FLIGHT and ns.VENDORS. Picked when the addon loads and again at login (the faction is surely known then)
function ns.UseFaction()
  local ok, f = pcall(UnitFactionGroup, "player")
  local side = (ok and f == "Horde") and "Horde" or "Alliance"
  if ns.FLIGHT_BY and ns.FLIGHT_BY[side] then ns.FLIGHT = ns.FLIGHT_BY[side] end
  if ns.VENDORS_BY and ns.VENDORS_BY[side] then ns.VENDORS = ns.VENDORS_BY[side] end
  return side
end
ns.On("ADDON_LOADED", function(name)
  if name ~= ADDON then return end
  ns.UseFaction()
  ns.hasPlan = ns.LoadMyPlan()
  ForeverRouteDB = ForeverRouteDB or {}
  ForeverRouteChar = ForeverRouteChar or {}
  copyDefaults(ForeverRouteDB, ns.DEFAULTS)
  ns.db = ForeverRouteDB
  -- combat fade was on by default and testers disliked it: off once for everyone (anyone can turn it back on)
  if not ns.db.combatFadeReset then ns.db.combatFade = false; ns.db.combatFadeReset = true end
  ns.char = ForeverRouteChar
  -- stay on the path you were on; nothing switches unless you choose (the zone you asked for is the one exception)
  ns.SelectRoute(ns.char.routeTitle, true)
  -- a path you asked for has arrived: switch to it once (you can switch away; it won't pull you back)
  if ns.char.requestZone and ns.char.requestHandled ~= ns.char.requestZone then
    for _, r in ipairs(ns.MainRoutes()) do
      if r.requested == ns.char.requestZone then ns.SelectRoute(r.id, true); ns.char.requestHandled = ns.char.requestZone; C_Timer.After(5, function() ns.Print("Now on the path you asked for, starting in " .. r.requested .. ".") end); break end
    end
  end
  ns.Fire("FR_LOADED")
end)
-- the name wasn't known yet when the addon loaded: look again now, and show the plan if it's found
-- maps the planner has no world bounds for (Forever's new ones: Zephras Isle 2521 and its second map 2665, Riverglades 2548, Shen'dralas 2652, Mount Hyjal 2482): the client
-- knows them for any map, wherever you are - recorded at login for the planner (tools/learn.js -> map-extras.json)
ns.MAPS_TO_MEASURE = { 2521, 2665, 2548, 2652, 2482 }
function ns.RecordMapBounds()
  if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) or not ForeverRouteDB then return 0 end
  ForeverRouteDB.mapBounds = type(ForeverRouteDB.mapBounds) == "table" and ForeverRouteDB.mapBounds or {}
  local n = 0
  for _, id in ipairs(ns.MAPS_TO_MEASURE) do
    local ok, inst, tl = pcall(C_Map.GetWorldPosFromMapPos, id, CreateVector2D(0, 0))
    local ok2, _, br = pcall(C_Map.GetWorldPosFromMapPos, id, CreateVector2D(1, 1))
    if ok and ok2 and tl and br and tl.GetXY then
      local top, left = tl:GetXY()
      local bottom, right = br:GetXY()
      if left and right and top and bottom and not (issecretvalue and (issecretvalue(left) or issecretvalue(top))) then
        local info = C_Map.GetMapInfo and C_Map.GetMapInfo(id)
        ForeverRouteDB.mapBounds[id] = { left = left, right = right, top = top, bottom = bottom, inst = inst, name = info and info.name }
        n = n + 1
      end
    end
  end
  return n
end
ns.On("PLAYER_LOGIN", function()
  ns.UseFaction()
  pcall(ns.RecordMapBounds)
  local key = ns.CharKey()
  if ForeverRouteChar and key then ForeverRouteChar.charKey = key end
  -- on the built-in plan: your own may be findable now that the name is known
  local onStarter = ns.planKey and ns.planKey.starter
  if ns.hasPlan and ns.Routes()[1] and not onStarter then return end
  if onStarter and ns.Routes()[1] and not (type(ForeverRouteByChar) == "table" and ns.FindMyPlan(key)) then ns.StarterNote(); return end
  ns.hasPlan = ns.LoadMyPlan()
  if ns.Routes()[1] then
    ns.SelectRoute(ns.char and ns.char.routeTitle, false)
    ns.StarterNote()
  else
    C_Timer.After(5, function()
      ns.Print("No plan for " .. tostring(key) .. " in Route.lua" .. (type(ForeverRouteByChar) == "table" and " (plans there: " .. (function() local t = {} for k in pairs(ForeverRouteByChar) do t[#t + 1] = k end return table.concat(t, ", ") end)() .. ")" or "") .. ". Is the companion running for this character?")
    end)
  end
end)

-- Several planned paths (ForeverRouteRoutes) or one route (ForeverRouteData). Progress flags are kept per route.
function ns.Routes() return ForeverRouteRoutes or (ForeverRouteData and { ForeverRouteData }) or {} end
-- main paths (not branches) for the path switcher
function ns.MainRoutes()
  local out = {}
  for _, r in ipairs(ns.Routes()) do if not r.branch and not r.dungeon and not r.zoneRoute then out[#out + 1] = r end end
  return out
end
-- ready-made routes into each of the best zones at your level (the planner builds them with every plan): picking one
-- switches at once, no replan to wait for
function ns.ZoneRoutes()
  local out = {}
  for _, r in ipairs(ns.Routes()) do if r.zoneRoute then out[#out + 1] = r end end
  return out
end
function ns.ZoneRouteFor(zone)
  for _, r in ipairs(ns.ZoneRoutes()) do if r.zoneName == zone then return r end end
end
function ns.DungeonRoutes()
  local out = {}
  for _, r in ipairs(ns.Routes()) do if r.dungeon then out[#out + 1] = r end end
  return out
end
-- dungeon routes are a side trip: remember the path you were on, and go back to it with its progress untouched
function ns.EnterDungeonRoute(id)
  local r = ns.RouteById(id); if not r then return end
  if ForeverRouteData and not ForeverRouteData.dungeon then ns.char.returnTo = ForeverRouteData.id end
  ns.SelectRoute(id)
  ns.Print((r.special and "Side trip: " or "Dungeon route: ") .. (r.dungeonName or r.title) .. ". Your leveling path is kept - \"Back to my path\" on the card returns you to it.")
end
function ns.LeaveDungeonRoute()
  -- a replan while you were on the trip may have renamed your path: find it by its zone order, not the top path
  local was = ns.char.returnTo
  local back = ns.ResolvePath(was) or ns.MainRoutes()[1]
  if not back then return end
  if was and back.id ~= was then
    if ns.char.pinnedPath == was then ns.char.pinnedPath = back.id end
    if ns.Why then ns.Why("path", "your path " .. tostring(was) .. " was renamed by a replan; back on " .. tostring(back.id) .. " (closest match to your zone order)") end
  end
  ns.char.returnTo = back.id
  ns.SelectRoute(back.id); ns.Print("Back on your path: " .. (back.title or ""))
end
-- a route's steps; branches and dungeon routes are kept packed until needed (see the planner's paths.js)
local unpackFn = loadstring or load
function ns.Steps(r)
  if not r then return {} end
  if not r.steps and r.packed then
    local fn = unpackFn and unpackFn("return {" .. r.packed .. "}")
    local ok, t = pcall(fn or error)
    if ok and type(t) == "table" then r.steps = t else ns.LogError("unpack", "could not unpack route " .. tostring(r.id)); r.steps = {} end
  end
  return r.steps or {}
end
-- quest IDs in a route without unpacking it
function ns.QuestIds(r)
  if not r then return {} end
  if not r._qids then
    local t = {}
    if r.questIds then for id in r.questIds:gmatch("%d+") do t[tonumber(id)] = true end
    else for _, s in ipairs(ns.Steps(r)) do if s.q then t[s.q] = true end end end
    r._qids = t
  end
  return r._qids
end
function ns.RouteById(id) for _, r in ipairs(ns.Routes()) do if r.id == id then return r end end end
-- a path's zones in order, each once ("Wetlands > Ashenvale > Wetlands" -> Wetlands, Ashenvale)
local function zoneOrder(legs)
  local out, seen = {}, {}
  for z in (legs or ""):gmatch("[^>]+") do
    z = z:gsub("^%s+", ""):gsub("%s+$", "")
    if z ~= "" and not seen[z] then seen[z] = true; out[#out + 1] = z end
  end
  return out
end
-- how well a path (its zones) continues the one you followed (old zones): the zones the two have in common in the same
-- order, over the next PATH_LOOK zones of each, and more for starting in the same zone - what you do next counts most.
-- "Wetlands > Duskwood > Ashenvale > Desolace" is continued by "Wetlands > Ashenvale > Arathi > Desolace" (3 in order,
-- same start), not by "Duskwood > Ashenvale > Stranglethorn > Wetlands" (2 in order): matching only from the old second
-- zone on once took a player standing in the Wetlands off to Ashenvale.
ns.PATH_LOOK = 6
function ns.PathContinuity(old, legs)
  local n, m = math.min(#old, ns.PATH_LOOK), math.min(#legs, ns.PATH_LOOK)
  if n == 0 or m == 0 then return 0 end
  local prev = {}; for j = 0, m do prev[j] = 0 end
  for i = 1, n do
    local row = { [0] = 0 }
    for j = 1, m do
      if old[i] == legs[j] then row[j] = prev[j - 1] + 1 else row[j] = math.max(prev[j], row[j - 1]) end
    end
    prev = row
  end
  local score = prev[m]
  if score > 0 and old[1] == legs[1] then score = score + 1.5 end
  return score
end
-- the route a saved id or title stands for, without switching to it. -> route, exact (false: matched by zone order)
-- A replan can rename your path (its zones changed a little), and a plan made from an older save does not know the
-- path you switched to since: then it is the path that best continues your zone order (ns.PathContinuity), the one
-- the planner marked as yours on a tie, rather than a different path.
function ns.ResolvePath(title)
  if not title then return nil end
  for _, r in ipairs(ns.Routes()) do if r.id == title or r.title == title then return r, true end end
  if not ns.char.routeLegs then return nil end
  local old = zoneOrder(ns.char.routeLegs)
  local best, bestScore = nil, 0
  for _, r in ipairs(ns.MainRoutes()) do
    local score = ns.PathContinuity(old, zoneOrder(r.meta and r.meta.legs))
    if score > 0 and r.continues then score = score + 0.25 end
    if score > bestScore then best, bestScore = r, score end
  end
  -- the planner marks the path it planned as the continuation of yours: take that one if nothing matched
  if not best then for _, r in ipairs(ns.MainRoutes()) do if r.continues then best = r; break end end end
  return best, false
end
-- your saved path is not in this plan and the one you continue on goes somewhere else next (its next three zones
-- differ): said once, in chat and in /fr why - a path never changes under you without a word. -> the text, or nil
function ns.PathSwitchNote(title, pick)
  if not (pick and ns.char and ns.char.routeLegs and pick.meta and pick.meta.legs) then return nil end
  local old, now = zoneOrder(ns.char.routeLegs), zoneOrder(pick.meta.legs)
  local same = true
  for k = 1, 3 do if old[k] ~= now[k] then same = false end end
  if same then return nil end
  local function head(t) local o = {}; for k = 1, math.min(3, #t) do o[k] = t[k] end; return table.concat(o, " > ") end
  return "The new plan does not have the path you were on (" .. head(old) .. "). You are now on the closest one: " .. head(now) .. ". The Paths window (/fr paths) has the others."
end
-- pick by id or by title (titles from older saves); a renamed path is found by its zone order (ns.ResolvePath);
-- nothing at all falls back to the first main path
function ns.SelectRoute(title, quiet)
  local list = ns.Routes()
  local pick, exact = ns.ResolvePath(title)
  pick = pick or ns.MainRoutes()[1] or list[1]
  if not exact and title and ns.char.routeLegs and pick then
    if ns.Why then ns.Why("path", "your path " .. tostring(title) .. " is not in the new plan; continuing on " .. tostring(pick.id) .. " (closest match to your zone order)") end
    -- your own pick (Paths window, a zone choice) follows the path to its new name
    if ns.char.pinnedPath == title and pick.id and not pick.branch and not pick.dungeon then ns.char.pinnedPath = pick.id end
    local note = ns.PathSwitchNote(title, pick)
    ns.pathSwitch = note and { from = title, to = pick.id, text = note } or nil
    if note and C_Timer and C_Timer.After then C_Timer.After(5, function() ns.Print(note) end) end
  end
  -- leaving a packed route: drop its unpacked steps (they come back from the string if picked again)
  local old = ForeverRouteData
  if old and old ~= pick and old.packed then old.steps = nil end
  if pick then ns.Steps(pick) end
  ForeverRouteData = pick
  ns.char.routeTitle = pick and (pick.id or pick.title) or nil
  if pick and not pick.branch and not pick.dungeon and pick.meta and pick.meta.legs then ns.char.routeLegs = pick.meta.legs end
  ns.char.progress = ns.char.progress or {}
  local rid = pick and pick.id or "none"
  local p = ns.char.progress[rid] or {}
  ns.char.progress[rid] = p
  p.skipped, p.manualDone, p.history = p.skipped or {}, p.manualDone or {}, p.history or {}
  -- ticks saved by step number (older versions) land on the wrong steps once a route is regenerated: drop them
  for _, t in ipairs({ p.skipped, p.manualDone }) do for k in pairs(t) do if type(k) == "number" then t[k] = nil end end end
  for n = #p.history, 1, -1 do local h = p.history[n]; for _, id in ipairs(h.ids or {}) do if type(id) == "number" then table.remove(p.history, n); break end end end
  ns.char.skipped, ns.char.manualDone, ns.char.history = p.skipped, p.manualDone, p.history
  ns.char.routeId = rid
  -- drop progress tables of routes that no longer exist
  local live = {}; for _, r in ipairs(list) do live[r.id or "none"] = true end
  for k in pairs(ns.char.progress) do if not live[k] then ns.char.progress[k] = nil end end
  if not quiet then ns.Fire("FR_ROUTE_CHANGED"); if ns.Engine then ns.Engine.view = nil; ns.Engine.Refresh() end end
end
-- "where next?" at a zone boundary: the choice for step i of the current route, if it's still open.
-- It stays on that step (your pick is marked) until you leave, so you can change your mind; a branch shows its parent's choice on step 1.
function ns.ChoiceFor(i)
  local data = ForeverRouteData
  if not (data and i) then return nil end
  local owner, at = data, i
  if data.branch then
    if i ~= 1 then return nil end
    owner = ns.RouteById(data.parent); at = data.branchAt
    if not owner then return nil end
  end
  for _, c in ipairs(owner.choices or {}) do
    if c.at == at then
      local key = (owner.id or "") .. "@" .. at
      return c, owner, key
    end
  end
end
-- take an option: stay on the main path, or switch to the branch planned for that zone
function ns.TakeChoice(opt, owner, key)
  ns.char.choices = ns.char.choices or {}
  ns.char.choices[key] = opt.zone
  local want = opt.route or owner.id
  ns.char.pinnedPath = owner.id -- choosing at a zone boundary is your own pick
  if ForeverRouteData ~= ns.RouteById(want) then
    ns.SelectRoute(want)
    ns.Print("Heading to " .. opt.zone .. (opt.next and (" - then " .. opt.next) or "") .. ".")
  else
    ns.Fire("FR_STEP", ns.Engine.Shown())
  end
end

function ns.ShowOnMap(i)
  local s = i and ForeverRouteData and ForeverRouteData.steps[i]
  if not s then return end
  local m = s.m
  if not m and ns.Engine.TravelTarget then m = ns.Engine.TravelTarget(s) end
  if not m and s.to then m = s.to end
  if not m then ns.Print("That step has no map spot (it's inside a dungeon, or a note)."); return end
  if InCombatLockdown() then ns.Print("Can't open the map in combat."); return end
  if i ~= ns.Engine.current then ns.Engine.view = i end
  ns.Fire("FR_STEP", ns.Engine.Shown()) -- pins follow the step being looked at
  local ok, err = pcall(function()
    if WorldMapFrame and not WorldMapFrame:IsShown() then
      if OpenWorldMap then OpenWorldMap(m) elseif ToggleWorldMap then ToggleWorldMap() end
    end
    if WorldMapFrame and WorldMapFrame.SetMapID then WorldMapFrame:SetMapID(m) end
  end)
  if not ok then ns.LogError("map", err) end
end

function ns.Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cffffd25aForever Route|r " .. tostring(msg))
  -- everything the addon tells you is also kept (last 200) in ForeverRouteDB.chat, so it can be read from your saves
  if ForeverRouteDB then
    if type(ForeverRouteDB.chat) ~= "table" then ForeverRouteDB.chat = {} end
    local t = ForeverRouteDB.chat
    t[#t + 1] = { t = time(), x = tostring(msg):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") }
    while #t > 200 do table.remove(t, 1) end
  end
end

-- keybinding labels (Bindings.xml)
BINDING_HEADER_FOREVERROUTE = "Forever Route"
BINDING_NAME_FOREVERROUTE_SKIP = "Skip current step"
BINDING_NAME_FOREVERROUTE_BACK = "Look at previous step"
BINDING_NAME_FOREVERROUTE_UNDO = "Undo last skip / done"
BINDING_NAME_FOREVERROUTE_TOGGLE = "Show / hide the card"
BINDING_NAME_FOREVERROUTE_LIST = "Show the whole route"
_G["BINDING_NAME_CLICK ForeverRouteTargetButton:LeftButton"] = "Forever Route Targeting"

SLASH_FOREVERROUTE1 = "/fr"
SLASH_FOREVERROUTE2 = "/route"
SlashCmdList.FOREVERROUTE = function(msg)
  msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if msg == "" or msg == "toggle" then ns.Fire("FR_TOGGLE")
  elseif msg == "list" then ns.Fire("FR_TOGGLE_LIST")
  elseif msg == "paths" then ns.Fire("FR_TOGGLE_PATHS")
  elseif msg == "why" then ns.WhyPrint(15)
  elseif msg == "save" then if ns.Card and ns.Card.Save then ns.Card.Save() else ReloadUI() end
  elseif msg == "dungeons" or msg == "dungeon" or msg == "trips" or msg == "bag" then ns.Fire("FR_TOGGLE_DUNGEONS")
  elseif msg == "card reset" then ns.db.uiScale, ns.db.scale = nil, 1; ns.Fire("FR_SETTINGS"); ns.db.hidden = nil; if ns.Card and ns.Card.ResetPos then ns.Card.ResetPos() end
  elseif msg == "target reset" then if ns.Card and ns.Card.ResetTarget then ns.Card.ResetTarget() else ns.db.targetPos = nil end
  elseif msg == "storage" then ns.Storage.Print()
  elseif msg == "scale" or msg:find("^scale ") then ns.Style.SlashScale(msg:sub(7))
  elseif msg == "news" then ns.Fire("FR_NEWS")
  elseif msg == "report" then ns.Fire("FR_REPORT", false)
  elseif msg == "report full" then ns.Fire("FR_REPORT", true)
  elseif msg == "logcheck" or msg == "cleanup" then ns.Fire("FR_TOGGLE_LOGCHECK")
  elseif msg == "nope" then ns.Engine.Nope()
  elseif msg == "rejoin" then ns.Engine.Rejoin()
  elseif msg == "nav" or msg == "pins" then for _, l in ipairs(ns.Nav.Report()) do ns.Print(l) end
  elseif msg == "perf" then
    local p = ns.Perf()
    ns.Print(string.format("memory %s  ·  refresh %.2f ms  ·  progress %.2f ms  ·  %d routes, %d unpacked", p.memoryKB and string.format("%.1f MB", p.memoryKB / 1024) or "?", p.refreshMs or 0, p.progressMs or 0, p.routes, p.unpacked))
  elseif msg == "trails" then
    local n, per = ns.Trails.Count(); local bits = {}
    for k, v in pairs(per) do bits[#bits + 1] = k .. " " .. v end
    ns.Print(string.format("city walking recorded: %d points%s. Saved on /reload or logout; the planner uses it next run.", n, #bits > 0 and (" (" .. table.concat(bits, ", ") .. ")") or ""))
  elseif msg == "log" then
    local log = ForeverRouteDB.log or {}
    if #log == 0 then ns.Print("no errors logged.") end
    for k = 1, math.min(5, #log) do local e = log[k]; ns.Print(string.format("%dx [%s] %s", e.count or 1, e.where or "?", e.msg or "?")) end
  elseif msg == "log clear" then ForeverRouteDB.log = {}; ns.Print("error log cleared.")
  elseif msg == "skip" then ns.Engine.Skip()
  elseif msg == "back" then ns.Engine.Back()
  elseif msg == "undo" then ns.Engine.Undo()
  elseif msg == "reset" then ns.char.skipped, ns.char.manualDone, ns.char.history = {}, {}, {}; ns.Engine.Refresh(); ns.Print("skips and manual ticks cleared.")
  elseif msg == "lock" then ns.db.locked = not ns.db.locked; ns.Fire("FR_SETTINGS"); ns.Print(ns.db.locked and "locked." or "unlocked.")
  elseif msg == "arrow" then ns.db.arrow = not ns.db.arrow; ns.Fire("FR_SETTINGS")
  elseif msg == "demo" then ns.Demo.Start()
  elseif msg == "snapshot" then ns.State.Snapshot("manual"); ns.Print("snapshot saved - written to disk on /reload or logout.")
  elseif msg == "options" or msg == "config" then ns.Fire("FR_OPEN_OPTIONS")
  else
    ns.Print("/fr - card · /fr list - whole route · /fr paths - choose a path · /fr dungeons - dungeon routes · /fr logcheck - what to abandon · /fr rejoin - pick the built-in plan up at your level · /fr report - copy a bug report · /fr news - what changed · /fr log - recent errors · /fr nav - where the game says you, the step and the minimap are · /fr skip · /fr back · /fr undo · /fr lock · /fr arrow · /fr demo · /fr options")
  end
end

-- /fr perf: what the addon costs in your game (memory, time per refresh), also saved with the snapshot
-- memOnly (at logout): just the memory, keeping the last timing - the timing runs ten route rebuilds, too long there
function ns.Perf(memOnly)
  if UpdateAddOnMemoryUsage then pcall(UpdateAddOnMemoryUsage) end
  local mem = GetAddOnMemoryUsage and select(2, pcall(GetAddOnMemoryUsage, ADDON)) or nil
  if memOnly then
    local p = ns.char.perf or {}
    p.memoryKB, p.at = type(mem) == "number" and math.floor(mem) or nil, time and time()
    ns.char.perf = p
    return p
  end
  local t = debugprofilestop
  local refresh, progress
  if t then
    local a = t(); for _ = 1, 10 do ns.Engine.Refresh() end; local b = t(); for _ = 1, 10 do ns.Engine.Progress() end; local c = t()
    refresh, progress = (b - a) / 10, (c - b) / 10
  end
  local unpacked = 0; for _, r in ipairs(ns.Routes()) do if r.steps then unpacked = unpacked + 1 end end
  local p = { memoryKB = type(mem) == "number" and math.floor(mem) or nil, refreshMs = refresh, progressMs = progress, routes = #ns.Routes(), unpacked = unpacked, at = time and time() }
  ns.char.perf = p
  return p
end

local function perfSample()
  if UpdateAddOnMemoryUsage then pcall(UpdateAddOnMemoryUsage) end
  local okm, mem = pcall(GetAddOnMemoryUsage or error, ADDON)
  local e = { at = time and time() or 0, memoryKB = okm and type(mem) == "number" and math.floor(mem) or nil, level = UnitLevel("player"), route = ns.char and ns.char.routeId } -- no map id: Forever may hand it out as a protected value that can't be saved
  for name, st in pairs(ns.stats) do e[name] = string.format("%d calls, avg %.2f ms, max %.2f ms", st.n, st.n > 0 and st.total / st.n or 0, st.max) end
  wipe(ns.stats)
  ns.char.perfLog = ns.char.perfLog or {}
  table.insert(ns.char.perfLog, e)
  while #ns.char.perfLog > 20 do table.remove(ns.char.perfLog, 1) end
end
-- failures go to the error log (they used to be swallowed, which hid a broken logger)
local guardedSample = ns.Guard("perf", perfSample)
ns.On("FR_LOADED", function() C_Timer.After(60, guardedSample); C_Timer.NewTicker(300, guardedSample) end)
ns.On("PLAYER_LOGOUT", guardedSample)
ns._perfSample = perfSample -- for tests
