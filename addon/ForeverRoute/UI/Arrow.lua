-- Waypoint tracking + arrow. A hidden driver tracks distance/arrival for the current step all the time (so goto steps
-- complete and the card shows distance even with the arrow off); the arrow frame is purely visual: it eases its rotation,
-- shifts green -> amber -> red as you turn away, shows distance + ETA, and pulses a ring when you arrive.
-- Along a path it steers for a spot a little way ahead on the line (Nav.Aim), so it turns into a corner over the
-- yards before it instead of swinging round on the corner itself.
local _, ns = ...
local Style = ns.Style
local C = Style.C
local HBD = LibStub("HereBeDragons-2.0")
local Arrow = {}
ns.Arrow = Arrow

local f, driver
local target -- { index, m, x, y, r, label, zone, wx, wy, winst }

local function lerp(a, b, t) return a + (b - a) * t end
-- s.wp = "x,y,z;x,y,z;..." (0-1 map coords, floor height): the walking path to the step, simplified to its turns
local function buildPath(s, m, wx, wy)
  if not (s.wp and m) then return nil end
  local pts = {}
  for x, y, z in s.wp:gmatch("([%d.]+),([%d.]+),(-?%d+)") do
    local X, Y = HBD:GetWorldCoordinatesFromZone(tonumber(x), tonumber(y), m)
    if X then pts[#pts + 1] = { X, Y, tonumber(z) } end
  end
  if #pts == 0 then return nil end
  pts[#pts + 1] = { wx, wy, s.z }
  local rem = {}; rem[#pts] = 0
  for k = #pts - 1, 1, -1 do rem[k] = rem[k + 1] + math.sqrt((pts[k + 1][1] - pts[k][1]) ^ 2 + (pts[k + 1][2] - pts[k][2]) ^ 2) end
  return { pts = pts, rem = rem, cursor = 1, z0 = s.z0, z1 = s.z }
end
Arrow._buildPath = function(...) return buildPath(...) end
-- How far ahead along the path the arrow looks, in yards: about Arrow.LOOK_SEC seconds of travel (so further on a
-- mount than on foot), within what the place allows. Open country (a walk map of 8-yd squares or more): 16 to 40.
-- A city's walk map (4-yd squares, walls): 8 to 10. The planner's own path: 8 to 12. Inside a building: 6.
-- Measured on real lines (docs/research/navigation-paths.md, "The arrow"): someone who follows the arrow strays
-- from the line by up to half of this at a sharp corner (the old arrow: 4 to 5 yd).
Arrow.LOOK_SEC = 3 -- (1.5 followed every bend of the line: the arrow should give the way, the line the detail)
Arrow.TURN = 8 -- how fast the drawn arrow follows its direction (1/s; it was 12)
local function lookFor(P, speed)
  if Arrow.Indoors() then return 6 end
  local lo, hi = 8, 12
  if P.nav then if (P.cell or 8) >= 8 then lo, hi = 16, 40 else hi = 10 end end
  return math.max(lo, math.min(hi, (speed or 7) * Arrow.LOOK_SEC))
end
Arrow._lookFor = lookFor
-- where to aim along the path: the spot on it `look` yards from you, ahead of where you are on it (Nav.Aim). Walk
-- somewhere else and come out near a later part (a shortcut) and it carries on from there; the spot is always on
-- the path, so the arrow never invents a shortcut longer than its look-ahead (a straight line could go through a
-- wall or off a cliff).
-- -> the spot { x, y }, yards to walk, how far off the path you are, the path's height where you are
-- far: open country (a walk map of 8-yd squares, outdoors), where it may aim as far as the line runs nearly straight
local function follow(P, px, py, look, far) return ns.Nav.Aim(P, px, py, look or 10, far) end
local function openCountry(P) return P.nav and (P.cell or 8) >= 8 and not Arrow.Indoors() end
Arrow._openCountry = openCountry
Arrow._follow = follow
local function colorFor(diff)
  local t = math.abs(diff) / math.pi
  if t < 0.5 then local u = t / 0.5; return lerp(C.good[1], C.gold[1], u), lerp(C.good[2], C.gold[2], u), lerp(C.good[3], C.gold[3], u) end
  local u = (t - 0.5) / 0.5; return lerp(C.gold[1], C.bad[1], u), lerp(C.gold[2], C.bad[2], u), lerp(C.gold[3], C.bad[3], u)
end

local function build()
  f = CreateFrame("Frame", "ForeverRouteArrow", UIParent)
  f:SetSize(120, 120)
  f:SetPoint("TOP", UIParent, "TOP", 0, -140)
  f:SetClampedToScreen(true); f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) if not ns.db.locked then self:StartMoving() end end)
  f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); local p, _, rp, x, y = self:GetPoint(); ns.db.arrowPos = { p, rp, x, y } end)
  f:SetScript("OnMouseUp", function(_, btn) if btn == "RightButton" and target then Arrow.hiddenFor = ForeverRouteData and ForeverRouteData.steps[target.index]; f:Hide(); if ns.Why then ns.Why("arrow", "hidden: you right-clicked it (comes back on the next step)") end end end)
  f:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_BOTTOM"); GameTooltip:SetText(target and target.label or "", 1, 1, 1, 1, true); GameTooltip:AddLine("Drag to move · right-click to hide for this step", 0.6, 0.65, 0.72); GameTooltip:Show() end)
  f:SetScript("OnLeave", GameTooltip_Hide)

  f.glow = f:CreateTexture(nil, "BACKGROUND"); f.glow:SetTexture(Style.MEDIA .. "glow"); f.glow:SetSize(110, 110); f.glow:SetPoint("CENTER", 0, 10); f.glow:SetVertexColor(0, 0, 0, 0.45)
  f.arrow = f:CreateTexture(nil, "ARTWORK"); f.arrow:SetTexture(Style.MEDIA .. "arrow"); f.arrow:SetSize(56, 56); f.arrow:SetPoint("CENTER", 0, 10)
  f.ring = f:CreateTexture(nil, "OVERLAY"); f.ring:SetTexture(Style.MEDIA .. "ring"); f.ring:SetSize(64, 64); f.ring:SetPoint("CENTER", 0, 10); f.ring:SetAlpha(0)
  f.ring:SetVertexColor(C.good[1], C.good[2], C.good[3])
  local pulse = f.ring:CreateAnimationGroup(); pulse:SetLooping("REPEAT")
  local s1 = pulse:CreateAnimation("Scale"); s1:SetScaleFrom(0.6, 0.6); s1:SetScaleTo(1.25, 1.25); s1:SetDuration(1.1); s1:SetSmoothing("OUT")
  local a1 = pulse:CreateAnimation("Alpha"); a1:SetFromAlpha(0.9); a1:SetToAlpha(0); a1:SetDuration(1.1)
  f.pulse = pulse
  f.check = f:CreateTexture(nil, "OVERLAY"); f.check:SetTexture(Style.MEDIA .. "icon-check"); f.check:SetSize(34, 34); f.check:SetPoint("CENTER", 0, 10)
  f.check:SetVertexColor(C.good[1], C.good[2], C.good[3]); f.check:Hide()
  f.dist = Style.Text(f, 15, C.text, "OUTLINE"); f.dist:SetPoint("TOP", f.arrow, "BOTTOM", 0, -4); f.dist:SetJustifyH("CENTER")
  f.label = Style.Text(f, 10, C.sub, "OUTLINE"); f.label:SetPoint("TOP", f.dist, "BOTTOM", 0, -2); f.label:SetJustifyH("CENTER"); f.label:SetWidth(220); f.label:SetWordWrap(false)
  if ns.db.arrowPos then local p = ns.db.arrowPos; f:ClearAllPoints(); f:SetPoint(p[1], UIParent, p[2], p[3], p[4]) end
  Style.Scaled(f, "arrowScale") -- the Forever Route scale x the arrow's own
  f:Hide()

  -- driver: always running while there's a target
  driver = CreateFrame("Frame")
  Arrow._driver = driver -- tests tick it
  local rot, acc, distAcc, lastDist = 0, 0, 0, nil
  -- own speed estimate from how far you moved (GetUnitSpeed is a protected "secret" value on Forever)
  local lastX, lastY, lastInst, speed = nil, nil, nil, 0
  -- your moving speed, learned over half-second windows only while you move (standing still or a stutter doesn't
  -- throw it off), and the distance / time on screen eased toward their new values so they don't jump
  local moveSpeed, winD, winT = 7, 0, 0
  local focusAcc = 0
  local lineAcc = 0
  local shownDist, shownEta, textAcc = nil, nil, 1
  driver:SetScript("OnUpdate", ns.Guard("arrow", function(_, el)
    acc = acc + el
    if acc < 0.03 then return end
    el, acc = acc, 0
    -- your speed, "on a boat" and live reordering run whether or not there is something to point at: on a boat
    -- there is no target (so landing must still be noticed), and many steps have no marker at all
    local px, py, pinst = HBD:GetPlayerWorldPosition()
    if px and lastX and pinst == lastInst and el > 0 then
      local v = math.sqrt((px - lastX) ^ 2 + (py - lastY) ^ 2) / el
      if v < 60 then -- ignore teleports / loading jumps
        speed = speed * 0.85 + v * 0.15
        Arrow.speed = speed
        -- on a boat: faster than any mount and not on a flight - the trip moves on to the next leg
        local aboard = speed > 16 and not ns.Is(UnitOnTaxi, "player")
        -- boarding the boat of the shown step's trip teaches its pier (only that step's trip: one planned for a
        -- step you looked at earlier has nothing to do with this boat)
        local lt = ns.Engine.lastTrip
        local shownStep = ForeverRouteData and ForeverRouteData.steps and ForeverRouteData.steps[ns.Engine.Shown() or 0]
        if aboard and not Arrow.aboard and lt and lt[1] and lt[1].how == "boat" and not (ns.Travel and ns.Travel.IsTram(lt[1])) and shownStep and ns.Engine.lastTripStep == shownStep and ns.Boats and ns.Boats.LearnDock then pcall(ns.Boats.LearnDock, lt[1].dock, lt[1].sm) end
        if aboard ~= Arrow.aboard then Arrow.aboard = aboard; C_Timer.After(0, function() Arrow.SetTarget(ns.Engine.Shown(), true); ns.Fire("FR_STEP", ns.Engine.Shown()) end) end
        winD = winD + v * el; winT = winT + el
        if winT >= 0.5 then
          local w = winD / winT
          if w > 2 then moveSpeed = math.max(3, math.min(30, moveSpeed * 0.7 + w * 0.3)) end
          winD, winT = 0, 0
        end
      end
    end
    lastX, lastY, lastInst = px, py, pinst
    focusAcc = (focusAcc or 0) + el
    if focusAcc >= 1 then focusAcc = 0; ns.Engine.UpdateFocus(px, py, pinst) end
    if not target then return end
    if not (px and target.wx) or pinst ~= target.winst then
      if f:IsShown() then f.arrow:SetAlpha(0.25); f.arrow:SetVertexColor(C.dim[1], C.dim[2], C.dim[3]); f.dist:SetText(target.zone and ("in " .. target.zone) or "-") end
      if lastDist ~= false then lastDist = false; ns.Fire("FR_DISTANCE", nil) end
      return
    end
    local angle, dist = HBD:GetWorldVector(pinst, px, py, target.wx, target.wy)
    if not dist then return end
    local shown, hint = dist, nil
    -- the live line from where you stand (Nav.lua), when this zone has a walk map; else the planner's path
    local live = ns.Nav and target.key and ns.Nav.PathFor(target.key)
    local P = live or target.path
    if P and dist > (target.r or 12) then
      local aim, walk, off, zHere = follow(P, px, py, lookFor(P, moveSpeed), openCountry(P))
      -- the planned path runs from the previous stop; you may well have come from somewhere else. Use it only while
      -- you're on it (or still at its start); otherwise point straight at the target and hide the line.
      local St = P.start
      local atStart = St and math.sqrt((px - St[1]) ^ 2 + (py - St[2]) ^ 2) <= (P.startR or 40) + 25
      local onPath = live and true or off <= 45 or atStart
      -- tell the map line how far along you are, so it only draws what's still ahead (not the part behind you)
      lineAcc = (lineAcc or 0) + el
      if not live and lineAcc >= 1.5 and (P.cursor ~= P.lastSeg or not P.lastPX or math.sqrt((px - P.lastPX) ^ 2 + (py - P.lastPY) ^ 2) > 12) then
        lineAcc = 0; P.lastSeg, P.lastPX, P.lastPY = P.cursor, px, py
        ns.Fire("FR_PATHPROGRESS", target.index, onPath and P.cursor or -1)
      end
      local dz = onPath and P.z1 and zHere and (P.z1 - zHere)
      if onPath then
        local a2 = HBD:GetWorldVector(pinst, px, py, aim[1], aim[2])
        if a2 then angle = a2 end
        shown = walk
      end
      if dz and math.abs(dz) >= 6 and Arrow.Indoors() then hint = string.format(dz > 0 and "|cff8fd3ff%d yd up|r" or "|cff8fd3ff%d yd down|r", math.floor(math.abs(dz) + 0.5)) end
    elseif target.path and target.path.z1 and target.path.z0 and dist <= 40 and math.abs(target.path.z1 - target.path.z0) >= 6 and Arrow.Indoors() then
      P = target.path
      hint = string.format("|cff8fd3ff%s - %d yd %s|r", P.z1 > P.z0 and "it's upstairs" or "it's below", math.floor(math.abs(P.z1 - P.z0) + 0.5), P.z1 > P.z0 and "up" or "down")
    end
    target.hint = hint
    -- a waypoint on the way (the flight master, the pier) is not the step: reaching it must not tick a goto
    -- or say "in the area" - the next leg takes over once you fly or sail
    local arrived = not target.leg and dist <= (target.r or 12)
    -- at the crossing a ride was pointed at: on toward the step (crossing the border re-plans anyway)
    if target.leg == "ride" and dist <= (target.r or 8) and not target.passing then
      target.passing = true
      Arrow.passed = { index = target.index, wx = target.wx, wy = target.wy, inst = target.winst }
      C_Timer.After(0, function() Arrow.SetTarget(ns.Engine.Shown(), true) end)
    end
    if arrived ~= target.arrived then
      target.arrived = arrived
      local t = target
      if arrived then ns.Engine.Arrived(t.index) end
      ns.Fire("FR_ARRIVED", t.index, arrived)
      if target ~= t then return end -- arriving ticked the step: the next one has its own target now (or none)
      if f:IsShown() then
        f.arrow:SetShown(not arrived); f.check:SetShown(arrived)
        if arrived then f.pulse:Play() else f.pulse:Stop(); f.ring:SetAlpha(0) end
      end
    end
    distAcc = distAcc + el
    if distAcc > 0.25 then distAcc = 0; lastDist = shown; ns.Fire("FR_DISTANCE", shown, arrived, target.leg) end
    if not f:IsShown() then return end
    local facing = GetPlayerFacing and GetPlayerFacing()
    if not facing or not angle then return end
    local want = angle - facing
    local d = (want - rot + math.pi) % (2 * math.pi) - math.pi
    rot = rot + d * math.min(1, el * Arrow.TURN)
    f.arrow:SetRotation(rot)
    local r, g, b = colorFor((want + math.pi) % (2 * math.pi) - math.pi)
    f.arrow:SetVertexColor(r, g, b); f.arrow:SetAlpha(1)
    local eta = shown / moveSpeed
    local k = math.min(1, el * 3)
    shownDist = shownDist and (math.abs(shown - shownDist) > 60 and shown or shownDist + (shown - shownDist) * k) or shown
    shownEta = shownEta and (math.abs(eta - shownEta) > 30 and eta or shownEta + (eta - shownEta) * k) or eta
    textAcc = textAcc + el
    if textAcc >= 0.25 or arrived then -- the text changes a few times a second, not every frame
      textAcc = 0
      local e = shownEta; if e > 30 then e = math.floor(e / 5 + 0.5) * 5 end
      local s = ForeverRouteData and ForeverRouteData.steps[target.index]
      f.dist:SetText(arrived and ((s and s.k == "obj") and "In the area" or "Here") or (Style.Distance(shownDist) .. "  |cff8a93a6" .. Style.Duration(e) .. "|r"))
    end
    f.label:SetText(target.hint or target.label)
  end))
end

-- the right-click hide is kept for that step itself (a replan or path switch renumbers steps: by number it could
-- hide some unrelated later step)
local function stepAt(i) return i and ForeverRouteData and ForeverRouteData.steps and ForeverRouteData.steps[i] end
local function visible(i)
  return ns.db.arrow and not (Arrow.hiddenFor and Arrow.hiddenFor == stepAt(i)) and not ns.Engine.view
end
-- why the arrow isn't showing, logged when that changes (ForeverRouteDB.why: read from the save after play)
local lastWhy
local function noteHidden(why)
  if why == lastWhy then return end
  lastWhy = why
  if why and ns.Why then ns.Why("arrow", "hidden: " .. why) end
end
Arrow.Visible = function(i) return visible(i) and true or false end
local function hiddenReason(i, s)
  if not s then return "no step" end
  if not ns.db.arrow then return "turned off in settings" end
  if Arrow.hiddenFor and Arrow.hiddenFor == s then return "you right-clicked it" end
  if ns.Engine.view then return "looking at another step (Back / list)" end
end

-- up/down hints only mean something inside a building (floors, stairs); outdoors a height difference is a hill
function Arrow.Indoors() return ns.Is(IsIndoors) and true or false end
-- what the arrow points at ({ index, m, x, y, label, ... } or nil), for tests: card, arrow and pins must agree
function Arrow.Current() return target end

function Arrow.SetTarget(i, force)
  local s = i and ForeverRouteData and ForeverRouteData.steps[i]
  if target and s and target.index == i and not force then
    f:SetShown(visible(i)); noteHidden(not visible(i) and hiddenReason(i, s) or nil)
    return
  end
  -- on a flight there is nothing to steer: the step's flight master is behind you and the step is the taxi's job.
  -- Pointing anywhere would read as "go back" (or as a trip planned from the sky). Landing re-targets.
  local step = s
  if s and ns.Is(UnitOnTaxi, "player") then s = nil end
  -- inside a dungeon the game gives no position: nothing to measure a direction from (the card lists the dungeon's
  -- quests instead). Walking out re-targets (FR_DUNGEON).
  local inDungeon = ns.Dungeon and ns.Dungeon.Inside()
  if inDungeon then s = nil end
  -- work the quest data has no place for (s.unknown): its spot is only its place in the order, nothing to point at
  local unknown = s and s.unknown
  if unknown then s = nil end
  local m, x, y, label = s and s.m, s and s.x, s and s.y, nil
  local leg -- how you travel from the waypoint the arrow points at ("fly", "boat", ...), when it is not the step itself
  if s and not x then
    local fm; m, x, y, fm = ns.Engine.TravelTarget(s)
    if fm then label = "Flight master: " .. fm; leg = "fly" end
  end
  -- the step is in another zone than you: point the way there - the flight master, the pier, or for a ride the first
  -- zone crossing on the way (the road, not a line over the mountains; the next zone re-targets)
  local trip = s and ns.Engine.TravelFor and ns.Engine.TravelFor(s)
  if trip and trip.how == "aboard" then m, x, y = nil, nil, nil -- sailing: nothing to point at until you land
  elseif trip then
    local l1 = trip.legs and trip.legs[1]
    local how = (l1 and l1.how) or trip.how or "ride"
    -- a ride with no crossing on the way points at the step itself: keep it the step (its radius, its arrival)
    local isStep = s.k ~= "fly" and how == "ride" and trip.m == s.m and trip.x == s.x and trip.y == s.y
    local useTrip = not isStep
    if useTrip and how == "ride" and s.k ~= "fly" then
      local cx, cy, ci = HBD:GetWorldCoordinatesFromZone(trip.x or 0, trip.y or 0, trip.m or 0)
      local px, py, pinst = HBD:GetPlayerWorldPosition()
      -- the crossing reached: carry on toward the step until the next zone takes over (a gate inside one zone
      -- would otherwise hold the arrow on a spot you are standing on)
      local P = Arrow.passed
      if P and P.index == i and cx and ci == P.inst and math.sqrt((cx - P.wx) ^ 2 + (cy - P.wy) ^ 2) < 30 then useTrip = false end
      -- the planner's own walking path to the step beats "crossing, then straight": follow it while you are on it
      if useTrip and s.wp and px then
        local sx, sy, si = HBD:GetWorldCoordinatesFromZone(s.x, s.y, s.m)
        local W = sx and si == pinst and buildPath(s, s.m, sx, sy)
        if W and select(3, follow(W, px, py)) <= 45 then useTrip = false end
      end
    end
    if useTrip then
      m, x, y, label = trip.m, trip.x, trip.y, (l1 and l1.text) or trip.text
      leg = how
    end
  end
  if s and m and x then
    local wx, wy, winst = HBD:GetWorldCoordinatesFromZone(x, y, m)
    -- a waypoint gets its own small radius: the step's (25 yd for a dungeon, up to 60 for a kill area) belongs to the step
    target = { index = i, m = m, x = x, y = y, r = leg and 8 or s.r, leg = leg, zone = s.zone, wx = wx, wy = wy, winst = winst, label = label or ns.Card.Plain((ns.Card.Describe(s))) }
    target.path = (not label) and buildPath(s, m, wx, wy) or nil
    -- the live line (Nav.lua) is for exactly this target: the step itself (with its planned floor height) or a waypoint
    target.key = wx and (i .. ":" .. math.floor(wx) .. ":" .. math.floor(wy)) or nil
    target.z = (not leg) and (m == s.m) and s.z or nil
    if target.path then
      local list = ForeverRouteData.steps
      for j = i - 1, math.max(1, i - 12), -1 do
        local p = list[j]
        if p.k == "fly" or p.k == "hearth" then break end
        if p.m == m and p.x then
          local sx, sy = HBD:GetWorldCoordinatesFromZone(p.x, p.y, m)
          if sx then target.path.start = { sx, sy, p.z }; target.path.startR = math.max(40, p.r or 40) end
          break
        end
      end
    end
    if ns.Nav then ns.Nav.Want(target.key and { key = target.key, wx = wx, wy = wy, inst = winst, z = target.z, m = m } or nil) end
    f.label:SetText(target.label)
    f.arrow:Show(); f.check:Hide(); f.pulse:Stop(); f.ring:SetAlpha(0)
    f:SetShown(visible(i)); noteHidden(not visible(i) and hiddenReason(i, s) or nil)
  else
    target = nil; f:Hide(); ns.Fire("FR_DISTANCE", nil)
    if ns.Nav then ns.Nav.Want(nil) end
    noteHidden(not step and "no step" or unknown and "where to do this isn't in the quest data" or inDungeon and ("inside " .. inDungeon .. " (no coordinates in a dungeon)") or ns.Is(UnitOnTaxi, "player") and "on a flight" or (trip and trip.how == "aboard") and "aboard (boat or tram, or somewhere no trip starts from)" or step.k == "hearth" and "hearth step (nowhere to walk)" or ("no position for this step: " .. tostring(step.k) .. " " .. tostring(step.text)))
  end
end

ns.On("FR_LOADED", build)
ns.On("FR_STEP", function(i) Arrow.SetTarget(i) end)
ns.On("FR_DUNGEON", function() if f then Arrow.SetTarget(ns.Engine.Shown(), true) end end)
-- a new zone can change the way there (landed, or rode across a border)
ns.On("ZONE_CHANGED_NEW_AREA", function() C_Timer.After(1, function() if f then Arrow.SetTarget(ns.Engine.Shown(), true) end end) end)
-- a different route can have a step at the same position: always rebuild the target
ns.On("FR_ROUTE_CHANGED", function() C_Timer.After(0, function() if f then Arrow.SetTarget(ns.Engine.Shown(), true) end end) end)
-- taking off and landing: drop the arrow for the flight, bring it back (with a trip planned from the ground) after it.
-- The step may well be the same one, so this has to force the rebuild; FR_STEP refreshes the card with it.
-- (Control is also lost to stuns and fears: only a flight counts.)
local flying = false
local function retarget() if f then Arrow.SetTarget(ns.Engine.Shown(), true); ns.Fire("FR_STEP", ns.Engine.Shown()) end end
ns.On("PLAYER_CONTROL_LOST", function() C_Timer.After(1, function() if ns.Is(UnitOnTaxi, "player") then flying = true; retarget() end end) end)
ns.On("PLAYER_CONTROL_GAINED", function() C_Timer.After(1, function() if flying then flying = false; retarget() end end) end)
ns.On("FR_SETTINGS", function() if f then Style.ApplyScale(); Arrow.SetTarget(ns.Engine.Shown(), true) end end)
ns.On("ZONE_CHANGED_NEW_AREA", function() C_Timer.After(1.5, function() if f and not (target and target.index and ForeverRouteData.steps[target.index] and ForeverRouteData.steps[target.index].x) then Arrow.SetTarget(ns.Engine.Shown(), true) end end) end)
