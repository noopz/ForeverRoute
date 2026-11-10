-- The decision log: every time the card shows something new or the route changes on its own, why. Kept in
-- ForeverRouteDB.why (the last 300, shared by your characters) so the planner side can read it from your saves too.
-- /fr why prints the last few in chat.
local _, ns = ...
local MAX = 300

local function store()
  if type(ForeverRouteDB.why) ~= "table" then ForeverRouteDB.why = {} end
  return ForeverRouteDB.why
end

local last = {}
-- kind: short category ("card", "reorder", "insert", "path", "ready", ...); text: what and why
function ns.Why(kind, text)
  if not text then return end
  local key = kind .. ":" .. text
  local now = time()
  if last[key] and now - last[key] < 120 then return end -- the same thing again within two minutes: once is enough
  last[key] = now
  local w = store()
  local m = ns.State and ns.State.Position and ns.State.Position()
  w[#w + 1] = { t = now, k = kind, x = text, lv = UnitLevel and UnitLevel("player") or nil, m = m }
  while #w > MAX do table.remove(w, 1) end
end

function ns.WhyPrint(n)
  local w = store()
  n = n or 10
  if #w == 0 then ns.Print("Nothing logged yet."); return end
  ns.Print("Last " .. math.min(n, #w) .. " decisions (newest last):")
  for k = math.max(1, #w - n + 1), #w do
    local e = w[k]
    print(string.format("  |cff8a93a6%s|r  |cffffd25a%s|r  %s", date("%H:%M", e.t), e.k, e.x))
  end
end
