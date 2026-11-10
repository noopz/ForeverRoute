-- /fr demo: cycle the UI through every kind of step and state (scripted, nothing real changes) so it can be checked
-- with screenshots. /fr demo again (or /reload) restores the real route.
local _, ns = ...
local Demo = {}
ns.Demo = Demo

local saved, ticker, idx
local scenes -- { step index, status, objectives = { [stepIndex] = {have, need, text} }, caption }

local function build()
  local m, x, y = ns.State.Position()
  m, x, y = m or 1436, x or 0.5, y or 0.5
  local function near(dx, dy) return { m = m, x = math.min(0.99, math.max(0.01, x + dx)), y = math.min(0.99, math.max(0.01, y + dy)) } end
  local function st(t, p) for k, v in pairs(p or near(0.01, -0.01)) do t[k] = v end; t.zone = "Westfall"; return t end
  local data = {
    id = "demo", title = "Demo route", meta = { endLevel = "19 (43%)" },
    sections = { { title = "Sentinel Hill", zone = "Westfall" }, { title = "Jangolode Mine", zone = "Westfall" }, { title = "Travel", zone = "Stormwind" } },
    steps = {
      st({ k = "accept", q = 1, name = "The People's Militia", level = 12, npc = "Gryan Stoutmantle", sec = 1, lvl = 16, r = 6 }),
      st({ k = "obj", q = 2, name = "The State of the Mines", level = 14, text = "Kill 4 Kobold Digger", match = "Kobold Digger", target = "Kobold Digger", sec = 2, lvl = 16, r = 40 }, near(-0.03, 0.02)),
      st({ k = "obj", q = 3, name = "Harvesting the Harvesters", level = 15, text = "Collect 14 Golem Isospring", match = "Golem Isospring", loot = true, target = "Harvest Watcher", item = 6948, sec = 2, lvl = 16, r = 40 }, near(-0.03, 0.02)),
      st({ k = "obj", q = 4, name = "Keeper of the Flame", level = 16, text = "Collect 5 Flask of Oil", match = "Flask of Oil", loot = true, sec = 2, lvl = 16, r = 40 }, near(-0.03, 0.02)),
      st({ k = "turnin", q = 5, name = "Westfall Stew", level = 13, npc = "Salma Saldean", sec = 1, lvl = 17, r = 6 }),
      st({ k = "turnin", q = 6, name = "Patrolling Westfall", level = 14, npc = "Captain Danuvin", sec = 1, lvl = 17, r = 6 }),
      st({ k = "accept", q = 7, name = "The Coast Isn't Clear", level = 19, npc = "Captain Grayson", sec = 1, lvl = 17, r = 6 }),
      st({ k = "fp", npc = "Thor", fp = "Sentinel Hill, Westfall", sec = 1, lvl = 17, r = 8 }),
      st({ k = "fly", dest = "Stormwind", to = 1453, npc = "Thor", sec = 3, lvl = 18, note = "Next leg: Redridge 18+" }),
      st({ k = "train", text = "level 18 spells", npc = "Demisette Cloyce", sec = 3, lvl = 18, note = "Stormwind, Mage Quarter" }),
      st({ k = "grind", level = 19, xp = 4200, text = "Murlocs along the coast", sec = 1, lvl = 18 }),
      st({ k = "bonus", text = "loot the book Crimes Against Anatomy", where = "Raven Hill Cemetery: the crypt, on a table at the back.", item = 209849, book = "anatomy", sec = 1, lvl = 18, r = 12, note = "Lore book on the way (HandyNotes Forever Books)." }),
    },
  }
  for i, s in ipairs(data.steps) do s.id = "demo" .. i end
  scenes = {
    { 1, "todo", caption = "accept step" },
    { 2, "todo", obj = { [2] = { 1, 4, "Kobold Digger slain: 1/4" }, [3] = { 9, 14, "Golem Isospring: 9/14" }, [4] = { 5, 5, "Flask of Oil: 5/5", true } }, caption = "three objectives at one spot, item + target buttons" },
    { 5, "notready", caption = "turn-in that isn't finished" },
    { 6, "todo", caption = "turn-in" },
    { 7, "wait", minLevel = 19, caption = "needs a higher level" },
    { 7, "blocked", caption = "quest not in the log" },
    { 8, "todo", caption = "flight path" },
    { 9, "todo", caption = "fly to the next zone" },
    { 10, "todo", caption = "class trainer" },
    { 11, "todo", caption = "grind to an XP target" },
    { 12, "todo", caption = "bonus pickup (lore book)" },
    { nil, "done", caption = "route complete" },
  }
  return data
end

local function show(n)
  local sc = scenes[n]
  ns.Engine.view = nil
  ns.Engine.current = sc[1]
  Demo.scene = sc
  ns.Print(string.format("demo %d/%d: %s", n, #scenes, sc.caption))
  ns.Fire("FR_STEP", sc[1])
end

function Demo.Start()
  if Demo.active then return Demo.Stop() end
  saved = { data = ForeverRouteData, Status = ns.Engine.Status, ObjectiveFor = ns.Engine.ObjectiveFor, Compute = ns.Engine.Compute, Quest = ns.State.Quest }
  ForeverRouteData = build()
  Demo.active = true
  ns.Engine.Compute = function() return ns.Engine.current end
  ns.Engine.Status = function(i)
    local sc = Demo.scene
    if not sc or not sc[1] then return "done" end
    if i < sc[1] then return "done" end
    if i == sc[1] then return sc[2] end
    return "todo"
  end
  ns.Engine.ObjectiveFor = function(s)
    local sc = Demo.scene; local i
    for k, t in ipairs(ForeverRouteData.steps) do if t == s then i = k end end
    local o = sc and sc.obj and sc.obj[i]
    if o then return { have = o[1], need = o[2], text = o[3], finished = o[4] or o[1] >= o[2] } end
  end
  ns.State.Quest = function(id) return { on = true, objectives = { { text = "Goretusk Liver: 3/8", finished = false } } } end
  for _, s in ipairs(ForeverRouteData.steps) do if s.k == "accept" and s.q == 7 then s.minLevel = 19 end end
  idx = 1; show(idx)
  ticker = C_Timer.NewTicker(5, function() idx = idx % #scenes + 1; show(idx) end)
  ns.Print("demo running - screenshots welcome (Print Screen). /fr demo again to stop.")
end

function Demo.Stop()
  if ticker then ticker:Cancel(); ticker = nil end
  ForeverRouteData = saved.data
  ns.Engine.Status, ns.Engine.ObjectiveFor, ns.Engine.Compute, ns.State.Quest = saved.Status, saved.ObjectiveFor, saved.Compute, saved.Quest
  Demo.active, Demo.scene = false, nil
  ns.Engine.Refresh()
  ns.Print("demo stopped.")
end
