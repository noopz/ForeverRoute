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
  smartNext = true,      -- the live solver picks what to do next from where you are (Next.lua); off: the plan order and the old reordering
  autoFly = false,       -- at a flight master, take the flight the card's trip needs
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
  -- the zone routes every plan of the faction shares are kept once (tools/bundle-plans.js): back into yours only
  if src and type(ForeverRoutePlanShared) == "table" then
    local shared = ForeverRoutePlanShared
    src = src:gsub("\n%-%-@zr ([^@\n]+)@", function(id) return shared[id] end)
  end
  ForeverRoutePlanSources, ForeverRoutePlanShared = nil, nil -- every other plan's text goes
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
  ns.SelectRoute(ns.SavedRoute(), true)
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
    ns.SelectRoute(ns.SavedRoute(), false)
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
-- a zone route that fits a level: a built-in plan's tree has one per zone and level band (r.level: planned from the
-- trunk at that level - tools/zone-routes.js); the newest one you are in reach of (its level up to 2 above yours). A
-- plan's own zone routes carry no level: the first for the zone, as before
local function fits(r, level) return not r.level or not level or (r.level <= level + 2 and r.level >= level - 6) end
function ns.ZoneRouteFor(zone, level)
  level = level or (UnitLevel and UnitLevel("player")) or nil
  local best
  for _, r in ipairs(ns.ZoneRoutes()) do
    if r.zoneName == zone and fits(r, level) then
      if not r.level then return r end
      if not best or r.level > best.level then best = r end
    end
  end
  return best
end
-- the zones you could go to now (one route each, the best fit for your level): what "fancy a change?" offers
function ns.ZoneRoutesAt(level)
  level = level or (UnitLevel and UnitLevel("player")) or nil
  local seen, out = {}, {}
  for _, r in ipairs(ns.ZoneRoutes()) do
    if r.zoneName and not seen[r.zoneName] and r.level and fits(r, level) then
      local pick = ns.ZoneRouteFor(r.zoneName, level)
      if pick then seen[r.zoneName] = true; out[#out + 1] = pick end
    end
  end
  table.sort(out, function(a, b) return (a.xph or 0) > (b.xph or 0) end)
  return out
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
  ns.char.chosenTrip = id -- (you picked it: kept across logins - ns.SavedRoute)
  ns.SelectRoute(id)
  ns.Print((r.special and "Side trip: " or "Dungeon route: ") .. (r.dungeonName or r.title) .. ". Your leveling path is kept - \"Back to my path\" on the card returns you to it.")
end
-- a zone you picked (a zone route, ns.ZoneRouteFor): the route you were on is remembered, so "Planned route" in the
-- zone picker goes back to it - picked up where it still has something for you at your level (UI/Paths.lua)
function ns.EnterZoneRoute(id)
  local d = ForeverRouteData
  -- (and where you were on it: "Planned route" picks up from there, not from its first step)
  if d and not d.dungeon and not d.special and not d.zoneRoute and not d.branch then ns.char.returnTo = d.id; ns.char.returnAt = ns.Engine and ns.Engine.current end
  ns.SelectRoute(id)
end
-- the planned route's next zone at your level: the first quest step on it you haven't done that isn't gray to you
-- (Stranglethorn at 39, after a detour to Arathi, is passed over: the route picks up in the zone after it)
local QUEST_KIND = { accept = true, turnin = true, obj = true }
function ns.PlannedNextZone()
  local d, S, E = ForeverRouteData, ns.State, ns.Engine
  -- on your planned route: the engine knows what's done - the first quest step from where you are that isn't
  if d and not d.zoneRoute and not d.dungeon and not d.special and E and E.current then
    local list = ns.Steps(d)
    for i = E.current, #list do
      local s = list[i]
      if s and s.q and s.zone and QUEST_KIND[s.k] and E.Status(i) ~= "done" then return s.zone, d end
    end
    return nil, d
  end
  -- on a zone you picked: the route you came from (ns.EnterZoneRoute), what's left of it at your level
  local r = (d and d.zoneRoute and ns.ResolvePath(ns.char.returnTo)) or ns.MainRoutes()[1]
  if not r then return nil end
  local list = ns.Steps(r)
  local from = (r.id == ns.char.returnTo and tonumber(ns.char.returnAt)) or 1
  for j = math.max(1, math.min(from, #list)), #list do
    local s = list[j]
    if s.q and s.zone and QUEST_KIND[s.k] and not S.IsCompleted(s.q)
      and not (s.k == "accept" and S.OnQuest(s.q)) and not (s.k ~= "accept" and not S.OnQuest(s.q))
      and not (E and E.Outlevelled and E.Outlevelled(s)) then
      return s.zone, r
    end
  end
  return nil, r
end

-- The XP a zone still holds for you: its route walked in order from where you are - a pick-up taken once you could
-- (not done, not gray, its prerequisites handed in or handed in earlier on the walk, its level reached), its hand-in
-- paying at the level you'd be by then - until nothing more there is yours to take: the wall that sends you elsewhere.
-- Quests that open up as you level in the zone count; ones you would outlevel before you get to them don't.
local wallCache = {}
for _, e in ipairs({ "FR_STATE", "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "QUEST_LOG_UPDATE", "PLAYER_LEVEL_UP", "FR_ROUTE_CHANGED" }) do
  ns.On(e, function() wallCache = {} end)
end
function ns.ZoneXpLeft(r, level)
  if not (r and ns.QuestXp) then return nil end
  local k = tostring(r.id) .. ":" .. tostring(level)
  if wallCache[k] then return wallCache[k] end
  local S, E = ns.State, ns.Engine
  local T = ns.XP_TO_LEVEL or {}
  local L = level
  local xpNow = (UnitXP and UnitXP("player")) or 0
  local total, taken, handed = 0, {}, {}
  local function gain(n)
    total = total + n; xpNow = xpNow + n
    while L < 60 and T[L] and T[L] > 0 and xpNow >= T[L] do xpNow = xpNow - T[L]; L = L + 1 end
  end
  local function preMet(q)
    local pre = ns.QUEST_PRE and ns.QUEST_PRE[q]
    if not pre then return true end
    for _, p in ipairs(pre.g or {}) do if not (S.IsCompleted(p) or handed[p]) then return false end end
    if pre.s and #pre.s > 0 then
      for _, p in ipairs(pre.s) do if S.IsCompleted(p) or handed[p] then return true end end
      return false
    end
    return true
  end
  for _, s in ipairs(ns.Steps(r)) do
    local q = s.q
    if q and not S.IsCompleted(q) and not handed[q] then
      if s.k == "accept" and not taken[q] and not S.OnQuest(q) then
        local gray = E and E.GrayAt and tonumber(s.level) and s.level > 0 and s.level <= E.GrayAt(L)
        if not gray and not (s.minLevel and L < s.minLevel) and preMet(q) and not (ns.Avail and ns.Avail.Unavailable(q))
          and not (E and E.Excluded and E.Excluded(s)) and not (ns.char.nope and ns.char.nope[q]) then taken[q] = true end
      elseif s.k == "turnin" and (taken[q] or S.OnQuest(q)) then
        handed[q] = true
        gain(ns.QuestXp(q, L) or 0)
      end
    end
  end
  wallCache[k] = total
  return total
end

-- What "Where to?" offers (UI/Paths.lua, the card, the simulated player): one row per zone you could go to now -
-- the zone routes for your level (a built-in plan's tree), the zones your companion plan ranked, and your planned
-- route's next zone, which is always the best pick ("BEST NEXT"). A row: { zone, key, xph, route, questsLeft,
-- handIns, here, best, planned }. Zones whose route has nothing left for you are left out.
local zoneKey = function(z) return (ns.Style and ns.Style.ShortZone and ns.Style.ShortZone(z)) or z end
ns.ZoneKey = zoneKey
local leftCache = {}
-- (cleared on every quest or level change: kept by time, a count outlived a quest's hand-in and sent the zone-hopper to
-- Redridge for quests it had already done)
for _, e in ipairs({ "FR_STATE", "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "QUEST_LOG_UPDATE", "PLAYER_LEVEL_UP", "FR_ROUTE_CHANGED" }) do
  ns.On(e, function() leftCache = {} end)
end
-- (the simulated world changes quests without the game's events: its player clears the counts before it looks)
function ns.ZoneCountsChanged() leftCache = {} end
-- a quest's prerequisites met (ns.QUEST_PRE: g all of these handed in, s any one of them)
function ns.PrereqsMet(q)
  local pre = ns.QUEST_PRE and ns.QUEST_PRE[q]
  if not pre then return true end
  local S = ns.State
  for _, p in ipairs(pre.g or {}) do if not S.IsCompleted(p) then return false end end
  if pre.s and #pre.s > 0 then
    local any = false
    for _, p in ipairs(pre.s) do if S.IsCompleted(p) then any = true; break end end
    if not any then return false end
  end
  return true
end
-- what a zone route still has for you: quests you can take there now (not done, not gray to you, their prerequisites
-- handed in) and quests in your log with work or a hand-in there. Counting every quest id on the route made a zone
-- you had finished look like 19 quests (the zone-hopper went back to Ashenvale it had already done)
local QUEST_STEP = { accept = true, turnin = true, obj = true }
-- where a quest is done on your plan (its pick-up or hand-in step): { name, zone }, for "needs X (zone) first"
local function onPlan(q)
  local d = ForeverRouteData
  local r = (d and d.zoneRoute and ns.ResolvePath(ns.char.returnTo)) or (d and not d.zoneRoute and d) or ns.MainRoutes()[1]
  for _, s in ipairs((r and ns.Steps(r)) or {}) do if s.q == q and s.name then return s.name, s.zone end end
end
-- also returns why the zone matters to you: a quest in your log with work there (continues), and the first quest there
-- held up by a prerequisite you haven't handed in (need = { q, prerequisite })
local function questsLeft(r, level)
  local k = tostring(r.id) .. ":" .. tostring(level)
  local c = leftCache[k]
  if c then return c.n, c.cont, c.need, c.ids end
  local n, S, E, seen = 0, ns.State, ns.Engine, {}
  local cont, need
  local ids = {} -- (the quests counted: for the simulated player's report)
  for _, s in ipairs(ns.Steps(r)) do
    local q = s.q
    if q and QUEST_STEP[s.k] and not seen[q] and not S.IsCompleted(q) then
      -- a quest you carry: only work to do there, or its hand-in there with the quest ready (a hand-in waiting on work
      -- elsewhere left Wetlands looking like it had quests when the card had nothing there)
      if S.OnQuest(q) then
        -- (an objective step counts only while its own objective is unfinished, as the engine has it: Baron Longshore's
        -- kill done in Stonetalon, his head handed in in Ratchet, made Stonetalon look like it had a quest left)
        local o = s.k == "obj" and not S.QuestReady(q) and (s.unknown or not (E and E.ObjectiveFor and (E.ObjectiveFor(s) or {}).finished))
        -- (and a ready hand-in only when the engine would send you to it: not a gray one, Baron Longshore at 23)
        if o or (s.k == "turnin" and S.QuestReady(q) and not (E and E.GrayHandIn and E.GrayHandIn(s))) then seen[q] = true; n = n + 1; cont = cont or s.name; ids[#ids + 1] = q end
      elseif not need and s.k == "accept" and not (s.minLevel and level < s.minLevel) and not ns.PrereqsMet(q) then
        local pre = ns.QUEST_PRE and ns.QUEST_PRE[q]
        for _, p in ipairs((pre and (pre.g or pre.s)) or {}) do if not S.IsCompleted(p) then need = { q = q, pre = p }; break end end
      elseif s.k == "accept" and not (s.minLevel and level < s.minLevel) and ns.PrereqsMet(q) and not (E and (
          (E.Outlevelled and E.Outlevelled(s)) or (E.Excluded and E.Excluded(s)) or (E.Breadcrumbed and E.Breadcrumbed(s))
          -- gray by level alone: whether it leads to something worth it depends on the route you are on, and on the zone's
          -- own route it often leads nowhere (A Free Lunch counted from your plan, outlevelled once you got to Redridge)
          or (E.GrayAt and tonumber(s.level) and s.level > 0 and s.level <= E.GrayAt(level))))
          and not (ns.Avail and ns.Avail.Unavailable(q)) then seen[q] = true; n = n + 1; ids[#ids + 1] = q end
    end
  end
  leftCache[k] = { n = n, cont = cont, need = need, ids = ids }
  return n, cont, need, ids
end
-- a map id's zone: as the plan's own steps name it (each route scanned once), else as the game names the map
local mapZone, scanned = {}, {}
local function learnMaps(r)
  if not r or scanned[r] then return end
  scanned[r] = true
  for _, s in ipairs(ns.Steps(r)) do if s.m and s.zone and mapZone[s.m] == nil then mapZone[s.m] = s.zone end end
end
local function zoneOfMap(m)
  if not m then return nil end
  if mapZone[m] == nil and C_Map and C_Map.GetMapInfo then
    local ok, info = pcall(C_Map.GetMapInfo, m)
    if ok and info and info.name then mapZone[m] = info.name end
  end
  return mapZone[m] or nil
end
function ns.ZoneChoices()
  local level = (UnitLevel and UnitLevel("player")) or 1
  local d, S = ForeverRouteData, ns.State
  local rows, byKey = {}, {}
  local function add(name, xph, route)
    if not name then return nil end
    local k = zoneKey(name)
    local r = byKey[k]
    if not r then r = { zone = name, key = k, handIns = 0 }; byKey[k] = r; rows[#rows + 1] = r end
    r.xph = r.xph or xph
    r.route = r.route or route
    return r
  end
  for _, r in ipairs(ns.ZoneRoutesAt(level)) do add(r.zoneName, r.xph, r) end
  for _, z in ipairs((ForeverRoutePlan and ForeverRoutePlan.zones) or {}) do add(z.name, z.xph, ns.ZoneRouteFor(z.name, level)) end
  local plannedZone = ns.PlannedNextZone()
  local best = add(plannedZone)
  if best then best.best, best.planned = true, true end
  -- where you are: the zone you picked, else the zone you're standing in (not the next step's: on your way to
  -- Desolace from Gnomeregan, Desolace was marked YOU'RE HERE)
  learnMaps(d); for _, r in ipairs(rows) do learnMaps(r.route) end
  local hereZone = d and d.zoneRoute and d.zoneName
  if not hereZone and ns.Engine and ns.Engine.HereMap then hereZone = zoneOfMap(ns.Engine.HereMap()) end
  local here = hereZone and byKey[zoneKey(hereZone)]
  if here then here.here = true end
  -- quests you finished whose hand-in is in a zone on the list
  if ns.Engine and ns.Engine.LogEnders then
    for q, e in pairs(ns.Engine.LogEnders()) do
      if S.QuestReady(q) and not S.IsCompleted(q) then
        local row = byKey[zoneKey(zoneOfMap(e.m))]
        if row then row.handIns = row.handIns + 1 end
      end
    end
  end
  local out = {}
  for _, r in ipairs(rows) do
    if r.route then
      local cont, need
      r.questsLeft, cont, need, r.leftIds = questsLeft(r.route, level)
      r.xpLeft = ns.ZoneXpLeft and ns.ZoneXpLeft(r.route, level) or nil
      -- one reason per row: hand-ins waiting, else a quest you carry, else what it needs first (Paths.lua)
      if cont then r.continues = cont end
      if need then local name, zone = onPlan(need.pre); if name then r.needs = { name = name, zone = zone } end end
    end
    -- (a zone whose quests need a start you haven't done stays, saying so)
    if r.planned or r.here or r.handIns > 0 or not r.route or r.needs or (r.questsLeft or 0) > 0 then out[#out + 1] = r end
  end
  table.sort(out, function(a, b)
    if (a.best and true or false) ~= (b.best and true or false) then return a.best and true or false end
    if (a.here and true or false) ~= (b.here and true or false) then return a.here and true or false end
    if a.handIns ~= b.handIns then return a.handIns > b.handIns end
    if (a.route and true or false) ~= (b.route and true or false) then return a.route and true or false end -- (a ready route before one to ask for)
    return (a.xpLeft or 0) > (b.xpLeft or 0)
  end)
  return { rows = out, best = best, level = level }
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
  ns.char.chosenTrip = nil
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
  -- the same path, or the same path with the zones you've finished dropped off the front (Westfall > Redridge >
  -- Duskwood, Westfall done: Redridge > Duskwood > Wetlands) - not a switch, nothing to say
  for s = 0, 2 do
    local same = true
    for k = 1, 3 do if now[k] ~= nil and now[k] ~= old[k + s] and not (old[k + s] == nil and k > 1) then same = false end end
    if same then return nil end
  end
  local function head(t) local o = {}; for k = 1, math.min(3, #t) do o[k] = t[k] end; return table.concat(o, " > ") end
  return "The new plan does not have the path you were on (" .. head(old) .. "). You are now on the closest one: " .. head(now) .. ". The Paths window (/fr paths) has the others."
end
-- pick by id or by title (titles from older saves); a renamed path is found by its zone order (ns.ResolvePath);
-- nothing at all falls back to the first main path
-- the route saved last time, at login / a new plan: a dungeon or class route you never chose (no path to go back to)
-- was a fallback (a plan file with no path in it put a player on Gnomeregan): back to a leveling path
function ns.SavedRoute()
  local t = ns.char and ns.char.routeTitle
  local r = t and ns.RouteById and ns.RouteById(t)
  -- (only one you picked - Route me, Do it now - is yours; a path you came from long ago doesn't make it so)
  if r and (r.dungeon or r.special) and ns.char.chosenTrip ~= r.id and ns.MainRoutes()[1] then
    if ns.Why then ns.Why("path", "saved on " .. tostring(t) .. ", which you didn't pick: back on a leveling path") end
    return ns.char.returnTo
  end
  return t
end
function ns.SelectRoute(title, quiet)
  local list = ns.Routes()
  local pick, exact = ns.ResolvePath(title)
  -- (never a dungeon or class route by default: a plan file with no path in it put a player on Gnomeregan)
  if not pick then for _, r in ipairs(list) do if not r.dungeon and not r.special then pick = r; break end end end
  pick = pick or ns.MainRoutes()[1]
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

-- Where the Map button takes you for step i: the map to open and the step whose pin to flash there.
--   a step with a spot of its own: its map, its pin
--   a trip (a fly step with no spot): the zone it goes to, and the pin of the first stop there. It used the arrow's
--     target, which for a trip is the flight master in the zone you are in - so the map opened where you stand, not
--     where you're going ("this just seems to open the map on your character and not the destination" - tester)
--   a spot nobody knows (s.unknown): its zone, no pin
-- -> uiMapID, step index (or nil); nil when the step has no place on a map
function ns.MapSpot(i)
  local list = ForeverRouteData and ForeverRouteData.steps
  local s = i and list and list[i]
  if not s then return nil end
  if s.m and s.x and not s.unknown then return s.m, i end
  if s.to and s.k == "fly" then
    for j = i + 1, #list do
      local t = list[j]
      if t.k == "fly" or t.k == "hearth" then break end
      if t.m == s.to and t.x and not t.unknown and not ns.Engine.IsDone(j) then return s.to, j end
    end
    return s.to, nil
  end
  return s.m, nil
end

function ns.ShowOnMap(i)
  local s = i and ForeverRouteData and ForeverRouteData.steps[i]
  if not s then return end
  local m, pin = ns.MapSpot(i)
  if not m then ns.Print("That step has no map spot (it's inside a dungeon, or a note)."); return end
  if InCombatLockdown() then ns.Print("Can't open the map in combat."); return end
  if i ~= ns.Engine.current then ns.Engine.view = i end
  ns.Fire("FR_STEP", ns.Engine.Shown()) -- pins follow the step being looked at
  local function setMap()
    if WorldMapFrame and WorldMapFrame:IsShown() and WorldMapFrame.SetMapID and WorldMapFrame:GetMapID() ~= m then WorldMapFrame:SetMapID(m) end
  end
  local ok, err = pcall(function()
    if WorldMapFrame and not WorldMapFrame:IsShown() then
      if OpenWorldMap then OpenWorldMap(m) elseif ToggleWorldMap then ToggleWorldMap() end
    end
    setMap()
  end)
  if not ok then ns.LogError("map", err) end
  -- again a moment later: an opening map goes to the zone you're in (the game's map does that as it opens, map addons
  -- can do it a frame later), which undid the step's map
  C_Timer.After(0, function() pcall(setMap) end)
  C_Timer.After(0.2, function() pcall(setMap) end)
  -- and make its pin flash, so the eye finds it among the map's own markers (tester)
  if pin and ns.Pins and ns.Pins.Blink then ns.Pins.Blink(pin) end
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
