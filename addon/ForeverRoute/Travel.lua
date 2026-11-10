-- Getting anywhere, as a small graph: you, the target, the ride network (towns, flight masters, docks and zone
-- crossings found in the walk maps, with walking yards between key points of a zone), the flight paths you know and
-- the boats. Rides go along the network - through the real crossings, never straight over a mountain or through a
-- wall - and never through a zone far above your level. Shortest trip by time (Dijkstra). The planner routes over
-- the same data with the same rules (tools/travel.js), so the plan and the arrow agree.
local _, ns = ...
local Travel = {}
ns.Travel = Travel
local HBD = LibStub("HereBeDragons-2.0")

-- the facts (speeds, docks, zone levels, boats, gates, the network) live in TravelData.lua, generated from
-- tools/travel-facts.json and tools/travel-net.json
local TD = ns.TravelData
Travel.RIDE, Travel.FLY, Travel.FLY_EXTRA, Travel.BOAT, Travel.FP_NEAR = TD.RIDE, TD.FLY, TD.FLY_EXTRA, TD.BOAT, TD.FP_NEAR
Travel.MOUNT = TD.MOUNT
-- how fast you ride: running, mounted from level 40 (TravelData MOUNT)
function Travel.Speed()
  local M, L = Travel.MOUNT, (UnitLevel and UnitLevel("player")) or 1
  return (M and L >= M.level) and M.speed or Travel.RIDE
end
Travel.DANGER_ABOVE, Travel.TOWN_WALK = TD.DANGER_ABOVE, TD.TOWN_WALK
-- a ride leg points at the first waypoint at least this far ahead (yards): nearer ones are under your feet
Travel.AHEAD_YD = 40
Travel.DOCKS, Travel.ZONE_MIN, Travel.BOATS, Travel.GATES = TD.DOCKS, TD.ZONE_MIN, TD.BOATS, TD.GATES
Travel.SPELLS = TD.SPELLS or {}
Travel.NET = TD.NET
Travel.OFFNET = 1.25 -- straight-line yards to the network's key points count this much longer (roads bend)

local function world(m, x, y)
  local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(x, y, m)
  if wx then return { wx, wy, inst } end
end
local function mapName(m) local i = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(m); return i and i.name or ("map " .. tostring(m)) end
local function d(a, b) return math.sqrt((a.w[1] - b.w[1]) ^ 2 + (a.w[2] - b.w[2]) ^ 2) end
-- the other faction's towns and camps (TravelData HOSTILE, from tools/hostile-towns.json): a ride through one costs
-- HOSTILE_SEC more - guards, players, a detour. Possible (fine for PvP), just trouble.
Travel.HOSTILE, Travel.HOSTILE_SEC = TD.HOSTILE or {}, TD.HOSTILE_SEC or 0
local hostileW, hostileFor
function Travel.HostileTowns()
  local okF, f = pcall(UnitFactionGroup, "player")
  local side = (okF and f == "Horde") and "horde" or "alliance"
  if hostileFor ~= side or not hostileW then
    hostileW, hostileFor = {}, side
    for _, h in ipairs(Travel.HOSTILE[side] or {}) do local w = world(h.m, h.x, h.y); if w then hostileW[#hostileW + 1] = { w = w, r = h.r, name = h.name } end end
  end
  return hostileW
end
local function segDist(a, b, p)
  local dx, dy = b[1] - a[1], b[2] - a[2]
  local L = dx * dx + dy * dy
  local t = L > 0 and math.max(0, math.min(1, ((p[1] - a[1]) * dx + (p[2] - a[2]) * dy) / L)) or 0
  return math.sqrt((a[1] + t * dx - p[1]) ^ 2 + (a[2] + t * dy - p[2]) ^ 2)
end
-- the other faction's town a ride from a to b passes through (its entry: name, radius), or nil. A quick box test first:
-- this runs for every road of every trip the card, arrow and pins ask for
function Travel.Through(a, b)
  local x0, x1 = math.min(a[1], b[1]), math.max(a[1], b[1])
  local y0, y1 = math.min(a[2], b[2]), math.max(a[2], b[2])
  for _, h in ipairs(Travel.HostileTowns()) do
    local p, r = h.w, h.r
    if p[3] == a[3] and p[1] + r >= x0 and p[1] - r <= x1 and p[2] + r >= y0 and p[2] - r <= y1 and segDist(a, b, p) < r then return h end
  end
  return nil
end
-- roads of the network never move: whether one passes a hostile town is worked out once per road (and faction)
local roadHostile, roadFor = {}, nil
local function throughCached(u, v)
  local side = hostileFor
  if roadFor ~= side then roadHostile, roadFor = {}, side end
  if not (u.id and v.id) or u.id == "you" or u.id == "target" or v.id == "you" or v.id == "target" then return Travel.Through(u.w, v.w) end
  local k = u.id < v.id and (u.id .. "|" .. v.id) or (v.id .. "|" .. u.id)
  local c = roadHostile[k]
  if c == nil then c = Travel.Through(u.w, v.w) or false; roadHostile[k] = c end
  return c or nil
end
Travel.ThroughCached = throughCached

-- the network's nodes with world coords, once (the map data doesn't change)
local netNodes, netById, netMaps, netInst, netSrc, netConv
local function net()
  -- rebuilt only if the data or the map conversion changes (tests swap both)
  if netNodes and netSrc == Travel.NET and netConv == HBD.GetWorldCoordinatesFromZone then return netNodes end
  netSrc, netConv = Travel.NET, HBD.GetWorldCoordinatesFromZone
  netNodes, netById, netMaps, netInst = {}, {}, {}, {}
  for _, n in ipairs((Travel.NET and Travel.NET.nodes) or {}) do
    local w = world(n.m, n.x, n.y)
    if w then
      local c = { id = n.id, kind = n.kind, m = n.m, x = n.x, y = n.y, name = n.name, dock = n.dock, m2 = n.m2, x2 = n.x2, y2 = n.y2, w = w }
      local D = n.dock and Travel.DOCKS[n.dock]
      if D then c.town, c.zone, c.pier, c.name, c.say = D.town, D.zone, D.pier, D.name, D.say end
      netNodes[#netNodes + 1] = c; netById[n.id] = c; netInst[w[3]] = true
      netMaps[n.m] = true; if n.m2 then netMaps[n.m2] = true end
    end
  end
  return netNodes
end
Travel.HasNetwork = function(m) net(); return netMaps[m] == true end
-- can a trip start here? Not from a place the network has no stop in: the Deeprun Tram is its own little world
-- (between the Ironforge and Stormwind stops), and so is a dungeon
-- (a map the network names is always on it; any other map is on it only if it lies in a world the network has stops in)
local rawMaps
function Travel.OnNetwork(m, x, y)
  if not Travel.NET or not m then return true end -- no network: plain straight lines from anywhere
  if not rawMaps or rawMaps.src ~= Travel.NET then
    rawMaps = { src = Travel.NET }
    for _, n in ipairs(Travel.NET.nodes or {}) do rawMaps[n.m] = true; if n.m2 then rawMaps[n.m2] = true end end
  end
  if rawMaps[m] then return true end
  net()
  local w = world(m, x, y)
  return w ~= nil and netInst[w[3]] == true
end
function Travel.IsTram(leg) return leg ~= nil and type(leg.dock) == "string" and leg.dock:find("^tram") ~= nil end

local function knowsFP(m) return ns.Engine and ns.Engine.KnowsFlightIn and ns.Engine.KnowsFlightIn(mapName(m)) end

-- the hearthstone: casting takes 10 s; the hour of cooldown it uses is worth about 3 minutes of travel
Travel.HEARTH_CAST, Travel.HEARTH_VALUE = 10, 180
-- where your hearthstone takes you, if it is in your bags and ready: the innkeeper of the map you bound on (or the map
-- named like your bind location). nil when unknown - never guess a hearth
function Travel.HearthInn()
  local ok, inn = pcall(function()
    if not GetBindLocation then return nil end
    local count = GetItemCount and GetItemCount(6948)
    if not (type(count) == "number" and count > 0) then return nil end
    if not (ns.HearthCooldown and ns.HearthCooldown() == 0) then return nil end
    local bind = GetBindLocation()
    if type(bind) ~= "string" or bind == "" then return nil end
    local maps, b = {}, ns.char and ns.char.boundAt
    if b and b.m and b.name == bind then maps[#maps + 1] = b.m end
    for m in pairs(ns.VENDORS or {}) do
      local n = mapName(m)
      if n == bind or bind:find(n, 1, true) or n:find(bind, 1, true) then maps[#maps + 1] = m end
    end
    for _, m in ipairs(maps) do
      for _, v in ipairs(ns.VENDORS[m] or {}) do
        if v[4] == "Innkeeper" then return { m = m, x = v[1], y = v[2], name = v[3], bind = bind } end
      end
    end
  end)
  return ok and inn or nil
end

-- from = { m, x, y }, to = { m, x, y, name } -> legs { { how = "ride"|"fly"|"boat", m, x, y (where to go), text } }, seconds
function Travel.Plan(from, to)
  from.w = from.w or world(from.m, from.x, from.y); to.w = to.w or world(to.m, to.x, to.y)
  if not (from.w and to.w) then return nil end
  local lvl = UnitLevel and UnitLevel("player") or 60
  local function risky(m) local z = Travel.ZONE_MIN[m]; return z and z > lvl + Travel.DANGER_ABOVE end
  local function gated(a, b)
    if a.gate or b.gate then return false end
    for _, g in ipairs(Travel.GATES) do if (a.m == g.a and b.m == g.b) or (a.m == g.b and b.m == g.a) then return true end end
    return false
  end
  local N = { { id = "you", w = from.w, m = from.m, x = from.x, y = from.y, name = "you" }, { id = "target", w = to.w, m = to.m, x = to.x, y = to.y, name = to.name or "there" } }
  local adj = { {}, {} }
  local idx = {}
  local function add(n) N[#N + 1] = n; adj[#N] = {}; return #N end
  local function edge(u, v, c, how)
    if how == "ride" and N[u].w and N[v].w then Travel.HostileTowns(); if throughCached(N[u], N[v]) then c = c + Travel.HOSTILE_SEC end end
    local au, av = adj[u], adj[v]; au[#au + 1] = { v, c, how }; av[#av + 1] = { u, c, how }
  end
  local learned = (ForeverRouteDB and ForeverRouteDB.docks) or {}
  for _, n in ipairs(net()) do
    local c = n
    if n.dock then
      -- a pier you learned moves the dock (its walking yards stay)
      local D = Travel.DOCKS[n.dock]; local L = D and learned[D.learned or n.dock]
      if L and L.m == n.m and L.x then
        local w = world(n.m, L.x, L.y)
        if w then c = setmetatable({ x = L.x, y = L.y, w = w }, { __index = n }) end
      end
    end
    if n.kind == "fp" and knowsFP(n.m) then c = setmetatable({ fp = true }, { __index = c }) end
    idx[n.id] = add(c)
  end
  for _, e in ipairs((Travel.NET and Travel.NET.edges) or {}) do
    local u, v = idx[e[1]], idx[e[2]]
    if u and v and not (risky(e[3]) and e[4] > Travel.TOWN_WALK) then edge(u, v, e[4] / Travel.Speed(), "ride") end
  end
  if not Travel.NET then
    -- no network: flight paths you know and the docks as plain nodes, straight rides
    for m, list in pairs(ns.FLIGHT or {}) do
      if knowsFP(m) then local f = list[1]; local w = world(m, f[1], f[2]); if w then add({ id = "fp" .. m, kind = "fp", fp = true, w = w, m = m, x = f[1], y = f[2], name = f[3] }) end end
    end
    for key, D in pairs(Travel.DOCKS) do
      local L = learned[D.learned or key]
      local x, y = (L and L.m == D.m and L.x) or D.x, (L and L.m == D.m and L.y) or D.y
      local w = world(D.m, x, y)
      if w then idx["dock-" .. key] = add({ id = "dock-" .. key, kind = "dock", dock = key, w = w, m = D.m, x = x, y = y, name = D.name, town = D.town, zone = D.zone, pier = D.pier, say = D.say }) end
    end
  end
  if Travel.NET then
    -- docks the network doesn't have (a map without a walk map: Zephras Isle's skyship): plain nodes joined in straight
    -- rides to the key points of their own map, like the gates (tools/travel.js does the same)
    for key, D in pairs(Travel.DOCKS) do
      if not idx["dock-" .. key] then
        local w = world(D.m, D.x, D.y)
        if w then
          local u = add({ id = "dock-" .. key, kind = "dock", dock = key, w = w, m = D.m, x = D.x, y = D.y, name = D.name, town = D.town, zone = D.zone, pier = D.pier, say = D.say })
          idx["dock-" .. key] = u
          for v = 3, u - 1 do local n = N[v]; if n.m == D.m or n.m2 == D.m then edge(u, v, d(N[u], n) * Travel.OFFNET / Travel.Speed(), "ride") end end
        end
      end
    end
  end
  -- gates (the breach past Mor'shan Rampart): the only way across their border when riding in straight lines
  local firstGate = #N + 1
  for k, g in ipairs(Travel.GATES) do
    local w = world(g.via.m, g.via.x, g.via.y)
    if w then add({ id = "gate" .. k, kind = "gate", gate = true, w = w, m = g.via.m, x = g.via.x, y = g.via.y, name = g.via.name }) end
  end
  if not Travel.NET then
    for u = 3, #N do for v = u + 1, #N do
      local a, b = N[u], N[v]
      if a.w[3] == b.w[3] and not gated(a, b) and (d(a, b) <= Travel.TOWN_WALK or not (risky(a.m) or risky(b.m))) then edge(u, v, d(a, b) / Travel.Speed(), "ride") end
    end end
  else
    -- with the network, a gate joins the key points of its own map
    for g = firstGate, #N do for v = 3, firstGate - 1 do
      local n = N[v]
      if n.m == N[g].m or n.m2 == N[g].m then edge(g, v, d(N[g], n) * Travel.OFFNET / Travel.Speed(), "ride") end
    end end
  end
  -- you and the target join the network at the key points of their own map (anywhere on the continent if the map
  -- has none - a dungeon map, a map the walk maps don't cover)
  net()
  for e = 1, 2 do
    local p = N[e]; local onNet = netMaps[p.m]
    for v = 3, #N do
      local n = N[v]
      if n.w[3] == p.w[3] then
        local ok
        if onNet then ok = n.m == p.m or n.m2 == p.m else ok = not gated(p, n) end
        -- the danger rule holds where you join and leave the network too (a town walk is fine anywhere)
        if ok and d(p, n) > Travel.TOWN_WALK and (risky(n.m) or risky(p.m)) then ok = false end
        if ok then edge(e, v, d(p, n) * Travel.OFFNET / Travel.Speed(), "ride") end
      end
    end
  end
  local a, b = N[1], N[2]
  if a.w[3] == b.w[3] and (a.m == b.m or not netMaps[a.m] or not netMaps[b.m]) and not gated(a, b) and (a.m == b.m or not (risky(a.m) or risky(b.m))) then
    edge(1, 2, d(a, b) * Travel.OFFNET / Travel.Speed(), "ride")
  end
  -- flights between the flight paths you know (same continent)
  local fps = {}
  for v = 3, #N do if N[v].fp then fps[#fps + 1] = v end end
  for i = 1, #fps do for j = i + 1, #fps do
    local u, v = fps[i], fps[j]
    if N[u].w[3] == N[v].w[3] then edge(u, v, Travel.FLY_EXTRA + d(N[u], N[v]) / Travel.FLY, "fly") end
  end end
  -- a crossing limited to some races (5th entry: the Skyborne-only portal) is not there for anyone else
  local myRace = ns.StarterKey and ns.StarterKey()
  local myClass = myRace and myRace:match("%-(.+)$")
  myRace = myRace and myRace:match("^(.-)%-")
  if not myClass and UnitClass then local _, c = UnitClass("player"); myClass = c and c:lower() end
  -- (or classes: the druids' hippogryph out of Moonglade)
  for _, bt in ipairs(Travel.BOATS) do
    local u, v = idx["dock-" .. bt[1]], idx["dock-" .. bt[2]]
    local allowed = not bt[5]
    if bt[5] then for _, r in ipairs(bt[5]) do if r == myRace or r == myClass then allowed = true end end end
    if u and v and allowed then edge(u, v, bt[3] or Travel.BOAT, "boat") end
  end
  -- a class spell that takes you somewhere from anywhere (Teleport: Moonglade): one way, from where you stand
  local myLevel = (UnitLevel and UnitLevel("player")) or 1
  for _, sp in ipairs(Travel.SPELLS) do
    local v = idx["dock-" .. sp.dock]
    if v and sp.class == myClass and myLevel >= (sp.level or 1) and N[v].m ~= from.m then adj[1][#adj[1] + 1] = { v, sp.cast or 10, "spell" }; N[v].spellSay = sp.say end
  end
  -- your hearthstone, when it is ready: from wherever you are to your inn. It costs an hour's cooldown, so it only
  -- wins when it saves a few minutes (HEARTH_VALUE)
  local inn = Travel.HearthInn()
  if inn then
    local w = world(inn.m, inn.x, inn.y)
    if w then
      local h = add({ id = "inn", kind = "inn", w = w, m = inn.m, x = inn.x, y = inn.y, name = inn.name, town = inn.bind })
      adj[1][#adj[1] + 1] = { h, Travel.HEARTH_CAST + Travel.HEARTH_VALUE, "hearth" } -- one way: you can't hearth back
      for v = 3, #N - 1 do
        local n = N[v]
        if n.w[3] == w[3] and (n.m == inn.m or n.m2 == inn.m) then edge(h, v, d(N[h], n) * Travel.OFFNET / Travel.Speed(), "ride") end
      end
      if N[2].w[3] == w[3] and N[2].m == inn.m then edge(h, 2, d(N[h], N[2]) * Travel.OFFNET / Travel.Speed(), "ride") end
    end
  end
  -- Dijkstra
  local dist, prev, how, done = {}, {}, {}, {}
  for i = 1, #N do dist[i] = math.huge end
  dist[1] = 0
  while true do
    local u, best = nil, math.huge
    for i = 1, #N do if not done[i] and dist[i] < best then u, best = i, dist[i] end end
    if not u or u == 2 then break end
    done[u] = true
    for _, e in ipairs(adj[u]) do
      local v, c = e[1], e[2]
      if not done[v] and dist[u] + c < dist[v] then dist[v], prev[v], how[v] = dist[u] + c, u, e[3] end
    end
  end
  if dist[2] == math.huge then return nil end
  -- walk back from the target: the hops in order; consecutive rides are one ride (through the crossings)
  local chain = {}
  local v = 2
  while v and v ~= 1 do table.insert(chain, 1, { node = N[v], how = how[v], from = N[prev[v]] }); v = prev[v] end
  local hops = {}
  for _, c in ipairs(chain) do
    local last = hops[#hops]
    if last and last.how == "ride" and c.how == "ride" then last.via[#last.via + 1] = c.from; last.node = c.node
    else hops[#hops + 1] = { node = c.node, from = c.from, how = c.how, via = {} } end
  end
  -- what you do, leg by leg; "ride to the flight master, fly to X" reads as one "Fly to X" leg
  local function placeName(n) return n.id == "target" and (to.name or mapName(n.m)) or (n.kind == "cross" and ((("the " .. n.name:gsub(" / ", " - ") .. " border"):gsub("^the The ", "the ")))) or n.town or n.name or mapName(n.m) end
  local legs = {}
  for k, c in ipairs(hops) do
    local n, f = c.node, c.from
    if c.how == "ride" then
      local nxt = hops[k + 1]
      -- a short walk to the flight master or pier reads as part of the next leg; a real ride (across a border, or
      -- more than a town walk) is its own leg, so the trip never skips twenty minutes of riding
      local short = #c.via == 0 and d(f, n) <= 2 * Travel.TOWN_WALK
      if not (nxt and (nxt.how == "fly" or nxt.how == "boat") and short) then
        -- point at the first crossing on the way: the arrow follows the road, not a line over the hills
        -- the first waypoint that is really ahead: one right beside you (a city waypoint you're standing on) would read
        -- "1 yd" and point at your feet - in Stormwind's Trade District it did, on the way to the harbor
        local first
        for _, x in ipairs(c.via) do if x.w and f.w and d(f, x) > Travel.AHEAD_YD then first = x; break end end
        local crossings = {}
        for _, x in ipairs(c.via) do if x.kind == "cross" or x.gate then crossings[#crossings + 1] = placeName(x) end end
        local text = "Ride " .. (f.town and ("from " .. f.town .. " ") or "") .. "to " .. placeName(n) .. (#crossings > 0 and (" (through " .. table.concat(crossings, ", ") .. ")") or "")
        local tgt = first or n
        local tm, tx, ty = tgt.m, tgt.x, tgt.y
        if first and first.m2 == f.m then tm, tx, ty = first.m2, first.x2, first.y2 end
        -- a town of the other faction on the way: still the way (a quest, a class trainer, the sleeping bag chain may
        -- lead there), said on the card so it's no surprise
        local passes, seen = {}, {}
        local pts = { f }; for _, x in ipairs(c.via) do pts[#pts + 1] = x end; pts[#pts + 1] = n
        for j = 1, #pts - 1 do
          local a, b = pts[j].w, pts[j + 1].w
          local h = a and b and Travel.Through(a, b)
          if h and not seen[h] then seen[h] = true; passes[#passes + 1] = h.name or "a town of the other faction" end
        end
        if #passes > 0 then text = text .. " - passes " .. table.concat(passes, ", ") .. " (the other faction: guards will attack)" end
        legs[#legs + 1] = { sm = f.m, sx = f.x, sy = f.y, how = "ride", m = tm, x = tx, y = ty, text = text, hostile = #passes > 0 or nil }
      end
    elseif c.how == "hearth" then
      -- nothing to point at: use the hearthstone (sm/sx/sy: where you land, for the flight-path note)
      legs[#legs + 1] = { sm = n.m, sx = n.x, sy = n.y, how = "hearth", text = "Hearth to " .. (n.town or n.name) .. " (your hearthstone is ready)" }
    elseif c.how == "spell" then
      -- nothing to point at either: cast it (Teleport: Moonglade)
      legs[#legs + 1] = { sm = n.m, sx = n.x, sy = n.y, how = "spell", text = (n.spellSay or "Cast your teleport") .. " (to " .. (n.zone or mapName(n.m)) .. ")" }
    elseif c.how == "fly" then legs[#legs + 1] = { sm = f.m, sx = f.x, sy = f.y, how = "fly", m = f.m, x = f.x, y = f.y, text = "Fly to " .. mapName(n.m) .. (f.name and (" (flight master " .. f.name .. ")") or "") }
    elseif c.how == "boat" then
      -- what you actually do: which town and zone you sail to; in a town with two piers, which one
      local prevLeg = legs[#legs]
      local sameTown = prevLeg and prevLeg.how == "boat" and prevLeg.toTown == f.town
      local tram = f.dock and f.dock:find("^tram")
      -- a crossing that is more than a boat (the skyship and portal off Zephras Isle) says what you do
      local say = type(f.say) == "table" and n.dock and f.say[n.dock]
      local text = say or tram and ("Take the Deeprun Tram to " .. (n.town or n.name)) or ((sameTown and ("In " .. f.town .. ", walk to " .. (f.pier or "the other pier") .. " and take the boat to ") or "Boat to ") .. (n.town or n.name) .. " (" .. (n.zone or mapName(n.m)) .. ")")
      legs[#legs + 1] = { sm = f.m, sx = f.x, sy = f.y, how = "boat", m = f.m, x = f.x, y = f.y, toTown = n.town, text = text, dock = (f.dock and Travel.DOCKS[f.dock] and Travel.DOCKS[f.dock].learned) or f.dock }
    end
  end
  -- flight paths you do not have yet, right where a leg starts (the dock you land at, a town you ride through): grab
  -- them on the way - a minute now, flights later
  for _, l in ipairs(legs) do
    local lw = world(l.sm or l.m, l.sx or l.x, l.sy or l.y) -- where the leg starts (the dock you step off at)
    if lw then
      for m, list in pairs(ns.FLIGHT or {}) do
        if not knowsFP(m) then
          for _, f in ipairs(list) do
            local fw = world(m, f[1], f[2])
            if fw and fw[3] == lw[3] then
              local dd = math.sqrt((fw[1] - lw[1]) ^ 2 + (fw[2] - lw[2]) ^ 2)
              local zn = mapName(m)
              if dd <= Travel.FP_NEAR and not l.fp then l.fp = { m = m, x = f[1], y = f[2], npc = f[3], zone = zn, yd = dd }; l.text = l.text .. " - get the " .. zn .. " flight path from " .. (f[3] or "the flight master") .. " there first" end
            end
          end
        end
      end
    end
  end
  return legs, dist[2]
end

-- one line for the card: "Fly to Wetlands -> Boat from Menethil Harbor to Theramore -> Ride to The Barrens"
function Travel.Describe(legs)
  local parts = {}
  for _, l in ipairs(legs or {}) do parts[#parts + 1] = l.text end
  return table.concat(parts, "  >  ")
end
