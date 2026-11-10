-- Errand reminders: one line on the card when it matters - bags nearly full (sell) or gear wearing out (repair) -
-- with the nearest vendor that can do it on this map (from Vendors.lua, generated from the quest database).
-- Hidden again once it's sorted, or dismissed until things change.
local _, ns = ...
local Errands = {}
ns.Errands = Errands
local HBD = LibStub("HereBeDragons-2.0")

local BAG_LOW, DURABILITY_LOW = 3, 0.25

function Errands.FreeSlots()
  local free, getFree = 0, (C_Container and C_Container.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
  if not getFree then return nil end
  for bag = 0, 4 do local ok, n = pcall(getFree, bag); if ok and type(n) == "number" then free = free + n end end
  return free
end
function Errands.Durability()
  if not GetInventoryItemDurability then return nil end
  local low
  for slot = 1, 18 do
    local ok, cur, max = pcall(GetInventoryItemDurability, slot)
    if ok and cur and max and max > 0 then local f = cur / max; if not low or f < low then low = f end end
  end
  return low
end
-- the nearest vendor on your map (one that repairs, if that's needed): name, title, yards
function Errands.Nearest(needRepair)
  local m = ns.State.Position()
  local list = m and ns.VENDORS and ns.VENDORS[m]
  if not list then return nil end
  local px, py, pinst = HBD:GetPlayerWorldPosition()
  local best, bd
  for _, v in ipairs(list) do
    if v[5] or not needRepair then
      local vx, vy, vinst = HBD:GetWorldCoordinatesFromZone(v[1], v[2], m)
      if vx and px and vinst == pinst then
        local d = math.sqrt((vx - px) ^ 2 + (vy - py) ^ 2)
        if not bd or d < bd then best, bd = v, d end
      end
    end
  end
  return best, bd
end

-- Well Fed (cooked food): about +5% kill XP. Checked out of combat only (aura data can be hidden in combat).
-- true / false, or nil when it can't tell
function Errands.WellFed()
  if InCombatLockdown and InCombatLockdown() then return nil end
  if C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName then
    local ok, a = pcall(C_UnitAuras.GetAuraDataBySpellName, "player", "Well Fed", "HELPFUL")
    if ok then return a ~= nil end
  end
  if AuraUtil and AuraUtil.FindAuraByName then
    local ok, name = pcall(AuraUtil.FindAuraByName, "Well Fed", "player", "HELPFUL")
    if ok then return name ~= nil end
  end
end
-- is this bag item Well Fed food you can eat now? Its "Use:" line says so. Not a recipe: a recipe's tooltip includes
-- the tooltip of the dish it teaches, "well fed" and all (recipes are item class 9; food is a consumable, class 0).
-- Not food above your level: the tooltip's "Requires Level N" (or the item's own required level) says when.
local CONSUMABLE, RECIPE = 0, 9
function Errands.IsWellFedFood(itemID, tip)
  local getInstant = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
  if getInstant and itemID then
    local ok, _, _, _, _, _, classID = pcall(getInstant, itemID)
    if ok and type(classID) == "number" and classID ~= CONSUMABLE then return false end
  end
  local level = UnitLevel and UnitLevel("player") or 1
  local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
  if getInfo and itemID then
    local ok, _, _, _, _, minLevel = pcall(getInfo, itemID)
    if ok and type(minLevel) == "number" and minLevel > level then return false end
  end
  local fed = false
  for _, line in ipairs(tip and tip.lines or {}) do
    local t = line.leftText
    if type(t) == "string" and not (issecretvalue and issecretvalue(t)) then
      if t:find("^Use: Teaches you") then return false end
      local need = tonumber(t:match("^Requires Level (%d+)"))
      if need and need > level then return false end
      if t:find("^Use:") and t:lower():find("well fed", 1, true) then fed = true end
    end
  end
  return fed
end

-- food in your bags that gives Well Fed; scanned when your bags change
local foodCache
function Errands.Food()
  if foodCache ~= nil then return foodCache or nil end
  foodCache = false
  if not (C_TooltipInfo and C_TooltipInfo.GetBagItem and C_Container and C_Container.GetContainerNumSlots) then return nil end
  for bag = 0, 4 do
    local okN, n = pcall(C_Container.GetContainerNumSlots, bag)
    for slot = 1, (okN and n or 0) do
      local okI, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
      if okI and info and info.itemID then
        local okT, tip = pcall(C_TooltipInfo.GetBagItem, bag, slot)
        if okT and tip and Errands.IsWellFedFood(info.itemID, tip) then   -- else keep looking: real food may be further on
          foodCache = { name = (tip.lines[1] and tip.lines[1].leftText) or info.itemName or "food", id = info.itemID }
          return foodCache
        end
      end
    end
  end
  return nil
end
ns.On("BAG_UPDATE_DELAYED", function() foodCache = nil end)
-- the step you're on has you killing things (Well Fed only adds kill XP)
local function killing()
  local i = ns.Engine.Shown()
  local s = i and ForeverRouteData and ForeverRouteData.steps and ForeverRouteData.steps[i]
  return s and s.k == "obj" and type(s.text) == "string" and (s.text:find("^Kill") or s.text:find("^Collect")) and true or false
end

-- warlock pet grimoires (bought from the demon trainer; Icy Veins' warlock guide): only for a demon you have, only in a
-- city with a demon trainer, once each ("Got it" marks it bought)
Errands.GRIMOIRES = {
  { name = "Sacrifice", level = 16, pet = "Voidwalker" },
  { name = "Consume Shadows", level = 18, pet = "Voidwalker" },
  { name = "Seduction", level = 26, pet = "Succubus", quest = { 1739 } },
  { name = "Devour Magic", level = 30, pet = "Felhunter", quest = { 1795 } },
  { name = "Spell Lock", level = 36, pet = "Felhunter", quest = { 1795 } },
}
Errands.DEMON_TRAINERS = { [1453] = "Spackle Thornberry, by Gakin in the Mage Quarter", [1455] = "Jubahl Corpseseeker, in the Forlorn Cavern" }
function Errands.Grimoire()
  local _, class = UnitClass("player")
  if class ~= "WARLOCK" then return nil end
  local m = ns.State.Position()
  local trainer = m and Errands.DEMON_TRAINERS[m]
  if not trainer then return nil end
  ns.char.grimoires = ns.char.grimoires or {}
  local lvl = UnitLevel("player") or 1
  for _, g in ipairs(Errands.GRIMOIRES) do
    local have = not g.quest
    for _, q in ipairs(g.quest or {}) do if ns.State.IsCompleted(q) then have = true end end
    if have and lvl >= g.level and not ns.char.grimoires[g.name] then
      return string.format("Demon trainer (%s): Grimoire of %s for your %s", trainer, g.name, g.pet), "grimoire:" .. g.name
    end
  end
end

-- what to show (or nil): text, and a key so a dismissal lasts until things change
function Errands.Current()
  local free, dur = Errands.FreeSlots(), Errands.Durability()
  local needSell = free and free <= BAG_LOW
  local needRepair = dur and dur <= DURABILITY_LOW
  if not (needSell or needRepair) then
    local gt, gk = Errands.Grimoire()
    if gt then return gt, gk end
    if killing() and Errands.WellFed() == false then
      local food = Errands.Food()
      if food and ns.char.errandDismissed ~= "food" then return "Eat " .. food.name .. " for Well Fed (about +5% kill XP)", "food" end
    end
    return nil
  end
  local key = (needSell and "bags" or "") .. (needRepair and "repair" or "")
  if ns.char.errandDismissed == key then return nil end
  local v, d = Errands.Nearest(needRepair)
  local where = v and string.format(": %s (%s), %s", v[3], v[4], ns.Style.Distance(d)) or " at the next vendor"
  local what
  if needSell and needRepair then what = string.format("Bags %d free, gear at %d%% - sell and repair", free, math.floor(dur * 100))
  elseif needRepair then what = string.format("Gear at %d%% - repair", math.floor(dur * 100))
  else what = string.format("Bags: %d free - sell", free) end
  return what .. where, key
end
function Errands.Dismiss()
  local _, key = Errands.Current()
  -- a grimoire's "x" means bought (or not wanted): never again; other errands come back when things change
  local g = key and key:match("^grimoire:(.+)$")
  if g then ns.char.grimoires = ns.char.grimoires or {}; ns.char.grimoires[g] = true else ns.char.errandDismissed = key end
  ns.Fire("FR_STEP", ns.Engine.Shown())
end

local last
local function check()
  local text, key = Errands.Current()
  if key ~= last then last = key; if not key then ns.char.errandDismissed = nil end; ns.Fire("FR_STEP", ns.Engine.Shown()) end
end
ns.On("BAG_UPDATE_DELAYED", check)
ns.On("UPDATE_INVENTORY_DURABILITY", check)
ns.On("FR_LOADED", function() C_Timer.After(5, check); C_Timer.NewTicker(15, ns.Guard("errands", check)) end)
