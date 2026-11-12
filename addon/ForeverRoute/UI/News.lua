-- What's new: after an update, a slim bar under the card ("Forever Route updated to 1.2.2 · What's new · x"), once per
-- version; What's new opens the changelog lines since the version you last had. /fr news brings it back any time.
-- The text is News.lua, generated from CHANGELOG.md (tools/gen-news.js). A first install gets no bar: nothing is new
-- to you yet.
local _, ns = ...
local News = {}
ns.News = News
local Style = ns.Style
local C = Style.C

-- "1.2.10" > "1.2.9"
local function newer(a, b)
  local x, y = {}, {}
  for n in tostring(a or ""):gmatch("%d+") do x[#x + 1] = tonumber(n) end
  for n in tostring(b or ""):gmatch("%d+") do y[#y + 1] = tonumber(n) end
  for i = 1, math.max(#x, #y) do
    local p, q = x[i] or 0, y[i] or 0
    if p ~= q then return p > q end
  end
  return false
end
News.Newer = newer

-- the version you run: the TOC's on a release; a dev install ("dev") reads as the newest in the changelog
function News.Current()
  local v = ns.VERSION
  if not (v and v:match("^%d+%.%d+")) then v = ns.NEWS and ns.NEWS[1] and ns.NEWS[1].version end
  return v
end

-- the versions newer than the one you last saw (all of News.lua when you never saw one)
function News.Since(seen)
  local out = {}
  for _, e in ipairs(ns.NEWS or {}) do if not seen or newer(e.version, seen) then out[#out + 1] = e end end
  return out
end

-- someone who used the addon before this version (and so has news): anything the addon keeps about you
local function returning()
  local db, ch = ForeverRouteDB or {}, ForeverRouteChar or {}
  return (type(db.why) == "table" and #db.why > 0) or ch.snapshot ~= nil or (type(ch.manualDone) == "table" and next(ch.manualDone) ~= nil)
end

-- should the bar show? (and remember a first install as having seen this version)
function News.Due()
  local cur = News.Current()
  if not cur then return false end
  local seen = ns.db.newsSeen
  if not seen then
    if not returning() then ns.db.newsSeen = cur; return false end
    return #News.Since(nil) > 0
  end
  return newer(cur, seen) and #News.Since(seen) > 0
end

function News.Dismiss()
  ns.db.newsSeen = News.Current()
  if News.bar then News.bar:Hide() end
end

local panel
local function buildPanel()
  panel = CreateFrame("Frame", "ForeverRouteNews", UIParent)
  panel:SetSize(440, 200); panel:SetPoint("CENTER", 0, 80); panel:SetFrameStrata("DIALOG")
  panel:SetClampedToScreen(true); panel:SetMovable(true); panel:EnableMouse(true); panel:RegisterForDrag("LeftButton")
  panel:SetScript("OnDragStart", panel.StartMoving); panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
  Style.Panel(panel, C.bg2)
  table.insert(UISpecialFrames, "ForeverRouteNews")
  panel.title = Style.Text(panel, 15, C.gold, "OUTLINE"); panel.title:SetPoint("TOPLEFT", 14, -12)
  local close = Style.Button(panel, "x", 18, 18, function() panel:Hide() end, "Close"); close:SetPoint("TOPRIGHT", -8, -8)
  -- the notes scroll: four versions of them are taller than a screen's corner
  panel.scroll = CreateFrame("ScrollFrame", "ForeverRouteNewsScroll", panel, "UIPanelScrollFrameTemplate")
  panel.scroll:SetPoint("TOPLEFT", 14, -38); panel.scroll:SetPoint("BOTTOMRIGHT", -32, 12)
  panel.content = CreateFrame("Frame", nil, panel.scroll); panel.content:SetSize(394, 10)
  panel.scroll:SetScrollChild(panel.content)
  panel.body = Style.Text(panel.content, 11, C.text); panel.body:SetPoint("TOPLEFT", 0, 0); panel.body:SetWidth(394)
  panel.body:SetJustifyH("LEFT"); panel.body:SetWordWrap(true)
end
News.MAX_HEIGHT = 360 -- the panel's tallest; past that the notes scroll

-- the panel: what changed since `seen` (nil: the last few versions)
function News.Show(seen)
  if not panel then buildPanel() end
  local list = News.Since(seen)
  if #list == 0 then list = { ns.NEWS and ns.NEWS[1] } end
  local lines = {}
  for _, e in ipairs(list) do
    if e then
      lines[#lines + 1] = "|cffffd25a" .. e.version .. "|r  |cff8a93a6" .. (e.date or "") .. "|r"
      for _, it in ipairs(e.items or {}) do lines[#lines + 1] = "  - " .. it end
      lines[#lines + 1] = " "
    end
  end
  panel.title:SetText("What's new in Forever Route")
  panel.body:SetText(table.concat(lines, "\n"))
  local h = panel.body:GetStringHeight()
  panel.content:SetHeight(h + 4)
  panel:SetHeight(math.min(News.MAX_HEIGHT, h + 56))
  panel.scroll:SetVerticalScroll(0)
  panel:Show()
  News.Dismiss()
  return panel
end

-- the bar under the card
local function buildBar()
  local card = ForeverRouteCard
  if not card then return nil end
  local b = CreateFrame("Frame", "ForeverRouteNewsBar", card)
  b:SetHeight(22); b:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -4); b:SetPoint("TOPRIGHT", card, "BOTTOMRIGHT", 0, -4)
  Style.Panel(b, C.bg2)
  b.text = Style.Text(b, 11, C.gold); b.text:SetPoint("LEFT", 10, 0)
  local x = Style.Button(b, "x", 18, 18, function() News.Dismiss() end, "Dismiss"); x:SetPoint("RIGHT", -3, 0)
  local open = Style.Button(b, "What's new", 80, 18, function() News.Show(ns.db.newsSeen) end, "What changed since your last version")
  open:SetPoint("RIGHT", x, "LEFT", -4, 0)
  b.text:SetPoint("RIGHT", open, "LEFT", -6, 0); b.text:SetWordWrap(false)
  News.bar = b
  return b
end

function News.Check()
  if not News.Due() then if News.bar then News.bar:Hide() end; return false end
  local b = News.bar or buildBar()
  if not b then return false end
  b.text:SetText("Forever Route updated to " .. tostring(News.Current()))
  b:Show()
  return true
end

ns.On("FR_LOADED", function() C_Timer.After(5, ns.Guard("news", News.Check)) end)
ns.On("FR_NEWS", function() News.Show(nil) end)
