-- Shared look: palette, fonts, panel/backdrop builder, small widgets.
local _, ns = ...
local Style = {}
ns.Style = Style

local MEDIA = "Interface\\AddOns\\ForeverRoute\\Media\\"
Style.MEDIA = MEDIA
Style.WHITE = MEDIA .. "white"

Style.C = {
  bg = { 0.025, 0.028, 0.036, 0.94 },
  bg2 = { 0.035, 0.038, 0.05, 0.96 },
  edge = { 1, 1, 1, 0.07 },
  gold = { 1.0, 0.82, 0.36 },
  text = { 0.95, 0.95, 0.97 },
  sub = { 0.62, 0.66, 0.74 },
  dim = { 0.42, 0.45, 0.52 },
  good = { 0.36, 0.86, 0.48 },
  warn = { 1.0, 0.55, 0.30 },
  bad = { 1.0, 0.36, 0.36 },
}
-- per step kind: icon + accent colour + verb
Style.KIND = {
  accept = { icon = "icon-accept", color = { 1.0, 0.82, 0.36 }, verb = "Accept" },
  turnin = { icon = "icon-turnin", color = { 0.45, 0.78, 1.0 }, verb = "Turn in" },
  obj = { icon = "icon-kill", color = { 1.0, 0.47, 0.42 }, verb = "" },
  loot = { icon = "icon-loot", color = { 0.82, 0.64, 1.0 }, verb = "" },
  ["goto"] = { icon = "icon-goto", color = { 0.9, 0.92, 0.96 }, verb = "Go to" },
  fly = { icon = "icon-fly", color = { 0.5, 0.9, 1.0 }, verb = "Fly to" },
  -- a boat crossing is a travel step too (k = "fly" with boat set), but it must never read "Fly to" or show wings
  boat = { icon = "icon-goto", color = { 0.45, 0.78, 1.0 }, verb = "Boat to" },
  -- a travel step's live trip (from the flight paths you know) can be a ride, or several kinds of leg
  ride = { icon = "icon-goto", color = { 0.5, 0.9, 1.0 }, verb = "Ride to" },
  travel = { icon = "icon-goto", color = { 0.5, 0.9, 1.0 }, verb = "Travel to" },
  fp = { icon = "icon-fly", color = { 0.5, 0.9, 1.0 }, verb = "Get the flight path" },
  hearth = { icon = "icon-hearth", color = { 1.0, 0.62, 0.3 }, verb = "Hearth to" },
  bind = { icon = "icon-hearth", color = { 1.0, 0.62, 0.3 }, verb = "Set your hearthstone" },
  train = { icon = "icon-train", color = { 0.58, 1.0, 0.62 }, verb = "Train" },
  grind = { icon = "icon-grind", color = { 1.0, 0.47, 0.42 }, verb = "Grind" },
  note = { icon = "icon-note", color = { 0.8, 0.84, 0.92 }, verb = "" },
  bonus = { icon = "icon-loot", color = { 0.98, 0.62, 0.95 }, verb = "Bonus:" },
}
function Style.Kind(step)
  local k = step.k
  if k == "obj" and step.loot then k = "loot" end
  if k == "fly" and step.boat then k = "boat" end
  return Style.KIND[k] or Style.KIND.note
end

local fontPath = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local fonts = {}
function Style.Font(size, flags)
  local key = size .. (flags or "")
  if not fonts[key] then
    local f = CreateFont("ForeverRouteFont" .. key:gsub("%W", ""))
    f:SetFont(fontPath, size, flags or "")
    f:SetShadowOffset(1, -1); f:SetShadowColor(0, 0, 0, 0.8)
    fonts[key] = f
  end
  return fonts[key]
end
function Style.Text(parent, size, color, flags, layer)
  local fs = parent:CreateFontString(nil, layer or "OVERLAY")
  fs:SetFontObject(Style.Font(size, flags))
  local c = color or Style.C.text
  fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
  fs:SetJustifyH("LEFT"); fs:SetJustifyV("TOP")
  fs:SetWordWrap(true)
  return fs
end

-- 9-slice from a 64px rounded-rect texture: corners keep their curve at any size
function Style.Nine(frame, tex, layer, sub, corner, inset, r, g, b, a)
  local parts = {}
  local c, t = corner or 12, 0.25
  local spec = {
    { "TOPLEFT", 0, t, 0, t }, { "TOP", t, 1 - t, 0, t }, { "TOPRIGHT", 1 - t, 1, 0, t },
    { "LEFT", 0, t, t, 1 - t }, { "CENTER", t, 1 - t, t, 1 - t }, { "RIGHT", 1 - t, 1, t, 1 - t },
    { "BOTTOMLEFT", 0, t, 1 - t, 1 }, { "BOTTOM", t, 1 - t, 1 - t, 1 }, { "BOTTOMRIGHT", 1 - t, 1, 1 - t, 1 },
  }
  local i = inset or 0
  for k, sp in ipairs(spec) do
    local x = frame:CreateTexture(nil, layer, nil, sub)
    x:SetTexture(Style.MEDIA .. tex); x:SetTexCoord(sp[2], sp[3], sp[4], sp[5]); x:SetVertexColor(r, g, b, a)
    parts[k] = x
  end
  local TL, T, TR, L, C, R, BL, B, BR = unpack(parts)
  TL:SetSize(c, c); TL:SetPoint("TOPLEFT", -i, i)
  TR:SetSize(c, c); TR:SetPoint("TOPRIGHT", i, i)
  BL:SetSize(c, c); BL:SetPoint("BOTTOMLEFT", -i, -i)
  BR:SetSize(c, c); BR:SetPoint("BOTTOMRIGHT", i, -i)
  T:SetPoint("TOPLEFT", TL, "TOPRIGHT"); T:SetPoint("BOTTOMRIGHT", TR, "BOTTOMLEFT")
  B:SetPoint("TOPLEFT", BL, "TOPRIGHT"); B:SetPoint("BOTTOMRIGHT", BR, "BOTTOMLEFT")
  L:SetPoint("TOPLEFT", TL, "BOTTOMLEFT"); L:SetPoint("BOTTOMRIGHT", BL, "TOPRIGHT")
  R:SetPoint("TOPLEFT", TR, "BOTTOMLEFT"); R:SetPoint("BOTTOMRIGHT", BR, "TOPRIGHT")
  C:SetPoint("TOPLEFT", TL, "BOTTOMRIGHT"); C:SetPoint("BOTTOMRIGHT", BR, "TOPLEFT")
  return parts
end

-- rounded panel: soft shadow, fill, hairline edge, faint top sheen
function Style.Panel(frame, fill)
  local c = fill or Style.C.bg
  Style.Nine(frame, "shadow", "BACKGROUND", -8, 22, 12, 0, 0, 0, 0.6)
  frame.fill = Style.Nine(frame, "panel", "BACKGROUND", -7, 12, 0, c[1], c[2], c[3], c[4])
  Style.Nine(frame, "panel-edge", "BORDER", 0, 12, 0, 1, 1, 1, 0.09)
  -- header band: a slightly lighter strip behind the title row
  local band = frame:CreateTexture(nil, "BACKGROUND", nil, -6)
  band:SetTexture(Style.WHITE); band:SetPoint("TOPLEFT", 4, -4); band:SetPoint("TOPRIGHT", -4, -4); band:SetHeight(26)
  band:SetVertexColor(1, 1, 1, 0.025)
end

-- square icon button (tinted glyph, hover glow, tooltip)
function Style.IconButton(parent, glyph, size, onClick, tip)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(size, size)
  b.bg = b:CreateTexture(nil, "BACKGROUND"); b.bg:SetTexture(Style.MEDIA .. "disc"); b.bg:SetAllPoints(); b.bg:SetVertexColor(1, 1, 1, 0.06)
  b.icon = b:CreateTexture(nil, "ARTWORK"); b.icon:SetTexture(Style.MEDIA .. glyph); b.icon:SetPoint("CENTER"); b.icon:SetSize(size * 0.55, size * 0.55)
  local c = Style.C.sub; b.icon:SetVertexColor(c[1], c[2], c[3])
  b:SetScript("OnClick", onClick)
  b:SetScript("OnEnter", function(self)
    self.bg:SetVertexColor(1, 0.82, 0.36, 0.22); self.icon:SetVertexColor(1, 0.9, 0.6)
    if tip then GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText(tip, 1, 1, 1, 1, true); GameTooltip:Show() end
    if parent.OnChildEnter then parent:OnChildEnter() end
  end)
  b:SetScript("OnLeave", function(self) self.bg:SetVertexColor(1, 1, 1, 0.06); local c2 = Style.C.sub; self.icon:SetVertexColor(c2[1], c2[2], c2[3]); GameTooltip:Hide() end)
  return b
end

-- small flat button with hover highlight
function Style.Button(parent, label, w, h, onClick, tip)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(w, h)
  local bg = b:CreateTexture(nil, "BACKGROUND"); bg:SetTexture(Style.WHITE); bg:SetAllPoints(); bg:SetVertexColor(1, 1, 1, 0.05)
  local hl = b:CreateTexture(nil, "HIGHLIGHT"); hl:SetTexture(Style.WHITE); hl:SetAllPoints(); hl:SetVertexColor(1, 0.82, 0.36, 0.14)
  b.label = Style.Text(b, 11, Style.C.sub); b.label:SetPoint("CENTER"); b.label:SetJustifyH("CENTER"); b.label:SetText(label)
  b:SetScript("OnClick", onClick)
  b:SetScript("OnEnter", function(self) self.label:SetTextColor(1, 0.86, 0.5); if tip then GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText(tip, 1, 1, 1, 1, true); GameTooltip:Show() end end)
  b:SetScript("OnLeave", function(self) local c = Style.C.sub; self.label:SetTextColor(c[1], c[2], c[3]); GameTooltip:Hide() end)
  return b
end

-- progress bar with label
function Style.Bar(parent, h)
  local f = CreateFrame("Frame", nil, parent); f:SetHeight(18)
  f.label = Style.Text(f, 10, Style.C.text); f.label:SetPoint("TOPLEFT"); f.label:SetWordWrap(false); f.label:SetPoint("RIGHT", -48, 0)
  f.value = Style.Text(f, 10, Style.C.sub); f.value:SetPoint("TOPRIGHT"); f.value:SetJustifyH("RIGHT")
  local track = CreateFrame("Frame", nil, f); track:SetPoint("BOTTOMLEFT"); track:SetPoint("BOTTOMRIGHT"); track:SetHeight(4)
  local bg = track:CreateTexture(nil, "BACKGROUND"); bg:SetTexture(Style.WHITE); bg:SetAllPoints(); bg:SetVertexColor(1, 1, 1, 0.07)
  local fill = track:CreateTexture(nil, "ARTWORK"); fill:SetTexture(Style.WHITE); fill:SetPoint("TOPLEFT"); fill:SetPoint("BOTTOMLEFT")
  fill:SetWidth(0.001); fill:Hide() -- empty until there is progress (a texture with no width would draw a default sliver)
  f.fill, f.track = fill, track
  function f:Set(p, color, label, value)
    p = math.max(0, math.min(1, p or 0))
    self.target = p
    if p <= 0 and (self.cur or 0) <= 0.004 then self.fill:Hide() end
    local done = p >= 1
    local c = done and Style.C.good or color
    self.fill:SetVertexColor(c[1], c[2], c[3], 0.95)
    self.label:SetText(label or ""); self.value:SetText(done and "|cff5cdc7adone|r" or (value or ""))
    self.label:SetTextColor(done and 0.6 or 0.92, done and 0.65 or 0.93, done and 0.7 or 0.96)
  end
  f:SetScript("OnUpdate", function(self, el)
    local w = self.track:GetWidth(); if w <= 0 then return end
    self.cur = self.cur or 0
    local t = self.target or 0
    if math.abs(t - self.cur) < 0.001 then return end
    self.cur = self.cur + (t - self.cur) * math.min(1, el * 8)
    self.fill:SetWidth(math.max(0.001, w * self.cur))
    self.fill:SetShown(self.cur > 0.004)
  end)
  return f
end

-- quest difficulty colour (like the quest log)
function Style.QuestColor(level)
  if not level then return Style.C.text end
  local d = level - UnitLevel("player")
  if d >= 5 then return { 1, 0.25, 0.2 } elseif d >= 3 then return { 1, 0.5, 0.25 } elseif d >= -2 then return { 1, 0.85, 0.2 }
  elseif d >= -(GetQuestGreenRange and GetQuestGreenRange() or 8) then return { 0.3, 0.85, 0.35 } else return { 0.6, 0.6, 0.6 } end
end
function Style.Hex(c) return string.format("|cff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255) end

function Style.Distance(yards)
  if not yards then return "" end
  if yards < 1000 then return string.format("%d yd", yards) end
  return string.format("%.1fk yd", yards / 1000)
end
function Style.Duration(sec)
  if not sec then return "" end
  if sec < 60 then return string.format("%ds", sec) end
  return string.format("%dm %02ds", sec / 60, sec % 60)
end

-- short zone names for tight spots
local SHORT = { ["Redridge Mountains"] = "Redridge", ["Stonetalon Mountains"] = "Stonetalon", ["Hillsbrad Foothills"] = "Hillsbrad", ["Stranglethorn Vale"] = "Stranglethorn",
  ["Thousand Needles"] = "Thousand Needles", ["Arathi Highlands"] = "Arathi", ["Swamp of Sorrows"] = "Swamp of Sorrows", ["Alterac Mountains"] = "Alterac", ["Dustwallow Marsh"] = "Dustwallow" }
function Style.ShortZone(z) return SHORT[z] or z end
-- a steady colour per zone, so the same zone looks the same everywhere
local ZONE_COLORS = {
  { 0.45, 0.78, 1.0 }, { 0.58, 1.0, 0.62 }, { 1.0, 0.70, 0.40 }, { 0.82, 0.64, 1.0 }, { 1.0, 0.55, 0.62 },
  { 0.45, 0.92, 0.85 }, { 1.0, 0.86, 0.45 }, { 0.70, 0.80, 1.0 }, { 0.95, 0.62, 0.95 }, { 0.75, 0.92, 0.50 },
}
function Style.ZoneColor(z)
  local h = 0
  for i = 1, #(z or "") do h = (h * 31 + z:byte(i)) % 9973 end
  return ZONE_COLORS[h % #ZONE_COLORS + 1]
end
-- small rounded label ("FASTEST", "CURRENT")
function Style.Pill(parent, text, color)
  local p = CreateFrame("Frame", nil, parent)
  p.bg = Style.Nine(p, "panel", "BACKGROUND", 0, 6, 0, color[1], color[2], color[3], 0.18)
  p.text = Style.Text(p, 9, color, "OUTLINE"); p.text:SetPoint("CENTER", 0, 0); p.text:SetJustifyH("CENTER"); p.text:SetWordWrap(false)
  function p:Set(t, c)
    c = c or color
    self.text:SetText(t); self.text:SetTextColor(c[1], c[2], c[3])
    for _, part in ipairs(self.bg or {}) do part:SetVertexColor(c[1], c[2], c[3], 0.18) end
    self:SetSize(self.text:GetStringWidth() + 12, 15)
  end
  p:Set(text, color)
  return p
end
-- zone chips flowing left to right with ">" between, wrapping at width; returns the height used
function Style.Chips(holder, zones, width)
  holder.chips = holder.chips or {}
  for _, c in ipairs(holder.chips) do c:Hide(); c.sep:Hide() end
  local x, y, lineH, gap = 0, 0, 18, 4
  for i, z in ipairs(zones) do
    local c = holder.chips[i]
    if not c then
      c = CreateFrame("Frame", nil, holder)
      c.bg = Style.Nine(c, "panel", "BACKGROUND", 0, 6, 0, 1, 1, 1, 0.08)
      c.text = Style.Text(c, 10, Style.C.text); c.text:SetPoint("CENTER", 0, 0); c.text:SetWordWrap(false)
      c.sep = Style.Text(holder, 10, Style.C.dim); c.sep:SetText(">")
      holder.chips[i] = c
    end
    local col = Style.ZoneColor(z)
    c.text:SetText(Style.ShortZone(z)); c.text:SetTextColor(col[1], col[2], col[3])
    for _, part in ipairs(c.bg or {}) do part:SetVertexColor(col[1], col[2], col[3], 0.13) end
    local w = c.text:GetStringWidth() + 12
    c:SetSize(w, 16)
    local sepW = i > 1 and 12 or 0
    if x > 0 and x + sepW + w > width then x = 0; y = y + lineH + 2; sepW = 0 end
    if sepW > 0 then c.sep:ClearAllPoints(); c.sep:SetPoint("TOPLEFT", holder, "TOPLEFT", x + 2, -y - 2); c.sep:Show() end
    x = x + sepW
    c:ClearAllPoints(); c:SetPoint("TOPLEFT", holder, "TOPLEFT", x, -y); c:Show()
    x = x + w + gap
  end
  return y + lineH
end
