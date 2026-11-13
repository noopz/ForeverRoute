-- The zones ahead, beside the card: a small pop-out list - "Alterac Mountains · 2 quests", "Hillsbrad Foothills · 6
-- quests", ... - from where you are on the route (Engine.ZonesAhead). Lighter than the route list: where you're
-- headed and how much there is in each. A tab on the card's edge opens and closes it (ns.db.zonesPanel); it sits on
-- whichever side of the card has room. Hover a row for its quests; click it to look at its first step.
local _, ns = ...

local Zones = {}
ns.Zones = Zones
local Style = ns.Style
local C = Style.C
local ROWS, W = 8, 190
local f, tab

local function card() return _G.ForeverRouteCard end

local function side()
  local c = card(); if not c then return "RIGHT" end
  local right = (c:GetRight() or 0) * c:GetEffectiveScale() / UIParent:GetEffectiveScale()
  return (right + W + 10 > UIParent:GetWidth()) and "LEFT" or "RIGHT"
end

local function place()
  local c = card(); if not (c and f) then return end
  f:ClearAllPoints(); tab:ClearAllPoints()
  if side() == "RIGHT" then
    tab:SetPoint("TOPLEFT", c, "TOPRIGHT", -2, -48); f:SetPoint("TOPLEFT", c, "TOPRIGHT", 12, 0); tab.label:SetText(f:IsShown() and "<" or ">")
  else
    tab:SetPoint("TOPRIGHT", c, "TOPLEFT", 2, -48); f:SetPoint("TOPRIGHT", c, "TOPLEFT", -12, 0); tab.label:SetText(f:IsShown() and ">" or "<")
  end
end

local function build()
  local c = card(); if not c then return end
  f = CreateFrame("Frame", "ForeverRouteZones", c)
  f:SetWidth(W); f:SetFrameStrata(c:GetFrameStrata())
  Style.Panel(f)
  f.title = Style.Text(f, 10, C.gold, "OUTLINE"); f.title:SetPoint("TOPLEFT", 12, -11); f.title:SetText("ZONES AHEAD")
  f.rows = {}
  for n = 1, ROWS do
    local r = CreateFrame("Button", nil, f); r:SetHeight(30)
    r:SetPoint("TOPLEFT", 8, -30 - (n - 1) * 31); r:SetPoint("RIGHT", f, "RIGHT", -8, 0)
    r.zone = Style.Text(r, 11, C.text); r.zone:SetPoint("TOPLEFT", 4, -2); r.zone:SetPoint("RIGHT", -4, 0); r.zone:SetWordWrap(false)
    r.what = Style.Text(r, 10, C.sub); r.what:SetPoint("TOPLEFT", r.zone, "BOTTOMLEFT", 0, -2); r.what:SetPoint("RIGHT", -4, 0); r.what:SetWordWrap(false)
    local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetTexture(Style.WHITE); hl:SetAllPoints(); hl:SetVertexColor(1, 1, 1, 0.05)
    r:SetScript("OnEnter", function(self)
      if not self.z then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(self.z.zone, 1, 1, 1)
      for _, q in ipairs(self.z.names) do GameTooltip:AddLine(q, 0.75, 0.8, 0.88) end
      GameTooltip:AddLine("Click to look at its first step", 0.5, 0.55, 0.62); GameTooltip:Show()
    end)
    r:SetScript("OnLeave", GameTooltip_Hide)
    r:SetScript("OnClick", function(self) if self.z then ns.Engine.view = (self.z.first ~= ns.Engine.current) and self.z.first or nil; ns.Fire("FR_STEP", ns.Engine.Shown()) end end)
    f.rows[n] = r
  end
  tab = CreateFrame("Button", nil, c); tab:SetSize(14, 40)
  Style.Nine(tab, "panel", "BACKGROUND", 0, 6, 0, 0.1, 0.11, 0.14, 0.95)
  tab.label = Style.Text(tab, 11, C.gold); tab.label:SetPoint("CENTER")
  tab:SetScript("OnClick", function() ns.db.zonesPanel = not ns.db.zonesPanel; Zones.Update() end)
  tab:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText("Zones ahead", 1, 1, 1); GameTooltip:AddLine("Where the route goes next and how many quests in each", 0.6, 0.65, 0.72, true); GameTooltip:Show() end)
  tab:SetScript("OnLeave", GameTooltip_Hide)
  c:HookScript("OnDragStop", function() Zones.Update() end)
end

function Zones.Update()
  local c = card()
  if not c then return end
  if not f then build() end
  if not f then return end
  local onRoute = ForeverRouteData and ForeverRouteData.steps and not ForeverRouteData.dungeon and not ns.db.collapsed
  tab:SetShown(onRoute and true or false)
  local list = onRoute and ns.db.zonesPanel and ns.Engine.ZonesAhead and ns.Engine.ZonesAhead(nil, ROWS) or {}
  f:SetShown(#list > 0)
  for n, r in ipairs(f.rows) do
    local z = list[n]
    r.z = z
    r:SetShown(z and true or false)
    if z then
      r.zone:SetText((n == 1 and "|cffffd25a" or "") .. z.zone .. (n == 1 and "|r" or ""))
      r.what:SetText(z.quests > 0 and string.format("%d quest%s", z.quests, z.quests == 1 and "" or "s") or "grinding")
    end
  end
  f:SetHeight(36 + #list * 31)
  place()
end

ns.On("FR_STEP", function() Zones.Update() end)
ns.On("FR_STATE", function() Zones.Update() end)
ns.On("FR_ROUTE_CHANGED", function() Zones.Update() end)
