-- Hints: a slim bar under the card for something only you can fix, shown until it's fixed or you dismiss it.
-- Flight paths: Forever's client won't tell addons which ones you know (its world map marks every flight point as
-- discovered - State.ScanTaxi), only a flight master's map does. A character of level 10 or more that the addon knows
-- at most one flight path for gets "open any flight master's map once"; it goes by itself once you have.
local _, ns = ...
local Hints = {}
ns.Hints = Hints
local Style = ns.Style
local C = Style.C

Hints.FP_LEVEL = 10

function Hints.TaxiDue()
  if ns.db.hintTaxiOff then return false end
  if (UnitLevel("player") or 1) < Hints.FP_LEVEL then return false end
  local n = 0
  for _ in pairs((ns.State and ns.State.knownTaxi) or {}) do n = n + 1 end
  return n <= 1
end

-- Small text: the game's UI scale is the player's choice and we follow it, but on a tall screen with a small UI
-- scale (ElvUI's pixel-perfect 768 / screen height: one pixel per unit) our size-10 and 11 text is 10-11 px tall.
-- Under Style.SMALL_PX pixels per unit, and only while the Forever Route scale was never chosen, a bar offers the
-- scale that brings it back to what a 1080p screen shows. One click, or dismissed for good; never by itself.
function Hints.ScaleDue()
  if ns.db.hintScaleOff or ns.db.uiScale then return nil end
  local card = ForeverRouteCard
  if card and Style.PxPerUnit(card) >= Style.SMALL_PX then return nil end -- (the card's own scale already makes up for it)
  return Style.SuggestScale()
end
local sbar
local function buildScale()
  local card = ForeverRouteCard
  if not card then return nil end
  sbar = CreateFrame("Frame", "ForeverRouteScaleBar", card)
  sbar:SetHeight(22)
  Style.Panel(sbar, C.bg2)
  sbar.text = Style.Text(sbar, 11, C.warn); sbar.text:SetPoint("LEFT", 10, 0); sbar.text:SetWordWrap(false)
  local x = Style.Button(sbar, "x", 18, 18, function() ns.db.hintScaleOff = true; sbar:Hide() end, "Leave it as it is (Forever Route scale, in /fr options, changes it any time)")
  x:SetPoint("RIGHT", -3, 0)
  sbar.go = Style.Button(sbar, "Bigger", 96, 18, function()
    local s = sbar.suggest or Style.SuggestScale(); if not s then sbar:Hide(); return end
    Style.SetUIScale(s); sbar:Hide()
    ns.Print(string.format("Forever Route scale set to %.2f. Change it under /fr options, or /fr scale 1 to go back.", s))
  end, "Makes the card, the arrow, the route list and every Forever Route window bigger. Nothing else in your UI changes.")
  sbar.go:SetPoint("RIGHT", x, "LEFT", -4, 0)
  sbar.text:SetPoint("RIGHT", sbar.go, "LEFT", -6, 0)
  return sbar
end
function Hints.CheckScale()
  local s = Hints.ScaleDue()
  if not s then if sbar then sbar:Hide() end; return false end
  if not (sbar or buildScale()) then return false end
  -- under the other bars that are showing
  local above = ForeverRouteCard
  for _, b in ipairs({ ForeverRouteNewsBar or false, ForeverRouteHintBar or false }) do if b and b:IsShown() then above = b end end
  sbar:ClearAllPoints(); sbar:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -4); sbar:SetPoint("TOPRIGHT", above, "BOTTOMRIGHT", 0, -4)
  sbar.suggest = s
  sbar.text:SetText("Small text on this screen?"); sbar.go.label:SetText(string.format("Make it %d%%", math.floor(s * 100 + 0.5)))
  sbar:Show()
  return true
end

local bar
local function build()
  local card = ForeverRouteCard
  if not card then return nil end
  bar = CreateFrame("Frame", "ForeverRouteHintBar", card)
  bar:SetHeight(22)
  Style.Panel(bar, C.bg2)
  bar.text = Style.Text(bar, 11, C.warn); bar.text:SetPoint("LEFT", 10, 0); bar.text:SetWordWrap(false)
  local x = Style.Button(bar, "x", 18, 18, function() ns.db.hintTaxiOff = true; bar:Hide() end, "Don't show this again")
  x:SetPoint("RIGHT", -3, 0)
  bar.text:SetPoint("RIGHT", x, "LEFT", -6, 0)
  return bar
end

function Hints.Check()
  local due = Hints.TaxiDue()
  if not due then if bar then bar:Hide() end; return false end
  if not (bar or build()) then return false end
  -- under the what's-new bar when that is showing
  local news = ForeverRouteNewsBar
  local above = (news and news:IsShown()) and news or ForeverRouteCard
  bar:ClearAllPoints(); bar:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -4); bar:SetPoint("TOPRIGHT", above, "BOTTOMRIGHT", 0, -4)
  bar.text:SetText("Open any flight master's map once so I know your flight paths.")
  bar:Show()
  if sbar and sbar:IsShown() then Hints.CheckScale() end -- (it sits under this one)
  return true
end

ns.On("FR_LOADED", function() C_Timer.After(6, ns.Guard("hints", Hints.Check)) end)
ns.On("FR_TAXI_OPENED", function() Hints.Check() end)
ns.On("FR_LOADED", function() C_Timer.After(7, ns.Guard("hints", Hints.CheckScale)) end)
ns.On("FR_SETTINGS", function() if sbar and sbar:IsShown() then Hints.CheckScale() end end)
ns.On("UI_SCALE_CHANGED", function() C_Timer.After(1, ns.Guard("hints", Hints.CheckScale)) end)
ns.On("PLAYER_LEVEL_UP", function() C_Timer.After(1, ns.Guard("hints", Hints.Check)) end)
