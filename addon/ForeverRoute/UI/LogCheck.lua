-- "Quest log check": which quests in your log are worth keeping. Each one is checked against your routes:
--   not on any route (you'll never be sent there)          -> suggest abandoning
--   on the route, but gray by the time you get there         -> suggest abandoning
--   finished, but not on the route                           -> hand it in if you pass by
--   on the route                                             -> keep (and when it comes up)
-- Nothing is abandoned unless you click Abandon and confirm. Opened from the route list or /fr logcheck.
local _, ns = ...
local Style = ns.Style
local C = Style.C
local LogCheck = {}
ns.LogCheck = LogCheck

local f, recount
local W, PAD, ROW = 470, 14, 34
local rows = {}

local function call(fn, ...) if type(fn) == "function" then local ok, a = pcall(fn, ...); if ok then return a end end end
local function greenRange() return (GetQuestGreenRange and call(GetQuestGreenRange)) or 8 end
local function grayAt(qLevel, myLevel) return qLevel and myLevel and (myLevel - qLevel) > greenRange() end

-- your quest log: id, title, level, zone header
function LogCheck.Entries()
  local out, zone = {}, nil
  local n = C_QuestLog and C_QuestLog.GetNumQuestLogEntries and call(C_QuestLog.GetNumQuestLogEntries) or 0
  for i = 1, n do
    local info = C_QuestLog.GetInfo and call(C_QuestLog.GetInfo, i)
    if info then
      if info.isHeader then zone = info.title
      elseif info.questID and info.questID > 0 then out[#out + 1] = { id = info.questID, title = info.title or ("quest " .. info.questID), level = info.level, zone = zone } end
    end
  end
  return out
end

-- where a quest comes up in a route: the first step for it, and the planned level there
local function findIn(route, id)
  if not route then return nil end
  local steps = route.steps or {}
  for i, s in ipairs(steps) do
    if s.q == id then
      -- the planned level there (steps the safety net added have none: use the nearest step that has one)
      for j = i, math.min(#steps, i + 30) do if steps[j].lvl then return i, steps[j].lvl end end
      for j = i - 1, math.max(1, i - 30), -1 do if steps[j].lvl then return i, steps[j].lvl end end
      return i, nil
    end
  end
end

-- quests that aren't about leveling but pay off later: never suggested for dropping
local KEEP_HEADERS = { ["Camping"] = "Camping - benefits later", ["Class"] = "class quest", ["First Aid"] = "profession", ["Cooking"] = "profession", ["Fishing"] = "profession",
  ["Alchemy"] = "profession", ["Blacksmithing"] = "profession", ["Enchanting"] = "profession", ["Engineering"] = "profession", ["Herbalism"] = "profession", ["Leatherworking"] = "profession",
  ["Mining"] = "profession", ["Skinning"] = "profession", ["Tailoring"] = "profession", ["Seasonal"] = "seasonal", ["Warlock"] = "class quest", ["Reputation"] = "reputation" }
local function keepReason(e)
  if ns.char.keepQuests and ns.char.keepQuests[e.id] then return "you chose to keep this" end
  if e.zone and KEEP_HEADERS[e.zone] then return KEEP_HEADERS[e.zone] end
  if e.title and e.title:find("^Camping") then return "Camping - benefits later" end
end
function LogCheck.Classify()
  local here = ForeverRouteData
  -- on a side trip or branch, quests are also judged against your path (found by zone order if a replan renamed it)
  local path = here and (here.branch or here.dungeon) and ns.ResolvePath(here.dungeon and ns.char.returnTo or here.parent) or here
  local myLevel = UnitLevel("player")
  local list = {}
  for _, e in ipairs(LogCheck.Entries()) do
    local q = ns.State.Quest(e.id)
    local done = q and q.complete
    local i, planLvl = findIn(here, e.id)
    local where = here
    if not i and path ~= here then i, planLvl = findIn(path, e.id); where = path end
    local inDungeon = false
    if not i then for _, r in ipairs(ns.DungeonRoutes()) do if ns.QuestIds(r)[e.id] then inDungeon = r.dungeonName; break end end end
    local verdict, why
    local keep = keepReason(e)
    if ns.char.nope and ns.char.nope[e.id] then
      verdict, why = "drop", "You said you're not doing this one"
    elseif keep then
      verdict, why = "keep", "Worth keeping: " .. keep
    elseif i then
      local st -- this quest's hand-in step on the route (the first step found may be its accept)
      for _, s in ipairs((where and where.steps) or {}) do if s.q == e.id and s.k == "turnin" then st = s; break end end
      if done and ns.Engine.GrayHandIn and ns.Engine.GrayHandIn(st) then
        -- the route passes this hand-in (finished, far below you, opens nothing): the card won't send you there
        verdict, why = "drop", "Gray and nothing follows it - your route skips this hand-in (not worth a trip)"
      elseif not done and planLvl and grayAt(e.level, planLvl) then
        verdict, why = "drop", string.format("Gray by the time the route gets to it (you'll be about %s) - very little XP", planLvl)
      else
        verdict, why = "keep", string.format("On your route at step %d%s", i, where ~= here and " of your path" or "")
      end
    elseif inDungeon then
      verdict, why = "keep", "For " .. inDungeon .. " (dungeon route)"
    elseif done and grayAt(e.level, myLevel) then
      verdict, why = "drop", "Gray and not on your route - not worth a trip (hand it in only if you pass by)"
    elseif done then
      verdict, why = "turnin", "Finished but not on your route - hand it in if you pass by"
    elseif grayAt(e.level, myLevel) then
      verdict, why = "drop", "Gray already and not on your route"
    else
      verdict, why = "drop", "Not on any of your routes - you won't be sent there"
    end
    list[#list + 1] = { e = e, verdict = verdict, why = why }
  end
  local order = { drop = 1, turnin = 2, keep = 3 }
  table.sort(list, function(a, b) if order[a.verdict] ~= order[b.verdict] then return order[a.verdict] < order[b.verdict] end return (a.e.zone or "") < (b.e.zone or "") end)
  return list
end

-- only quests this check marks to drop get an Abandon button, so an abandon here also drops the quest from the route
-- (otherwise the card would send you straight back to its quest giver until the next replan)
local function abandon(id, title, why)
  if InCombatLockdown() then ns.Print("Not in combat."); return end
  if C_QuestLog and C_QuestLog.SetSelectedQuest and C_QuestLog.SetAbandonQuest and C_QuestLog.AbandonQuest then
    C_QuestLog.SetSelectedQuest(id); C_QuestLog.SetAbandonQuest(); C_QuestLog.AbandonQuest()
  elseif SelectQuestLogEntry and SetAbandonQuest and AbandonQuest then
    local idx = C_QuestLog and C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(id)
    if not idx then return end
    SelectQuestLogEntry(idx); SetAbandonQuest(); AbandonQuest()
  end
  if ns.Engine and ns.Engine.Abandoned then ns.Engine.Abandoned({ id }, why) end
  ns.Print("Abandoned " .. (title or "quest") .. ". Dropped from your route too (Undo brings it back).")
end
LogCheck.Abandon = abandon
StaticPopupDialogs["FOREVERROUTE_ABANDON"] = {
  text = "Abandon %s?", button1 = YES or "Yes", button2 = NO or "No", timeout = 0, whileDead = true, hideOnEscape = true,
  OnAccept = function(self, data) abandon(data.id, data.title, data.why); C_Timer.After(0.5, function() LogCheck.Draw() end) end,
}

-- how many quests are worth dropping (the card shows a button when there are any)
LogCheck.dropCount = 0
recount = function()
  local ok, list = pcall(LogCheck.Classify)
  local n = 0; if ok then for _, x in ipairs(list) do if x.verdict == "drop" then n = n + 1 end end end
  if n ~= LogCheck.dropCount then LogCheck.dropCount = n; ns.Fire("FR_STEP", ns.Engine.Shown()) end
end
ns.On("FR_STATE", function() C_Timer.After(0.3, recount) end)
ns.On("FR_ROUTE_CHANGED", function() C_Timer.After(0.3, recount) end)
ns.On("PLAYER_LEVEL_UP", function() C_Timer.After(1, recount) end)

-- drop several: one confirm listing them, then one at a time (the game abandons the selected quest)
local function dropAll(list)
  local k = 0
  local function nextOne() k = k + 1; local e = list[k]; if not e then C_Timer.After(0.5, function() recount(); LogCheck.Draw() end) return end abandon(e.id, e.title, e.why); C_Timer.After(0.4, nextOne) end
  nextOne()
end
StaticPopupDialogs["FOREVERROUTE_DROPALL"] = {
  text = "Drop these %d quests?%s", button1 = YES or "Yes", button2 = NO or "No", timeout = 0, whileDead = true, hideOnEscape = true,
  OnAccept = function(self, data) dropAll(data) end,
}

local COLORS = { drop = { 1, 0.55, 0.30 }, turnin = { 0.45, 0.78, 1.0 }, keep = { 0.36, 0.86, 0.48 } }
local function row(k)
  if rows[k] then return rows[k] end
  local r = CreateFrame("Frame", nil, f); r:SetSize(W - 2 * PAD, ROW)
  r.edge = r:CreateTexture(nil, "ARTWORK"); r.edge:SetTexture(Style.WHITE); r.edge:SetWidth(3); r.edge:SetPoint("TOPLEFT", 0, -4); r.edge:SetPoint("BOTTOMLEFT", 0, 4)
  r.title = Style.Text(r, 11, C.text); r.title:SetPoint("TOPLEFT", 10, -3); r.title:SetWordWrap(false); r.title:SetWidth(W - 2 * PAD - 110)
  r.why = Style.Text(r, 10, C.sub); r.why:SetPoint("TOPLEFT", r.title, "BOTTOMLEFT", 0, -2); r.why:SetWordWrap(false); r.why:SetWidth(W - 2 * PAD - 110)
  r.btn = Style.Button(r, "Abandon", 80, 18, function(self)
    local d = self:GetParent().data; if not d then return end
    local dlg = StaticPopup_Show("FOREVERROUTE_ABANDON", d.title); if dlg then dlg.data = { id = d.id, title = d.title, why = self:GetParent().reason } end
  end, "Drop this quest from your log (asks first)")
  r.btn:SetPoint("RIGHT", r, "RIGHT", -4, 0)
  r.keep = Style.Button(r, "Keep", 44, 18, function(self)
    local d = self:GetParent().data; if not d then return end
    ns.char.keepQuests = ns.char.keepQuests or {}; ns.char.keepQuests[d.id] = true
    LogCheck.Draw(); recount()
  end, "Never suggest dropping this one")
  r.keep:SetPoint("RIGHT", r.btn, "LEFT", -4, 0)
  rows[k] = r
  return r
end

local function build()
  f = CreateFrame("Frame", "ForeverRouteLogCheck", UIParent)
  f:SetSize(W, 200); f:SetPoint("CENTER", 0, 40); f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true); f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
  Style.Panel(f, C.bg2)
  table.insert(UISpecialFrames, "ForeverRouteLogCheck")
  f.title = Style.Text(f, 15, C.gold, "OUTLINE"); f.title:SetPoint("TOPLEFT", PAD, -12); f.title:SetText("Quest log check")
  local close = Style.Button(f, "x", 18, 18, function() f:Hide() end, "Close"); close:SetPoint("TOPRIGHT", -8, -8)
  f.sum = Style.Text(f, 11, C.sub); f.sum:SetPoint("TOPLEFT", PAD, -34); f.sum:SetWidth(W - 2 * PAD - 110)
  f.all = Style.Button(f, "Drop all", 90, 20, function()
    local drop = {}; for _, x in ipairs(LogCheck.Classify()) do if x.verdict == "drop" then drop[#drop + 1] = { id = x.e.id, title = x.e.title, why = x.why } end end
    if #drop == 0 then return end
    local names = ""; for _, e in ipairs(drop) do names = names .. "\n" .. e.title end
    local dlg = StaticPopup_Show("FOREVERROUTE_DROPALL", #drop, names); if dlg then dlg.data = drop end
  end, "Drop every quest marked here (asks first, listing them)")
  f.all:SetPoint("TOPRIGHT", -PAD, -34)
  f:Hide()
end

function LogCheck.Draw()
  if not f or not f:IsShown() then return end
  local list = LogCheck.Classify()
  local drops = 0; for _, x in ipairs(list) do if x.verdict == "drop" then drops = drops + 1 end end
  f.sum:SetText(string.format("%d quests in your log (max %d).  %s", #list, ns.State.MaxLog() or 40,
    drops > 0 and string.format("|cffff8c4d%d worth dropping|r - they're not on your route, or will be gray before you get to them.", drops) or "|cff5cdc7aEverything here is on your route.|r"))
  f.all:SetShown(drops > 0); f.all.label:SetText(string.format("Drop all %d", drops))
  local y = 34 + math.max(f.sum:GetStringHeight(), 22) + 10
  for k, r in ipairs(rows) do if k > #list then r:Hide() end end
  local lastZone
  for k, x in ipairs(list) do
    local r = row(k)
    r.data, r.reason = x.e, x.why
    local c = COLORS[x.verdict]
    r.edge:SetVertexColor(c[1], c[2], c[3], 0.9)
    local qc = Style.QuestColor(x.e.level)
    r.title:SetText(string.format("%s[%s] %s|r  |cff6c7486%s|r", Style.Hex(qc), x.e.level or "?", x.e.title, x.e.zone or ""))
    r.why:SetText(Style.Hex(c) .. x.why .. "|r")
    r.btn:SetShown(x.verdict == "drop"); r.keep:SetShown(x.verdict == "drop")
    r:ClearAllPoints(); r:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -y); r:Show()
    y = y + ROW + 2
  end
  f:SetHeight(y + 8)
end

function LogCheck.Toggle()
  if f:IsShown() then f:Hide(); return end
  f:Show(); LogCheck.Draw()
end

ns.On("FR_LOADED", build)
ns.On("FR_TOGGLE_LOGCHECK", function() LogCheck.Toggle() end)
ns.On("QUEST_LOG_UPDATE", function() if f and f:IsShown() then LogCheck.Draw() end end)
