-- "Where to?": a window with a rail of two tabs on its left.
--   Zones - the zones you could go to now (ns.ZoneChoices): the XP left there for you (and what share of your level
--           that is), quests left, hand-ins waiting, your plan's next zone marked PLANNED NEXT. Picking one takes you there.
--   Plan  - your plan as the zones ahead, each with its quests (read-only); a companion's other plans fold under it.
-- The window keeps its size and the list scrolls. Paths.Draw builds one state (Paths.State) and lays it out; each
-- kind of row has one paint function for its looks (selected, hover, kind), so they never stack oddly. Opened from the
-- route list's "Where to?", the card's "Change zone" or "/fr paths".
local _, ns = ...
local Style = ns.Style
local C = Style.C
local Paths = {}
ns.Paths = Paths

local f
local MEDIA = "Interface\\AddOns\\ForeverRoute\\Media\\"
local W, H, PAD = 470, 470, 14      -- content width, window height
local RAIL = 64                     -- the tab rail
local LEFT = RAIL + PAD
local TOP = 58                      -- where the scrolling list starts
local ROW_H, ROW_GAP = 40, 4        -- a zone row
local CARD_H = 96                   -- a path card
local RIGHT_W = 120                 -- the numbers at a row's right

-- the two tabs: label, icon, colour, the window title and a line under it
local TABS = {
  zones = { label = "Zones", icon = "icon-goto", color = C.gold, title = "Where to?", tip = "The zones you could go to now" },
  paths = { label = "Plan", icon = "btn-list", color = C.good, title = "Your plan", tip = "The zones ahead on your plan, with their quests" },
}
Paths.tab = "zones"

-- ---------------------------------------------------------------- looks

local function paintTab(b)
  local t = TABS[b.key]
  local lit = b.on or b.hover
  local col = lit and t.color or C.sub
  b.icon:SetVertexColor(col[1], col[2], col[3]); b.icon:SetAlpha(lit and 1 or 0.65)
  b.label:SetTextColor(col[1], col[2], col[3])
  b.wash:SetVertexColor(t.color[1], t.color[2], t.color[3], 0.12); b.wash:SetShown(b.on)
  b.bar:SetVertexColor(t.color[1], t.color[2], t.color[3]); b.bar:SetShown(b.on)
end

-- a zone row: its edge says what it is (best next gold, where you are green), hover lights it up
local function paintRow(b)
  local z = b.row or {}
  local col = z.best and C.gold or (z.here and C.good or C.dim)
  b.edge:SetVertexColor(col[1], col[2], col[3], (z.best or z.here) and 0.95 or 0.45)
  for _, part in ipairs(b.bg) do part:SetVertexColor(1, 1, 1, b.hover and 0.09 or 0.04) end
  local nc = (z.best and C.gold) or C.text
  b.name:SetTextColor(nc[1], nc[2], nc[3])
end

local function paintCard(c)
  local col = c.isCur and C.gold or (c.isBest and C.good or C.dim)
  c.edge:SetVertexColor(col[1], col[2], col[3], c.isCur and 0.95 or 0.5)
  for _, part in ipairs(c.bg) do part:SetVertexColor(1, 1, 1, (c.hover or c.isCur) and 0.07 or 0.035) end
end

local function hover(b, on, paint)
  b.hover = on; paint(b)
end

-- ---------------------------------------------------------------- widgets

local function tabButton(key, y)
  local b = CreateFrame("Button", nil, f.rail)
  b:SetSize(RAIL - 6, 48); b:SetPoint("TOP", f.rail, "TOP", 0, -y); b.key = key
  b.wash = b:CreateTexture(nil, "BACKGROUND"); b.wash:SetTexture(Style.WHITE); b.wash:SetAllPoints()
  b.bar = b:CreateTexture(nil, "ARTWORK"); b.bar:SetTexture(Style.WHITE); b.bar:SetWidth(3); b.bar:SetPoint("TOPLEFT", 0, -6); b.bar:SetPoint("BOTTOMLEFT", 0, 6)
  b.icon = b:CreateTexture(nil, "ARTWORK"); b.icon:SetTexture(MEDIA .. TABS[key].icon); b.icon:SetSize(18, 18); b.icon:SetPoint("TOP", 0, -8)
  b.label = Style.Text(b, 10, C.sub); b.label:SetPoint("TOP", b.icon, "BOTTOM", 0, -4); b.label:SetJustifyH("CENTER"); b.label:SetText(TABS[key].label)
  b:SetScript("OnClick", function() Paths.tab = key; Paths.Draw() end)
  b:SetScript("OnEnter", function(self)
    hover(self, true, paintTab)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(TABS[key].tip, 1, 1, 1, 1, true); GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function(self) hover(self, false, paintTab); GameTooltip:Hide() end)
  return b
end

-- rows and cards are kept by identity (a zone, a path id), so one keeps its look from one draw to the next
local rows, cards = {}, {}

local function zoneRow(key)
  if rows[key] then return rows[key] end
  local b = CreateFrame("Button", nil, f.content)
  b:SetSize(W - 2 * PAD - 8, ROW_H)
  b.bg = Style.Nine(b, "panel", "BACKGROUND", 0, 8, 0, 1, 1, 1, 0.04)
  b.edge = b:CreateTexture(nil, "ARTWORK"); b.edge:SetTexture(Style.WHITE); b.edge:SetWidth(3); b.edge:SetPoint("TOPLEFT", 1, -5); b.edge:SetPoint("BOTTOMLEFT", 1, 5)
  -- line 1: the zone's name, bounded by the numbers at the right (they never run into each other)
  b.right = Style.Text(b, 10, C.sub); b.right:SetPoint("TOPRIGHT", -10, -7); b.right:SetWidth(RIGHT_W); b.right:SetJustifyH("RIGHT"); b.right:SetWordWrap(false)
  b.name = Style.Text(b, 12, C.text, "OUTLINE"); b.name:SetPoint("TOPLEFT", 12, -6); b.name:SetPoint("RIGHT", b.right, "LEFT", -8, 0)
  b.name:SetJustifyH("LEFT"); b.name:SetWordWrap(false)
  -- line 2: what it is (a pill), then why, both bounded by the row's right edge
  b.pill = Style.Pill(b, "", C.gold); b.pill:SetPoint("TOPLEFT", 12, -22)
  b.why = Style.Text(b, 10, C.sub); b.why:SetJustifyH("LEFT"); b.why:SetWordWrap(false)
  b:SetScript("OnClick", function(self) if self.row then Paths.Pick(self.row) end end)
  b:SetScript("OnEnter", function(self)
    hover(self, true, paintRow)
    local z = self.row; if not z then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(z.zone, 1, 1, 1)
    if z.planned then GameTooltip:AddLine("Next on your plan. The plan weighs more than one zone's XP: the trip there, chains that carry on, what comes after it, and coming back to zones you've done. Picking it keeps you on your path.", 0.72, 0.76, 0.84, true)
    elseif z.route and z.xpLeft then GameTooltip:AddLine(string.format("About %s XP left there for you. Click to go there now: the route takes you there with the pick-ups on the way%s.", Paths.Short(z.xpLeft), (ns.HasCompanion and ns.HasCompanion()) and ", and your next plan is built from there" or ""), 0.72, 0.76, 0.84, true)
    elseif z.route then GameTooltip:AddLine("Click to go there now: the route takes you there with the pick-ups on the way, and your plan carries on from it.", 0.72, 0.76, 0.84, true)
    else GameTooltip:AddLine("No ready route at your level yet." .. ((ns.HasCompanion and ns.HasCompanion()) and " Click to ask the planner for one." or ""), 0.72, 0.76, 0.84, true) end
    if z.handIns > 0 then GameTooltip:AddLine(z.handIns .. " quest" .. (z.handIns == 1 and " you finished is" or "s you finished are") .. " handed in there.", 0.36, 0.86, 0.48, true) end
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function(self) hover(self, false, paintRow); GameTooltip:Hide() end)
  rows[key] = b
  return b
end

local function legsOf(r)
  local out = {}
  for z in ((r.meta and r.meta.legs) or r.title or ""):gmatch("[^>·]+") do
    z = Style.ShortZone((z:gsub("^%s+", ""):gsub("%s+$", "")))
    if z ~= "" and out[#out] ~= z then out[#out + 1] = z end
  end
  return out
end

local function follow(r) if r then ns.SelectRoute(r.id); ns.char.pinnedPath = r.id; Paths.Draw() end end

local function pathCard(id)
  if cards[id] then return cards[id] end
  local c = CreateFrame("Button", nil, f.content)
  c:SetSize(W - 2 * PAD - 8, CARD_H)
  c.bg = Style.Nine(c, "panel", "BACKGROUND", 0, 10, 0, 1, 1, 1, 0.035)
  c.edge = c:CreateTexture(nil, "ARTWORK"); c.edge:SetTexture(Style.WHITE); c.edge:SetWidth(3); c.edge:SetPoint("TOPLEFT", 1, -8); c.edge:SetPoint("BOTTOMLEFT", 1, 8)
  c.hours = Style.Text(c, 12, C.gold); c.hours:SetPoint("TOPRIGHT", -12, -10); c.hours:SetWidth(RIGHT_W); c.hours:SetJustifyH("RIGHT"); c.hours:SetWordWrap(false)
  c.name = Style.Text(c, 13, C.text, "OUTLINE"); c.name:SetPoint("TOPLEFT", 14, -10); c.name:SetWordWrap(false)
  c.pill = Style.Pill(c, "", C.gold); c.pill:SetPoint("LEFT", c.name, "RIGHT", 8, 0)
  c.chips = CreateFrame("Frame", nil, c); c.chips:SetPoint("TOPLEFT", 14, -32); c.chips:SetSize(W - 2 * PAD - 36, 20)
  c.go = Style.Button(c, "Follow", 80, 20, function(self) follow(self:GetParent().route) end)
  c.go:SetPoint("BOTTOMRIGHT", -12, 10)
  c.stats = Style.Text(c, 10, C.sub); c.stats:SetPoint("BOTTOMLEFT", 14, 14); c.stats:SetPoint("RIGHT", c.go, "LEFT", -8, 0)
  c.stats:SetJustifyH("LEFT"); c.stats:SetWordWrap(false)
  c:SetScript("OnClick", function(self) follow(self.route) end)
  c:SetScript("OnEnter", function(self)
    hover(self, true, paintCard)
    local r = self.route; if not r then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(self.name:GetText() or "Path", 1, 1, 1)
    GameTooltip:AddLine(table.concat(legsOf(r), " > "), 0.72, 0.76, 0.84, true)
    if r.rewards then GameTooltip:AddLine(r.rewards .. " good rewards", 0.72, 0.76, 0.84) end
    if r.dungeons and r.dungeons > 0 then GameTooltip:AddLine(r.dungeons .. (r.dungeons == 1 and " dungeon" or " dungeons"), 0.72, 0.76, 0.84) end
    GameTooltip:Show()
  end)
  c:SetScript("OnLeave", function(self) hover(self, false, paintCard); GameTooltip:Hide() end)
  cards[id] = c
  return c
end

-- one zone ahead on your plan: its name and how many quests, a few of them under it (read-only)
local planRows = {}
local PLAN_H = 34
local function planRow(k)
  if planRows[k] then return planRows[k] end
  local b = CreateFrame("Frame", nil, f.content)
  b:SetSize(W - 2 * PAD - 8, PLAN_H)
  b.dot = b:CreateTexture(nil, "ARTWORK"); b.dot:SetTexture(Style.WHITE); b.dot:SetSize(6, 6); b.dot:SetPoint("TOPLEFT", 4, -9)
  b.line = b:CreateTexture(nil, "BACKGROUND"); b.line:SetTexture(Style.WHITE); b.line:SetWidth(1); b.line:SetPoint("TOP", b.dot, "BOTTOM", 0, -2); b.line:SetPoint("BOTTOM", b, "BOTTOM", 0, -2)
  b.line:SetVertexColor(1, 1, 1, 0.12)
  b.right = Style.Text(b, 10, C.sub); b.right:SetPoint("TOPRIGHT", -10, -4); b.right:SetWidth(RIGHT_W); b.right:SetJustifyH("RIGHT"); b.right:SetWordWrap(false)
  b.name = Style.Text(b, 12, C.text, "OUTLINE"); b.name:SetPoint("TOPLEFT", 18, -3); b.name:SetPoint("RIGHT", b.right, "LEFT", -8, 0); b.name:SetJustifyH("LEFT"); b.name:SetWordWrap(false)
  b.sub = Style.Text(b, 10, C.sub); b.sub:SetPoint("TOPLEFT", 18, -18); b.sub:SetPoint("RIGHT", b, "RIGHT", -10, 0); b.sub:SetJustifyH("LEFT"); b.sub:SetWordWrap(false)
  planRows[k] = b
  return b
end

-- ---------------------------------------------------------------- the window

local function setScroll(v)
  local max = math.max(0, f.content:GetHeight() - f.scroll:GetHeight())
  v = math.max(0, math.min(max, v)); f.scroll:SetVerticalScroll(v)
  local th = f.track:GetHeight() or 0
  f.thumb:SetShown(max > 0); f.track:SetShown(max > 0); f.grip:SetShown(max > 0)
  if max > 0 and th > 0 then
    local h = math.max(20, th * f.scroll:GetHeight() / f.content:GetHeight())
    f.thumb:SetHeight(h); f.thumb:ClearAllPoints(); f.thumb:SetPoint("TOP", f.track, "TOP", 0, -(th - h) * v / max)
  end
end

local function build()
  f = CreateFrame("Frame", "ForeverRoutePaths", UIParent)
  f:SetSize(W + RAIL, H); f:SetPoint("CENTER", 0, 40); f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true); f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
  Style.Panel(f, C.bg2); Style.Scaled(f, nil, true)
  table.insert(UISpecialFrames, "ForeverRoutePaths")
  -- the rail
  f.rail = CreateFrame("Frame", nil, f)
  f.rail:SetPoint("TOPLEFT", 4, -4); f.rail:SetPoint("BOTTOMLEFT", 4, 4); f.rail:SetWidth(RAIL - 6)
  f.rail.bg = f.rail:CreateTexture(nil, "BACKGROUND"); f.rail.bg:SetAllPoints(); f.rail.bg:SetColorTexture(0, 0, 0, 0.28)
  f.tabs = { tabButton("zones", 8), tabButton("paths", 60) }
  -- the top: title, one line under it, close
  f.title = Style.Text(f, 15, C.gold, "OUTLINE"); f.title:SetPoint("TOPLEFT", LEFT, -12)
  local close = Style.Button(f, "x", 18, 18, function() f:Hide() end, "Close"); close:SetPoint("TOPRIGHT", -8, -8)
  f.intro = Style.Text(f, 10, C.sub); f.intro:SetPoint("TOPLEFT", LEFT, -34); f.intro:SetPoint("RIGHT", f, "RIGHT", -PAD, 0); f.intro:SetWordWrap(false)
  -- the list: scrolls inside a window that keeps its size
  f.scroll = CreateFrame("ScrollFrame", nil, f); f.scroll:EnableMouseWheel(true)
  f.scroll:SetPoint("TOPLEFT", LEFT, -TOP); f.scroll:SetPoint("BOTTOMRIGHT", -PAD - 8, 34)
  f.content = CreateFrame("Frame", nil, f.scroll); f.content:SetSize(W - 2 * PAD, 10); f.scroll:SetScrollChild(f.content)
  f.track = f:CreateTexture(nil, "ARTWORK"); f.track:SetTexture(Style.WHITE); f.track:SetVertexColor(1, 1, 1, 0.05); f.track:SetWidth(4)
  f.track:SetPoint("TOPRIGHT", -PAD + 2, -TOP); f.track:SetPoint("BOTTOMRIGHT", -PAD + 2, 34)
  f.thumb = f:CreateTexture(nil, "OVERLAY"); f.thumb:SetTexture(Style.WHITE); f.thumb:SetVertexColor(C.gold[1], C.gold[2], C.gold[3], 0.6); f.thumb:SetWidth(4)
  f.scroll:SetScript("OnMouseWheel", function(self, d) setScroll(self:GetVerticalScroll() - d * 60) end)
  f.grip = Style.ScrollGrip(f, f.track, f.thumb, function(fr) setScroll(fr * math.max(0, f.content:GetHeight() - f.scroll:GetHeight())) end)
  -- the bottom: one line (a zone you asked for, or how many more zones there are)
  f.foot = Style.Text(f, 10, C.sub); f.foot:SetPoint("BOTTOMLEFT", LEFT, 12); f.foot:SetPoint("RIGHT", f, "RIGHT", -PAD, 0); f.foot:SetWordWrap(false)
  f:Hide()
end

-- ---------------------------------------------------------------- state

Paths.PLANNED = "\1planned" -- (the planned route's row, picked from a zone you chose)
-- 14200 -> "14k", 1500 -> "1.5k", 950 -> "950"
function Paths.Short(n)
  n = tonumber(n) or 0
  if n >= 10000 then return string.format("%.0fk", n / 1000) elseif n >= 1000 then return string.format("%.1fk", n / 1000) end
  return tostring(math.floor(n))
end
-- a row picked: the zone you're on stays; your planned route's row on a zone you chose goes back to the route;
-- anything else is that zone's route, or a request for one (Paths.Request)
function Paths.Pick(row)
  local onZone = ForeverRouteData and ForeverRouteData.zoneRoute
  if row.planned then
    if onZone then return Paths.Request(Paths.PLANNED) end
    if f then f:Hide() end; return -- (on your planned route already)
  end
  if row.here then if f then f:Hide() end; return end
  return Paths.Request(row.zone)
end
function Paths.Request(zone)
  ns.char.requestZone = zone; ns.char.requestHandled = nil
  -- a ready-made route into that zone: go now (the next replan builds your whole path from there, and the addon moves
  -- you onto it); without one, the planner makes it after your next save
  local zr = zone and ns.ZoneRouteFor and ns.ZoneRouteFor(zone)
  if zone == Paths.PLANNED then
    ns.char.requestZone = nil
    ns.LeaveDungeonRoute(); ns.Fire("FR_ROUTE_CHANGED"); ns.Engine.Refresh()
    Paths.Draw(); return
  end
  if zr then
    ns.EnterZoneRoute(zr.id); ns.Fire("FR_ROUTE_CHANGED"); ns.Engine.Refresh()
    if ns.Why then ns.Why("path", "you picked " .. zone .. ": on its ready-made route now; your next plan starts there") end
    ns.Print("Now heading to " .. zone .. " (the route takes you there, with pick-ups on the way). Your next plan builds your path from there - no need to wait for it.")
  else
    ns.Print(zone and ("Asked for a path starting in " .. zone .. ". /reload to send it to the planner (about 5 minutes), then /reload once more to get it.") or "Cleared your zone request.")
  end
  Paths.Draw()
end

-- one line about a zone you asked for (nil: nothing asked)
function Paths.HelpText(list)
  local req = ns.char.requestZone
  if not req then return nil end
  for _, r in ipairs(list or {}) do if r.requested == req then return "|cff5cdc7aA path starting in " .. req .. " is ready under Paths.|r" end end
  local companion = ns.HasCompanion and ns.HasCompanion()
  if ns.ZoneRouteFor and ns.ZoneRouteFor(req) then return "|cff5cdc7aOn your way to " .. req .. ".|r" .. (companion and " Your next plan builds on from there." or "") end
  return companion and ("|cffffd25aAsked for " .. req .. ".|r /reload to send it to the planner, then /reload again.") or ("|cffffd25aNo ready route into " .. req .. " at your level.|r")
end

-- everything the window shows, worked out once per draw
local MAX_NO_ROUTE = 3
function Paths.State()
  local list = ns.MainRoutes()
  local st = { tab = Paths.tab, list = list, rows = {}, more = 0, level = 0 }
  local zc = ns.ZoneChoices and ns.ZoneChoices() or { rows = {} }
  st.level = zc.level or 0
  local noRoute = 0
  for _, z in ipairs(zc.rows) do
    if z.route or z.planned or z.handIns > 0 then st.rows[#st.rows + 1] = z
    else noRoute = noRoute + 1; if noRoute <= MAX_NO_ROUTE then st.rows[#st.rows + 1] = z else st.more = st.more + 1 end end
  end
  -- the zone that pays most per hour, when it is not the planned one (a ready route: XP/h is that route's)
  st.help = Paths.HelpText(list)
  st.here = ForeverRouteData and ForeverRouteData.branch and ns.RouteById(ForeverRouteData.parent) or ForeverRouteData
  for _, r in ipairs(list) do if r.best or (r.meta and r.meta.best) then st.best = r end end
  return st
end

-- ---------------------------------------------------------------- layout

local function layoutZones(st)
  local y = 0
  local onZone = ForeverRouteData and ForeverRouteData.zoneRoute
  for _, z in ipairs(st.rows) do
    local b = zoneRow(z.key)
    b.row = z
    b.name:SetText(Style.ShortZone(z.zone))
    local right = {}
    -- the XP left there for you, and what share of your level that is: finish this zone, or go where there is more
    if z.xpLeft and z.xpLeft > 0 then
      local need = (UnitXPMax and UnitXPMax("player")) or 0
      right[#right + 1] = "~" .. Paths.Short(z.xpLeft) .. " XP" .. (need > 0 and string.format(" (%d%%)", math.floor(100 * z.xpLeft / need + 0.5)) or "")
    end
    if z.questsLeft then right[#right + 1] = z.questsLeft .. (z.questsLeft == 1 and " quest" or " quests") end
    b.right:SetText(table.concat(right, "  ·  "))
    -- the pill says what it is; the reason follows it
    -- PLANNED NEXT is what your plan does; the XP at the right says what each zone holds for you
    local pill = (z.best and "PLANNED NEXT") or (z.here and "YOU'RE HERE") or nil
    b.pill:SetShown(pill ~= nil)
    if pill then b.pill:Set(pill, z.best and C.gold or C.good) end
    local why = {}
    if z.best and z.here then why[#why + 1] = "you're here" end
    if z.planned then why[#why + 1] = onZone and "where your planned route picks up" or "next on your planned route" end
    -- one chain reason: hand-ins waiting, else a quest you carry there, else what it needs first
    if z.handIns > 0 then why[#why + 1] = z.handIns .. (z.handIns == 1 and " hand-in waiting" or " hand-ins waiting")
    elseif z.continues then why[#why + 1] = "continues " .. z.continues
    elseif z.needs then why[#why + 1] = "needs " .. z.needs.name .. (z.needs.zone and (" (" .. Style.ShortZone(z.needs.zone) .. ")") or "") .. " first" end
    if not z.route and not z.planned then why[#why + 1] = "no route yet" end
    b.why:ClearAllPoints()
    if pill then b.why:SetPoint("LEFT", b.pill, "RIGHT", 8, 0) else b.why:SetPoint("TOPLEFT", 12, -23) end
    b.why:SetPoint("RIGHT", b, "RIGHT", -10, 0)
    b.why:SetText(table.concat(why, "  ·  "))
    paintRow(b)
    b:ClearAllPoints(); b:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, -y); b:Show()
    y = y + ROW_H + ROW_GAP
  end
  return y
end

local function layoutPaths(st, y0)
  local y = y0 or 0
  for k, r in ipairs(st.list) do
    local c = pathCard(r.id)
    c.route, c.isCur, c.isBest = r, (r == st.here), (r == st.best)
    local m = r.meta or {}
    c.name:SetText("Path " .. k)
    -- one pill at most: FOLLOWING, else MOST ENJOYABLE
    local pill = (c.isCur and "FOLLOWING") or (c.isBest and "MOST ENJOYABLE") or nil
    c.pill:SetShown(pill ~= nil)
    if pill then c.pill:Set(pill, c.isCur and C.gold or C.good) end
    c.hours:SetText(m.hoursTo and string.format("~%s h to %s", m.hoursTo, m.target or 60) or (m.hours and ("~" .. m.hours .. " h")) or "")
    Style.Chips(c.chips, legsOf(r), W - 2 * PAD - 36, 4)
    local stats = {}
    local endLevel = tostring(m.endLevel or "?"):match("^(%d+)") or m.endLevel or "?"
    stats[#stats + 1] = string.format("Level %s to %s", m.startLevel or "?", endLevel)
    if r.story then stats[#stats + 1] = r.story .. " story quests" end
    if r.revisits then stats[#stats + 1] = r.revisits == 0 and "no backtracking" or (r.revisits .. " revisit" .. (r.revisits == 1 and "" or "s")) end
    if r.requested then stats[#stats + 1] = "starts in " .. Style.ShortZone(r.requested) end
    c.stats:SetText(table.concat(stats, "  ·  "))
    c.go.label:SetText(c.isCur and "Following" or "Follow"); c.go:SetEnabled(not c.isCur)
    paintCard(c)
    c:ClearAllPoints(); c:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, -y); c:Show()
    y = y + CARD_H + 8
  end
  return y - (y0 or 0)
end

Paths.showOthers = false
local function layoutPlan(st)
  local y = 0
  local d = ForeverRouteData
  local ahead = {}
  if d and d.zoneRoute then
    -- on a zone you picked: that zone, then where your planned route picks up
    ahead[1] = { zone = d.zoneName or "", quests = 0, names = { "the zone you picked" }, now = true }
    local nz = ns.PlannedNextZone and ns.PlannedNextZone()
    if nz then ahead[2] = { zone = nz, quests = 0, names = { "where your planned route picks up" } } end
  else
    for _, z in ipairs(ns.Engine.ZonesAhead and ns.Engine.ZonesAhead(nil, 12) or {}) do
      local last = ahead[#ahead]
      if last and Style.ShortZone(last.zone) == Style.ShortZone(z.zone) then
        last.quests = last.quests + z.quests; for _, n in ipairs(z.names) do last.names[#last.names + 1] = n end
      else ahead[#ahead + 1] = { zone = z.zone, quests = z.quests, names = { unpack(z.names) }, grind = z.grind } end
    end
  end
  for k, z in ipairs(ahead) do
    local b = planRow(k)
    b.name:SetText(Style.ShortZone(z.zone))
    b.right:SetText(z.quests > 0 and (z.quests .. (z.quests == 1 and " quest" or " quests")) or "")
    local names = {}
    for n = 1, math.min(2, #z.names) do names[#names + 1] = z.names[n] end
    b.sub:SetText(table.concat(names, ", ") .. (#z.names > 2 and string.format(" and %d more", #z.names - 2) or ""))
    local col = (k == 1) and C.gold or C.dim
    b.dot:SetVertexColor(col[1], col[2], col[3]); b.line:SetShown(k < #ahead)
    b:ClearAllPoints(); b:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, -y); b:Show()
    y = y + PLAN_H
  end
  -- a companion's other plans, folded
  if #st.list > 1 then
    f.others = f.others or Style.Button(f.content, "", 160, 20, function() Paths.showOthers = not Paths.showOthers; Paths.Draw() end, "Your companion's other full plans")
    f.others.label:SetText((Paths.showOthers and "Hide" or "Other plans") .. " (" .. #st.list .. ")")
    f.others:ClearAllPoints(); f.others:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, -(y + 8)); f.others:Show()
    y = y + 36
    if Paths.showOthers then
      y = y + layoutPaths(st, y)
    end
  elseif f.others then f.others:Hide() end
  return y
end

function Paths.Draw()
  if not f or not f:IsShown() then return end
  local st = Paths.State()
  local zones = st.tab ~= "paths"
  for _, b in ipairs(f.tabs) do b.on = (b.key == "zones") == zones; paintTab(b) end
  f.tabs[2].label:SetText("Plan")
  f.title:SetText(TABS[zones and "zones" or "paths"].title)
  f.intro:SetText(zones and string.format("Level %d  ·  XP left per zone (%% of level)", st.level) or "The zones ahead on your plan, and the quests in each")
  -- everything hidden, then what this tab shows
  for _, b in pairs(rows) do b:Hide() end
  for _, c in pairs(cards) do c:Hide() end
  for _, b in pairs(planRows) do b:Hide() end
  if f.others then f.others:Hide() end
  local h = zones and layoutZones(st) or layoutPlan(st)
  f.content:SetHeight(math.max(h, 1))
  local foot
  if zones then
    foot = st.help or (st.more > 0 and string.format("+%d more zone%s at your level the planner can make a route for", st.more, st.more == 1 and "" or "s")) or nil
  end
  f.foot:SetText(foot or ""); f.foot:SetShown(foot ~= nil)
  setScroll(f.scroll:GetVerticalScroll())
end

function Paths.Show(tab) if not f then return end; if tab then Paths.tab = tab end; f:Show(); setScroll(0); Paths.Draw() end
function Paths.Toggle()
  if f:IsShown() then f:Hide(); return end
  f:Show(); setScroll(0); Paths.Draw()
end

ns.On("FR_LOADED", build)
ns.On("FR_TOGGLE_PATHS", function() Paths.Toggle() end)
ns.On("FR_ROUTE_CHANGED", function() Paths.Draw() end)
