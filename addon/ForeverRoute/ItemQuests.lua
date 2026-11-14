-- Quests an item starts: a drop (Message in a Bottle's Carefully Folded Note, an OOX distress beacon) comes when it
-- comes, so no plan can count on it - and an unread one sat in the bags while the route ran out of quests and sent you
-- grinding. When one is in your bags and the quest is yours to take, the card offers it: one line, "use it" (the
-- use-item button above the card), and an "x" to say no. Once you take it, its objectives and hand-in are fitted into
-- your route where they cost least, the way a side quest's are (Engine.SideStops, ns.ITEM_QUESTS in QuestData.lua).
local _, ns = ...
local IQ = {}
ns.ItemQuests = IQ

-- some values are hidden from addons on Forever ("secret values"): unknown
local function plain(v) if v == nil or (issecretvalue and issecretvalue(v)) then return nil end return v end
local function call(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, a, b, c = pcall(fn, ...)
  if not ok then return nil end
  return plain(a), plain(b), plain(c)
end
local CC = function() return C_Container or {} end

-- item -> the quest it starts (ITEM_QUESTS lists the items per quest)
local byItem
local function questOf(item)
  if not byItem or byItem.src ~= ns.ITEM_QUESTS then
    byItem = { src = ns.ITEM_QUESTS }
    for q, d in pairs(ns.ITEM_QUESTS or {}) do for it in pairs(d.it or {}) do byItem[it] = q end end
  end
  return item and byItem[item]
end

-- what is in your bags that starts a quest: { { item, q, active } }. The game says it per slot (an item's quest info);
-- a client or the simulator without that call: the quest data's own list of starting items.
function IQ.BagItems()
  local out = {}
  local numSlots = CC().GetContainerNumSlots or GetContainerNumSlots
  local itemID = CC().GetContainerItemID or GetContainerItemID
  local questInfo = CC().GetContainerItemQuestInfo or GetContainerItemQuestInfo
  if type(numSlots) ~= "function" then return out end
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    for slot = 1, call(numSlots, bag) or 0 do
      local item = call(itemID, bag, slot)
      if not item and CC().GetContainerItemInfo then
        local info = call(CC().GetContainerItemInfo, bag, slot)
        item = type(info) == "table" and plain(info.itemID) or nil
      end
      if item then
        -- (a table on newer clients - { isQuestItem, questID, isActive } - three values on older ones)
        local a, b, c = call(questInfo, bag, slot)
        local q, active
        if type(a) == "table" then q, active = plain(a.questID), plain(a.isActive) else q, active = b, c end
        -- the game's quest id, when it is one the quest data knows; else the data's own match for the item
        if not (q and ns.ITEM_QUESTS and ns.ITEM_QUESTS[q]) then q = questOf(item) end
        if q then out[#out + 1] = { item = item, q = q, active = active and true or false } end
      end
    end
  end
  return out
end

-- why this quest is not offered (nil: it is): yours already, not for you, gray, ...
function IQ.WhyNot(q)
  local d = ns.ITEM_QUESTS and ns.ITEM_QUESTS[q]
  local State, Engine = ns.State, ns.Engine
  if not d then return "not in the quest data" end
  if State.IsCompleted(q) or State.OnQuest(q) then return "yours already" end
  if ns.char.nope and ns.char.nope[q] then return "you are not doing it" end
  if ns.char.itemQuestNo and ns.char.itemQuestNo[q] then return "you said no" end
  if Engine.SideMine and not Engine.SideMine(d) then return "not for you" end
  local lvl = (UnitLevel and UnitLevel("player")) or 1
  if lvl < (d.r or 1) then return "needs level " .. d.r end
  -- (no XP worth a stop: the gray line, as for the route's own quests)
  if d.l <= Engine.GrayAt(lvl) then return "gray" end
  for _, p in ipairs(d.pre or {}) do if not State.IsCompleted(p) then return "something comes before it" end end
  if d.any then
    local one = false
    for _, p in ipairs(d.any) do one = one or State.IsCompleted(p) end
    if not one then return "something comes before it" end
  end
  for _, x in ipairs(d.ex or {}) do if State.IsCompleted(x) or State.OnQuest(x) then return "not with a quest you have or did" end end
  -- the plan has it: the route sends you to it already
  for _, s in ipairs((ForeverRouteData and ForeverRouteData.steps) or {}) do if s.q == q and not s.inserted then return "on your route" end end
  return nil
end

IQ.offer = nil      -- what the card offers: { q, item, itemName, name, xp, fresh }
local carried       -- the starting items in your bags at the last look: an item not among them was just looted
local told = {}     -- quests the why log has an answer for this session
function IQ.Scan()
  if not ns.char then return end
  local found = IQ.BagItems()
  local now, best = {}, nil
  for _, b in ipairs(found) do
    now[b.item] = true
    local why = (b.active and "yours already") or IQ.WhyNot(b.q)
    local d = ns.ITEM_QUESTS[b.q]
    if not why then
      local fresh = carried ~= nil and not carried[b.item]
      -- the one you just looted first, then the most XP
      if not best or (fresh and not best.fresh) or (fresh == best.fresh and d.xp > best.xp) then
        best = { q = b.q, item = b.item, itemName = (d.it and d.it[b.item]) or ("item " .. b.item), name = d.n, xp = d.xp, fresh = fresh }
      end
    elseif d and told[b.q] ~= why and why ~= "yours already" and ns.Why then
      told[b.q] = why
      ns.Why("itemquest", d.n .. " (from the " .. ((d.it and d.it[b.item]) or "item") .. " in your bags) is not offered: " .. why)
    end
  end
  carried = now
  local old = IQ.offer
  -- (the same quest stays "just looted" while it is on offer)
  if best and old and old.q == best.q then best.fresh = old.fresh end
  IQ.offer = best
  if (old and old.q) ~= (best and best.q) then
    if best and ns.Why then ns.Why("itemquest", best.name .. " starts from the " .. best.itemName .. " in your bags: offered (" .. best.xp .. " xp)") end
    if ns.Engine and ns.Engine.Shown then ns.Fire("FR_STEP", ns.Engine.Shown()) end
  end
  return best
end
function IQ.Current() return IQ.offer end
-- the card's line: what it says (fromBags: the button above the card is busy with the step's own item)
function IQ.Text(o, fromBags)
  o = o or IQ.offer
  if not o then return nil end
  return string.format("%s starts from the %s %s - use it%s", o.name, o.itemName, o.fresh and "you just looted" or "in your bags",
    fromBags and " from your bags" or " (the icon above the card)")
end
-- "x": not this one (for good, on this character: the item stays in your bags; taking the quest anyway still gets it
-- its stops)
function IQ.Dismiss()
  local o = IQ.offer
  if not (o and ns.char) then return end
  ns.char.itemQuestNo = ns.char.itemQuestNo or {}
  ns.char.itemQuestNo[o.q] = true
  if ns.Why then ns.Why("itemquest", o.name .. ": you said no; not offered again") end
  IQ.Scan()
end

local function rescan() IQ.Scan() end
ns.On("BAG_UPDATE_DELAYED", ns.Guard("itemquest", rescan))
ns.On("QUEST_ACCEPTED", function() C_Timer.After(0.3, ns.Guard("itemquest", rescan)) end)
ns.On("QUEST_TURNED_IN", function() C_Timer.After(0.5, ns.Guard("itemquest", rescan)) end)
ns.On("PLAYER_LEVEL_UP", function() C_Timer.After(1, ns.Guard("itemquest", rescan)) end)
ns.On("FR_NOPE", function() C_Timer.After(0, ns.Guard("itemquest", rescan)) end)
-- (what you carried before the addon looked is "in your bags", not "just looted")
ns.On("FR_LOADED", function() C_Timer.After(4, ns.Guard("itemquest", rescan)) end)
