-- Numbered pins for the current and next steps on the world map and minimap (HereBeDragons-Pins).
-- Rebuilt only when the set of pinned steps changes (or one of them opens). Click a pin to look at the step;
-- Shift-click to jump to it.
local _, ns = ...
local Style = ns.Style
local Pins = {}
ns.Pins = Pins
local HBDP = LibStub("HereBeDragons-Pins-2.0")

-- A frame keeps its job for life: one pool for world-map pins, one for minimap pins. HereBeDragons parents a minimap
-- pin to the minimap and a world-map pin to the map canvas - but only once it actually places it. A frame that had
-- been on the minimap and came back from a shared pool as a world-map pin stayed on the minimap, at the spot it last
-- had there, whenever the world map was not showing that zone (closed since login, or last looked at elsewhere):
-- a pin at a fixed offset from your arrow, walking with you. So: separate pools, a frame is handed over hidden and
-- unanchored (HereBeDragons shows it when it places it), and Pins.Sweep hides anything that slipped through.
local pool, used, lastKey = { world = {}, mini = {} }, {}, nil
local all = {} -- every frame made here (pins and dots)
-- the step the first (current) pin marks, for tests: card, arrow and pins must agree
function Pins.First() local p = used[1]; return p and p.index end
-- The minimap shows one thing: where the card's step is, when it's near. A pin beside you reads as "do this now", so
-- nothing else belongs there (a "2" for a hand-in to Elling Trias sat next to you in Stormwind - for a quest Jorgen
-- across town only gives you after the hand-in before it).
-- The world map shows the plan, and each pin says which of three things it is:
--   the step on the card - big, coloured, no number
--   a next stop you could do right now - coloured, numbered in plan order
--   a stop that isn't open yet (its quest isn't in your log, an earlier quest has to be handed in, objectives left,
--   a level to reach) - small and grey, and its tooltip says what comes first
local GREY = { 0.62, 0.65, 0.7 }
local function describe(s)
  local title, detail = ns.Card.Describe(s)
  return title, detail
end
-- what comes first, in words (nil when the step can be done now)
function Pins.NotYetText(i)
  local why, j, extra = ns.Engine.NotYet(i)
  if not why then return nil end
  local first = j and ForeverRouteData.steps[j]
  if first then
    local title, detail = describe(first)
    return "Not yet - first: " .. ns.Card.Plain(title) .. (detail and (" " .. ns.Card.Plain(detail)) or "")
  end
  if why == "level" then return extra and ("Not yet - at level " .. extra) or "Not yet - you need a higher level" end
  if why == "dungeon" then return "Not yet - on your next run of " .. (extra or "the dungeon") end
  if why == "pickup" then return "Not yet - its quest isn't in your log" end
  if why == "full" then return "Not yet - your quest log is full" end
  if why == "handin" then return "Not yet - an earlier quest of its chain comes first" end
  return "Not yet - its objectives come first"
end
-- the tooltip of the pin for step i, the n-th pin (1 = the card's step), as { text, r, g, b } lines
function Pins.Tip(i, n)
  local s = ForeverRouteData and ForeverRouteData.steps[i]; if not s then return {} end
  local lines = {}
  local notYet = Pins.NotYetText(i)
  if n and n > 1 then
    lines[#lines + 1] = { (notYet and "Later on your plan" or "Next on your plan") .. " (" .. (n - 1) .. ")", 0.5, 0.55, 0.62 }
  end
  local title, detail = describe(s)
  lines[#lines + 1] = { title, 1, 1, 1 }
  if detail then lines[#lines + 1] = { detail, 0.7, 0.75, 0.82 } end
  if s.note then lines[#lines + 1] = { ns.Card.Note and ns.Card.Note(s) or s.note, 1, 0.6, 0.3 } end
  if notYet then lines[#lines + 1] = { notYet, 1, 0.82, 0.36 } end
  -- jumping to a stop that isn't open would skip the very step that opens it: only looking is offered
  lines[#lines + 1] = { (notYet and n and n > 1) and "Click to look" or "Click to look · Shift-click to jump here", 0.5, 0.55, 0.62 }
  return lines
end
-- How a pin looks. World map: the card's step is the pin shape with a dark edge; the next stops are small round
-- badges with their number (the pin shape has a hole in its head, right where the number sat - on a dark map the
-- digit was gone). Minimap (the card's step only): no bigger than before, but a round badge that fills its size, in
-- the kind's colour with a dark rim and the kind's icon (the one on the card) - the pin shape was a few yellow pixels
-- that said nothing on Stormwind's blue and brown.
local DARK = { 0.05, 0.05, 0.07 }
-- what a pin's look depends on: the pins are redrawn whenever a step or your nearness changes, and one that already
-- looks this way is left as it is (a dozen texture and font calls each, for nothing) - the redraw takes such a pin
-- from the pool first
local function lookKey(where, n, s, notYet)
  return tostring(Style.Kind(s)) .. where .. ((n == 1 or where == "mini") and "" or n) .. (notYet and "n" or "")
end
local function look(p, where, n, s, notYet)
  local kind = Style.Kind(s)
  local mini, first = where == "mini", n == 1
  local key = lookKey(where, n, s, notYet)
  if p.looks == key then return end
  p.looks = key
  local c = notYet and GREY or kind.color
  local size = mini and 20 or (first and 22 or (notYet and 14 or 16))
  p:SetSize(size, size)
  local round = mini or not first
  local shape = Style.MEDIA .. (round and "disc" or "pin")
  local rim = mini and 1.5 or 1
  p.back:SetTexture(shape); p.back:ClearAllPoints()
  p.back:SetPoint("TOPLEFT", -rim, rim); p.back:SetPoint("BOTTOMRIGHT", rim, -rim)
  p.back:SetVertexColor(0, 0, 0, notYet and 0.5 or (mini and 0.95 or 0.8))
  p.pin:SetTexture(shape)
  p.pin:SetVertexColor(c[1], c[2], c[3], (first or mini) and 1 or (notYet and 0.8 or 0.95))
  p.num:SetFontObject(Style.Font(notYet and 8 or 9, nil, true))
  p.num:SetTextColor(DARK[1], DARK[2], DARK[3]); p.num:SetShadowColor(0, 0, 0, 0)
  p.num:ClearAllPoints(); p.num:SetPoint("CENTER", 0, 0)
  p.num:SetText((first or mini) and "" or tostring(n - 1))
  if mini and kind.icon then
    p.icon:SetTexture(Style.MEDIA .. kind.icon); p.icon:SetSize(size * 0.66, size * 0.66); p.icon:Show()
  else p.icon:Hide() end
end
local blinkFor -- (Pins.Blink: a step whose pin is to blink once it is placed)
local function makePin()
  local p = CreateFrame("Button", nil, UIParent)
  all[#all + 1] = p
  p:SetSize(20, 20)
  p.back = p:CreateTexture(nil, "BACKGROUND")
  p.pin = p:CreateTexture(nil, "ARTWORK"); p.pin:SetAllPoints()
  p.icon = p:CreateTexture(nil, "OVERLAY"); p.icon:SetPoint("CENTER"); p.icon:SetVertexColor(DARK[1], DARK[2], DARK[3])
  p.num = Style.Text(p, 9, DARK, nil, "OVERLAY"); p.num:SetFontObject(Style.Font(9, nil, true)); p.num:SetJustifyH("CENTER")
  p:SetScript("OnEnter", function(self)
    if not (self.index and ForeverRouteData and ForeverRouteData.steps[self.index]) then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    for _, l in ipairs(Pins.Tip(self.index, self.n)) do GameTooltip:AddLine(l[1], l[2], l[3], l[4], true) end
    GameTooltip:Show()
  end)
  p:SetScript("OnLeave", GameTooltip_Hide)
  -- the Map button's blink: a glow behind the pin that pulses a few times so the eye finds it (Pins.Blink)
  p.flash = p:CreateTexture(nil, "BACKGROUND", nil, -1); p.flash:SetTexture(Style.MEDIA .. "glow"); p.flash:SetSize(56, 56); p.flash:SetPoint("CENTER")
  p.flash:SetVertexColor(1, 0.85, 0.35); p.flash:SetAlpha(0)
  local ag = p.flash:CreateAnimationGroup(); ag:SetLooping("REPEAT")
  local fa = ag:CreateAnimation("Alpha"); fa:SetFromAlpha(1); fa:SetToAlpha(0); fa:SetDuration(0.6)
  local fs = ag:CreateAnimation("Scale"); fs:SetScaleFrom(0.5, 0.5); fs:SetScaleTo(1.3, 1.3); fs:SetDuration(0.6)
  ag:SetScript("OnPlay", function() ag.loops = 0 end)
  ag:SetScript("OnLoop", function() ag.loops = (ag.loops or 0) + 1; if ag.loops >= 5 then ag:Stop(); p.flash:SetAlpha(0) end end)
  p.blink = ag
  p:SetScript("OnClick", function(self)
    if not self.index then return end
    if IsShiftKeyDown() and not self.notYet then ns.Engine.Jump(self.index) else ns.Engine.view = (self.index ~= ns.Engine.current) and self.index or nil; ns.Fire("FR_STEP", ns.Engine.Shown()) end
  end)
  return p
end

-- The walking line of the step being shown, as dots on the world map and the minimap.
-- Where the zone has a walk map (Nav.lua) the line runs from where you stand, along the ground, and its dots are
-- fixed in the world: they are laid out from the target backwards, so walking only takes away the ones behind you.
-- Elsewhere it is the planner's path from the previous stop (world map only: on the minimap that one started where
-- the plan expected you, and read as a line to nowhere - ns.db.miniPath brings it back for a look).
-- Dots keep their job like the pins do (see the pools above): world-map dots and minimap dots never swap.
local dotPool, dotsUsed = { world = {}, mini = {} }, {}
local dots = {} -- the reference HereBeDragons tracks them under
local function dot(where, color)
  local d = table.remove(dotPool[where])
  if not d then d = CreateFrame("Frame", nil, UIParent); all[#all + 1] = d; d:SetSize(6, 6); d.t = d:CreateTexture(nil, "OVERLAY"); d.t:SetTexture(Style.MEDIA .. "dot"); d.t:SetAllPoints() end
  d.where = where
  d.t:SetVertexColor(color[1], color[2], color[3], 0.85)
  d:Hide(); d:ClearAllPoints() -- HereBeDragons shows it when it places it
  return d
end
local function freeDot(d)
  if d.where == "world" then HBDP:RemoveWorldMapIcon(dots, d) else HBDP:RemoveMinimapIcon(dots, d) end
  d:Hide(); d:ClearAllPoints()
  table.insert(dotPool[d.where], d)
end
local line -- the live line being drawn: { key, P, color, step (yards between world dots), world = { [k] = dot }, mini = { [k] = dot } }
local function clearDots()
  for _, d in ipairs(dotsUsed) do d:Hide(); d:ClearAllPoints(); table.insert(dotPool[d.where], d) end
  wipe(dotsUsed)
  if line then
    for _, d in pairs(line.world) do d:Hide(); d:ClearAllPoints(); table.insert(dotPool.world, d) end
    for _, d in pairs(line.mini) do d:Hide(); d:ClearAllPoints(); table.insert(dotPool.mini, d) end
    line.world, line.mini, line.laid = {}, {}, nil
  end
  HBDP:RemoveAllWorldMapIcons(dots); HBDP:RemoveAllMinimapIcons(dots)
end
local function drawPath(s, color, fromSeg)
  clearDots()
  line = nil
  if not (ns.db.pathLine ~= false and s and s.wp and s.m and s.x) then return end
  local pts = {}
  for x, y in s.wp:gmatch("([%d.]+),([%d.]+),%-?%d+") do pts[#pts + 1] = { tonumber(x), tonumber(y) } end
  table.insert(pts, { s.x, s.y })
  -- only what's still ahead: from where you are, through the rest of the path
  if fromSeg then
    local m, mx, my = ns.State.Position()
    if m == s.m and mx then
      local rest = { { mx, my } }
      for k = fromSeg + 1, #pts do rest[#rest + 1] = pts[k] end
      pts = rest
    end
  end
  -- a dot about every 1% of the map along the path
  local n = 0
  for k = 2, #pts do
    local a, b = pts[k - 1], pts[k]
    local len = math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
    local steps = math.max(1, math.floor(len / 0.01))
    for t = 0, steps - 1 do
      if n > 160 then break end
      local x, y = a[1] + (b[1] - a[1]) * t / steps, a[2] + (b[2] - a[2]) * t / steps
      local d = dot("world", color)
      HBDP:AddWorldMapIconMap(dots, d, s.m, x, y, HBD_PINS_WORLDMAP_SHOW_PARENT or 1)
      dotsUsed[#dotsUsed + 1] = d
      -- minimap: only near you (same rule as the pins), but never right under you
      if ns.db.miniPath and Pins.Near and Pins.Near(s.m, x, y) and not Pins.Near(s.m, x, y, 15) then
        local wx, wy, inst = LibStub("HereBeDragons-2.0"):GetWorldCoordinatesFromZone(x, y, s.m)
        if wx then d = dot("mini", color); HBDP:AddMinimapIconWorld(dots, d, inst, wx, wy, false); dotsUsed[#dotsUsed + 1] = d end
      end
      n = n + 1
    end
  end
end

-- the live line (Nav.lua). Dots sit at whole multiples of the spacing, counted in yards-still-to-walk from the target.
Pins.MINI_STEP = 10    -- yards between minimap dots
Pins.MINI_AHEAD = 300  -- the minimap shows this much of the line ahead of you
Pins.MINI_GAP = 14     -- and none this close to you (a dot under your arrow reads as a marker on you)
-- the point of the line with `left` yards still to walk; j: a segment to start looking from
local function pointAt(P, left, j)
  local pts, rem = P.pts, P.rem
  j = j or 1
  while j < #pts - 1 and rem[j + 1] > left do j = j + 1 end
  local a, b = pts[j], pts[j + 1]
  local seg = rem[j] - rem[j + 1]
  local t = seg > 0 and (rem[j] - left) / seg or 0
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  return a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, j
end
local function trimLine()
  if not line then return end
  local P = line.P
  local left = P.left or P.len
  -- world map: every dot still ahead of you
  local top = math.floor((left - 4) / line.step)
  for k, d in pairs(line.world) do if k > top then freeDot(d); line.world[k] = nil end end
  if not line.laid then
    line.laid = true
    local j = 1
    for k = top, 1, -1 do
      local x, y; x, y, j = pointAt(P, k * line.step, j)
      -- a dot already at this spot is replaced, never left behind: an orphan stays on the map and walking never takes it away
      if line.world[k] then freeDot(line.world[k]) end
      local d = dot("world", line.color)
      HBDP:AddWorldMapIconWorld(dots, d, P.inst, x, y, HBD_PINS_WORLDMAP_SHOW_PARENT or 1)
      line.world[k] = d
    end
  end
  -- minimap: the stretch just ahead
  local hi, lo = math.floor((left - Pins.MINI_GAP) / Pins.MINI_STEP), math.max(1, math.ceil((left - Pins.MINI_AHEAD) / Pins.MINI_STEP))
  for k, d in pairs(line.mini) do if k > hi or k < lo then freeDot(d); line.mini[k] = nil end end
  local j = 1
  for k = hi, lo, -1 do
    if not line.mini[k] then
      local x, y; x, y, j = pointAt(P, k * Pins.MINI_STEP, j)
      local d = dot("mini", line.color)
      HBDP:AddMinimapIconWorld(dots, d, P.inst, x, y, false)
      line.mini[k] = d
    end
  end
end
local function shownStep() local i = ns.Engine.Shown(); return i and ForeverRouteData and ForeverRouteData.steps and ForeverRouteData.steps[i] end
local arrivedAt -- the step whose area you are standing in: no line there
local function drawLine(key, P)
  clearDots()
  line = nil
  if not P or ns.db.pathLine == false then return end
  local s = shownStep()
  -- about a dot every 1% of the map, never more than 200 of them
  local step = math.max(8, math.min(40, (P.mapYd or 2000) * 0.01))
  if P.len / step > 200 then step = P.len / 200 end
  line = { key = key, P = P, color = s and Style.Kind(s).color or { 1, 1, 1 }, step = step, world = {}, mini = {} }
  if arrivedAt and arrivedAt == ns.Engine.Shown() then return end
  trimLine()
end
function Pins.Line() return line end
-- the dots now on the minimap / world map for the live line, as { rem = yards still to walk, frame } (for tests)
function Pins.LineDots(where)
  local out = {}
  if line then for k, d in pairs(line[where]) do out[#out + 1] = { rem = k * (where == "mini" and Pins.MINI_STEP or line.step), frame = d } end end
  table.sort(out, function(a, b) return a.rem < b.rem end)
  return out
end

local planned -- draws the planned path where no live line is coming (defined with the events at the end)
-- the planned path's dots now on the maps (for tests)
function Pins.PathDots() return #dotsUsed end


-- the minimap only shows steps near you (a few hundred yards): a step in another zone has no business there, and
-- some minimap setups draw far-away pins on top of you instead of hiding them
local HBD = LibStub("HereBeDragons-2.0")
local NEAR_YD = 500
function Pins.Near(m, x, y, yd)
  local px, py, pinst = HBD:GetPlayerWorldPosition()
  local wx, wy, winst = HBD:GetWorldCoordinatesFromZone(x, y, m)
  if not (px and wx) or pinst ~= winst then return false end
  yd = yd or NEAR_YD
  return (px - wx) ^ 2 + (py - wy) ^ 2 <= yd * yd
end
local lastPathKey
function Pins.Update(force)
  local list, spots = {}, {}
  local cur = ns.Engine.Shown()
  -- (none inside a dungeon: there is no position in there to place them by, and the card is about the dungeon)
  if ns.db.pins and ForeverRouteData and cur and not (ns.Dungeon and ns.Dungeon.Inside()) then
    list[1] = cur
    for _, i in ipairs(ns.Engine.Upcoming(cur, (ns.db.pinCount or 4) - 1)) do list[#list + 1] = i end
  end
  -- where each pin goes, and whether the card's step is near enough for the minimap. Nearness is part of the key:
  -- walking up to a step changes neither the steps nor the zone, but its minimap pin has to appear (and go once you
  -- walk off)
  local near, notYet = {}, {}
  for n, i in ipairs(list) do
    local s = ForeverRouteData.steps[i]
    -- a next stop that isn't open yet (the card's own step is never dimmed: it is what the card tells you to do)
    local why, opener = nil, nil
    if n > 1 then why, opener = ns.Engine.NotYet(i) end
    notYet[n] = why and true or false
    -- opened by a pinned step at the same spot (hand in to Jorgen, take the next part from him): it is part of that
    -- stop, which has its pin - a second, grey one on top of it says nothing
    local o = opener and ForeverRouteData.steps[opener]
    -- (not an opener with no pin of its own: work whose place the quest data doesn't have, s.unknown)
    if o and not o.unknown and s.x and o.m == s.m and math.abs((o.x or 9) - s.x) < 0.01 and math.abs((o.y or 9) - s.y) < 0.01 then
      for k = 1, n - 1 do if list[k] == opener then s = nil end end
    end
    -- work the quest data has no place for (s.unknown): its spot is only its place in the order - no pin
    if s and s.unknown then s = nil end
    local m, x, y = s and s.m, s and s.x, s and s.y
    if s and not x and n == 1 then m, x, y = ns.Engine.TravelTarget(s) end
    -- standing at it: no minimap pin (it would sit on your own arrow - "a marker on me"; the arrow says Here)
    local onIt = s and m and x and Pins.Near(m, x, y, math.max(15, (s.r or 8) + 5))
    if s and m and x then spots[n] = { m = m, x = x, y = y, near = n == 1 and Pins.Near(m, x, y) and not onIt }; near[n] = (onIt and "2" or spots[n].near and "1" or "0") .. (notYet[n] and "n" or "")
    else near[n] = "-" end
  end
  -- (what the arrow points at is part of it: the step itself or a stop on the way there, and nothing on a flight -
  -- the planned path is judged against that)
  local at = ns.Arrow and ns.Arrow.Current and ns.Arrow.Current()
  local pathKey = table.concat(list, ",") .. ":" .. tostring((ns.State.Position())) .. ":" .. tostring(at and at.key or nil)
  -- the path line only when the step, the zone or the arrow's target changes (not when a pin comes near: that would
  -- undo its trimming)
  if pathKey ~= lastPathKey or force then
    lastPathKey = pathKey
    if list[1] ~= arrivedAt then arrivedAt = nil end
    -- a live line (Nav.lua) draws itself when it is ready; the planned path only where none is coming
    if line and ns.Nav and ns.Nav.PathFor(line.key) == line.P and ns.db.pathLine ~= false and #list > 0 then if force then drawLine(line.key, line.P) end else planned() end
  end
  local key = pathKey .. ":" .. table.concat(near)
  if key == lastKey and not force then return end
  lastKey = key
  HBDP:RemoveAllWorldMapIcons(Pins); HBDP:RemoveAllMinimapIcons(Pins)
  for _, p in ipairs(used) do p:Hide(); p:ClearAllPoints(); table.insert(pool[p.where], p) end
  wipe(used)
  -- numbers count the pins drawn, in plan order: 1 is the stop after the card's
  local label = -1
  for n, i in ipairs(list) do
    local s, at = ForeverRouteData.steps[i], spots[n]
    if s and at then
      label = label + 1
      local m, x, y = at.m, at.x, at.y
      for _, where in ipairs(at.near and { "world", "mini" } or { "world" }) do
        local pl, k = pool[where], lookKey(where, label + 1, s, notYet[n])
        local p
        for q = #pl, 1, -1 do if pl[q].looks == k then p = table.remove(pl, q); break end end
        p = p or table.remove(pl) or makePin()
        p.index, p.where, p.n, p.notYet = i, where, label + 1, notYet[n]
        look(p, where, label + 1, s, notYet[n])
        -- hidden and unanchored until HereBeDragons places it (it shows the frame itself)
        p:Hide(); p:ClearAllPoints()
        -- (on top of the map's own markers - a quest giver's "!" covered ours - like other Forever map addons)
        if where == "world" then HBDP:AddWorldMapIconMap(Pins, p, m, x, y, HBD_PINS_WORLDMAP_SHOW_PARENT or 1, "PIN_FRAME_LEVEL_TOPMOST")
        else
          -- by world position, not by map: the map-bound call only draws the pin while the game says you are on
          -- exactly that map (not on a keep's or a district's own map), and nearness is already checked in yards
          local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(x, y, m)
          if wx then HBDP:AddMinimapIconWorld(Pins, p, inst, wx, wy, label == 0) end
        end
        used[#used + 1] = p
      end
    end
  end
  Pins.Sweep()
end
Pins._used = used
-- blink the world map pin of step i (the card's Map button) once it is on the screen. A pin is in the list before the
-- map shows it (HereBeDragons places it when the map opens on its zone): its blink played unseen and was used up, so
-- the map opened with nothing marked. Until it shows it is looked for again every tenth of a second, for 3 seconds
-- (not on the screen by then: no late blink). -> true when it blinked now
Pins.BLINK_TRIES = 30
function Pins.Blink(i, tries)
  tries = tries or Pins.BLINK_TRIES
  blinkFor = i
  for _, p in ipairs(used) do
    if p.where == "world" and p.index == i and p.blink and p:IsVisible() then p.blink:Stop(); p.blink:Play(); blinkFor = nil; return true end
  end
  if tries <= 1 then blinkFor = nil; return false end
  C_Timer.After(0.1, function() if blinkFor == i then Pins.Blink(i, tries - 1) end end)
  return false
end
function Pins.PendingBlink() local i = blinkFor; blinkFor = nil; return i end
-- every frame this file ever put on a map (pins and path dots)
function Pins.Frames() return all end
-- nothing of ours may show on the minimap unless HereBeDragons is placing it there; returns how many it had to hide
function Pins.Sweep()
  local n = 0
  local placed = HBDP.minimapPins or {}
  for _, f in ipairs(all) do
    if f:IsShown() and f:GetParent() == (HBDP.Minimap or Minimap) and not placed[f] then f:Hide(); f:ClearAllPoints(); n = n + 1 end
  end
  if n > 0 and ns.Why then ns.Why("pins", n .. " stray frame(s) on the minimap hidden") end
  return n
end
-- re-check nearness every couple of seconds as you move (rebuilds only when a pin comes near or goes far)
ns.On("FR_LOADED", function() C_Timer.NewTicker(2, ns.Guard("pins", function() Pins.Update() end)) end)

ns.On("FR_STEP", function() Pins.Update() end)
ns.On("FR_DUNGEON", function() Pins.Update(true) end)
ns.On("FR_SETTINGS", function() Pins.Update(true) end)
ns.On("FR_ROUTE_CHANGED", function() Pins.Update(true) end)
ns.On("ZONE_CHANGED_NEW_AREA", function() C_Timer.After(1.5, function() Pins.Update() end) end)

-- Is a live line (Nav.lua) on its way, or drawn, for what the arrow points at? Then the planned path stays off the
-- map: it was drawn for the seconds the live line took to be found and then replaced by it ("a random path that
-- flashes for a few seconds"). A line that waits for your position (a loading screen: the game has none for a
-- moment) is on its way too; one that waits because the target is in another world is not.
function Pins.LiveComing()
  local N = ns.Nav
  if not N then return false end
  if N.Coming and N.Coming() then return true end
  local L = N.Live and N.Live()
  if L and L.waiting and not L.none and not L.failedAt then
    local px, _, pinst = HBD:GetPlayerWorldPosition()
    return not px or pinst == L.inst
  end
  return false
end
-- Where you are on the shown step's planned path, as the arrow judges it (Arrow.lua: within 45 yd of it, or still
-- at the stop it starts from): the stretch you are on, -1 when you are not on it (or not walking at all: a flight, a
-- boat), nil when the arrow points at something else on the way there (the flight master, a zone crossing) or the
-- step is in another world - the path is then a look at what is planned over there, whole.
-- The planned path starts where the plan expected you to come from. Drawn from that start whenever a step came up,
-- it showed a path from somewhere you never were until the arrow's first word on it, a second or two later, took
-- it away again.
Pins.PLANNED_OFF_YD = 45
function Pins.OnPlanned(i)
  local t = ns.Arrow and ns.Arrow.Current and ns.Arrow.Current()
  if not t or t.index ~= i then return -1 end -- nothing to walk to (a flight), or the arrow hasn't turned to this step yet
  local P = t.path
  if not (P and P.pts and #P.pts >= 2) then return nil end
  local px, py, pinst = HBD:GetPlayerWorldPosition()
  if not px then return -1 end -- no position yet (a loading screen): nothing until there is one
  if pinst ~= t.winst then return nil end
  local best, bd = nil, math.huge
  for j = math.max(1, P.cursor or 1), #P.pts - 1 do
    local a, b = P.pts[j], P.pts[j + 1]
    local dx, dy = b[1] - a[1], b[2] - a[2]
    local L2 = dx * dx + dy * dy
    local u = L2 > 0 and math.max(0, math.min(1, ((px - a[1]) * dx + (py - a[2]) * dy) / L2)) or 0
    local d = math.sqrt((px - a[1] - u * dx) ^ 2 + (py - a[2] - u * dy) ^ 2)
    if d < bd - 0.01 then best, bd = j, d end
  end
  if not best then return -1 end
  local St = P.start
  local atStart = St and math.sqrt((px - St[1]) ^ 2 + (py - St[2]) ^ 2) <= (P.startR or 40) + 25
  return (bd <= Pins.PLANNED_OFF_YD or atStart) and best or -1
end
-- the planned path of a step, where no live line is coming (no walk map for this zone, or no way found on it):
-- only what is still ahead of you, and only while you are on it. seg: the arrow's word on where you are on it
-- (FR_PATHPROGRESS), nil to work it out here.
planned = function(seg)
  local i = ns.Engine.Shown()
  local s = shownStep()
  if Pins.LiveComing() then drawPath(nil, nil) return end
  if arrivedAt and arrivedAt == i then drawPath(nil, nil) return end
  if seg == nil then seg = Pins.OnPlanned(i) end
  if seg == -1 then drawPath(nil, nil) return end
  drawPath(s, s and Style.Kind(s).color or { 1, 1, 1 }, seg)
end

-- inside the step's area the walking path is noise: hide it, and bring it back if you walk out
ns.On("FR_ARRIVED", function(i, arrived)
  if i ~= ns.Engine.Shown() then return end
  arrivedAt = arrived and i or nil
  if line then
    -- 'not there' also comes each time the arrow takes a fresh aim at the same step: the line is only laid again when
    -- arriving took it away
    if arrived then local keep = line; clearDots(); line = keep elseif not line.laid then trimLine() end
  else planned() end
end)

ns.On("FR_PATHPROGRESS", function(i, seg)
  if i ~= ns.Engine.Shown() or line then return end
  planned(seg) -- seg -1: not on the planned path - no line (the arrow points straight at the target)
end)

-- the live line: ready, changed or gone / you moved along it
ns.On("FR_NAVPATH", function(key, P)
  if P then drawLine(key, P) else if line then clearDots(); line = nil end; planned() end
end)
ns.On("FR_NAVPROGRESS", function(key, P)
  if line and line.P == P and not (arrivedAt and arrivedAt == ns.Engine.Shown()) then trimLine() end
end)
