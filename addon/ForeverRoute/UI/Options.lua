-- Options: a small canvas page under Options > AddOns (our own frames, nothing inserted into Blizzard's
-- settings layouts, so no taint), plus the same panel standalone from /fr options.
local _, ns = ...
local Style = ns.Style
local C = Style.C
local panel

local function check(parent, label, key, y, tip)
  local b = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  b:SetPoint("TOPLEFT", 16, y); b:SetSize(24, 24)
  local t = Style.Text(parent, 12, C.text); t:SetPoint("LEFT", b, "RIGHT", 4, 0); t:SetText(label); t:SetJustifyV("MIDDLE"); t:SetWidth(370); t:SetJustifyH("LEFT")
  b:SetScript("OnShow", function(self) self:SetChecked(ns.db[key]) end)
  b:SetScript("OnClick", function(self) ns.db[key] = self:GetChecked() and true or false; ns.Fire("FR_SETTINGS") end)
  if tip then b:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(tip, 1, 1, 1, 1, true); GameTooltip:Show() end); b:SetScript("OnLeave", GameTooltip_Hide) end
  return b
end
local function slider(parent, label, key, lo, hi, step, y, fmt, default)
  local s = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
  s:SetPoint("TOPLEFT", 20, y); s:SetWidth(240); s:SetMinMaxValues(lo, hi); s:SetValueStep(step); s:SetObeyStepOnDrag(true)
  local t = Style.Text(parent, 11, C.sub); t:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 0, 4)
  local function upd(v) t:SetText(label .. ":  " .. string.format(fmt or "%.2f", v)) end
  s:SetScript("OnShow", function(self) self.loading = true; self:SetValue(ns.db[key] or default); upd(ns.db[key] or default); self.loading = false end)
  -- the Forever Route scale also sizes this window: applied while you drag, the slider grew or shrank under the
  -- cursor and ran off to its end. That one takes effect when you let go (the number follows as you drag)
  local onRelease = key == "uiScale"
  s:SetScript("OnValueChanged", function(self, v)
    upd(v)
    if self.loading or (ns.db[key] or default) == v then return end
    if onRelease and self.dragging then self.pending = v; return end
    ns.db[key] = v; ns.Fire("FR_SETTINGS")
  end)
  if onRelease then
    s:HookScript("OnMouseDown", function(self) self.dragging = true end)
    s:HookScript("OnMouseUp", function(self)
      self.dragging = false
      local v = self.pending; self.pending = nil
      if v and (ns.db[key] or default) ~= v then ns.db[key] = v; ns.Fire("FR_SETTINGS") end
    end)
  end
  for _, r in ipairs({ s:GetRegions() }) do if r.GetText and (r:GetText() == "Low" or r:GetText() == "High") then r:SetText("") end end
  if s.Low then s.Low:SetText(""); s.High:SetText("") end
  return s
end

local function build()
  panel = CreateFrame("Frame", "ForeverRouteOptions", UIParent)
  panel:SetSize(420, 672)
  panel.name = "Forever Route"
  panel:Hide()
  local title = Style.Text(panel, 16, C.gold, "OUTLINE"); title:SetPoint("TOPLEFT", 16, -16); title:SetText("Forever Route")
  local sub = Style.Text(panel, 11, C.sub); sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6); sub:SetWidth(380)
  sub:SetText("Your planner-made route, tracked live from your quest log. /fr toggles the card, /fr list shows the whole route.")
  check(panel, "Show the waypoint arrow", "arrow", -70)
  check(panel, "Show route pins on the world map and minimap", "pins", -96)
  check(panel, "Lock the card and arrow in place", "locked", -122)
  check(panel, "Highlight the best quest reward for you", "rewardHint", -148)
  check(panel, "Fade the card while in combat", "combatFade", -174)
  check(panel, "Show the walking path on the maps", "pathLine", -200)
  check(panel, "Record where I walk (improves the planner's walking paths)", "trails", -226)
  check(panel, "Targeting the step's NPC also marks it with a star", "markTarget", -252)
  check(panel, "Accept and hand in quests automatically", "autoQuest", -278, "Accepts the quests your route picks up and hands in finished ones. Never when there's a reward to choose. Hold Shift while talking to an NPC to do it yourself.")
  -- one scale for everything of ours (card, arrow, route list, every window), on top of the game's UI scale; the
  -- card and the arrow keep their own as a fine adjustment. The line under it says what it comes to on this screen
  local all = slider(panel, "Forever Route scale (everything)", "uiScale", Style.SCALE_MIN, Style.SCALE_MAX, 0.05, -324, nil, 1)
  local px = Style.Text(panel, 10, C.sub); px:SetPoint("LEFT", all, "RIGHT", 12, 0); px:SetWidth(130); px:SetJustifyV("MIDDLE")
  local function pxText()
    local sug = Style.SuggestScale()
    px:SetText(string.format("text: about %d px tall%s", math.floor(11 * Style.PxPerUnit() * Style.UIScale() + 0.5), sug and string.format("\nsuggested here: %.2f", sug) or ""))
  end
  all:HookScript("OnShow", pxText); ns.On("FR_SETTINGS", pxText)
  panel.scaleSlider, panel.scaleNote = all, px
  slider(panel, "Card scale", "scale", 0.7, 2.0, 0.05, -366)
  slider(panel, "Card width", "cardWidth", 280, 520, 10, -408, "%d")
  slider(panel, "Arrow scale", "arrowScale", 0.6, 2.5, 0.05, -450)
  slider(panel, "Upcoming steps shown", "showNext", 0, 5, 1, -492, "%d")
  slider(panel, "Steps pinned on the maps", "pinCount", 1, 8, 1, -534, "%d")
  local reset = Style.Button(panel, "Clear all skips / ticks", 160, 20, function() ns.char.skipped, ns.char.manualDone, ns.char.history = {}, {}, {}; ns.Engine.Refresh() end)
  reset:SetPoint("TOPLEFT", 16, -572)
  local hint = Style.Text(panel, 10, C.dim); hint:SetPoint("TOPLEFT", 16, -604); hint:SetWidth(390)
  hint:SetText("Keys: Options > Keybindings, under AddOns: Forever Route Targeting (targets and marks the step's NPC), Skip, Back, Undo, Show / hide the card, Show the whole route.")
  -- the attribution the license asks every copy and adaptation to keep (NOTICE)
  local credit = Style.Text(panel, 10, C.sub); credit:SetPoint("TOPLEFT", 16, -638); credit:SetWidth(390)
  credit:SetText("Forever Route by noopz  ·  github.com/noopz/ForeverRoute  ·  CC BY-NC-SA 4.0, not for sale")
  if Settings and Settings.RegisterCanvasLayoutCategory then
    local cat = Settings.RegisterCanvasLayoutCategory(panel, "Forever Route")
    Settings.RegisterAddOnCategory(cat)
    panel.categoryID = cat:GetID()
  elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
  end
end

ns.On("FR_LOADED", build)
-- /fr options and the gear button: show the panel in our own window. Opening Blizzard's Settings to an addon page
-- from code isn't reliable on Forever, and this works the same everywhere. (The Settings page still exists.)
local host
local function openStandalone()
  if not host then
    host = CreateFrame("Frame", "ForeverRouteOptionsWindow", UIParent)
    host:SetSize(440, 690) -- the panel is 672 tall: at 620 the credit line fell below the window
    host:SetPoint("CENTER"); host:SetFrameStrata("DIALOG")
    host:SetClampedToScreen(true); host:SetMovable(true); host:EnableMouse(true); host:RegisterForDrag("LeftButton")
    host:SetScript("OnDragStart", host.StartMoving); host:SetScript("OnDragStop", host.StopMovingOrSizing)
    Style.Panel(host, C.bg2); Style.Scaled(host, nil, true)
    table.insert(UISpecialFrames, "ForeverRouteOptionsWindow") -- Escape closes it
    local close = Style.Button(host, "x", 18, 18, function() host:Hide() end, "Close"); close:SetPoint("TOPRIGHT", -8, -8)
    close:SetFrameLevel(host:GetFrameLevel() + 10)
    host:SetScript("OnHide", function() if panel:GetParent() == host then panel:Hide() end end)
  end
  panel:SetParent(host); panel:ClearAllPoints(); panel:SetPoint("TOPLEFT", host, "TOPLEFT", 4, -4)
  panel:SetFrameLevel(host:GetFrameLevel() + 2)
  host:Show(); panel:Show()
end
ns.Options = { Open = openStandalone }
ns.On("FR_OPEN_OPTIONS", function()
  if host and host:IsShown() then host:Hide() else openStandalone() end
end)
