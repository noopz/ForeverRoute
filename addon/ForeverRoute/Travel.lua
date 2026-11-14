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
Travel.ZONE_MIN_HORDE = TD.ZONE_MIN_HORDE or {}
Travel.CROSS_CLEAR = 150 -- yards beyond a hostile town's radius where a border crossing is no way for you
Travel.NET = TD.NET
-- your faction, as the travel facts name it: crossings, spells and gates with a faction are only there for that one
function Travel.Side()
  local ok, f = pcall(UnitFactionGroup, "player")
  return (ok and f == "Horde") and "horde" or "alliance"
end
local function forSide(only, side) return not only or only == side end
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
-- (the towns of each world apart, in their order: a trip joins you and the target to dozens of roads, each checked)
local byInstOf = setmetatable({}, { __mode = "k" })
local function hostileIn(list, inst)
  local by = byInstOf[list]
  if not by then
    by = {}
    for _, h in ipairs(list) do local i = h.w[3]; local l = by[i]; if not l then l = {}; by[i] = l end; l[#l + 1] = h end
    byInstOf[list] = by
  end
  return by[inst] or {}
end
function Travel.Through(a, b)
  local x0, x1 = math.min(a[1], b[1]), math.max(a[1], b[1])
  local y0, y1 = math.min(a[2], b[2]), math.max(a[2], b[2])
  for _, h in ipairs(hostileIn(Travel.HostileTowns(), a[3])) do
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
  -- (by the two ids, the lower first: a string made of them for each of the network's 9,000 roads was much of building
  -- the trip planner's graph)
  local a, b = u.id, v.id
  if b < a then a, b = b, a end
  local row = roadHostile[a]
  if not row then row = {}; roadHostile[a] = row end
  local c = row[b]
  if c == nil then c = Travel.Through(u.w, v.w) or false; row[b] = c end
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
      local c = { id = n.id, kind = n.kind, m = n.m, x = n.x, y = n.y, name = n.name, dock = n.dock, m2 = n.m2, x2 = n.x2, y2 = n.y2, side = n.side, w = w }
      local D = n.dock and Travel.DOCKS[n.dock]
      if D then c.town, c.zone, c.pier, c.name, c.say = D.town, D.zone, D.pier, D.name, D.say end
      netNodes[#netNodes + 1] = c; netById[n.id] = c; netInst[w[3]] = true
      netMaps[n.m] = true; if n.m2 then netMaps[n.m2] = true end
    end
  end
  return netNodes
end
Travel.HasNetwork = function(m) net(); return netMaps[m] == true end
-- where a trip can leave the walk on map m: your side's flight masters (known or not) and the piers - the places a
-- trip between two far stops starts or lands at (Next indexes the plan's far gaps by the walks to them before it
-- knows which one the trip takes) -> { world positions }
local portsOf, portsKey = {}, nil
function Travel.Ports(m)
  net()
  local letter = Travel.Side() == "horde" and "H" or "A"
  local key = tostring(netNodes) .. letter .. tostring(ns.FLIGHT)
  if portsKey ~= key then portsOf, portsKey = {}, key end
  local out = portsOf[m]
  if out then return out end
  out = {}
  for _, n in ipairs(netNodes or {}) do
    if (n.m == m or n.m2 == m) and ((n.kind == "fp" and (not n.side or n.side:find(letter, 1, true))) or n.kind == "dock") then out[#out + 1] = n.w end
  end
  if #out == 0 then
    -- (no network here: the flight masters of your side alone)
    for _, f in ipairs((ns.FLIGHT and ns.FLIGHT[m]) or {}) do local w = world(m, f[1], f[2]); if w then out[#out + 1] = w end end
  end
  portsOf[m] = out
  return out
end
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

-- do you have this flight point? FlightMasters.lua names each flight master's point as the flight map does
-- ("Sentinel Hill, Westfall": the client's TaxiNodes table), so a zone with two points for your faction (Feralas, The
-- Barrens, Stranglethorn, Ashenvale, Mount Hyjal) no longer counts both as yours when you have one. Having the point by
-- that name: yes. Having another point of the same zone by its name, and not this one: no. Otherwise (a flight master
-- without a name, a client in another language) the zone's name decides, as it always did.
local taxiOf, taxiSrc
local function taxiNames()
  if taxiOf and taxiSrc == ns.FLIGHT_BY then return taxiOf end
  taxiOf, taxiSrc = {}, ns.FLIGHT_BY
  for _, byMap in pairs(ns.FLIGHT_BY or {}) do
    for m, list in pairs(byMap) do
      for _, f in ipairs(list) do if f[4] then taxiOf[m .. ":" .. tostring(f[3])] = f[4] end end
    end
  end
  return taxiOf
end
local function knowsFP(m, npc)
  local known = (ns.State and ns.State.knownTaxi) or {}
  local mine = npc and taxiNames()[m .. ":" .. npc]
  if mine then
    if known[mine] then return true end
    for _, f in ipairs((ns.FLIGHT and ns.FLIGHT[m]) or {}) do if f[4] and f[4] ~= mine and known[f[4]] then return false end end
  end
  return ns.Engine and ns.Engine.KnowsFlightIn and ns.Engine.KnowsFlightIn(mapName(m))
end
Travel.KnowsFlightPoint = knowsFP

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

-- The graph a trip is searched on, without you and the target: the network's places, its roads, the gates, the
-- flights between the flight paths you know and the boats. Building it was most of a trip's ~35 ms (9,000 roads, each
-- checked against the other faction's towns), and the card asks for trips many times a minute - so it is built once and
-- kept until something it is made of changes: the flight paths you know, your level and speed, your faction, race and
-- class, the piers you learned, or the data itself (tests swap all of these). You and the target are joined on each
-- trip; those roads are kept apart from the graph's own (ext), so the kept graph is never changed by a trip.
local graphs, graphCount = {}, 0
local function taxiSig()
  local parts = {}
  for name, v in pairs((ns.State and ns.State.knownTaxi) or {}) do parts[#parts + 1] = tostring(name) .. "=" .. tostring(v) end
  return table.concat(parts, ",")
end
local function docksSig(learned)
  local parts = {}
  for k, L in pairs(learned) do parts[#parts + 1] = tostring(k) .. "=" .. (type(L) == "table" and (tostring(L.m) .. ":" .. tostring(L.x) .. ":" .. tostring(L.y)) or tostring(L)) end
  return table.concat(parts, ",")
end
-- what knowsFP says of each flight master: asked again for every leg of every trip, and it only changes with things the
-- graph's key holds
local fpKnown, fpKey = {}, nil
local function knowsFPKept(m, npc)
  local k = tostring(m) .. ":" .. tostring(npc)
  local v = fpKnown[k]
  if v == nil then v = knowsFP(m, npc) and true or false; fpKnown[k] = v end
  return v
end
-- a Horde player's own lands are not the 60 that keeps the Alliance out (ZONE_MIN_HORDE)
local function riskyFor(side, lvl)
  return function(m)
    local z = Travel.ZONE_MIN[m]
    if side == "horde" and Travel.ZONE_MIN_HORDE[m] ~= nil then z = Travel.ZONE_MIN_HORDE[m] end
    return z and z > lvl + Travel.DANGER_ABOVE
  end
end
local function gatesFor(side)
  local gates = {}
  for _, g in ipairs(Travel.GATES) do if forSide(g.faction, side) then gates[#gates + 1] = g end end
  return gates
end
local function gatedBy(gates)
  return function(a, b)
    if a.gate or b.gate then return false end
    for _, g in ipairs(gates) do if (a.m == g.a and b.m == g.b) or (a.m == g.b and b.m == g.a) then return true end end
    return false
  end
end
-- a crossing limited to some races (5th entry: the Skyborne-only portal) is not there for anyone else
-- (or classes: the druids' hippogryph out of Moonglade)
local function myRaceClass()
  local myRace = ns.StarterKey and ns.StarterKey()
  local myClass = myRace and myRace:match("%-(.+)$")
  myRace = myRace and myRace:match("^(.-)%-")
  if not myClass and UnitClass then local _, c = UnitClass("player"); myClass = c and c:lower() end
  return myRace, myClass
end
local campMemo = setmetatable({}, { __mode = "k" })
local function buildGraph(ground, lvl, side, myRace, myClass, learned)
  local risky, gates = riskyFor(side, lvl), gatesFor(side)
  local gated = gatedBy(gates)
  local myLetter = side == "horde" and "H" or "A"
  local N = { false, false } -- (you and the target: each trip's own)
  local adj = { {}, {} }
  local idx = {}
  local function add(n) N[#N + 1] = n; adj[#N] = {}; return #N end
  local function edge(u, v, c, how)
    -- (the towns are looked up once for the whole build, below: not for each of 9,000 roads)
    if how == "ride" and N[u].w and N[v].w and throughCached(N[u], N[v]) then c = c + Travel.HOSTILE_SEC end
    local au, av = adj[u], adj[v]; au[#au + 1] = { v, c, how }; av[#av + 1] = { u, c, how }
  end
  local hostile = Travel.HostileTowns()
  -- (whether a crossing is in a camp only changes with your faction's list of camps: the graph is built again for every
  -- flight path you learn and every level, and this was most of that)
  local camps = campMemo[hostile]
  if not camps or camps.clear ~= Travel.CROSS_CLEAR then camps = { clear = Travel.CROSS_CLEAR, of = setmetatable({}, { __mode = "k" }) }; campMemo[hostile] = camps end
  local function inCamp(n)
    local v = camps.of[n]
    if v ~= nil then return v end
    v = false
    for _, h in ipairs(hostile) do
      if n.w and h.w[3] == n.w[3] and math.sqrt((h.w[1] - n.w[1]) ^ 2 + (h.w[2] - n.w[2]) ^ 2) < h.r + Travel.CROSS_CLEAR then v = true; break end
    end
    camps.of[n] = v
    return v
  end
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
    -- a flight master of the other faction is only a spot on the road for you
    if n.kind == "fp" and not ground and (not n.side or n.side:find(myLetter, 1, true)) and knowsFPKept(n.m, n.name) then c = setmetatable({ fp = true }, { __index = c }) end
    -- a border crossing inside the other faction's town or camp (Mor'shan Rampart's gate) is no way for you: a crossing
    -- is a chokepoint, and the border has another one clear of it (tools/travel.js does the same)
    if not (n.kind == "cross" and inCamp(n)) then idx[n.id] = add(c) end
  end
  for _, e in ipairs((Travel.NET and Travel.NET.edges) or {}) do
    local u, v = idx[e[1]], idx[e[2]]
    if u and v and not (risky(e[3]) and e[4] > Travel.TOWN_WALK) then edge(u, v, e[4] / Travel.Speed(), "ride") end
  end
  if not Travel.NET then
    -- no network: flight paths you know and the docks as plain nodes, straight rides
    for m, list in pairs(ns.FLIGHT or {}) do
      local f = list[1]
      if not ground and knowsFPKept(m, f[3]) then local w = world(m, f[1], f[2]); if w then add({ id = "fp" .. m, kind = "fp", fp = true, w = w, m = m, x = f[1], y = f[2], name = f[3] }) end end
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
  for k, g in ipairs(gates) do
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
  -- flights between the flight paths you know (same continent)
  local fps = {}
  for v = 3, #N do if N[v].fp then fps[#fps + 1] = v end end
  for i = 1, #fps do for j = i + 1, #fps do
    local u, v = fps[i], fps[j]
    if N[u].w[3] == N[v].w[3] then edge(u, v, Travel.FLY_EXTRA + d(N[u], N[v]) / Travel.FLY, "fly") end
  end end
  for _, bt in ipairs(Travel.BOATS) do
    local u, v = idx["dock-" .. bt[1]], idx["dock-" .. bt[2]]
    local allowed = not bt[5]
    if bt[5] then for _, r in ipairs(bt[5]) do if r == myRace or r == myClass then allowed = true end end end
    -- (6th entry: a faction's own crossings - the zeppelins, the Stormwind boat)
    if not forSide(bt[6], side) then allowed = false end
    if u and v and allowed and not ground then
      -- the kind rides along (a portal reads "take the portal"); a 7th entry true: one way (no portal back)
      -- (plus a change of transport: a near tie goes to the trip with fewer legs)
      local c = (bt[3] or Travel.BOAT) + (TD.TRANSFER or 0)
      if bt[7] then adj[u][#adj[u] + 1] = { v, c, "boat", bt[4] }
      else edge(u, v, c, "boat"); adj[u][#adj[u]][4] = bt[4]; adj[v][#adj[v]][4] = bt[4] end
    end
  end
  return { N = N, adj = adj, idx = idx, risky = risky, gated = gated }
end
local function graphFor(ground, lvl, side, myRace, myClass)
  local learned = (ForeverRouteDB and ForeverRouteDB.docks) or {}
  local nodes = net()
  -- (everything the graph is made of; all but the flight paths you know and the piers you learned change almost never)
  local key = table.concat({ ground and "g" or "-", lvl, side, tostring(myRace), tostring(myClass), Travel.Speed(), taxiSig(), docksSig(learned),
    tostring(nodes), tostring(Travel.NET), tostring(ns.FLIGHT), tostring(ns.FLIGHT_BY), tostring(C_Map and C_Map.GetMapInfo), tostring(ns.Engine and ns.Engine.KnowsFlightIn),
    tostring(Travel.DOCKS), tostring(Travel.GATES), tostring(Travel.BOATS), tostring(Travel.ZONE_MIN), tostring(Travel.ZONE_MIN_HORDE), tostring(Travel.HOSTILE),
    Travel.DANGER_ABOVE, Travel.TOWN_WALK, Travel.OFFNET, Travel.FLY, Travel.FLY_EXTRA, tostring(Travel.BOAT), tostring(TD.TRANSFER), Travel.HOSTILE_SEC, Travel.CROSS_CLEAR }, "|")
  -- (the flight-path answers hold while the same things do, whichever kind of trip asks)
  local fk = key:sub(3)
  if fpKey ~= fk then fpKnown, fpKey = {}, fk end
  local G = graphs[key]
  if G then return G end
  -- (a few kept: the card's shortcut check asks with and without flights in turn)
  if graphCount >= 4 then graphs, graphCount = {}, 0 end
  G = buildGraph(ground, lvl, side, myRace, myClass, learned)
  graphs[key], graphCount = G, graphCount + 1
  return G
end

local flightW, flightWConv = {}, nil
local function flightWorld(m, f)
  local w = flightW[f]
  if w == nil then w = world(m, f[1], f[2]) or false; flightW[f] = w end
  return w or nil
end

-- from = { m, x, y }, to = { m, x, y, name } -> legs { { how = "ride"|"fly"|"boat", m, x, y (where to go), text } }, seconds
-- opts.ground: on foot only (no flights, boats, spells or hearthstone) - what the same trip takes without them
-- opts.hearth = false: without your hearthstone
function Travel.Plan(from, to, opts)
  local ground = opts and opts.ground
  from.w = from.w or world(from.m, from.x, from.y); to.w = to.w or world(to.m, to.x, to.y)
  if not (from.w and to.w) then return nil end
  local lvl = UnitLevel and UnitLevel("player") or 60
  local side = Travel.Side()
  local myRace, myClass = myRaceClass()
  local G = graphFor(ground, lvl, side, myRace, myClass)
  local risky, gated, idx = G.risky, G.gated, G.idx
  -- this trip's nodes: you, the target, the kept graph's, and your inn; the roads that join them are this trip's own
  -- (ext), searched along with the graph's
  local N = { { id = "you", w = from.w, m = from.m, x = from.x, y = from.y, name = "you" }, { id = "target", w = to.w, m = to.m, x = to.x, y = to.y, name = to.name or "there" } }
  local GN, Gadj = G.N, G.adj
  for v = 3, #GN do N[v] = GN[v] end
  local ext = {}
  local function push(u, e) local l = ext[u]; if not l then l = {}; ext[u] = l end; l[#l + 1] = e end
  local function edge(u, v, c, how)
    if how == "ride" and N[u].w and N[v].w then Travel.HostileTowns(); if throughCached(N[u], N[v]) then c = c + Travel.HOSTILE_SEC end end
    push(u, { v, c, how }); push(v, { u, c, how })
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
  -- a class spell that takes you somewhere from anywhere (Teleport: Moonglade): one way, from where you stand
  local myLevel = (UnitLevel and UnitLevel("player")) or 1
  for _, sp in ipairs(Travel.SPELLS) do
    local v = idx["dock-" .. sp.dock]
    if v and not ground and sp.class == myClass and myLevel >= (sp.level or 1) and forSide(sp.faction, side) and N[v].m ~= from.m then push(1, { v, sp.cast or 10, "spell" }); N[v].spellSay = sp.say end
  end
  -- your hearthstone, when it is ready: from wherever you are to your inn. It costs an hour's cooldown, so it only
  -- wins when it saves a few minutes (HEARTH_VALUE)
  local inn = not ground and not (opts and opts.hearth == false) and Travel.HearthInn()
  if inn then
    local w = world(inn.m, inn.x, inn.y)
    if w then
      N[#N + 1] = { id = "inn", kind = "inn", w = w, m = inn.m, x = inn.x, y = inn.y, name = inn.name, town = inn.bind }
      local h = #N
      push(1, { h, Travel.HEARTH_CAST + Travel.HEARTH_VALUE, "hearth" }) -- one way: you can't hearth back
      for v = 3, #N - 1 do
        local n = N[v]
        if n.w[3] == w[3] and (n.m == inn.m or n.m2 == inn.m) then edge(h, v, d(N[h], n) * Travel.OFFNET / Travel.Speed(), "ride") end
      end
      if N[2].w[3] == w[3] and N[2].m == inn.m then edge(h, 2, d(N[h], N[2]) * Travel.OFFNET / Travel.Speed(), "ride") end
    end
  end
  -- Dijkstra, on the time you spend playing: a flight or a boat is time you can look away (the player: "flying is an
  -- AFK activity vs walking requires being fully engaged AND has to navigate mobs and PvP"), so its seconds count at
  -- Travel.AFK_WEIGHT. secs: the real time, for the plan's clock; afk: the seconds of it on a flight or boat
  -- (the next place to settle comes off a heap ordered by distance, then by node number: the order a plain scan over
  -- all ~500 nodes took - the least distance, the first of equals - so ties come out the same, at a fraction of the cost)
  local dist, prev, how, done, kindOf, secs, afk = {}, {}, {}, {}, {}, {}, {}
  for i = 1, #N do dist[i] = math.huge end
  dist[1], secs[1], afk[1] = 0, 0, 0
  local hd, hi, hn = {}, {}, 0
  local function less(p, q) return hd[p] < hd[q] or (hd[p] == hd[q] and hi[p] < hi[q]) end
  local function hpush(dv, iv)
    hn = hn + 1; local k = hn; hd[k], hi[k] = dv, iv
    while k > 1 do
      local p = math.floor(k / 2)
      if less(k, p) then hd[k], hd[p], hi[k], hi[p] = hd[p], hd[k], hi[p], hi[k]; k = p else break end
    end
  end
  local function hpop()
    local dv, iv = hd[1], hi[1]
    hd[1], hi[1] = hd[hn], hi[hn]; hd[hn], hi[hn] = nil, nil; hn = hn - 1
    local k = 1
    while true do
      local l, r, m = 2 * k, 2 * k + 1, k
      if l <= hn and less(l, m) then m = l end
      if r <= hn and less(r, m) then m = r end
      if m == k then break end
      hd[k], hd[m], hi[k], hi[m] = hd[m], hd[k], hi[m], hi[k]; k = m
    end
    return dv, iv
  end
  hpush(0, 1)
  local AFK = Travel.AFK_WEIGHT
  while hn > 0 do
    local du, u = hpop()
    if not done[u] and du == dist[u] then
      if u == 2 then break end
      done[u] = true
      for pass = 1, 2 do
        local list
        if pass == 1 then list = Gadj[u] else list = ext[u] end
        if list then
          for _, e in ipairs(list) do
            local v, c = e[1], e[2]
            local away = (e[3] == "fly" or e[3] == "boat") and c or 0
            local cost = c - away + away * AFK
            if not done[v] and dist[u] + cost < dist[v] then
              dist[v], prev[v], how[v], kindOf[v], secs[v], afk[v] = dist[u] + cost, u, e[3], e[4], secs[u] + c, afk[u] + away
              hpush(dist[v], v)
            end
          end
        end
      end
    end
  end
  if dist[2] == math.huge then return nil end
  -- walk back from the target: the hops in order; consecutive rides are one ride (through the crossings)
  local chain = {}
  local v = 2
  while v and v ~= 1 do table.insert(chain, 1, { node = N[v], how = how[v], kind = kindOf[v], from = N[prev[v]] }); v = prev[v] end
  local hops = {}
  for _, c in ipairs(chain) do
    local last = hops[#hops]
    if last and last.how == "ride" and c.how == "ride" then last.via[#last.via + 1] = c.from; last.node = c.node
    else hops[#hops + 1] = { node = c.node, from = c.from, how = c.how, kind = c.kind, via = {} } end
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
        -- (a border crossing or a gate, not a flight master or a pier the road happens to pass: riding from Southshore
        -- to Alterac the arrow pointed at Southshore's flight master 70 yd away and read as "fly" - tester)
        for _, x in ipairs(c.via) do if x.w and f.w and (x.kind == "cross" or x.gate) and d(f, x) > Travel.AHEAD_YD then first = x; break end end
        if not first then for _, x in ipairs(c.via) do if x.w and f.w and d(f, x) > Travel.AHEAD_YD then first = x; break end end end
        local crossings = {}
        for _, x in ipairs(c.via) do if x.kind == "cross" or x.gate then crossings[#crossings + 1] = placeName(x) end end
        local text = ns.RideWord() .. " " .. ((f.town and f.town ~= placeName(n)) and ("from " .. f.town .. " ") or "") .. "to " .. placeName(n) .. (#crossings > 0 and (" (through " .. table.concat(crossings, ", ") .. ")") or "")
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
    elseif c.how == "fly" then legs[#legs + 1] = { sm = f.m, sx = f.x, sy = f.y, how = "fly", m = f.m, x = f.x, y = f.y, toTaxi = n.name and taxiNames()[n.m .. ":" .. n.name] or nil, text = "Fly to " .. mapName(n.m) .. (f.name and (" (flight master " .. f.name .. ")") or "") }
    elseif c.how == "boat" then
      -- what you actually do: which town and zone you sail to; in a town with two piers, which one
      local prevLeg = legs[#legs]
      local sameTown = prevLeg and prevLeg.how == "boat" and prevLeg.toTown == f.town
      local tram = f.dock and f.dock:find("^tram")
      -- a crossing that is more than a boat (the skyship and portal off Zephras Isle) says what you do
      local say = type(f.say) == "table" and n.dock and f.say[n.dock]
      -- a dock portal (Forever added them beside the boats and zeppelins): the dock's text may name the boat
      if c.kind == "portal" and not (say and say:lower():find("portal", 1, true)) then say = "Take the portal to " .. (n.town or n.name) .. " (" .. (n.zone or mapName(n.m)) .. ")" end
      local text = say or tram and ("Take the Deeprun Tram to " .. (n.town or n.name)) or ((sameTown and ("In " .. f.town .. ", walk to " .. (f.pier or "the other pier") .. " and take the boat to ") or "Boat to ") .. (n.town or n.name) .. " (" .. (n.zone or mapName(n.m)) .. ")")
      legs[#legs + 1] = { sm = f.m, sx = f.x, sy = f.y, how = "boat", m = f.m, x = f.x, y = f.y, toTown = n.town, text = text, dock = (f.dock and Travel.DOCKS[f.dock] and Travel.DOCKS[f.dock].learned) or f.dock }
    end
  end
  -- (where each flight master is in the world: the same every trip)
  if flightWConv ~= HBD.GetWorldCoordinatesFromZone then flightW, flightWConv = setmetatable({}, { __mode = "k" }), HBD.GetWorldCoordinatesFromZone end
  -- flight paths you do not have yet, right where a leg starts (the dock you land at, a town you ride through): grab
  -- them on the way - a minute now, flights later
  for _, l in ipairs(legs) do
    local lw = world(l.sm or l.m, l.sx or l.x, l.sy or l.y) -- where the leg starts (the dock you step off at)
    if lw then
      for m, list in pairs(ns.FLIGHT or {}) do
        for _, f in ipairs(list) do
          if not knowsFP(m, f[3]) then
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
  -- the trip's real seconds, its seconds on a flight or boat, and what it costs you in time spent playing
  return legs, secs[2], afk[2], dist[2]
end

-- A trip inside one zone is a walk - unless a flight you know lands so much nearer the spot that flying is clearly
-- quicker: Darkshire to Sven's camp at the far west end of Duskwood is five minutes on foot, or a flight to Sentinel
-- Hill and a short walk back across the border. The same planner decides (your flight master, the take-off, the flight,
-- the walk from where you land - through the real crossings), against the same trip on foot, and the flight is offered
-- only when it wins by a margin: the times are estimates, and a coin flip is not worth a flight. Your hearthstone is
-- left out of it: the plan has its own hearth steps, and an hour's cooldown is not spent on a walk inside one zone.
-- -> legs, seconds, seconds on foot; nil = walk
-- Cheap, because the card asks on every refresh and most steps are in your zone: a short walk plans nothing; neither
-- does a walk no flight could beat (your nearest flight point is too far, or you know fewer than two); and what was
-- decided holds while you stay within SHORTCUT_CELL yards and nothing else changed.
Travel.AFK_WEIGHT = 0.35     -- a second on a flight or a boat, as time spent playing (taking off and landing need you)
Travel.SHORTCUT_SLOWER = 0.2 -- a flight that means less time on foot may take this share longer than the walk
Travel.SHORTCUT_MIN = 120    -- a walk shorter than this (seconds) is never worth a flight: nothing is planned at all
Travel.SHORTCUT_SAVES = 45   -- the flight must save at least this many seconds...
Travel.SHORTCUT_SHARE = 0.15 -- ...and this share of the walk
Travel.SHORTCUT_CELL = 40
local shortcutMemo, shortcutCount = {}, 0
function Travel.Shortcut(from, to)
  from.w = from.w or world(from.m, from.x, from.y); to.w = to.w or world(to.m, to.x, to.y)
  if not (from.w and to.w and from.w[3] == to.w[3]) then return nil end
  local speed = Travel.Speed()
  local walk = d(from, to) * Travel.OFFNET / speed
  if walk < Travel.SHORTCUT_MIN then return nil end
  local function margin(w) return math.max(Travel.SHORTCUT_SAVES, Travel.SHORTCUT_SHARE * w) end
  local taxi = (ns.State and ns.State.knownTaxi) or {}
  local known = 0; for _ in pairs(taxi) do known = known + 1 end -- (flight paths are only ever gained: their number says which)
  local C = Travel.SHORTCUT_CELL
  local tk = to.m .. ":" .. to.x .. ":" .. to.y
  local key = table.concat({ from.m, math.floor(from.w[1] / C), math.floor(from.w[2] / C), tostring(taxi), known, speed, Travel.Side(), tostring(Travel.NET), tostring(ns.FLIGHT) }, "|")
  local memo = shortcutMemo[tk]
  if memo and memo.key == key then return memo.legs, memo.secs, memo.walk end
  if not memo then
    if shortcutCount >= 64 then shortcutMemo, shortcutCount = {}, 0 end
    memo = {}; shortcutMemo[tk] = memo; shortcutCount = shortcutCount + 1
  end
  memo.key, memo.legs, memo.secs, memo.walk = key, nil, nil, nil
  -- the quickest a flight could be: the walk to your nearest flight point, the take-off, and a landing right on the spot
  local letter = Travel.Side() == "horde" and "H" or "A"
  local near, count = nil, 0
  local function point(w) count = count + 1; local dd = math.sqrt((w[1] - from.w[1]) ^ 2 + (w[2] - from.w[2]) ^ 2); if not near or dd < near then near = dd end end
  if Travel.NET then
    for _, n in ipairs(net()) do
      if n.kind == "fp" and n.w[3] == from.w[3] and (not n.side or n.side:find(letter, 1, true)) and knowsFP(n.m, n.name) then point(n.w) end
    end
  else
    for m, list in pairs(ns.FLIGHT or {}) do
      local f = list[1]; local w = world(m, f[1], f[2])
      if w and w[3] == from.w[3] and knowsFP(m, f[3]) then point(w) end
    end
  end
  -- (the quickest a flight could be, in time on foot: the walk to the flight point and the take-off)
  if not (count >= 2 and near * Travel.OFFNET / speed + Travel.FLY_EXTRA <= walk - margin(walk) * Travel.AFK_WEIGHT) then return nil end
  local legs, secs, afk = Travel.Plan(from, to, { hearth = false })
  if not (legs and legs[1] and secs) then return nil end
  local rides = true
  for _, l in ipairs(legs) do if l.how ~= "ride" then rides = false; break end end
  if rides then return nil end
  -- on foot along the roads may beat the straight-line guess: the flight has to beat the better of the two
  local _, foot = Travel.Plan({ m = from.m, x = from.x, y = from.y, w = from.w }, { m = to.m, x = to.x, y = to.y, name = to.name, w = to.w }, { ground = true })
  if foot and foot < walk then walk = foot end
  -- the flight wins on time spent playing: its time on foot plus a share of its time in the air, by a margin, and not
  -- much slower on the clock (a flight and a short walk beats walking the length of Stranglethorn: the player)
  local onFoot = secs - (afk or 0)
  local playing = onFoot + (afk or 0) * Travel.AFK_WEIGHT
  if playing > walk - margin(walk) or secs > walk * (1 + Travel.SHORTCUT_SLOWER) then return nil end
  -- said on the card and the arrow: why you are sent to a flight master for a step in your own zone
  local saved = math.max(1, math.floor((walk - onFoot) / 60 + 0.5))
  legs[1].text = legs[1].text .. (secs <= walk - margin(walk) and (" - about " .. math.max(1, math.floor((walk - secs) / 60 + 0.5)) .. " min quicker than walking there")
    or (" - about as quick as walking, and " .. saved .. " min less on foot"))
  memo.legs, memo.secs, memo.walk = legs, secs, walk
  return legs, secs, walk
end

-- one line for the card: "Fly to Wetlands -> Boat from Menethil Harbor to Theramore -> Ride to The Barrens"
function Travel.Describe(legs)
  local parts = {}
  for _, l in ipairs(legs or {}) do parts[#parts + 1] = l.text end
  return table.concat(parts, "  >  ")
end
