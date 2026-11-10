-- Whole-route list: steps grouped under their hub/section headers, done steps dimmed with a tick,
-- the current one highlighted; mouse wheel scrolls; click a step to jump to it.
local _, ns = ...
local Style = ns.Style
local C = Style.C
local List = {}
ns.List = List

local f
local ROW, VISIBLE = 18, 24
local rows = {}
local entries = {} -- { header = text } or { index = i }
local builtFor, builtN   -- the step list (and its length) the entries were made from

local function rebuild()
  wipe(entries)
  local data = ForeverRouteData
  builtFor, builtN = data and data.steps, data and data.steps and #data.steps
  if not data then return end
  local lastSec
  for i, s in ipairs(data.steps) do
    if s.sec ~= lastSec then
      lastSec = s.sec
      local sec = data.sections and data.sections[s.sec]
      entries[#entries + 1] = { header = sec and (sec.title .. (sec.zone and ("  |cff8a93a6" .. sec.zone .. "|r") or "")) or "" }
    end
    entries[#entries + 1] = { index = i }
  end
end

local function build()
  f = CreateFrame("Frame", "ForeverRouteList", UIParent)
  f:SetSize(420, ROW * VISIBLE + 84)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true); f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
  Style.Panel(f, C.bg2)
  table.insert(UISpecialFrames, "ForeverRouteList") -- Escape closes it
  f.title = Style.Text(f, 13, C.gold, "OUTLINE"); f.title:SetPoint("TOPLEFT", 12, -10)
  f.sub = Style.Text(f, 10, C.sub); f.sub:SetPoint("TOPLEFT", 80, -12); f.sub:Hide()
  local close = Style.Button(f, "x", 18, 18, function() f:Hide() end, "Close"); close:SetPoint("TOPRIGHT", -8, -8)
  -- which path you're following: name + badges, the zones in order, level/hours, and a button to change it
  f.paths = CreateFrame("Frame", nil, f); f.paths:SetPoint("TOPLEFT", 10, -32); f.paths:SetPoint("TOPRIGHT", -10, -32); f.paths:SetHeight(60)
  f.paths.bg = Style.Nine(f.paths, "panel", "BACKGROUND", 0, 10, 0, 1, 0.82, 0.36, 0.06)
  f.pathLabel = Style.Text(f.paths, 9, C.dim, "OUTLINE"); f.pathLabel:SetPoint("TOPLEFT", 10, -8); f.pathLabel:SetText("FOLLOWING")
  f.pathName = Style.Text(f.paths, 12, C.text, "OUTLINE"); f.pathName:SetPoint("LEFT", f.pathLabel, "RIGHT", 6, 0); f.pathName:SetWordWrap(false)
  f.pathFast = Style.Pill(f.paths, "MOST ENJOYABLE", C.good)
  f.logc = Style.Button(f, "Log check", 74, 18, function() ns.Fire("FR_TOGGLE_LOGCHECK") end, "Which quests in your log are worth keeping, and which to drop")
  f.logc:SetPoint("TOPRIGHT", -32, -8)
  f.dung = Style.Button(f, "Side trips", 70, 18, function() ns.Fire("FR_TOGGLE_DUNGEONS") end, "Special rewards (like the Cozy Sleeping Bag) and dungeon routes - each a side trip that keeps your path")
  f.dung:SetPoint("RIGHT", f.logc, "LEFT", -4, 0)
  f.change = Style.Button(f, "Change path", 88, 18, function() ns.Fire("FR_TOGGLE_PATHS") end, "See every planned path side by side")
  f.change:SetPoint("RIGHT", f.dung, "LEFT", -4, 0)
  f.pathChips = CreateFrame("Frame", nil, f.paths); f.pathChips:SetPoint("TOPLEFT", 10, -26); f.pathChips:SetSize(380, 18)
  f.pathMeta = Style.Text(f.paths, 10, C.sub); f.pathMeta:SetWordWrap(false)
  for k = 1, VISIBLE do
    local r = CreateFrame("Button", nil, f); r:SetHeight(ROW)
    r:SetPoint("RIGHT", -14, 0)
    r.hl = r:CreateTexture(nil, "BACKGROUND"); r.hl:SetTexture(Style.WHITE); r.hl:SetAllPoints()
    r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(12, 12); r.icon:SetPoint("LEFT", 14, 0)
    r.text = Style.Text(r, 11, C.text); r.text:SetPoint("LEFT", r.icon, "RIGHT", 7, 0); r.text:SetPoint("RIGHT"); r.text:SetWordWrap(false); r.text:SetJustifyV("MIDDLE")
    local hover = r:CreateTexture(nil, "HIGHLIGHT"); hover:SetTexture(Style.WHITE); hover:SetAllPoints(); hover:SetVertexColor(1, 1, 1, 0.05)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:SetScript("OnClick", function(self, btn) if not self.index then return end if btn == "RightButton" then ns.ShowOnMap(self.index) return end if IsShiftKeyDown() then ns.Engine.Jump(self.index) else ns.Engine.view = (self.index ~= ns.Engine.current) and self.index or nil; ns.Fire("FR_STEP", ns.Engine.Shown()) end end)
    r:SetScript("OnEnter", function(self) if self.index then GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText("Click to look · Right-click: map · Shift-click to jump here", 1, 1, 1); GameTooltip:Show() end end)
    r:SetScript("OnLeave", GameTooltip_Hide)
    rows[k] = r
  end
  -- scrollbar thumb (visual only; wheel scrolls)
  f.track = f:CreateTexture(nil, "ARTWORK"); f.track:SetTexture(Style.WHITE); f.track:SetVertexColor(1, 1, 1, 0.04); f.track:SetWidth(3)
  f.track:SetPoint("BOTTOMRIGHT", -6, 14)
  f.thumb = f:CreateTexture(nil, "OVERLAY"); f.thumb:SetTexture(Style.WHITE); f.thumb:SetVertexColor(C.gold[1], C.gold[2], C.gold[3], 0.6); f.thumb:SetWidth(3)
  f.offset = 0
  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, d) List.Scroll(-d * 3) end)
  f:Hide()
end

function List.Scroll(d)
  f.offset = math.max(0, math.min(#entries - VISIBLE, f.offset + d))
  List.Draw()
end

function List.Draw()
  if not f or not f:IsShown() then return end
  local data = ForeverRouteData
  -- stops get added while the list is open (finished quests' hand-ins, side trips on the way, flight paths): those
  -- only redraw, so a stale list would put every header after the new stop one row off and lose the last step
  if (data and data.steps) ~= builtFor or (data and data.steps and #data.steps) ~= builtN then
    rebuild(); f.offset = math.max(0, math.min(#entries - VISIBLE, f.offset))
  end
  f.title:SetText("Route")
  local list = ns.MainRoutes()
  local main = data and data.branch and ns.RouteById(data.parent) or data
  local idx = 1; for i, r in ipairs(list) do if r == main then idx = i end end
  local m = data and data.meta or {}
  local done, total = ns.Engine.Progress()
  f.sub:SetText("")
  if data then
    f.pathName:SetText(data.dungeon and ("Dungeon route: " .. (data.dungeonName or data.title)) or data.branch and ("Path " .. idx .. ": " .. (data.title or "")) or ("Path " .. idx .. " of " .. #list))
    f.pathName:SetWidth(math.min(300, f.pathName:GetStringWidth() + 2))
    f.pathFast:ClearAllPoints(); f.pathFast:SetPoint("LEFT", f.pathName, "RIGHT", 6, 0)
    f.pathFast:SetShown((data.best or m.best) and true or false)
    local legs = {}
    for z in (m.legs or data.title or ""):gmatch("[^>·]+") do z = z:gsub("^%s+", ""):gsub("%s+$", ""); if z ~= "" and legs[#legs] ~= z then legs[#legs + 1] = z end end
    local hc = Style.Chips(f.pathChips, legs, 396)
    f.pathChips:SetHeight(hc)
    f.pathMeta:ClearAllPoints(); f.pathMeta:SetPoint("TOPLEFT", f.pathChips, "BOTTOMLEFT", 0, -6); f.pathMeta:SetPoint("RIGHT", f.paths, "RIGHT", -10, 0)
    -- how fresh the plan is (the companion app replans after every save)
    local fresh = ""
    local plan = ForeverRoutePlan
    if plan and plan.generated and time then
      local ago = math.max(0, time() - plan.generated)
      local agoText = ago < 120 and "just now" or ago < 7200 and (math.floor(ago / 60) .. " min ago") or (math.floor(ago / 3600) .. " h ago")
      fresh = "  ·  planned " .. agoText .. (plan.fromSave and plan.fromSave > 0 and date and (" from your " .. date("%H:%M", plan.fromSave) .. " save") or "")
    end
    f.pathMeta:SetText(string.format("Level %s to %s%s  ·  %d of %d done%s", m.startLevel or "?", m.endLevel or "?", m.hours and ("  ·  ~" .. m.hours .. " h") or "", done, total, fresh))
    f.pathMeta:SetWordWrap(true); f.pathMeta:SetWidth(396)
    f.paths:SetHeight(26 + hc + 10 + f.pathMeta:GetStringHeight() + 8)
  else
    f.pathName:SetText("No route loaded"); f.pathFast:Hide(); Style.Chips(f.pathChips, {}, 396); f.pathMeta:SetText(""); f.paths:SetHeight(30)
  end
  f.change:SetShown(#list > 1 and not (data and data.dungeon))
  f.dung:SetShown(#ns.DungeonRoutes() > 0)
  -- the step rows sit under the header, whatever its height
  local top = 32 + f.paths:GetHeight() + 8
  for k, r in ipairs(rows) do r:ClearAllPoints(); r:SetPoint("TOPLEFT", 10, -top - (k - 1) * ROW); r:SetPoint("RIGHT", -14, 0) end
  f.track:ClearAllPoints(); f.track:SetPoint("TOPRIGHT", -6, -top); f.track:SetPoint("BOTTOMRIGHT", -6, 14)
  f:SetHeight(top + ROW * VISIBLE + 16)
  local cur = ns.Engine.Shown()
  for k, r in ipairs(rows) do
    local e = entries[f.offset + k]
    r.index = nil
    if not e then r:Hide()
    elseif e.header then
      r:Show(); r.icon:Hide(); r.text:ClearAllPoints(); r.text:SetPoint("LEFT", 2, 0); r.text:SetPoint("RIGHT")
      r.text:SetFontObject(Style.Font(11, "OUTLINE")); r.text:SetJustifyH("LEFT"); r.text:SetText(e.header); r.text:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
      r.hl:SetVertexColor(1, 1, 1, 0.03)
    else
      local s = data.steps[e.index]; local kind = Style.Kind(s)
      r:Show(); r.index = e.index; r.icon:Show()
      r.text:ClearAllPoints(); r.text:SetPoint("LEFT", r.icon, "RIGHT", 7, 0); r.text:SetPoint("RIGHT")
      r.text:SetFontObject(Style.Font(11)); r.text:SetJustifyH("LEFT")
      local isDone = ns.Engine.IsDone(e.index)
      r.icon:SetTexture(Style.MEDIA .. (isDone and "icon-check" or kind.icon))
      if isDone then r.icon:SetVertexColor(C.good[1], C.good[2], C.good[3], 0.6) else r.icon:SetVertexColor(kind.color[1], kind.color[2], kind.color[3]) end
      local title = ns.Card.Describe(s)
      local ch = ns.ChoiceFor and ns.ChoiceFor(e.index)
      if ch and not isDone then
        local names = {}
        for _, o in ipairs(ch.options) do names[#names + 1] = Style.ShortZone(o.zone) end
        title = title .. "  |cffffd25a(choose: " .. table.concat(names, " / ") .. ")|r"
      end
      if isDone then r.text:SetText(ns.Card.Plain(title)); r.text:SetTextColor(0.42, 0.45, 0.52)
      else r.text:SetText(title); r.text:SetTextColor(1, 1, 1) end
      if e.index == cur then r.hl:SetVertexColor(C.gold[1], C.gold[2], C.gold[3], 0.16) else r.hl:SetVertexColor(0, 0, 0, 0) end
    end
  end
  local n = math.max(1, #entries)
  local h = f.track:GetHeight()
  f.thumb:SetHeight(math.max(16, h * math.min(1, VISIBLE / n)))
  f.thumb:ClearAllPoints(); f.thumb:SetPoint("TOPRIGHT", f.track, "TOPRIGHT", 0, -(h - f.thumb:GetHeight()) * (f.offset / math.max(1, n - VISIBLE)))
end

function List.Entries() return entries end   -- for tests

-- scroll so the current step sits in view
local function scrollToCurrent()
  local cur = ns.Engine.Shown()
  f.offset = 0
  for k, e in ipairs(entries) do if e.index == cur then f.offset = math.max(0, math.min(#entries - VISIBLE, k - 4)); break end end
end

function List.Toggle()
  if f:IsShown() then f:Hide(); return end
  rebuild(); f:Show()
  scrollToCurrent()
  List.Draw()
end

ns.On("FR_LOADED", build)
ns.On("FR_TOGGLE_LIST", function() List.Toggle() end)
ns.On("FR_STEP", function() List.Draw() end)
-- another path or "Back to my path": show where you are on it, not its first step
ns.On("FR_ROUTE_CHANGED", function() if f and f:IsShown() then rebuild(); scrollToCurrent(); List.Draw() end end)
