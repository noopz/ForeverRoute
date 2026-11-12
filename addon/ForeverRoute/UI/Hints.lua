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
  return true
end

ns.On("FR_LOADED", function() C_Timer.After(6, ns.Guard("hints", Hints.Check)) end)
ns.On("FR_TAXI_OPENED", function() Hints.Check() end)
ns.On("PLAYER_LEVEL_UP", function() C_Timer.After(1, ns.Guard("hints", Hints.Check)) end)
