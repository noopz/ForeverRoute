-- "Also hand in" (fallback): a quest you finished that your route has no hand-in for AND that the engine could not
-- slot into the route as a stop (its NPC is on no stretch of the route). (you did it on the way, out of order, or the
-- plan had left it out). If its hand-in NPC is near you, the card shows one line for it - no replan needed.
-- Hand-in spots come from the plan (ForeverRouteEnders: every quest you could take, up to a few levels past the target).
local _, ns = ...
local Extras = {}
ns.Extras = Extras
local HBD = LibStub("HereBeDragons-2.0")
local NEAR = 250 -- yards

-- does the current route already hand this quest in?
local function routeTurnsIn(q)
  for _, s in ipairs(ForeverRouteData and ForeverRouteData.steps or {}) do if s.k == "turnin" and s.q == q then return true end end
  return false
end

-- finished quests with no hand-in on the route whose NPC is within reach: { { q, name, npc, yards } } nearest first
function Extras.Current()
  if not ForeverRouteEnders then return {} end
  local px, py, pinst = HBD:GetPlayerWorldPosition()
  if not px then return {} end
  local out = {}
  for q, e in pairs(ns.Engine.LogEnders()) do -- only quests in your log (every 3 s: not all ~1000 spots)
    if ns.State.QuestReady(q) and not ns.State.IsCompleted(q) and not routeTurnsIn(q) then
      local ex, ey, einst = HBD:GetWorldCoordinatesFromZone(e.x, e.y, e.m)
      if ex and einst == pinst then
        local d = math.sqrt((ex - px) ^ 2 + (ey - py) ^ 2)
        if d <= NEAR then out[#out + 1] = { q = q, name = e.name, npc = e.npc, yards = d } end
      end
    end
  end
  table.sort(out, function(a, b) return a.yards < b.yards end)
  return out
end

-- one line of text for the card, or nil
function Extras.Line()
  local list = Extras.Current()
  if #list == 0 then return nil end
  local first = list[1]
  if #list == 1 then return string.format("Also hand in: %s  ->  %s, %s", first.name, first.npc, ns.Style.Distance(first.yards)) end
  local same = true; for _, x in ipairs(list) do if x.npc ~= first.npc then same = false end end
  if same then return string.format("Also hand in %d quests  ->  %s, %s", #list, first.npc, ns.Style.Distance(first.yards)) end
  return string.format("Also hand in: %s (+%d more nearby)  ->  %s, %s", first.name, #list - 1, first.npc, ns.Style.Distance(first.yards))
end

local last
local function check()
  local l = Extras.Line()
  if l ~= last then last = l; ns.Fire("FR_STEP", ns.Engine.Shown()) end
end
ns.On("FR_STATE", function() C_Timer.After(0.2, check) end)
ns.On("FR_LOADED", function() C_Timer.NewTicker(3, ns.Guard("extras", check)) end)
