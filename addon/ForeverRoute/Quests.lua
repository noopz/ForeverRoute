-- Quest dialogs: suggest the best quest reward for this character (highlight + chat line). Never clicks anything.
local _, ns = ...
local Q = {}
ns.Quests = Q

-- Nothing here clicks for you: quests are never accepted or handed in automatically. It only suggests a reward.
local function call(fn, ...) if type(fn) == "function" then local ok, a = pcall(fn, ...); if ok then return a end end end

----------------------------------------------------------------------------------------------------------------
-- Reward picker: score each choice for this character against what's equipped in that slot.
----------------------------------------------------------------------------------------------------------------
local WEIGHTS = { -- per point of stat
  WARLOCK = { INTELLECT = 1, STAMINA = 1, SPIRIT = 0.45, SPELL = 1.6, ARMOR = 0.02, DPS = 0.6 },
  MAGE = { INTELLECT = 1, STAMINA = 0.8, SPIRIT = 0.55, SPELL = 1.6, ARMOR = 0.02, DPS = 0.6 },
  PRIEST = { INTELLECT = 1, STAMINA = 0.8, SPIRIT = 0.8, SPELL = 1.3, HEAL = 0.9, ARMOR = 0.02, DPS = 0.6 },
  DRUID = { INTELLECT = 0.8, STAMINA = 0.8, SPIRIT = 0.6, STRENGTH = 0.6, AGILITY = 0.6, SPELL = 1, ARMOR = 0.03, DPS = 1 },
  SHAMAN = { INTELLECT = 0.8, STAMINA = 0.8, SPIRIT = 0.4, STRENGTH = 0.8, AGILITY = 0.5, SPELL = 1, ARMOR = 0.03, DPS = 2.5 },
  PALADIN = { STRENGTH = 1, STAMINA = 0.8, INTELLECT = 0.5, AGILITY = 0.4, SPIRIT = 0.2, SPELL = 0.6, ARMOR = 0.04, DPS = 3 },
  WARRIOR = { STRENGTH = 1, STAMINA = 0.9, AGILITY = 0.7, ATTACK = 0.5, ARMOR = 0.05, DPS = 3.5 },
  ROGUE = { AGILITY = 1, STRENGTH = 0.5, STAMINA = 0.7, ATTACK = 0.5, ARMOR = 0.03, DPS = 3.5 },
  HUNTER = { AGILITY = 1, STAMINA = 0.7, INTELLECT = 0.3, ATTACK = 0.5, ARMOR = 0.03, DPS = 1.5, RANGEDDPS = 4 },
}
-- armor subclass: 1 cloth 2 leather 3 mail 4 plate 6 shield; weapons by subclass id
local ARMOR = { WARLOCK = { [1] = true }, MAGE = { [1] = true }, PRIEST = { [1] = true }, ROGUE = { [1] = true, [2] = true }, DRUID = { [1] = true, [2] = true },
  HUNTER = { [1] = true, [2] = true }, SHAMAN = { [1] = true, [2] = true, [6] = true }, WARRIOR = { [1] = true, [2] = true, [3] = true, [6] = true }, PALADIN = { [1] = true, [2] = true, [3] = true, [6] = true } }
local WEAPON = { -- 0 1h axe 1 2h axe 2 bow 3 gun 4 1h mace 5 2h mace 6 polearm 7 1h sword 8 2h sword 10 staff 13 fist 15 dagger 16 thrown 18 crossbow 19 wand
  WARLOCK = { [7] = 1, [10] = 1, [15] = 1, [19] = 1 }, MAGE = { [7] = 1, [10] = 1, [15] = 1, [19] = 1 }, PRIEST = { [4] = 1, [10] = 1, [15] = 1, [19] = 1 },
  DRUID = { [4] = 1, [5] = 1, [10] = 1, [13] = 1, [15] = 1 }, SHAMAN = { [0] = 1, [1] = 1, [4] = 1, [5] = 1, [10] = 1, [13] = 1, [15] = 1 },
  ROGUE = { [0] = 1, [2] = 1, [3] = 1, [4] = 1, [7] = 1, [13] = 1, [15] = 1, [16] = 1, [18] = 1 }, HUNTER = { [0] = 1, [1] = 1, [2] = 1, [3] = 1, [6] = 1, [7] = 1, [8] = 1, [10] = 1, [13] = 1, [15] = 1, [16] = 1, [18] = 1 },
  WARRIOR = { [0] = 1, [1] = 1, [2] = 1, [3] = 1, [4] = 1, [5] = 1, [6] = 1, [7] = 1, [8] = 1, [10] = 1, [13] = 1, [15] = 1, [16] = 1, [18] = 1 },
  PALADIN = { [0] = 1, [1] = 1, [4] = 1, [5] = 1, [6] = 1, [7] = 1, [8] = 1 } }
local SLOTS = { INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_BODY = { 4 }, INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 },
  INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 }, INVTYPE_FINGER = { 11, 12 },
  INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 }, INVTYPE_WEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 }, INVTYPE_2HWEAPON = { 16 },
  INVTYPE_SHIELD = { 17 }, INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_HOLDABLE = { 17 }, INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 } }

local function statScore(link, class)
  local stats = (ns.GetItemStats and ns.GetItemStats(link)) or {}
  local w = WEIGHTS[class] or WEIGHTS.WARRIOR
  local score = 0
  for k, v in pairs(stats) do
    local K = k:upper()
    local wt = (K:find("INTELLECT") and w.INTELLECT) or (K:find("STAMINA") and w.STAMINA) or (K:find("SPIRIT") and w.SPIRIT) or (K:find("STRENGTH") and w.STRENGTH)
      or (K:find("AGILITY") and w.AGILITY) or ((K:find("SPELL") and not K:find("HEAL")) and w.SPELL) or (K:find("HEAL") and w.HEAL) or (K:find("ATTACK_POWER") and w.ATTACK)
      or (K:find("RESISTANCE0") and w.ARMOR) or (K:find("DAMAGE_PER_SECOND") and w.DPS) or 0
    score = score + (wt or 0) * v
  end
  return score
end

-- the enchant on what you wear goes when you swap it out, so it counts for the item you have (the game's own comparison
-- leaves it out: "Enchanted: Stamina +2 and Armor +16" on Robes of the Disgraced Thane made the Robes of Antiquity
-- look like an upgrade)
local ENCH = { stamina = "STAMINA", intellect = "INTELLECT", spirit = "SPIRIT", strength = "STRENGTH", agility = "AGILITY",
  armor = "RESISTANCE0", ["spell power"] = "SPELL_POWER", ["attack power"] = "ATTACK_POWER", ["healing"] = "HEAL" }
local function plainText(t) return type(t) == "string" and not (issecretvalue and issecretvalue(t)) and t or nil end
function Q.EnchantStats(slot)
  local tip = C_TooltipInfo and C_TooltipInfo.GetInventoryItem and call(C_TooltipInfo.GetInventoryItem, "player", slot)
  local out = {}
  for _, line in ipairs(type(tip) == "table" and tip.lines or {}) do
    local t = plainText(line.leftText)
    local e = t and t:match("^Enchanted: (.+)$")
    if e then
      for part in (e .. " and "):gmatch("(.-) and ") do
        local name, n = part:match("^(.-) %+(%d+)$")
        if not name then n, name = part:match("^%+(%d+) (.+)$") end
        local K = name and ENCH[name:lower()]
        if K then out[K] = (out[K] or 0) + tonumber(n) end
      end
    end
  end
  return out
end
local function wornScore(slot, class)
  local cur = GetInventoryItemLink("player", slot)
  if not cur then return 0 end
  local sc = statScore(cur, class)
  local w = WEIGHTS[class] or WEIGHTS.WARRIOR
  for K, v in pairs(Q.EnchantStats(slot)) do
    local wt = (K == "SPELL_POWER" and w.SPELL) or (K == "RESISTANCE0" and w.ARMOR) or (K == "ATTACK_POWER" and w.ATTACK) or w[K] or 0
    sc = sc + wt * v
  end
  return sc
end

-- returns score delta (positive = upgrade), or nil if unusable
local function evaluate(link)
  local _, class = UnitClass("player")
  local _, _, _, _, reqLevel, _, _, _, equipLoc, _, sellPrice, classID, subclassID = ns.GetItemInfo(link)
  if not equipLoc then return nil, nil, true end -- not cached yet
  local slots = SLOTS[equipLoc]
  if not slots then return nil, sellPrice end
  if classID == 4 and subclassID and subclassID > 0 and equipLoc ~= "INVTYPE_CLOAK" and not (ARMOR[class] or {})[subclassID] then return nil, sellPrice end
  if classID == 2 and not (WEAPON[class] or {})[subclassID] then return nil, sellPrice end
  local new = statScore(link, class)
  local worst = math.huge
  for _, slot in ipairs(slots) do
    local sc = wornScore(slot, class)
    if sc < worst then worst = sc end
  end
  if equipLoc == "INVTYPE_2HWEAPON" then worst = worst + wornScore(17, class) end
  return new - worst, sellPrice
end

local toast
local function showToast(text)
  if not toast then
    toast = CreateFrame("Frame", nil, UIParent)
    toast:SetSize(300, 40); toast:SetPoint("TOP", UIParent, "TOP", 0, -220); toast:SetFrameStrata("DIALOG")
    ns.Style.Panel(toast)
    toast.text = ns.Style.Text(toast, 12, ns.Style.C.text); toast.text:SetPoint("CENTER"); toast.text:SetJustifyH("CENTER"); toast.text:SetWidth(280)
    toast.fade = toast:CreateAnimationGroup()
    local a = toast.fade:CreateAnimation("Alpha"); a:SetFromAlpha(1); a:SetToAlpha(0); a:SetDuration(0.6); a:SetStartDelay(6)
    toast.fade:SetScript("OnFinished", function() toast:Hide() end)
  end
  toast.text:SetText(text); toast:SetHeight(toast.text:GetStringHeight() + 20)
  toast:SetAlpha(1); toast:Show(); toast.fade:Stop(); toast.fade:Play()
end

local glow
local function highlight(index)
  local btn = QuestInfo_GetRewardButton and QuestInfoFrame and QuestInfoFrame.rewardsFrame and QuestInfo_GetRewardButton(QuestInfoFrame.rewardsFrame, index)
  if not btn then return end
  glow = glow or btn:CreateTexture(nil, "OVERLAY")
  glow:SetParent(btn); glow:ClearAllPoints(); glow:SetAllPoints(btn)
  glow:SetTexture(ns.Style.WHITE); glow:SetVertexColor(0.36, 0.86, 0.48, 0.25); glow:Show()
end

local function pickReward(retry)
  local n = GetNumQuestChoices() or 0
  if n < 2 then return end
  if not ns.db.rewardHint then return end
  local best, bestDelta, bestValue, bestValueIdx, uncached = nil, 0, -1, nil, false
  for i = 1, n do
    local link = GetQuestItemLink("choice", i)
    if link then
      local delta, value, notCached = evaluate(link)
      if notCached then uncached = true end
      if delta and delta > bestDelta then best, bestDelta = i, delta end
      if (value or 0) > bestValue then bestValue, bestValueIdx = value or 0, i end
    end
  end
  if uncached and not retry then C_Timer.After(0.6, function() if QuestInfoFrame and (QuestFrame and QuestFrame:IsShown() or true) then pickReward(true) end end); return end
  local pick, why
  if best then pick, why = best, string.format("best for you (+%d)", math.floor(bestDelta + 0.5))
  elseif bestValueIdx then pick, why = bestValueIdx, "no upgrade - highest vendor price" end
  if not pick then return end
  local link = GetQuestItemLink("choice", pick)
  highlight(pick)
  showToast("|cff5cdc7aReward:|r " .. (link or "?") .. "\n|cff9aa3b5" .. why .. "|r")
  ns.Print("pick " .. (link or "?") .. " - " .. why)
end
ns.On("QUEST_COMPLETE", function() pickReward(false) end)
ns.On("QUEST_FINISHED", function() if glow then glow:Hide() end end)

Q.Evaluate = evaluate -- exposed for tests

----------------------------------------------------------------------------------------------------------------
-- Gear rewards on your route: is each one better than what you wear? The planner only knows item levels; the game
-- knows the stats, your gear and its enchants. Verdicts: ForeverRouteChar.gearVerdict[itemID] = { d = score
-- difference (<= 0: not an upgrade), worn = what was in the slot }. The card says it on the step at once; the
-- companion reads the save and stops counting a reward that isn't one (tools/quality.js).
----------------------------------------------------------------------------------------------------------------
local function verdicts() ns.char.gearVerdict = type(ns.char.gearVerdict) == "table" and ns.char.gearVerdict or {}; return ns.char.gearVerdict end
function Q.Judge(id)
  local ok, _, link = pcall(ns.GetItemInfo, id)
  if not ok then link = nil end
  if not link then if C_Item and C_Item.RequestLoadItemDataByID then call(C_Item.RequestLoadItemDataByID, id) end; return false end
  local d, _, notCached = evaluate(link)
  if notCached then return false end
  verdicts()[id] = { d = d and math.floor(d + 0.5) or -1, unusable = (d == nil) or nil, t = time and time() or 0 }
  return true
end
function Q.Verdict(id) local v = id and ns.char and type(ns.char.gearVerdict) == "table" and ns.char.gearVerdict[id]; return v or nil end
local judgeQueue, seen
function Q.JudgeTick(n)
  if not (ns.char and ForeverRouteData and ForeverRouteData.steps) then return end
  if not judgeQueue then
    judgeQueue, seen = {}, {}
    for _, s in ipairs(ForeverRouteData.steps) do
      local id = tonumber(s.reward)
      if id and not seen[id] and not verdicts()[id] then seen[id] = true; judgeQueue[#judgeQueue + 1] = { id = id, tries = 0 } end
    end
  end
  for _ = 1, n or 3 do
    local e = table.remove(judgeQueue, 1)
    if not e then return end
    if not Q.Judge(e.id) then e.tries = e.tries + 1; if e.tries < 5 then judgeQueue[#judgeQueue + 1] = e end end
  end
end
-- what you wear changed: every verdict is stale (judged again in the background)
ns.On("PLAYER_EQUIPMENT_CHANGED", function() if ns.char then ns.char.gearVerdict = {} end; judgeQueue = nil end)
ns.On("FR_ROUTE_CHANGED", function() judgeQueue = nil end)
ns.On("FR_LOADED", function() C_Timer.After(15, function() C_Timer.NewTicker(2, ns.Guard("gear", function() Q.JudgeTick(3) end)) end) end)
-- the step's note with the planner's reward guess replaced by the game's verdict
function Q.RewardNote(s)
  local note = s and s.note
  local v = note and s.reward and Q.Verdict(tonumber(s.reward))
  if not v then return note end
  local say = v.unusable and "not usable by you" or v.d > 0 and string.format("upgrade for you, +%d", v.d) or "not an upgrade for you"
  return (note:gsub("(Reward: [^(]-) %(([^)]*)%)", function(name) return name .. " (" .. say .. ")" end, 1))
end
Q.PickReward = pickReward
