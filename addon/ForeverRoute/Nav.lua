-- Navigation: the walking line from where you really stand to what the arrow points at (the step, or the first
-- waypoint of a trip on this map), along streets, bridges and ramps - never through a wall.
--
-- Data: one byte per map square (4 yd in a city, 8 outdoors), baked from the planner's walk maps by tools/navgrid.js
-- into Nav/Nav<map>.lua (ForeverRouteNavData[map]) and unpacked here the first time you need the zone. A square's
-- byte says from which of its 8 neighbours you can step into it; the few places with more than one level (a bridge
-- over the canal, an upper floor) are overlay nodes with their own links.
-- Search: A* from the target back to you, a couple of milliseconds per frame. What it has explored stays: when you
-- stray from the line, the way from your new spot is usually read straight off it, with no new search.
-- Outdoors a square also says what its ground is like (road, water, a hostile spawn nearby): a yard of road costs
-- less than a yard of field, a yard beside a mob that would come for you costs more, so the line keeps to the road
-- and walks round camps where that is not much further.
-- The arrow steers for a point a little way ahead along the line (Nav.Aim), not for the line's next corner.
-- The line is fixed in the world; only the part behind you goes.
-- Design, measurements and what is left for all zones: docs/research/navigation-paths.md.
local _, ns = ...
local Nav = {}
ns.Nav = Nav
local HBD = LibStub("HereBeDragons-2.0")
local byte, sub, rep, char, concat = string.byte, string.sub, string.rep, string.char, table.concat
local floor, sqrt, abs, max, min, huge = math.floor, math.sqrt, math.abs, math.max, math.min, math.huge

Nav.WEIGHT = 1.2       -- how greedy the search is: a few % longer lines for far fewer squares looked at
Nav.WEIGHT_RATED = 0.9 -- the same where the ground is rated (roads, mobs), counted against a yard of open ground: 1.2
                       -- times what a yard of road costs. Measured on seven walks in Elwynn, Redridge and the
                       -- Wetlands: at 1.1 the search runs straight past a road that bends away (a fifth to a half
                       -- of the road yards of the cheapest line); at 0.9 its line costs within 3% of the cheapest,
                       -- for 30 to 70% of the squares an estimate that cannot miss (0.75) looks at
Nav.BUDGET_MS = 2      -- CPU per frame while a zone unpacks or a search runs
Nav.STRAY_YD = 30      -- this far off the line: a new line from where you are
Nav.SWIM = 1.5         -- swimming costs this much more than walking (the planner's factor)
Nav.LOOK = 64          -- a straightened stretch spans at most this many squares
Nav.SLACK = 1.02       -- ...and may cost this much more than the squares the search walked
Nav.SLACK_ROAD = 1.08  -- the same from a road square: more would cut the road's bends
Nav.SLACK_OPEN = 1.2   -- ...and from open ground where the ground is rated (mobs)
Nav.SNAP = 6           -- you (or the target) may be this many squares from the nearest ground the grid knows
Nav.KEEP = 2           -- unpacked zones kept in memory
Nav.ROAD = 0.75        -- a yard of road costs this much of a yard of open ground: up to a third further to stay on it
Nav.MOB_NEAR = 1.4     -- a yard of open ground within about 24 yd of a hostile spawn costs this much more...
Nav.MOB_CLOSE = 2.2    -- ...and within about 12 yd this much (tools/navgrid.js MOB_NEAR, MOB_CLOSE)
Nav.MOB_ROAD = 1.4     -- on a road only a spawn within 12 yd counts, and this much: roads run past camps, and what
                       -- stands 20 yd off one mostly leaves you alone. (Counting those sent the line off the road
                       -- and through the quiet woods beside it - the opposite of what a road is for.)
Nav.MOB_GAP = 5        -- mobs this many levels under you (or more) are left out: they hardly notice you
Nav.AIM_REACH = 1.25   -- off the line by more than the arrow's look-ahead, it looks this many times as far as you are off

-- the 85 characters of the packed text -> 0..84 (tools/navgrid.js ALPHA)
local V = {}
do
  local A = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$&()*+,-./:;<=>?@_{}~"
  for i = 1, #A do V[byte(A, i)] = i - 1 end
end
-- the 8 directions (row, column), in the order of the bits of a square's byte
local DR = { -1, -1, -1, 0, 0, 1, 1, 1 }
local DC = { -1, 0, 1, -1, 1, -1, 0, 1 }
-- byte value -> the directions whose bit is set
local BITS = {}
for m = 0, 255 do
  local l, v = {}, m
  for d = 1, 8 do if v % 2 == 1 then l[#l + 1] = d end; v = floor(v / 2) end
  BITS[m] = l
end
-- (dr, dc) of a step -> the value of the bit "from the square I came from", in the byte of the square stepped into
local FROMBIT = {}
for d = 1, 8 do FROMBIT[(-DR[d] + 1) * 3 + (-DC[d] + 1)] = 2 ^ (d - 1) end

local clock = debugprofilestop or function() return GetTime() * 1000 end

function Nav.Data(m) return ForeverRouteNavData and ForeverRouteNavData[m] or nil end
function Nav.Has(m) return Nav.Data(m) ~= nil end

-- a packed byte grid (tools/navgrid.js packBase): rows of tokens (run / copy from the row above / literal) -> the rows
local function unpackRows(s, codes, W, pause)
  local codeChar = {}
  for i = 0, #codes / 2 - 1 do codeChar[i] = char(V[byte(codes, 2 * i + 1)] * 16 + V[byte(codes, 2 * i + 2)]) end
  local p, n = 1, #s
  local rows, nr, prevRow, parts, np, filled = {}, 0, nil, {}, 0, 0
  while p <= n do
    local t = V[byte(s, p)]; p = p + 1
    local kind, len
    if t == 84 then kind = V[byte(s, p)]; len = V[byte(s, p + 1)] * 85 + V[byte(s, p + 2)]; p = p + 3
    elseif t < 28 then kind, len = 0, t + 1
    elseif t < 56 then kind, len = 1, t - 27
    else kind, len = 2, t - 55 end
    if kind == 0 then
      local c = V[byte(s, p)]; p = p + 1
      local ch
      if c < 84 then ch = codeChar[c] else ch = char(V[byte(s, p)] * 16 + V[byte(s, p + 1)]); p = p + 2 end
      np = np + 1; parts[np] = rep(ch, len)
    elseif kind == 1 then
      np = np + 1; parts[np] = sub(prevRow, filled + 1, filled + len)
    else
      for _ = 1, len do
        local c = V[byte(s, p)]; p = p + 1
        np = np + 1
        if c < 84 then parts[np] = codeChar[c] else parts[np] = char(V[byte(s, p)] * 16 + V[byte(s, p + 1)]); p = p + 2 end
      end
    end
    filled = filled + len
    if filled >= W then
      prevRow = concat(parts, "", 1, np)
      nr = nr + 1; rows[nr] = prevRow
      np, filled = 0, 0
      if pause then pause() end
    end
  end
  return rows
end
-- which side's enemies count (the other side's guards and townsfolk are a layer of their own in the data)
function Nav.Side() local f = UnitFactionGroup and UnitFactionGroup("player"); return f == "Horde" and "H" or "A" end
-- your level, for which mobs matter
function Nav.Level() return (UnitLevel and UnitLevel("player")) or 1 end

-- Unpack a zone's packed text into what the search reads: `base`, `swim` and `terr` (one character per square) and
-- the overlay tables. pause (optional) is called now and then so the work can be spread over frames.
function Nav.Unpack(D, pause)
  local W, H = D.W, D.H
  local NC = W * H
  local N = { W = W, H = H, NC = NC, cell = D.cell, left = D.left, top = D.top, right = D.right, bottom = D.bottom, inst = D.inst }
  N.base = concat(unpackRows(D.base, D.codes, W, pause))
  if #N.base ~= NC then error("nav data: " .. #N.base .. " squares unpacked, " .. NC .. " expected") end
  -- water: runs of 0s and 1s in turn
  local s = D.swim
  local p, n = 1, #s
  local sw, ns_, bit = {}, 0, 0
  local ZERO, ONE = char(0), char(1)
  while p <= n do
    local len = V[byte(s, p)]; p = p + 1
    if len == 84 then len = (V[byte(s, p)] * 85 + V[byte(s, p + 1)]) * 85 + V[byte(s, p + 2)]; p = p + 3 end
    if len > 0 then ns_ = ns_ + 1; sw[ns_] = rep(bit == 1 and ONE or ZERO, len) end
    bit = 1 - bit
  end
  N.swim = concat(sw)
  if pause then pause() end
  -- what the ground is like, one character a square: 128 water, 64 road, 32 a hostile spawn right here, 1-31 the
  -- level (halved) of the hostile spawns around. A zone without this (a city) has only the water.
  if D.terr then
    local rows = unpackRows(D.terr, D.terrCodes, W, pause)
    local extra = D["terr" .. Nav.Side()]
    if extra then
      -- the mobs hostile to your side only: the higher level, and "right here" from either
      local more = unpackRows(extra, D["terr" .. Nav.Side() .. "Codes"], W, pause)
      local none = rep(char(0), W)
      for r = 1, #rows do
        local b = more[r]
        if b and b ~= none then
          local a, out = rows[r], {}
          for i = 1, W do
            local x, y = byte(a, i), byte(b, i)
            if y ~= 0 then
              local lx, ly = x % 32, y % 32
              x = x - x % 64 + ((x % 64 >= 32 or y >= 32) and 32 or 0) + (lx > ly and lx or ly)
            end
            out[i] = char(x)
          end
          rows[r] = concat(out)
          if pause then pause() end
        end
      end
    end
    N.terr = concat(rows)
    if #N.terr ~= NC then error("nav data: " .. #N.terr .. " ground squares unpacked, " .. NC .. " expected") end
    N.rated = true
  else
    N.terr = N.swim:gsub(char(1), char(128))
  end
  if pause then pause() end
  -- overlay nodes: node id = NC + j - 1 for the j-th (squares and base nodes count from 0)
  local oc, oz, osw, at, atN, bz, inc = {}, {}, {}, {}, {}, {}, {}
  local lp, ln = {}, {}
  local zmin = D.zmin or 0
  s = D.over; p = 1
  local cell, slot = 0, 0
  for j = 1, D.nOver or 0 do
    local t = V[byte(s, p)]; p = p + 1
    if t == 84 then t = ((V[byte(s, p)] * 85 + V[byte(s, p + 1)]) * 85 + V[byte(s, p + 2)]) * 85 + V[byte(s, p + 3)]; p = p + 4 end
    cell = cell + t
    if j == 1 or t > 0 then
      slot = 1; at[cell] = j
      bz[cell] = V[byte(s, p)] * 85 + V[byte(s, p + 1)] + zmin; p = p + 2
    else slot = slot + 1 end
    atN[cell] = slot
    oc[j] = cell
    oz[j] = V[byte(s, p)] * 85 + V[byte(s, p + 1)] + zmin
    local h = V[byte(s, p + 2)]; p = p + 3
    if h >= 42 then osw[j] = true; h = h - 42 end
    lp[j], ln[j] = p, h
    for _ = 1, h do if V[byte(s, p)] == 84 then p = p + 3 else p = p + 1 end end
    if pause and j % 64 == 0 then pause() end
  end
  local function link(from, to, cost) local l = inc[to]; if not l then l = {}; inc[to] = l end; l[#l + 1] = from; l[#l + 1] = cost end
  for j = 1, D.nOver or 0 do
    local me, sq = NC + j - 1, oc[j]
    local q = lp[j]
    for _ = 1, ln[j] do
      local c = V[byte(s, q)]; q = q + 1
      local where, sl, kind
      if c == 84 then -- a crowded square: the long form
        c = V[byte(s, q)] * 85 + V[byte(s, q + 1)]; q = q + 2
        kind = c % 3; c = floor(c / 3); sl = c % 251; where = floor(c / 251)
      else where, sl, kind = floor(c / 9), floor(c / 3) % 3, c % 3 end
      local osq = where == 8 and sq or (sq + DR[where + 1] * W + DC[where + 1])
      local other = sl == 0 and osq or (NC + at[osq] + sl - 2)
      if kind ~= 1 then link(other, me, 0) end
      if kind ~= 0 then link(me, other, 0) end
    end
    if pause and j % 64 == 0 then pause() end
  end
  -- far links (lifts, recorded trails): from, to, yards
  s = D.far or ""
  local function num4(q) return ((V[byte(s, q)] * 85 + V[byte(s, q + 1)]) * 85 + V[byte(s, q + 2)]) * 85 + V[byte(s, q + 3)] end
  for q = 1, #s, 10 do link(num4(q), num4(q + 4), V[byte(s, q + 8)] * 85 + V[byte(s, q + 9)]) end
  -- base nodes whose byte is 0 (nothing steps into them from a neighbouring base; reached through links)
  local solo = {}
  s = D.solo or ""
  for q = 1, #s, 4 do solo[num4(q)] = true end
  N.oc, N.oz, N.osw, N.at, N.atN, N.bz, N.inc, N.solo = oc, oz, osw, at, atN, bz, inc, solo
  -- steps to the 8 neighbours for this width, and what they cost
  local off, cost = {}, {}
  for d = 1, 8 do off[d] = DR[d] * W + DC[d]; cost[d] = (DR[d] ~= 0 and DC[d] ~= 0) and D.cell * 1.41421356 or D.cell end
  N.off, N.cost = off, cost
  return N
end

-- What a yard of each kind of ground costs (by the square's character in N.terr), for someone of this level.
function Nav.Factors(N, level)
  level = level or Nav.Level()
  local key = level .. ":" .. Nav.ROAD .. ":" .. Nav.MOB_NEAR .. ":" .. Nav.MOB_CLOSE .. ":" .. Nav.MOB_ROAD .. ":" .. Nav.MOB_GAP .. ":" .. Nav.SWIM
  if N.F and N.Fkey == key then return N.F end
  local F = {}
  for b = 0, 255 do
    local road, close = b < 128 and b % 128 >= 64, b % 64 >= 32
    local f = b >= 128 and Nav.SWIM or (road and Nav.ROAD or 1)
    local lvl = (b % 32) * 2
    if lvl > 0 and lvl > level - Nav.MOB_GAP then
      if road then f = f * (close and Nav.MOB_ROAD or 1) else f = f * (close and Nav.MOB_CLOSE or Nav.MOB_NEAR) end
    end
    F[b] = f
  end
  N.F, N.Fkey = F, key
  return F
end
-- is this square road? and is a hostile spawn that matters at this level near it (2: right here)?
function Nav.Road(N, sq) return byte(N.terr, sq + 1) % 128 >= 64 end
function Nav.Mob(N, sq, level)
  local b = byte(N.terr, sq + 1)
  local lvl = (b % 32) * 2
  if lvl == 0 or lvl <= (level or Nav.Level()) - Nav.MOB_GAP then return nil end
  return b % 64 >= 32 and 2 or 1
end

-- unpacked zones (the last Nav.KEEP used)
local grids, gridUse, useN = {}, {}, 0
function Nav.Grid(m, pause)
  local N = grids[m]
  if not N then
    local D = Nav.Data(m); if not D then return nil end
    local t0 = clock()
    N = Nav.Unpack(D, pause)
    N.m = m
    N.unpackMs = clock() - t0
    grids[m] = N
    local n = 0; for _ in pairs(grids) do n = n + 1 end
    if n > Nav.KEEP then
      local old, oldUse
      for k in pairs(grids) do if k ~= m and (not oldUse or (gridUse[k] or 0) < oldUse) then old, oldUse = k, gridUse[k] or 0 end end
      if old then grids[old] = nil; gridUse[old] = nil end
    end
  end
  useN = useN + 1; gridUse[m] = useN
  return N
end
function Nav.Forget() grids, gridUse = {}, {} end
function Nav._grids() return grids end

-- a node's square, and the middle of a square in world yards (as HereBeDragons counts them)
local function squareOf(N, n) if n < N.NC then return n end return N.oc[n - N.NC + 1] end
local function centre(N, sq)
  local r = floor(sq / N.W)
  return N.left - (sq - r * N.W + 0.5) * N.cell, N.top - (r + 0.5) * N.cell
end
local function heightOf(N, n) if n < N.NC then return N.bz[n] end return N.oz[n - N.NC + 1] end
local function swims(N, n) if n < N.NC then return byte(N.swim, n + 1) == 1 end return N.osw[n - N.NC + 1] or false end
-- is there any ground in this square?
function Nav.Ground(N, sq) return byte(N.base, sq + 1) ~= 0 or N.solo[sq] or N.at[sq] ~= nil end
local function squareAt(N, wx, wy)
  local c, r = floor((N.left - wx) / N.cell), floor((N.top - wy) / N.cell)
  if r < 0 or c < 0 or r >= N.H or c >= N.W then return nil end
  return r * N.W + c
end
function Nav.Inside(D, wx, wy) return wx <= D.left and wx >= D.right and wy <= D.top and wy >= D.bottom end
Nav._squareOf, Nav._centre, Nav._squareAt, Nav._heightOf = squareOf, centre, squareAt, heightOf

-- the nodes at a world point: those of its square, or of the nearest ring of squares that has any (you may stand on
-- a crate the grid left out). With a height: the one node nearest to it. Without: all of them.
local function nodesNear(N, wx, wy, z)
  local sq0 = squareAt(N, wx, wy); if not sq0 then return {} end
  local W, H, NC, base, at, atN, solo = N.W, N.H, N.NC, N.base, N.at, N.atN, N.solo
  local r0 = floor(sq0 / W); local c0 = sq0 - r0 * W
  for rad = 0, Nav.SNAP do
    local found = {}
    for dr = -rad, rad do
      local r = r0 + dr
      if r >= 0 and r < H then
        local stepc = (abs(dr) == rad) and 1 or (rad * 2)
        for dc = -rad, rad, (stepc > 0 and stepc or 1) do
          local c = c0 + dc
          if c >= 0 and c < W then
            local sq = r * W + c
            if byte(base, sq + 1) ~= 0 or solo[sq] then found[#found + 1] = sq end
            local j = at[sq]
            if j then for k = j, j + atN[sq] - 1 do found[#found + 1] = NC + k - 1 end end
          end
        end
      end
    end
    if #found > 0 then
      if not z then return found, rad end
      local best, bd
      for _, n in ipairs(found) do
        local d = abs((heightOf(N, n) or z) - z)
        if not bd or d < bd then best, bd = n, d end
      end
      return { best }, rad
    end
  end
  return {}
end
Nav._nodesNear = nodesNear

-- Start a search on grid N from the target (tx, ty, tz) back to you (sx, sy, sz); heights when known.
-- Nav.Run works on it a slice at a time; then S.found is the node you stand on (nil: no way).
function Nav.Search(N, sx, sy, sz, tx, ty, tz, level)
  local S = { N = N, F = Nav.Factors(N, level), w = N.cell * (N.rated and Nav.WEIGHT_RATED or Nav.WEIGHT), g = {}, nxt = {}, closed = {}, hk = {}, hv = {}, hn = 0, starts = {}, sx = sx, sy = sy, tx = tx, ty = ty, tz = tz, expansions = 0, done = false, ms = 0 }
  local goals = nodesNear(N, tx, ty, tz)
  local starts = nodesNear(N, sx, sy, sz)
  if #goals == 0 or #starts == 0 then S.done = true; return S end
  for _, n in ipairs(starts) do S.starts[n] = true end
  local ssq = squareOf(N, starts[1])
  S.sr = floor(ssq / N.W); S.sc = ssq - S.sr * N.W
  local w = S.w
  for _, n in ipairs(goals) do
    local sq = squareOf(N, n)
    local r = floor(sq / N.W); local c = sq - r * N.W
    local dr, dc = abs(r - S.sr), abs(c - S.sc)
    S.g[n] = 0
    local k = (dr > dc and dr + 0.4142 * dc or dc + 0.4142 * dr) * w
    local hk, hv = S.hk, S.hv
    local i = S.hn + 1; S.hn = i
    while i > 1 do local q = floor(i / 2); if hk[q] <= k then break end; hk[i], hv[i] = hk[q], hv[q]; i = q end
    hk[i], hv[i] = k, n
  end
  return S
end

-- work on a search for up to budgetMs (nil: to the end); true when it is finished
function Nav.Run(S, budgetMs)
  if S.done then return true end
  local N = S.N
  local g, nxt, closed, starts, hk, hv = S.g, S.nxt, S.closed, S.starts, S.hk, S.hv
  local W, NC, base, terr, inc, oc, osw = N.W, N.NC, N.base, N.terr, N.inc, N.oc, N.osw
  local OFF, COST, cellYd, F = N.off, N.cost, N.cell, S.F
  local sr, sc, w, swimF = S.sr, S.sc, S.w, Nav.SWIM
  local hn = S.hn
  local t0 = clock()
  local count = 0
  while hn > 0 do
    -- pop the most promising node
    local u = hv[1]
    local lk, lv = hk[hn], hv[hn]
    hk[hn], hv[hn] = nil, nil
    hn = hn - 1
    if hn > 0 then
      local i = 1
      while true do
        local l = i * 2; local r = l + 1; local m = i; local mk = lk
        if l <= hn and hk[l] < mk then m = l; mk = hk[l] end
        if r <= hn and hk[r] < mk then m = r; mk = hk[r] end
        if m == i then break end
        hk[i], hv[i] = hk[m], hv[m]; i = m
      end
      hk[i], hv[i] = lk, lv
    end
    if not closed[u] then
      closed[u] = true
      count = count + 1
      if starts[u] then S.hn = hn; S.found = u; S.done = true; S.expansions = S.expansions + count; S.ms = S.ms + (clock() - t0); return true end
      local gu = g[u]
      local fu -- what a yard of this node's ground costs; a step costs the dearer of its two ends
      if u < NC then
        fu = F[byte(terr, u + 1)]
        local m = byte(base, u + 1)
        if m > 0 then
          local r = floor(u / W); local c = u - r * W
          local list = BITS[m]
          for i = 1, #list do
            local d = list[i]
            local v = u + OFF[d]
            if not closed[v] then
              local fv = F[byte(terr, v + 1)]
              if fv < fu then fv = fu end
              local nv = gu + COST[d] * fv
              local old = g[v]
              if not old or nv < old then
                g[v] = nv; nxt[v] = u
                local dr, dc = r + DR[d] - sr, c + DC[d] - sc
                if dr < 0 then dr = -dr end; if dc < 0 then dc = -dc end
                local k = nv + (dr > dc and dr + 0.4142 * dc or dc + 0.4142 * dr) * w
                hn = hn + 1
                local j = hn
                while j > 1 do local q = floor(j / 2); if hk[q] <= k then break end; hk[j], hv[j] = hk[q], hv[q]; j = q end
                hk[j], hv[j] = k, v
              end
            end
          end
        end
      else fu = osw[u - NC + 1] and swimF or 1 end
      local l = inc[u]
      if l then
        local usq = u < NC and u or oc[u - NC + 1]
        local ur = floor(usq / W); local uc = usq - ur * W
        for i = 1, #l, 2 do
          local v = l[i]
          if not closed[v] then
            local vsq = v < NC and v or oc[v - NC + 1]
            local vr = floor(vsq / W); local vc = vsq - vr * W
            local cost = l[i + 1]
            if cost == 0 then
              cost = sqrt((vr - ur) ^ 2 + (vc - uc) ^ 2) * cellYd
              if cost < cellYd / 2 then cost = cellYd / 2 end
            end
            local fv
            if v < NC then fv = F[byte(terr, v + 1)] else fv = osw[v - NC + 1] and swimF or 1 end
            if fv < fu then fv = fu end
            local nv = gu + cost * fv
            local old = g[v]
            if not old or nv < old then
              g[v] = nv; nxt[v] = u
              local dr, dc = vr - sr, vc - sc
              if dr < 0 then dr = -dr end; if dc < 0 then dc = -dc end
              local k = nv + (dr > dc and dr + 0.4142 * dc or dc + 0.4142 * dr) * w
              hn = hn + 1
              local j = hn
              while j > 1 do local q = floor(j / 2); if hk[q] <= k then break end; hk[j], hv[j] = hk[q], hv[q]; j = q end
              hk[j], hv[j] = k, v
            end
          end
        end
      end
      if budgetMs and count % 64 == 0 and clock() - t0 > budgetMs then
        S.hn = hn; S.expansions = S.expansions + count; S.ms = S.ms + (clock() - t0)
        return false
      end
    end
  end
  S.hn = hn; S.done = true; S.expansions = S.expansions + count; S.ms = S.ms + (clock() - t0)
  return true
end

-- can you walk the straight run of squares from base square a to base square b, for no more than maxCost (counted
-- the way the search counts: F, what a yard of each kind of ground costs)?
local function clear(N, a, b, maxCost, F)
  local W, base, terr, cellYd = N.W, N.base, N.terr, N.cell
  F = F or Nav.Factors(N)
  local r, r1 = floor(a / W), floor(b / W)
  local c, c1 = a - r * W, b - r1 * W
  local dr, dc = abs(r1 - r), abs(c1 - c)
  local sr, sc = (r1 > r) and 1 or -1, (c1 > c) and 1 or -1
  local err = dc - dr
  local cost = 0
  local cf = F[byte(terr, a + 1)]
  while r ~= r1 or c ~= c1 do
    local e2 = 2 * err
    local mr, mc = 0, 0
    if e2 > -dr then err = err - dr; c = c + sc; mc = sc end
    if e2 < dc then err = err + dc; r = r + sr; mr = sr end
    local nx = r * W + c
    local m = byte(base, nx + 1)
    if floor(m / FROMBIT[(mr + 1) * 3 + (mc + 1)]) % 2 ~= 1 then return false end
    local step = (mr ~= 0 and mc ~= 0) and cellYd * 1.41421356 or cellYd
    local nf = F[byte(terr, nx + 1)]
    cost = cost + step * (nf > cf and nf or cf)
    if cost > maxCost then return false end
    cf = nf
  end
  return true
end
Nav._clear = clear

-- the nodes from `from` to the target, as the search left them
local function trace(S, from)
  local nodes, n, guard = {}, from, 0
  while n do
    nodes[#nodes + 1] = n
    n = S.nxt[n]
    guard = guard + 1
    if guard > 100000 then break end
  end
  return nodes
end
-- The line for a finished search, from node `from` (default: where the search found you): the squares the search
-- walked, straightened wherever the straight run is walkable too and no dearer. Points are { wx, wy, z or nil }:
-- first where you stand, last the target itself. sx, sy: where you stand now (default: where the search started).
function Nav.Path(S, from, sx, sy, pause)
  from = from or S.found
  if not (S.done and from and S.g[from]) then return nil end
  local N, g = S.N, S.g
  local NC = N.NC
  local nodes = trace(S, from)
  local n = #nodes
  local keep = { 1 }
  local a = 1
  local terr, rated = N.terr, N.rated
  while a < n do
    local j = a + 1
    if nodes[a] < NC then
      -- how much dearer the straight run may be: little from a road square (the line stays on the road round its
      -- bends), more in the open (no stepping aside for every spawn)
      local slack = Nav.SLACK
      if rated then slack = byte(terr, nodes[a] + 1) % 128 >= 64 and Nav.SLACK_ROAD or Nav.SLACK_OPEN end
      local k, misses, lim = a + 2, 0, min(n, a + Nav.LOOK)
      while k <= lim and nodes[k] < NC and misses < 3 do
        if nodes[k - 1] >= NC then break end
        if clear(N, nodes[a], nodes[k], (g[nodes[a]] - g[nodes[k]]) * slack + 0.01, S.F) then j = k; misses = 0 else misses = misses + 1 end
        k = k + 1
      end
    end
    keep[#keep + 1] = j
    a = j
    if pause then pause() end
  end
  sx, sy = sx or S.sx, sy or S.sy
  local pts = { { sx, sy, heightOf(N, nodes[1]) } }
  -- the square you stand in is not a point of its own (the line starts at you); the target's own point replaces
  -- the last square's middle when it lies inside it
  for i = 2, #keep do
    local node = nodes[keep[i]]
    local x, y = centre(N, squareOf(N, node))
    pts[#pts + 1] = { x, y, heightOf(N, node) }
  end
  local last = pts[#pts]
  local dEnd = sqrt((last[1] - S.tx) ^ 2 + (last[2] - S.ty) ^ 2)
  if #pts > 1 and dEnd <= N.cell * 1.5 then last[1], last[2] = S.tx, S.ty else pts[#pts + 1] = { S.tx, S.ty, S.tz or last[3] } end
  if S.tz then pts[#pts][3] = S.tz end
  -- a point that sits (within a third of a square) on the straight run between its neighbours says nothing: a
  -- bridge deck is a row of overlay nodes, each of them a point until here
  local eps, slim = N.cell * 0.35, { pts[1] }
  for i = 2, #pts - 1 do
    local A, B, p = slim[#slim], pts[i + 1], pts[i]
    local dx, dy = B[1] - A[1], B[2] - A[2]
    local L = sqrt(dx * dx + dy * dy)
    local d = L > 0 and abs((p[1] - A[1]) * dy - (p[2] - A[2]) * dx) / L or 0
    local between = L > 0 and ((p[1] - A[1]) * dx + (p[2] - A[2]) * dy) > 0 and ((p[1] - B[1]) * dx + (p[2] - B[2]) * dy) < 0
    local zJump = p[3] and A[3] and abs(p[3] - A[3]) > 3.5
    if d > eps or not between or zJump then slim[#slim + 1] = p end
  end
  if #pts > 1 then slim[#slim + 1] = pts[#pts] end
  pts = slim
  local rem = {}; rem[#pts] = 0
  for k = #pts - 1, 1, -1 do rem[k] = rem[k + 1] + sqrt((pts[k + 1][1] - pts[k][1]) ^ 2 + (pts[k + 1][2] - pts[k][2]) ^ 2) end
  return { pts = pts, rem = rem, len = rem[1], cursor = 1, z0 = pts[1][3], z1 = pts[#pts][3], nodes = nodes, inst = N.inst, m = N.m, mapYd = N.left - N.right, cell = N.cell, nav = true }
end

-- which grid serves a walk from (px, py) to (tx, ty) in instance inst: the map you are on if it holds both ends,
-- else the target's map, else any that does
function Nav.MapFor(px, py, tx, ty, inst, here, there)
  local function fits(m)
    local D = m and Nav.Data(m)
    return D and D.inst == inst and Nav.Inside(D, px, py) and Nav.Inside(D, tx, ty)
  end
  if fits(here) then return here end
  if fits(there) then return there end
  for m in pairs(ForeverRouteNavData or {}) do if fits(m) then return m end end
  return nil
end

-- One go, for tests and tools: from and to in world yards on map m. -> path (or nil), the search, total ms
function Nav.Find(m, sx, sy, sz, tx, ty, tz, level)
  local N = Nav.Grid(m); if not N then return nil end
  local t0 = clock()
  local S = Nav.Search(N, sx, sy, sz, tx, ty, tz, level)
  Nav.Run(S)
  local P = Nav.Path(S)
  return P, S, clock() - t0
end

-- distance from a point to the segment a-b
local function segDist(px, py, a, b)
  local dx, dy = b[1] - a[1], b[2] - a[2]; local L2 = dx * dx + dy * dy
  local t = L2 > 0 and max(0, min(1, ((px - a[1]) * dx + (py - a[2]) * dy) / L2)) or 0
  return sqrt((px - a[1] - t * dx) ^ 2 + (py - a[2] - t * dy) ^ 2), t
end
-- Where you are along a line: the nearest segment from the cursor on (the cursor only moves forward: what is behind
-- you is gone). Sets P.cursor and P.left (yards still to walk); returns the segment and how far off the line you are.
function Nav.Advance(P, px, py)
  local pts = P.pts
  local best, bd, bt = P.cursor, huge, 0
  for j = P.cursor, #pts - 1 do
    local d, t = segDist(px, py, pts[j], pts[j + 1])
    if d < bd - 0.01 then best, bd, bt = j, d, t end
  end
  P.cursor = best
  if pts[best + 1] then
    local a, b = pts[best], pts[best + 1]
    P.left = P.rem[best + 1] + (1 - bt) * sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
  else P.left = 0 end
  return best, bd
end

-- Where to steer along a line (P.pts, P.rem; a live line or the planner's path): not for the next corner - that
-- swings the arrow by the whole corner the moment you reach it, and by a lot whenever you stand a little beside the
-- line near a point - but for the spot on the line `look` yards from you, ahead of where you are on it (where the
-- line leaves a circle of that size round you). Coming up to a corner that spot slides round it, so the arrow turns
-- over those yards, as you would; where you stand beside the line hardly matters. Further off the line than the
-- look-ahead, the circle grows to reach it (Nav.AIM_REACH times as far as you are off), so the arrow leads back onto
-- the line at a slant, not square to it.
-- The look-ahead is the caller's (Arrow.lua: short in a city and indoors, longer in open country and on a mount).
-- It is not shortened where the straight run to the spot is blocked: that was tried (asking the walk map) and made
-- the spot jump at every corner - the swing this is here to take away. A short look-ahead cuts a corner by no more
-- than the old arrow did (it turned for the next point 7 yd before a corner).
-- Where you are = the nearest stretch from P.cursor on (it only moves forward).
-- -> the spot { x, y } (one table per line, reused), yards to walk (to the spot, then the rest of the line), how
--    far off the line you are, the line's height where you are (when it has heights)
function Nav.Aim(P, px, py, look)
  local pts, rem = P.pts, P.rem
  local n = #pts
  local aim = P.aim; if not aim then aim = {}; P.aim = aim end
  if n < 2 then
    local a = pts[1]
    aim[1], aim[2] = a[1], a[2]
    local d = sqrt((a[1] - px) ^ 2 + (a[2] - py) ^ 2)
    return aim, d, d, a[3] or P.z0
  end
  local c0 = P.cursor or 1; if c0 < 1 then c0 = 1 end; if c0 > n - 1 then c0 = n - 1 end
  local best, bd, bt = c0, huge, 0
  for j = c0, n - 1 do
    local d, t = segDist(px, py, pts[j], pts[j + 1])
    if d < bd - 0.01 then best, bd, bt = j, d, t end
  end
  P.cursor = best
  local a, b = pts[best], pts[best + 1]
  local zHere = P.z0
  if a[3] and b[3] then zHere = a[3] + (b[3] - a[3]) * bt end
  -- forward from where you are on the line to where it leaves the circle
  local R = look
  if bd * Nav.AIM_REACH > R then R = bd * Nav.AIM_REACH end
  local j, t0, t = best, bt, nil
  while true do
    a, b = pts[j], pts[j + 1]
    local dx, dy, ex, ey = b[1] - a[1], b[2] - a[2], a[1] - px, a[2] - py
    local A, B, C = dx * dx + dy * dy, 2 * (dx * ex + dy * ey), ex * ex + ey * ey - R * R
    local disc = B * B - 4 * A * C
    if A > 0 and disc >= 0 then
      local t2 = (-B + sqrt(disc)) / (2 * A)
      if t2 >= t0 and t2 <= 1 then t = t2; break end
    end
    if j >= n - 1 then t = 1; break end -- the line ends inside the circle: its end
    j = j + 1; t0 = 0
  end
  local ax, ay = a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t
  aim[1], aim[2] = ax, ay
  return aim, sqrt((ax - px) ^ 2 + (ay - py) ^ 2) + rem[j + 1] + (1 - t) * (rem[j] - rem[j + 1]), bd, zHere
end
-- ---------------------------------------------------------------------------------------------------------------
-- The live line: for what the arrow points at right now.
-- Nav.Want(t): t = { key, wx, wy, inst (world, as HereBeDragons counts), z (height, when known), m (its map) }, or
-- nil for nothing. Fires FR_NAVPATH(key, path or nil) when a line is ready, changed or gone, and
-- FR_NAVPROGRESS(key, path) as you move along it.
local live -- { key, wx, wy, inst, z, m, path, S, job, failedAt, at }
local frame = CreateFrame("Frame")
frame:Hide()
Nav.stats = {}

-- called all through the work: gives the frame back once this slice has used its milliseconds
local sliceT0 = 0
local function pause()
  if coroutine.running() and clock() - sliceT0 >= Nav.BUDGET_MS then coroutine.yield() end
end
local function setPath(P)
  if not live then return end
  live.path = P
  ns.Fire("FR_NAVPATH", live.key, P)
end
-- plan from where you stand; runs inside a coroutine, a slice per frame
local function plan(L)
  local px, py, pinst = HBD:GetPlayerWorldPosition()
  if not px or pinst ~= L.inst then L.waiting = true; return end
  local here = ns.State.Position()
  local m = Nav.MapFor(px, py, L.wx, L.wy, L.inst, here, L.m)
  if not m then L.none = true; if live == L then setPath(nil) end; return end
  local t0 = clock()
  local N = Nav.Grid(m, pause)
  -- the height you are at: where the last line had you, when you are still near it (a bridge stays a bridge)
  local sz = L.zHint
  local S = Nav.Search(N, px, py, sz, L.wx, L.wy, L.z)
  local slices = 1
  while not Nav.Run(S, Nav.BUDGET_MS) do slices = slices + 1; pause(); if live ~= L then return end end
  if live ~= L then return end
  L.S = S
  local P = Nav.Path(S, nil, nil, nil, pause)
  if live ~= L then return end
  L.failedAt = (not P) and GetTime() or nil
  L.from = { px, py }
  Nav.stats = { map = m, expansions = S.expansions, searchMs = S.ms, unpackMs = N.unpackMs, frames = slices, totalMs = clock() - t0, len = P and P.len, points = P and #P.pts }
  if P then local x, y = HBD:GetPlayerWorldPosition(); if x then Nav.Advance(P, x, y) end end
  setPath(P)
end
local function start(L)
  L.waiting, L.none = nil, nil
  L.job = coroutine.create(plan)
  L.at = GetTime()
  frame:Show()
end

function Nav.Want(t)
  if not (t and t.wx and t.inst) then
    if live then local key, had = live.key, live.path; live = nil; frame:Hide(); if had then ns.Fire("FR_NAVPATH", key, nil) end end
    return
  end
  if live and live.key == t.key and abs(live.wx - t.wx) < 1 and abs(live.wy - t.wy) < 1 and live.inst == t.inst then return end
  local had = live and live.path
  local oldKey = live and live.key
  live = { key = t.key, wx = t.wx, wy = t.wy, inst = t.inst, z = t.z, m = t.m }
  if had then ns.Fire("FR_NAVPATH", oldKey, nil) end
  start(live)
end
function Nav.Live() return live end
-- is a line on its way (or drawn) for the current target? (false: no walk map holds both ends, or no way on it)
function Nav.Coming() return live ~= nil and not live.none and not live.failedAt and not live.waiting end
-- the line for the target with this key, or nil (none yet, no data for this zone, no way)
function Nav.PathFor(key) return live and live.key == key and live.path or nil end
function Nav.Clear() Nav.Want(nil) end
-- plan again from scratch (the tests; after a teleport)
function Nav.Replan() if live then live.S = nil; start(live) end end

-- you left the line: read the way from your new spot off what the last search explored; a new search only when it
-- never looked there
local function rejoin(L, px, py)
  local S = L.S
  local zHint
  if L.path then local seg = L.path.cursor; local a = L.path.pts[seg]; zHint = a and a[3] end
  L.zHint = zHint
  if S and S.done and S.found then
    local cands = nodesNear(S.N, px, py, zHint)
    local best, bg
    for _, n in ipairs(cands) do if S.closed[n] and S.g[n] and (not bg or S.g[n] < bg) then best, bg = n, S.g[n] end end
    if best then
      local P = Nav.Path(S, best, px, py)
      if P then
        Nav.Advance(P, px, py)
        Nav.stats.rejoined = (Nav.stats.rejoined or 0) + 1
        L.from = { px, py }
        setPath(P)
        return
      end
    end
  end
  start(L)
end

local acc = 0
local function tick(el)
  local L = live
  if not L then frame:Hide(); return end
  if L.job then
    sliceT0 = clock()
    local ok, err = coroutine.resume(L.job, L)
    if coroutine.status(L.job) == "dead" then L.job = nil end
    if not ok then L.job = nil; L.failedAt = GetTime(); error(err, 0) end
    return
  end
  acc = acc + (el or 0)
  if acc < 0.5 then return end
  acc = 0
  local px, py, pinst = HBD:GetPlayerWorldPosition()
  if not px then return end
  if pinst ~= L.inst then if L.path then setPath(nil) end; L.waiting = true; return end
  if L.waiting then start(L); return end
  local P = L.path
  if P then
    local was, wasLeft = P.cursor, P.left
    local _, off = Nav.Advance(P, px, py)
    if off > Nav.STRAY_YD then rejoin(L, px, py)
    elseif P.cursor ~= was or not wasLeft or abs(wasLeft - P.left) > 4 then ns.Fire("FR_NAVPROGRESS", L.key, P) end
  elseif L.none then
    -- no grid held both ends: look again once you have moved on (a zone border)
    if not L.from or (px - L.from[1]) ^ 2 + (py - L.from[2]) ^ 2 > 2500 then L.from = { px, py }; start(L) end
  elseif L.failedAt and (GetTime() - L.failedAt > 10 or (L.from and (px - L.from[1]) ^ 2 + (py - L.from[2]) ^ 2 > 900)) then
    start(L)
  end
end
frame:SetScript("OnUpdate", ns.Guard("nav", function(_, el) tick(el) end))
-- for tests: run the live line's work to the end (every frame it would take), then one check of where you are
function Nav.Settle(maxFrames)
  local n = 0
  while live and live.job and n < (maxFrames or 100000) do tick(0); n = n + 1 end
  acc = 1; tick(0)
  while live and live.job and n < (maxFrames or 100000) do tick(0); n = n + 1 end
  return n
end
ns.On("FR_LOADED", function() ns.On("PLAYER_ENTERING_WORLD", function() if live then live.waiting = true; frame:Show() end end) end)

-- /fr nav: what the game says about where you, the step and the minimap are - to tell a wrong coordinate from a
-- wrong placement (docs/research/navigation-paths.md, "Telling the causes apart in game")
function Nav.Report()
  local out = {}
  local function add(fmt, ...) out[#out + 1] = string.format(fmt, ...) end
  local function f(v) return type(v) == "number" and string.format("%.1f", v) or tostring(v) end
  local px, py, pinst = HBD:GetPlayerWorldPosition()
  local best = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  local zx, zy, zm = HBD:GetPlayerZonePosition()
  add("you: map %s (HereBeDragons %s) at %s, %s; world %s, %s in %s", tostring(best), tostring(zm), zx and f(zx * 100) or "-", zy and f(zy * 100) or "-", f(px), f(py), tostring(pinst))
  local HBDP = LibStub("HereBeDragons-Pins-2.0")
  local _, minor = LibStub:GetLibrary("HereBeDragons-Pins-2.0")
  local mm = HBDP.Minimap or Minimap
  add("minimap: %s x %s, scale %s, zoom %s, view radius %s yd, shape %s, rotates %s, pins lib v%s%s", f(mm:GetWidth()), f(mm:GetHeight()), f(mm:GetScale()), tostring(mm:GetZoom()),
    (C_Minimap and C_Minimap.GetViewRadius) and f(C_Minimap.GetViewRadius()) or "no API (zoom table)", tostring(GetMinimapShape and GetMinimapShape() or "round"), tostring(GetCVar("rotateMinimap")), tostring(minor), mm ~= Minimap and " on another addon's minimap frame" or "")
  if abs(mm:GetWidth() - mm:GetHeight()) > 1 then add("  the minimap is not square: pins are placed as if it were - off by more the further away they are") end
  local t = ns.Arrow and ns.Arrow.Current and ns.Arrow.Current()
  if t and t.wx and px then
    local d = sqrt((px - t.wx) ^ 2 + (py - t.wy) ^ 2)
    add("target: map %s at %s, %s; world %s, %s - %s yd from you", tostring(t.m), f((t.x or 0) * 100), f((t.y or 0) * 100), f(t.wx), f(t.wy), f(d))
    add("  standing on it this should read under about 5 yd; if not, its coordinates are that far out")
    for _, p in ipairs(ns.Pins and ns.Pins._used or {}) do
      if p.where == "mini" then
        local _, _, _, ox, oy = p:GetPoint(1)
        local radius = (C_Minimap and C_Minimap.GetViewRadius) and C_Minimap.GetViewRadius() or nil
        if ox and radius and radius > 0 then
          add("  minimap pin at %s, %s px from the middle (%s); by your positions it belongs at %s, %s", f(ox), f(oy), p:IsShown() and "shown" or "hidden", f((px - t.wx) / radius * mm:GetWidth() / 2), f(-(py - t.wy) / radius * mm:GetHeight() / 2))
        end
      end
    end
  else add("target: none with a place") end
  local D = zm and Nav.Data(zm)
  local md = zm and HBD.mapData and HBD.mapData[zm]
  if D and md and md[1] and md[1] > 0 then
    add("map %s: the game says left %s top %s, %s x %s yd; the walk map was made for left %s top %s, %s x %s%s", tostring(zm), f(md[3]), f(md[4]), f(md[1]), f(md[2]), f(D.left), f(D.top), f(D.left - D.right), f(D.top - D.bottom),
      (abs(md[3] - D.left) > 2 or abs(md[4] - D.top) > 2 or abs(md[1] - (D.left - D.right)) > 2) and " - THEY DIFFER: the plan's coordinates for this map are off" or " (the same)")
  elseif zm then add("map %s: %s", tostring(zm), D and "walk map present" or "no walk map shipped - the line falls back to the planned path") end
  local s = Nav.stats or {}
  if live then
    add("line: %s; last search on map %s: %s squares in %s ms over %s frames (unpack %s ms), %s yd in %s points, re-read %s times", live.path and "drawn" or (live.job and "being found" or (live.none and "no walk map holds both ends" or "none")), tostring(s.map), tostring(s.expansions), f(s.searchMs), tostring(s.frames), f(s.unpackMs), f(s.len), tostring(s.points), tostring(s.rejoined or 0))
  else add("line: nothing to walk to") end
  if ns.Pins and ns.Pins.Sweep then add("stray frames on the minimap hidden just now: %d", ns.Pins.Sweep()) end
  return out
end
Nav._tick = tick
