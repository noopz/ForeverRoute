-- Numbered pins for the current and next steps on the world map and minimap (HereBeDragons-Pins).
-- Rebuilt only when the set of pinned steps changes. Click a pin to look at the step; Shift-click to jump to it.
local _, ns = ...
local Style = ns.Style
local Pins = {}
ns.Pins = Pins
local HBDP = LibStub("HereBeDragons-Pins-2.0")

local pool, used, lastKey = {}, {}, nil
-- the step the first (current) pin marks, for tests: card, arrow and pins must agree
function Pins.First() local p = used[1]; return p and p.index end
local function makePin()
  local p = CreateFrame("Button", nil, UIParent)
  p:SetSize(20, 20)
  p.pin = p:CreateTexture(nil, "ARTWORK"); p.pin:SetTexture(Style.MEDIA .. "pin"); p.pin:SetAllPoints()
  p.num = Style.Text(p, 9, { 0.05, 0.05, 0.07 }, nil, "OVERLAY"); p.num:SetPoint("CENTER", 0, 3); p.num:SetJustifyH("CENTER")
  p:SetScript("OnEnter", function(self)
    local s = self.index and ForeverRouteData.steps[self.index]; if not s then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local title, detail = ns.Card.Describe(s)
    GameTooltip:AddLine(title, 1, 1, 1, true)
    if detail then GameTooltip:AddLine(detail, 0.7, 0.75, 0.82, true) end
    if s.note then GameTooltip:AddLine(ns.Card and ns.Card.Note and ns.Card.Note(s) or s.note, 1, 0.6, 0.3, true) end
    GameTooltip:AddLine("Click to look · Shift-click to jump here", 0.5, 0.55, 0.62)
    GameTooltip:Show()
  end)
  p:SetScript("OnLeave", GameTooltip_Hide)
  p:SetScript("OnClick", function(self)
    if not self.index then return end
    if IsShiftKeyDown() then ns.Engine.Jump(self.index) else ns.Engine.view = (self.index ~= ns.Engine.current) and self.index or nil; ns.Fire("FR_STEP", ns.Engine.Shown()) end
  end)
  return p
end

-- the walking path of the step being shown, as a dotted line on the world map and minimap
local dots, dotsUsed = {}, {}
local function dot()
  local d = table.remove(dots)
  if not d then d = CreateFrame("Frame", nil, UIParent); d:SetSize(6, 6); d.t = d:CreateTexture(nil, "OVERLAY"); d.t:SetTexture(Style.MEDIA .. "dot"); d.t:SetAllPoints() end
  return d
end
local function drawPath(s, color, fromSeg)
  for _, d in ipairs(dotsUsed) do d:Hide(); table.insert(dots, d) end
  wipe(dotsUsed)
  HBDP:RemoveAllWorldMapIcons(dots); HBDP:RemoveAllMinimapIcons(dots)
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
      for _, where in ipairs({ "world", "mini" }) do
        local d = dot(); d.t:SetVertexColor(color[1], color[2], color[3], 0.85); d:Show()
        if where == "world" then HBDP:AddWorldMapIconMap(dots, d, s.m, x, y, HBD_PINS_WORLDMAP_SHOW_PARENT or 1)
        -- minimap: only near you (same rule as the pins), but never right under you - the line starts at your
        -- position, and a dot there reads as a marker stuck on your arrow (it lags as you move)
        elseif Pins.Near and Pins.Near(s.m, x, y) and not Pins.Near(s.m, x, y, 15) then HBDP:AddMinimapIconMap(dots, d, s.m, x, y, false, false) end
        dotsUsed[#dotsUsed + 1] = d
      end
      n = n + 1
    end
  end
end

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
  if ns.db.pins and ForeverRouteData and cur then
    list[1] = cur
    for _, i in ipairs(ns.Engine.Upcoming(cur, (ns.db.pinCount or 4) - 1)) do list[#list + 1] = i end
  end
  -- where each pin goes, and whether it is near enough for the minimap. Nearness is part of the key: walking up to
  -- a step changes neither the steps nor the zone, but its minimap pin has to appear (and go once you walk off)
  local near = {}
  for n, i in ipairs(list) do
    local s = ForeverRouteData.steps[i]
    local m, x, y = s and s.m, s and s.x, s and s.y
    if s and not x and n == 1 then m, x, y = ns.Engine.TravelTarget(s) end
    -- standing at it: no minimap pin (it would sit on your own arrow - "a marker on me"; the arrow says Here)
    local onIt = m and x and Pins.Near(m, x, y, math.max(15, (s.r or 8) + 5))
    if m and x then spots[n] = { m = m, x = x, y = y, near = Pins.Near(m, x, y) and not onIt }; near[n] = onIt and "2" or spots[n].near and "1" or "0"
    else near[n] = "-" end
  end
  local pathKey = table.concat(list, ",") .. ":" .. tostring((ns.State.Position()))
  -- the path line only when the step or zone changes (not when a pin comes near: that would undo its trimming)
  if pathKey ~= lastPathKey or force then lastPathKey = pathKey; local s = list[1] and ForeverRouteData.steps[list[1]]; drawPath(s, s and Style.Kind(s).color or { 1, 1, 1 }) end
  local key = pathKey .. ":" .. table.concat(near)
  if key == lastKey and not force then return end
  lastKey = key
  HBDP:RemoveAllWorldMapIcons(Pins); HBDP:RemoveAllMinimapIcons(Pins)
  for _, p in ipairs(used) do p:Hide(); table.insert(pool, p) end
  wipe(used)
  for n, i in ipairs(list) do
    local s, at = ForeverRouteData.steps[i], spots[n]
    if s and at then
      local m, x, y = at.m, at.x, at.y
      local kind = Style.Kind(s)
      for _, where in ipairs(at.near and { "world", "mini" } or { "world" }) do
        local p = table.remove(pool) or makePin()
        p.index, p.where = i, where
        local size = n == 1 and 22 or 16
        p:SetSize(size, size)
        p.pin:SetVertexColor(kind.color[1], kind.color[2], kind.color[3], n == 1 and 1 or 0.8)
        p.num:SetText(n == 1 and "" or tostring(n - 1))
        p:Show()
        if where == "world" then HBDP:AddWorldMapIconMap(Pins, p, m, x, y, HBD_PINS_WORLDMAP_SHOW_PARENT or 1)
        else HBDP:AddMinimapIconMap(Pins, p, m, x, y, false, n == 1) end
        used[#used + 1] = p
      end
    end
  end
end
Pins._used = used
-- re-check nearness every couple of seconds as you move (rebuilds only when a pin comes near or goes far)
ns.On("FR_LOADED", function() C_Timer.NewTicker(2, ns.Guard("pins", function() Pins.Update() end)) end)

ns.On("FR_STEP", function() Pins.Update() end)
ns.On("FR_SETTINGS", function() Pins.Update(true) end)
ns.On("FR_ROUTE_CHANGED", function() Pins.Update(true) end)
ns.On("ZONE_CHANGED_NEW_AREA", function() C_Timer.After(1.5, function() Pins.Update() end) end)

-- inside the step's area the walking path is noise: hide it, and bring it back if you walk out
ns.On("FR_ARRIVED", function(i, arrived)
  if i ~= ns.Engine.Shown() then return end
  local s = ForeverRouteData and ForeverRouteData.steps[i]
  if arrived then drawPath(nil, nil) else drawPath(s, s and Style.Kind(s).color or { 1, 1, 1 }) end
end)

ns.On("FR_PATHPROGRESS", function(i, seg)
  if i ~= ns.Engine.Shown() then return end
  local s = ForeverRouteData and ForeverRouteData.steps[i]
  if seg == -1 then drawPath(nil, nil) return end -- not on the planned path: no line (the arrow points straight at the target)
  drawPath(s, s and Style.Kind(s).color or { 1, 1, 1 }, seg)
end)
