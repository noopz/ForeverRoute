-- Quest automation, on a toggle (ns.db.autoQuest, off by default; Options: "Accept and hand in quests automatically"):
--   accept   a quest a quest-giver offers that your route picks up (not one you marked "won't do"): never random ones
--   hand in  a quest in your log that's finished, and take the reward when there is no choice to make (a choice of
--            rewards always waits for you)
--   gossip   at an NPC with several quests, the finished one first, then one your route picks up
-- Hold Shift while talking to an NPC to do it yourself that time. Quests not in your log (repeatable turn-ins like
-- runecloth) are never handed in for you.
local _, ns = ...
local Auto = {}
ns.AutoQuest = Auto

function Auto.Enabled() return ns.db and ns.db.autoQuest == true and not (IsShiftKeyDown and IsShiftKeyDown()) end

-- the quests your route picks up: an accept step for it, on any of your routes; cached per plan
local wantCache, wantFor
function Auto.Wanted(q)
  q = tonumber(q)
  if not q or (ns.char and ns.char.nope and ns.char.nope[q]) then return false end
  local routes = {}
  for _, r in ipairs(ns.Routes and ns.Routes() or {}) do routes[#routes + 1] = r end
  if ForeverRouteData then routes[#routes + 1] = ForeverRouteData end -- (the plan you are on)
  if wantFor ~= routes[1] or not wantCache then
    wantCache, wantFor = {}, routes[1]
    for _, r in ipairs(routes) do for _, s in ipairs((ns.Steps and ns.Steps(r)) or r.steps or {}) do if s.k == "accept" and s.q then wantCache[s.q] = true end end end
  end
  return wantCache[q] == true
end
ns.On("FR_ROUTE_CHANGED", function() wantCache = nil end)

local function inLog(q)
  if not q then return false end
  local idx = C_QuestLog and C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(q)
  return idx ~= nil and idx > 0
end
local function did(what, q, name)
  if ns.Why then ns.Why("auto", what .. " " .. tostring(name or q) .. (q and (" (" .. q .. ")") or "")) end
end

-- a quest's details (offered): accept it if the route picks it up
function Auto.Detail()
  if not Auto.Enabled() then return false end
  local q = GetQuestID and GetQuestID()
  if QuestGetAutoAccept and QuestGetAutoAccept() then return false end -- the game accepts those itself
  if q and q > 0 and Auto.Wanted(q) and not inLog(q) then AcceptQuest(); did("accepted", q, GetTitleText and GetTitleText()); return true end
  return false
end
-- "do you have the items?": go on when it's finished and in your log
function Auto.Progress()
  if not Auto.Enabled() then return false end
  local q = GetQuestID and GetQuestID()
  if q and inLog(q) and IsQuestCompletable and IsQuestCompletable() then CompleteQuest(); return true end
  return false
end
-- the reward: take it when there's nothing to choose
function Auto.Complete()
  if not Auto.Enabled() then return false end
  local q = GetQuestID and GetQuestID()
  local n = GetNumQuestChoices and GetNumQuestChoices() or 0
  if n > 1 then return false end
  GetQuestReward(n == 1 and 1 or 0); did("handed in", q, GetTitleText and GetTitleText())
  return true
end
-- an NPC with several quests (gossip window): a finished one first, then one the route picks up
function Auto.Gossip()
  if not Auto.Enabled() or not C_GossipInfo then return false end
  for _, a in ipairs(C_GossipInfo.GetActiveQuests and C_GossipInfo.GetActiveQuests() or {}) do
    if a.isComplete and a.questID then C_GossipInfo.SelectActiveQuest(a.questID); return true end
  end
  for _, a in ipairs(C_GossipInfo.GetAvailableQuests and C_GossipInfo.GetAvailableQuests() or {}) do
    if a.questID and Auto.Wanted(a.questID) then C_GossipInfo.SelectAvailableQuest(a.questID); return true end
  end
  return false
end
-- the older quest-greeting window (an NPC with only quests to offer)
function Auto.Greeting()
  if not Auto.Enabled() then return false end
  for i = 1, (GetNumActiveQuests and GetNumActiveQuests() or 0) do
    local _, complete = GetActiveTitle(i)
    if complete then SelectActiveQuest(i); return true end
  end
  for i = 1, (GetNumAvailableQuests and GetNumAvailableQuests() or 0) do
    local q = select(5, GetAvailableQuestInfo(i))
    if q and Auto.Wanted(q) then SelectAvailableQuest(i); return true end
  end
  return false
end

ns.On("QUEST_DETAIL", ns.Guard("auto", Auto.Detail))
ns.On("QUEST_PROGRESS", ns.Guard("auto", Auto.Progress))
ns.On("QUEST_COMPLETE", ns.Guard("auto", Auto.Complete))
ns.On("GOSSIP_SHOW", ns.Guard("auto", Auto.Gossip))
ns.On("QUEST_GREETING", ns.Guard("auto", Auto.Greeting))

-- Auto-fly, on its own toggle (ns.db.autoFly, off by default; Options: "Take the flight my route needs"): open a flight
-- master's map while the card's trip flies from here, and it takes that flight. Only a flight path you have (the map
-- lists it as reachable), only the trip of the step the card shows, and Shift held opens the map for you to choose.
function Auto.FlightFor()
  local E = ns.Engine
  local legs, step = E and E.lastTrip, E and E.lastTripStep
  local shown = E and E.Shown and E.Shown()
  local list = ForeverRouteData and ForeverRouteData.steps
  if not (legs and step and shown and list and list[shown] == step) then return nil end
  for _, leg in ipairs(legs) do
    if leg.how == "fly" then return leg.toTaxi end
    if leg.how ~= "ride" then return nil end -- (a boat or a hearth first: this flight is not the one from here)
  end
end
ns.On("TAXIMAP_OPENED", function()
  if not (ns.db and ns.db.autoFly == true) or (IsShiftKeyDown and IsShiftKeyDown()) then return end
  C_Timer.After(0.1, ns.Guard("autofly", function()
    local want = Auto.FlightFor()
    if not (want and NumTaxiNodes and TaxiNodeName and TakeTaxiNode) then return end
    for i = 1, NumTaxiNodes() do
      if TaxiNodeName(i) == want and (not TaxiNodeGetType or TaxiNodeGetType(i) == "REACHABLE") then
        if ns.Why then ns.Why("auto", "flying to " .. want .. " (auto-fly)") end
        ns.Print("Flying to " .. want .. ". (Auto-fly: hold Shift when you talk to the flight master to choose yourself.)")
        TakeTaxiNode(i)
        return
      end
    end
  end))
end)
