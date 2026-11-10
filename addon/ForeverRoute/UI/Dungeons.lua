-- "Dungeon routes": pick a dungeon and get a route that picks up every quest for it (and does the whole chain that
-- unlocks them), takes you there, then hands everything in. Your leveling path is kept as it was; the card shows
-- "Back to my path" while you're on a dungeon route. Opened from the card (sword button), the route list or /fr dungeons.
local _, ns = ...
local Style = ns.Style
local C = Style.C
local Dungeons = {}
ns.Dungeons = Dungeons

local f
local W, PAD = 470, 14
local cards = {}

-- quest progress for a route, live from the quest log
local function progressOf(r)
  local total, done, inLog = 0, 0, 0
  for q in pairs(ns.QuestIds(r)) do
    if q > 0 then
      total = total + 1
      if ns.State.IsCompleted(q) then done = done + 1 elseif ns.State.OnQuest(q) then inLog = inLog + 1 end
    end
  end
  return done, total, inLog
end

local function card(k)
  if cards[k] then return cards[k] end
  local c = CreateFrame("Frame", nil, f.content)
  c:SetWidth(W - 2 * PAD)
  c.bg = Style.Nine(c, "panel", "BACKGROUND", 0, 10, 0, 1, 1, 1, 0.035)
  c.edge = c:CreateTexture(nil, "ARTWORK"); c.edge:SetTexture(Style.WHITE); c.edge:SetWidth(3); c.edge:SetPoint("TOPLEFT", 1, -8); c.edge:SetPoint("BOTTOMLEFT", 1, 8)
  c.name = Style.Text(c, 13, C.text, "OUTLINE"); c.name:SetPoint("TOPLEFT", 14, -10); c.name:SetWordWrap(false)
  c.cur = Style.Pill(c, "FOLLOWING", C.gold)
  c.quick = Style.Pill(c, "QUICK", C.good)
  c.special = Style.Pill(c, "SPECIAL REWARD", C.gold)
  c.time = Style.Text(c, 12, C.gold); c.time:SetPoint("TOPRIGHT", -14, -11); c.time:SetJustifyH("RIGHT")
  c.lvl = Style.Text(c, 10, C.sub); c.lvl:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -5); c.lvl:SetWordWrap(true); c.lvl:SetWidth(W - 2 * PAD - 150) -- clear of the button
  c.quests = Style.Text(c, 10, C.dim); c.quests:SetPoint("TOPLEFT", c.lvl, "BOTTOMLEFT", 0, -4); c.quests:SetWidth(W - 2 * PAD - 160)
  c.go = Style.Button(c, "Route me", 110, 22, function(self) local r = self:GetParent().route; if r then ns.EnterDungeonRoute(r.id); Dungeons.Draw() end end)
  c.go:SetPoint("RIGHT", c, "RIGHT", -12, -6)
  cards[k] = c
  return c
end

local function build()
  f = CreateFrame("Frame", "ForeverRouteDungeons", UIParent)
  f:SetSize(W, 200); f:SetPoint("CENTER", 0, 40); f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true); f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
  Style.Panel(f, C.bg2)
  table.insert(UISpecialFrames, "ForeverRouteDungeons")
  f.title = Style.Text(f, 15, C.gold, "OUTLINE"); f.title:SetPoint("TOPLEFT", PAD, -12); f.title:SetText("Side trips")
  local close = Style.Button(f, "x", 18, 18, function() f:Hide() end, "Close"); close:SetPoint("TOPRIGHT", -8, -8)
  f.intro = Style.Text(f, 11, C.sub); f.intro:SetPoint("TOPLEFT", PAD, -34); f.intro:SetWidth(W - 2 * PAD)
  f.intro:SetText("Special rewards first - one-off items worth going out of your way for - then dungeons. Pick a dungeon: its route picks up every quest for it, does the whole chain that unlocks them, takes you to the entrance, then hands everything in. Your leveling path is kept as it is - \"Back to my path\" on the card returns you to it.")
  f.back = Style.Button(f, "Back to my path", 130, 20, function() ns.LeaveDungeonRoute(); Dungeons.Draw() end)
  f.empty = Style.Text(f, 11, C.dim)
  -- the list scrolls (mouse wheel) once it is taller than most of the screen
  f.scroll = CreateFrame("ScrollFrame", nil, f)
  f.content = CreateFrame("Frame", nil, f.scroll); f.content:SetSize(W, 10)
  f.scroll:SetScrollChild(f.content)
  f.scroll:EnableMouseWheel(true)
  f.bar = f:CreateTexture(nil, "OVERLAY"); f.bar:SetTexture(Style.WHITE); f.bar:SetWidth(3); f.bar:SetVertexColor(C.gold[1], C.gold[2], C.gold[3], 0.6)
  local function scrollTo(v)
    local max = math.max(0, f.content:GetHeight() - f.scroll:GetHeight())
    v = math.max(0, math.min(max, v)); f.scroll:SetVerticalScroll(v)
    local vh, ch = f.scroll:GetHeight(), f.content:GetHeight()
    f.bar:SetShown(max > 0)
    if max > 0 then
      local bh = math.max(24, vh * vh / ch)
      f.bar:ClearAllPoints(); f.bar:SetPoint("TOPRIGHT", f.scroll, "TOPRIGHT", -4, -((vh - bh) * v / max)); f.bar:SetHeight(bh)
    end
  end
  f.scrollTo = scrollTo
  f.scroll:SetScript("OnMouseWheel", function(_, delta) scrollTo(f.scroll:GetVerticalScroll() - delta * 80) end)
  f:Hide()
end

function Dungeons.Draw()
  if not f or not f:IsShown() then return end
  local list = {}
  for _, r in ipairs(ns.DungeonRoutes()) do if r.special then list[#list + 1] = r end end
  for _, r in ipairs(ns.DungeonRoutes()) do if not r.special then list[#list + 1] = r end end
  local y = 34 + f.intro:GetStringHeight() + 12
  local y0
  local onDungeon = ForeverRouteData and ForeverRouteData.dungeon
  f.back:ClearAllPoints(); f.back:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -y); f.back:SetShown(onDungeon and true or false)
  if onDungeon then y = y + 28 end
  for k, c in ipairs(cards) do if k > #list then c:Hide() end end
  f.empty:SetShown(#list == 0)
  if #list == 0 then f.empty:ClearAllPoints(); f.empty:SetPoint("TOPLEFT", PAD, -y); f.empty:SetText("No dungeon routes in this plan. Run the planner again."); y = y + 24 end
  y0 = y
  local yc = 0
  local myLevel = UnitLevel("player") or 1
  for k, r in ipairs(list) do
    local c = card(k)
    c.route = r
    local isCur = (ForeverRouteData == r)
    local zc = Style.ZoneColor(r.dungeonName or r.title)
    c.name:SetText(r.dungeonName or r.title); c.name:SetTextColor(zc[1], zc[2], zc[3])
    c.quick:ClearAllPoints(); c.quick:SetPoint("LEFT", c.name, "RIGHT", 8, 0); c.quick:SetShown(r.variant == "quick")
    c.special:ClearAllPoints(); c.special:SetPoint("LEFT", c.name, "RIGHT", 8, 0); c.special:SetShown(r.special and true or false)
    local tag = (r.variant == "quick" and c.quick) or (r.special and c.special) or nil
    c.cur:ClearAllPoints(); c.cur:SetPoint("LEFT", tag or c.name, "RIGHT", tag and 4 or 8, 0); c.cur:SetShown(isCur)
    c.time:SetText(r.meta and r.meta.hours and string.format("~%d min", math.floor(tonumber(r.meta.hours) * 60 + 0.5)) or "")
    local need = tonumber(r.needsLevel) or 0
    local lvlText = string.format("Quests around level %s", r.questLevel or "?")
    if need > myLevel then lvlText = lvlText .. "  ·  |cffff8c4dsome need level " .. need .. "|r" end
    local done, total, inLog = progressOf(r)
    c.lvl:SetText(lvlText .. string.format("  ·  %d quest%s%s", total, total == 1 and "" or "s", done > 0 and string.format(" (%d done)", done) or "") .. (inLog > 0 and string.format(", %d in your log", inLog) or "") .. ((tonumber(r.xp) or 0) > 0 and string.format("  ·  |cffffd25a%.1fk XP|r", r.xp / 1000) or ""))
    if r.special then
      c.lvl:SetText(string.format("Can start at level %s  ·  %d quest%s", r.needsLevel or "?", total, total == 1 and "" or "s") .. (done > 0 and string.format(" (%d done)", done) or "") .. (inLog > 0 and string.format(", %d in your log", inLog) or ""))
      c.quests:SetText((r.why or "") .. "\n|cff8a93a6" .. ((r.meta and r.meta.legs) or "") .. "|r")
    else
    c.quests:SetText("For the dungeon: " .. (r.quests or "") .. ((r.chainCount or 0) > 0 and string.format("  |cff8a93a6+ %d chain quest%s that unlock them|r", r.chainCount, r.chainCount == 1 and "" or "s") or "")
      .. (r.cut and ("\n|cffffb36bSkips: " .. r.cut .. "|r") or ""))
    end
    c.go.label:SetText(isCur and "Following" or "Route me"); c.go:SetEnabled(not isCur)
    local col = isCur and C.gold or zc
    c.edge:SetVertexColor(col[1], col[2], col[3], isCur and 0.95 or 0.5)
    c.quests:ClearAllPoints(); c.quests:SetPoint("TOPLEFT", c.lvl, "BOTTOMLEFT", 0, -4)
    local h = 10 + 16 + 5 + c.lvl:GetStringHeight() + 4 + c.quests:GetStringHeight() + 12
    c:SetHeight(math.max(64, h))
    c:ClearAllPoints(); c:SetPoint("TOPLEFT", f.content, "TOPLEFT", PAD, -yc); c:Show()
    yc = yc + c:GetHeight() + 8
  end
  -- at most 85% of the screen tall; the rest scrolls
  local maxH = (UIParent:GetHeight() or 800) * 0.85
  local view = math.max(60, math.min(yc, maxH - y0 - 6))
  f.content:SetHeight(math.max(1, yc))
  f.scroll:ClearAllPoints(); f.scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -y0); f.scroll:SetSize(W, view)
  f:SetHeight(y0 + view + 6)
  f.scrollTo(f.scroll:GetVerticalScroll())
end

function Dungeons.Toggle()
  if f:IsShown() then f:Hide(); return end
  f:Show(); Dungeons.Draw()
end

ns.On("FR_LOADED", build)
ns.On("FR_TOGGLE_DUNGEONS", function() Dungeons.Toggle() end)
ns.On("FR_ROUTE_CHANGED", function() Dungeons.Draw() end)
ns.On("QUEST_LOG_UPDATE", function() if f and f:IsShown() then Dungeons.Draw() end end)
