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
News.MIN_W, News.MIN_H, News.MAX_W, News.MAX_H = 320, 160, 900, 800
News.MAX_HEIGHT = 360 -- the tallest it opens at (drag the corner for more); past that the notes scroll

-- the notes, laid out for the panel's width: what's measured depends on it
local function relayout()
  if not panel then return end
  local w = math.max(100, panel:GetWidth() - 46)
  panel.content:SetWidth(w); panel.body:SetWidth(w)
  local h = panel.body:GetStringHeight()
  panel.content:SetHeight(h + 4)
  panel.older:ClearAllPoints(); panel.older:SetPoint("TOPLEFT", panel.body, "BOTTOMLEFT", 0, -6)
  panel.content:SetHeight(h + 4 + (panel.older:IsShown() and 28 or 0))
end

local function buildPanel()
  panel = CreateFrame("Frame", "ForeverRouteNews", UIParent)
  local size = ns.db.newsSize
  panel:SetSize(size and size[1] or 440, size and size[2] or 200); panel:SetPoint("CENTER", 0, 80); panel:SetFrameStrata("DIALOG")
  panel:SetClampedToScreen(true); panel:SetMovable(true); panel:EnableMouse(true); panel:RegisterForDrag("LeftButton")
  panel:SetScript("OnDragStart", panel.StartMoving); panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
  -- resizable from the bottom-right corner; the size is remembered
  panel:SetResizable(true)
  if panel.SetResizeBounds then panel:SetResizeBounds(News.MIN_W, News.MIN_H, News.MAX_W, News.MAX_H)
  elseif panel.SetMinResize then panel:SetMinResize(News.MIN_W, News.MIN_H); panel:SetMaxResize(News.MAX_W, News.MAX_H) end
  Style.Panel(panel, C.bg2)
  table.insert(UISpecialFrames, "ForeverRouteNews")
  panel.title = Style.Text(panel, 15, C.gold, "OUTLINE"); panel.title:SetPoint("TOPLEFT", 14, -12)
  local close = Style.Button(panel, "x", 18, 18, function() panel:Hide() end, "Close"); close:SetPoint("TOPRIGHT", -8, -8)
  panel.scroll = CreateFrame("ScrollFrame", "ForeverRouteNewsScroll", panel, "UIPanelScrollFrameTemplate")
  panel.scroll:SetPoint("TOPLEFT", 14, -38); panel.scroll:SetPoint("BOTTOMRIGHT", -32, 18)
  panel.content = CreateFrame("Frame", nil, panel.scroll); panel.content:SetSize(394, 10)
  panel.scroll:SetScrollChild(panel.content)
  panel.body = Style.Text(panel.content, 11, C.text); panel.body:SetPoint("TOPLEFT", 0, 0); panel.body:SetWidth(394)
  panel.body:SetJustifyH("LEFT"); panel.body:SetWordWrap(true)
  -- older versions, on request, at the end of the notes
  panel.older = Style.Button(panel.content, "Older versions", 110, 20, function() News.Show(panel.seen, true) end, "The notes of earlier versions too")
  panel.grip = CreateFrame("Button", "ForeverRouteNewsGrip", panel)
  panel.grip:SetSize(14, 14); panel.grip:SetPoint("BOTTOMRIGHT", -3, 3)
  local g = panel.grip:CreateTexture(nil, "OVERLAY"); g:SetAllPoints(); g:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  panel.grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  panel.grip:SetScript("OnMouseDown", function() panel:StartSizing("BOTTOMRIGHT") end)
  panel.grip:SetScript("OnMouseUp", function() panel:StopMovingOrSizing(); ns.db.newsSize = { math.floor(panel:GetWidth()), math.floor(panel:GetHeight()) }; relayout() end)
  panel:SetScript("OnSizeChanged", function() relayout() end)
end

-- the panel: what changed since `seen` (nil: the latest version); all = every version News.lua has
function News.Show(seen, all)
  if not panel then buildPanel() end
  panel.seen = seen
  local list = all and (ns.NEWS or {}) or News.Since(seen)
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
  -- the "Older versions" button when there are more versions than shown
  panel.older:SetShown(not all and #list < #(ns.NEWS or {}))
  relayout()
  if not ns.db.newsSize then panel:SetHeight(math.min(News.MAX_HEIGHT, panel.content:GetHeight() + 60)) end
  if not all then panel.scroll:SetVerticalScroll(0) end
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
