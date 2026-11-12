-- What the addon keeps in your saved files, and keeping it small. Everything has a cap (Why.lua 300 decisions, Core.lua
-- 200 chat lines and 20 timing records, Learn.lua 300 pace samples and 100 incidents, Trails.lua 1.5 MB of walking).
-- Walking trails and learning are read only by the companion (the planner on your PC): an install without it (no
-- plan file of its own - ns.HasCompanion) records neither, and what an older version recorded is cleared at login.
-- /fr storage shows the sizes.
local _, ns = ...
local Storage = {}
ns.Storage = Storage

-- about how many bytes a value takes in the saved file
local function size(v, depth)
  local t = type(v)
  if t == "string" then return #v + 3 end
  if t == "number" then return 8 end
  if t == "boolean" then return 5 end
  if t ~= "table" or (depth or 0) > 12 then return 4 end
  local n = 4
  for k, x in pairs(v) do n = n + size(k, (depth or 0) + 1) + size(x, (depth or 0) + 1) + 6 end
  return n
end
Storage.Size = size

-- the parts, biggest first: { name, bytes, where }
function Storage.Parts()
  local out = {}
  for k, v in pairs(ForeverRouteDB or {}) do if type(v) == "table" then out[#out + 1] = { k, size(v), "account" } end end
  for k, v in pairs(ForeverRouteChar or {}) do if type(v) == "table" then out[#out + 1] = { k, size(v), "character" } end end
  table.sort(out, function(a, b) return a[2] > b[2] end)
  return out
end

-- without the companion, what only it reads goes (an addon-site install that recorded trails before this version)
function Storage.Clean()
  if ns.HasCompanion() or not ForeverRouteDB then return 0 end
  local freed = 0
  for _, k in ipairs({ "trailData", "learn" }) do
    if ForeverRouteDB[k] ~= nil then freed = freed + size(ForeverRouteDB[k]); ForeverRouteDB[k] = nil end
  end
  if freed > 0 and ns.Why then ns.Why("storage", string.format("cleared %d KB of walking trails and learning: only the companion reads them", math.floor(freed / 1024))) end
  return freed
end

function Storage.Print()
  local parts, total = Storage.Parts(), 0
  for _, p in ipairs(parts) do total = total + p[2] end
  ns.Print(string.format("Saved data: about %d KB%s.", math.floor(total / 1024), ns.HasCompanion() and " (companion: walking trails and learning are recorded)" or " (no companion: walking trails and learning are not recorded)"))
  for i = 1, math.min(8, #parts) do local p = parts[i]; ns.Print(string.format("  %s (%s): %d KB", p[1], p[3], math.floor(p[2] / 1024 + 0.5))) end
end

ns.On("FR_LOADED", ns.Guard("storage", Storage.Clean))
