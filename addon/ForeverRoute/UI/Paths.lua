-- "Choose your path": one card per planned path. Each card shows the zones in order as chips, how long it takes, where it
-- ends, how many zone choices come up along the way, and a button to follow it. Opened from the route list or /fr paths.
local _, ns = ...
local Style = ns.Style
local C = Style.C
local Paths = {}
ns.Paths = Paths

local f
local W, PAD = 470, 14
local cards = {}

local function legsOf(r)
  local out = {}
  for z in ((r.meta and r.meta.legs) or r.title or ""):gmatch("[^>·]+") do
    z = z:gsub("^%s+", ""):gsub("%s+$", "")
    if z ~= "" and out[#out] ~= z then out[#out + 1] = z end
  end
  return out
end

local function card(k)
  if cards[k] then return cards[k] end
  local c = CreateFrame("Button", nil, f)
  c:SetWidth(W - 2 * PAD)
  c.bg = Style.Nine(c, "panel", "BACKGROUND", 0, 10, 0, 1, 1, 1, 0.035)
  c.edge = c:CreateTexture(nil, "ARTWORK"); c.edge:SetTexture(Style.WHITE); c.edge:SetWidth(3); c.edge:SetPoint("TOPLEFT", 1, -8); c.edge:SetPoint("BOTTOMLEFT", 1, 8)
  local hl = c:CreateTexture(nil, "HIGHLIGHT"); hl:SetTexture(Style.WHITE); hl:SetPoint("TOPLEFT", 3, -3); hl:SetPoint("BOTTOMRIGHT", -3, 3); hl:SetVertexColor(1, 0.82, 0.36, 0.05)
  c.name = Style.Text(c, 13, C.text, "OUTLINE"); c.name:SetPoint("TOPLEFT", 14, -10); c.name:SetWordWrap(false)
  c.fast = Style.Pill(c, "MOST ENJOYABLE", C.good)
  c.cur = Style.Pill(c, "FOLLOWING", C.gold)
  c.hours = Style.Text(c, 13, C.gold); c.hours:SetPoint("TOPRIGHT", -14, -10); c.hours:SetJustifyH("RIGHT")
  c.chips = CreateFrame("Frame", nil, c); c.chips:SetPoint("TOPLEFT", 14, -32); c.chips:SetSize(W - 2 * PAD - 28, 20)
  c.stats = Style.Text(c, 10, C.sub); c.stats:SetWordWrap(false)
  c.go = Style.Button(c, "Follow this path", 120, 20, function(self) local r = self:GetParent().route; if r then ns.SelectRoute(r.id); ns.char.pinnedPath = r.id; Paths.Draw() end end)
  c:SetScript("OnClick", function(self) if self.route then ns.SelectRoute(self.route.id); ns.char.pinnedPath = self.route.id; Paths.Draw() end end)
  cards[k] = c
  return c
end

local function build()
  f = CreateFrame("Frame", "ForeverRoutePaths", UIParent)
  f:SetSize(W, 200); f:SetPoint("CENTER", 0, 40); f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true); f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
  Style.Panel(f, C.bg2)
  table.insert(UISpecialFrames, "ForeverRoutePaths")
  f.title = Style.Text(f, 15, C.gold, "OUTLINE"); f.title:SetPoint("TOPLEFT", PAD, -12); f.title:SetText("Choose your path")
  local close = Style.Button(f, "x", 18, 18, function() f:Hide() end, "Close"); close:SetPoint("TOPRIGHT", -8, -8)
  f.intro = Style.Text(f, 11, C.sub); f.intro:SetPoint("TOPLEFT", PAD, -34); f.intro:SetWidth(W - 2 * PAD)
  f.intro:SetText("Each path is a full plan from where you are now, using your level, finished quests and quest log. The recommended one is the most enjoyable - story chains, good rewards and dungeons, fewer annoying quests and less backtracking - not just the quickest. Switching is free: each path keeps its own progress.")
  -- "Start next in...": ask the planner (on your PC) for a path that starts in a zone of your choice
  f.reqLabel = Style.Text(f, 11, C.gold, "OUTLINE"); f.reqLabel:SetText("Start next in...")
  f.reqHelp = Style.Text(f, 10, C.sub); f.reqHelp:SetWidth(W - 2 * PAD)
  f.reqZones = {}
  f:Hide()
end

local function zoneButton(k)
  if f.reqZones[k] then return f.reqZones[k] end
  local b = Style.Button(f, "", 100, 20, function(self) Paths.Request(self.zone) end)
  f.reqZones[k] = b
  return b
end
function Paths.Request(zone)
  ns.char.requestZone = zone; ns.char.requestHandled = nil
  -- a ready-made route into that zone: go now (the next replan builds your whole path from there, and the addon moves
  -- you onto it); without one, the planner makes it after your next save
  local zr = zone and ns.ZoneRouteFor and ns.ZoneRouteFor(zone)
  if zr then
    ns.SelectRoute(zr.id); ns.Fire("FR_ROUTE_CHANGED"); ns.Engine.Refresh()
    if ns.Why then ns.Why("path", "you picked " .. zone .. ": on its ready-made route now; your next plan starts there") end
    ns.Print("Now heading to " .. zone .. " (the route takes you there, with pick-ups on the way). Your next plan builds your path from there - no need to wait for it.")
  else
    ns.Print(zone and ("Asked for a path starting in " .. zone .. ". /reload to send it to the planner (about 5 minutes), then /reload once more to get it.") or "Cleared your zone request.")
  end
  Paths.Draw()
end

function Paths.Draw()
  if not f or not f:IsShown() then return end
  local list = ns.MainRoutes()
  local here = ForeverRouteData and ForeverRouteData.branch and ns.RouteById(ForeverRouteData.parent) or ForeverRouteData
  local best = 0
  for _, r in ipairs(list) do local h = tonumber(r.meta and r.meta.hours) or 0; if r.best or (r.meta and r.meta.best) then best = r end end
  local y = 34 + f.intro:GetStringHeight() + 12
  for k, c in ipairs(cards) do if k > #list then c:Hide() end end
  for k, r in ipairs(list) do
    local c = card(k)
    c.route = r
    local m = r.meta or {}
    local isCur = (r == here)
    local isBest = (r == best)
    c.name:SetText("Path " .. k .. (r.requested and ("  |cffffd25a(you asked: " .. r.requested .. ")|r") or ""))
    c.fast:ClearAllPoints(); c.fast:SetPoint("LEFT", c.name, "RIGHT", 8, 0); c.fast:SetShown(isBest)
    c.cur:ClearAllPoints(); c.cur:SetPoint("LEFT", isBest and c.fast or c.name, "RIGHT", isBest and 5 or 8, 0); c.cur:SetShown(isCur)
    -- hours to the same level for every path, so they compare fairly
    c.hours:SetText(m.hoursTo and string.format("~%s h to %s", m.hoursTo, m.target or 30) or (m.hours and ("~" .. m.hours .. " h")) or "")
    local hChips = Style.Chips(c.chips, legsOf(r), W - 2 * PAD - 28)
    c.chips:SetHeight(hChips)
    local picks = #(r.choices or {})
    local steps = #(r.steps or {})
    c.stats:ClearAllPoints(); c.stats:SetPoint("TOPLEFT", c.chips, "BOTTOMLEFT", 0, -8)
    -- why it's recommended: what makes a path enjoyable, in plain counts
    local why = {}
    if r.story then why[#why + 1] = r.story .. " story quests" end
    if r.rewards then why[#why + 1] = r.rewards .. " good rewards" end
    if r.dungeons and r.dungeons > 0 then why[#why + 1] = r.dungeons .. (r.dungeons == 1 and " dungeon" or " dungeons") end
    if r.revisits then why[#why + 1] = r.revisits == 0 and "no backtracking" or (r.revisits .. " zone revisit" .. (r.revisits == 1 and "" or "s")) end
    c.stats:SetText(string.format("Level %s to %s%s", m.startLevel or "?", m.endLevel or "?", #why > 0 and ("  ·  " .. table.concat(why, "  ·  ")) or string.format("  ·  %d steps", steps))
      .. (picks > 0 and string.format("  ·  %d zone choice%s", picks, picks == 1 and "" or "s") or ""))
    c.stats:SetWordWrap(true); c.stats:SetWidth(W - 2 * PAD - 28 - 132)
    c.go:ClearAllPoints(); c.go:SetPoint("TOPRIGHT", c, "TOPRIGHT", -12, -(32 + hChips + 4))
    c.go.label:SetText(isCur and "Following" or "Follow this path")
    c.go:SetEnabled(not isCur)
    local col = isCur and C.gold or (isBest and C.good or C.dim)
    c.edge:SetVertexColor(col[1], col[2], col[3], isCur and 0.95 or 0.5)
    for _, part in ipairs(c.bg) do part:SetVertexColor(1, 1, 1, isCur and 0.06 or 0.035) end
    local h = 32 + hChips + 14 + math.max(22, c.stats:GetStringHeight() + 4) -- the reasons line can wrap
    c:SetHeight(h)
    c:ClearAllPoints(); c:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -y); c:Show()
    y = y + h + 8
  end
  -- zone request row
  local plan = ForeverRoutePlan or {}
  local zones = {}
  for _, z in ipairs(plan.zones or {}) do zones[#zones + 1] = { name = z.name, xph = z.xph } end
  for _, z in ipairs(plan.later or {}) do zones[#zones + 1] = { name = z, later = true } end
  f.reqLabel:ClearAllPoints(); f.reqLabel:SetPoint("TOPLEFT", PAD, -y - 4); y = y + 22
  local x, rowY = PAD, y
  for k, b in ipairs(f.reqZones) do if k > #zones then b:Hide() end end
  for k, z in ipairs(zones) do
    local b = zoneButton(k); b.zone = z.name
    local asked = ns.char.requestZone == z.name
    b.label:SetText((asked and "|cffffd25a" or "") .. Style.ShortZone(z.name) .. (z.xph and z.xph > 0 and string.format("  |cff8a93a6%.0fk|r", z.xph / 1000) or "") .. (asked and "|r" or ""))
    local w = b.label:GetStringWidth() + 18; b:SetWidth(w)
    if x + w > W - PAD then x = PAD; rowY = rowY + 24 end
    b:ClearAllPoints(); b:SetPoint("TOPLEFT", x, -rowY); b:Show()
    x = x + w + 4
  end
  y = rowY + 26
  local req = ns.char.requestZone
  local help
  if req then
    local ready = false; for _, r in ipairs(list) do if r.requested == req then ready = true end end
    local known = false; for _, z in ipairs(plan.zones or {}) do if z.name == req then known = true end end
    local zr = ns.ZoneRouteFor and ns.ZoneRouteFor(req)
    help = ready and ("|cff5cdc7aA path starting in " .. req .. " is ready - it's in the list above.|r")
      or (zr and ("|cff5cdc7aOn your way to " .. req .. ".|r Your next plan builds the rest of your path from there."))
      or ("|cffffd25aAsked for " .. req .. ".|r /reload to send it to the planner (about 5 min), then /reload again.")
    if not known then help = help .. "  |cffff8c4dFew quests there at your level yet, so it may be slow until you level a bit.|r" end
  else
    help = "Zone too crowded, or fancy a change? Click a zone to go there now: the route takes you there with the pick-ups on the way, and your path is rebuilt from it. Numbers are XP per hour at your level."
  end
  f.reqHelp:SetText(help); f.reqHelp:ClearAllPoints(); f.reqHelp:SetPoint("TOPLEFT", PAD, -y); y = y + f.reqHelp:GetStringHeight() + 10
  if ForeverRouteData and ForeverRouteData.branch then
    f.note = f.note or Style.Text(f, 10, C.gold)
    f.note:ClearAllPoints(); f.note:SetPoint("TOPLEFT", PAD, -y); f.note:SetWidth(W - 2 * PAD)
    f.note:SetText("You're on a zone choice you picked (" .. (ForeverRouteData.title or "") .. "). Following a path above leaves it.")
    f.note:Show(); y = y + f.note:GetStringHeight() + 8
  elseif f.note then f.note:Hide() end
  f:SetHeight(y + 6)
end

function Paths.Toggle()
  if f:IsShown() then f:Hide(); return end
  f:Show(); Paths.Draw()
end

ns.On("FR_LOADED", build)
ns.On("FR_TOGGLE_PATHS", function() Paths.Toggle() end)
ns.On("FR_ROUTE_CHANGED", function() Paths.Draw() end)
