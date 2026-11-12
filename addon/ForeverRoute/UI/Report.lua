-- /fr report: everything needed to replay what a player sees, as one block of text to copy and paste (Discord, a
-- GitHub issue). A readable first line, then the data packed as bytes and base64'd: numbers as variable-length
-- bytes, completed quest ids as gaps between sorted ids. tools/report.js decodes it into a save the replay tools load.
-- Anonymous by design: no character name, realm or account.
-- Short form (fits a Discord message) leaves out the completed quests; Full adds them.
local _, ns = ...
local Report = {}
ns.Report = Report
local Style = ns.Style
local C = Style.C

Report.FORMAT = 1
-- sections: tag byte, then a varint byte length, then the body - a decoder skips tags it doesn't know
-- (7: errors without version or time - an old report's; 10 and 11 replace it)
local T = { meta = 1, log = 2, completed = 3, taxi = 4, ticks = 5, why = 6, errors = 11, card = 8, settings = 9, where = 10 }
Report.TAGS = T
-- why a step before the card's was passed over
local REASON = { done = 1, todo = 2, blocked = 3, wait = 4, notready = 5, later = 6, skip = 7, tick = 8, nope = 9,
  outlevel = 10, gray = 11, crumb = 12, behind = 13, unavail = 14 }
Report.REASON = REASON

---------------------------------------------------------------------------------------------------------------
-- bytes
local function buf() return {} end
local function byte(b, v) b[#b + 1] = v % 256 end
local function varint(b, n)
  n = math.floor(tonumber(n) or 0); if n < 0 then n = 0 end
  while n >= 128 do byte(b, 128 + n % 128); n = math.floor(n / 128) end
  byte(b, n)
end
local function sint(b, n) n = math.floor(tonumber(n) or 0); varint(b, n >= 0 and n * 2 or -n * 2 - 1) end
local function str(b, s, max)
  s = tostring(s or ""); if max and #s > max then s = s:sub(1, max) end
  varint(b, #s); for i = 1, #s do b[#b + 1] = s:byte(i) end
end
local function section(out, tag, body)
  if #body == 0 then return end
  byte(out, tag); varint(out, #body); for i = 1, #body do out[#out + 1] = body[i] end
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_" -- url-safe: no + or / to trip chat
local function b64(bytes)
  local out, n = {}, #bytes
  for i = 1, n, 3 do
    local a, b, c = bytes[i], bytes[i + 1] or 0, bytes[i + 2] or 0
    local v = a * 65536 + b * 256 + c
    local d1, d2, d3, d4 = math.floor(v / 262144) % 64, math.floor(v / 4096) % 64, math.floor(v / 64) % 64, v % 64
    out[#out + 1] = B64:sub(d1 + 1, d1 + 1) .. B64:sub(d2 + 1, d2 + 1)
    if i + 1 <= n then out[#out + 1] = B64:sub(d3 + 1, d3 + 1) end
    if i + 2 <= n then out[#out + 1] = B64:sub(d4 + 1, d4 + 1) end
  end
  return table.concat(out)
end
Report.B64 = b64

---------------------------------------------------------------------------------------------------------------
-- what goes in
local function reasonOf(i, s)
  local E, St, key = ns.Engine, ns.State, ns.Engine.Key(i)
  if ns.char.skipped[key] then return REASON.skip end
  if ns.char.manualDone[key] then return REASON.tick end
  if s.q and ns.char.nope and ns.char.nope[s.q] then return REASON.nope end
  if s.q and ns.Avail and ns.Avail.Unavailable(s.q) and not St.OnQuest(s.q) and not St.IsCompleted(s.q) then return REASON.unavail end
  if E.Outlevelled(s) then return REASON.outlevel end
  if E.GrayHandIn(s) then return REASON.gray end
  if E.Breadcrumbed(s) then return REASON.crumb end
  if E.BehindYou and E.BehindYou(s) then return REASON.behind end
  return REASON[E.Status(i)] or 0
end

-- the report's data, gathered fresh (a table: Report.Pack turns it into text; the tests check both halves)
function Report.Gather(full)
  -- a fresh read, without replacing the snapshot the companion plans from (a report run where the game gives no
  -- coordinates once left the save with no position: the live check and the planner had nothing to start from)
  local kept = ns.char.snapshot
  ns.State.Snapshot("report")
  local sn = ns.char.snapshot or {}
  ns.char.snapshot = kept
  local d = { full = full and true or false }
  local data = ForeverRouteData
  local pk = ns.planKey or {}
  local stamp = pk.starter and type(ForeverRouteStarterStamp) == "table" and ForeverRouteStarterStamp[pk.starter]
  local cur = ns.Engine.Shown and ns.Engine.Shown()
  local s = cur and data and data.steps and data.steps[cur]
  d.meta = {
    version = ns.VERSION, client = select(4, GetBuildInfo()), time = time(),
    race = sn.race, class = sn.class, faction = sn.faction, level = sn.level, xp = sn.xp, xpMax = sn.xpMax,
    map = sn.pos and sn.pos.map, x = sn.pos and sn.pos.x, y = sn.pos and sn.pos.y, bind = sn.bind,
    plan = pk.starter and ("built-in " .. pk.starter) or (pk.found and "own") or "none",
    stamp = stamp or (ForeverRoutePlan and ForeverRoutePlan.generated and ("generated " .. ForeverRoutePlan.generated)) or "",
    route = ns.char.routeTitle or (data and data.id) or "", current = cur or 0, steps = data and data.steps and #data.steps or 0,
    step = s and string.format("%s %s", tostring(s.k), tostring(s.name or s.text or s.npc or s.dest or "")) or "",
    stepQ = s and s.q or 0, stepKey = cur and ns.Engine.Key(cur) or "",
  }
  d.log = sn.log or {}
  d.completed = full and (sn.completed or {}) or {}
  d.taxi = sn.taxi or {}
  d.ticks = { skipped = {}, manualDone = {}, nope = {} }
  for k in pairs(ns.char.skipped or {}) do d.ticks.skipped[#d.ticks.skipped + 1] = k end
  for k in pairs(ns.char.manualDone or {}) do d.ticks.manualDone[#d.ticks.manualDone + 1] = k end
  for q in pairs(ns.char.nope or {}) do if tonumber(q) then d.ticks.nope[#d.ticks.nope + 1] = tonumber(q) end end
  table.sort(d.ticks.skipped); table.sort(d.ticks.manualDone); table.sort(d.ticks.nope)
  -- the card: why each of the steps just before it was passed over
  d.card = {}
  if cur and data and data.steps then
    for i = math.max(1, cur - 25), cur - 1 do
      local t = data.steps[i]
      if t then d.card[#d.card + 1] = { i = i, r = reasonOf(i, t), k = t.k, q = t.q or 0 } end
    end
  end
  local why = (ForeverRouteDB and ForeverRouteDB.why) or {}
  d.why = {}
  for i = math.max(1, #why - (full and 30 or 12) + 1), #why do local w = why[i]; if w then d.why[#d.why + 1] = w end end
  -- errors seen in the last week, newest first (the log keeps every error ever, deduplicated: the last three entries
  -- were once version 0.3.0's, long fixed)
  d.errors = {}
  local log, now = (ForeverRouteDB and ForeverRouteDB.log) or {}, time()
  -- (from the version you run, or seen in the last day: an old install's errors are noise)
  for _, e in ipairs(log) do
    local age = now - (e.last or e.first or 0)
    if age < 7 * 86400 and (e.version == ns.VERSION or age < 86400) then d.errors[#d.errors + 1] = e end
  end
  table.sort(d.errors, function(a, b) return (a.last or a.first or 0) > (b.last or b.first or 0) end)
  while #d.errors > 3 do table.remove(d.errors) end
  -- where you are when the game gives no coordinates (on a flight, indoors in some places, loading): the map it does
  -- give, and why
  local best = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  d.where = { map = best or 0, taxi = ns.Is(UnitOnTaxi, "player"), indoors = ns.Is(IsIndoors), dead = ns.Is(UnitIsDeadOrGhost, "player"),
    instance = ns.Is(IsInInstance) or (ns.Dungeon and ns.Dungeon.Here() ~= nil) or false, mounted = ns.Is(IsMounted), coords = sn.pos ~= nil }
  d.settings = { pathLine = ns.db.pathLine ~= false, pins = ns.db.pins ~= false, hideDone = ns.db.hideDone ~= false, markTarget = ns.db.markTarget ~= false }
  return d
end

local KINDS = { "accept", "turnin", "obj", "fly", "fp", "hearth", "train", "bind", "goto", "grind", "bonus", "special" }
local KIND = {}; for i, k in ipairs(KINDS) do KIND[k] = i end
Report.KINDS = KINDS

-- the data as text: "FR report 1.2.2 | built-in gnome-warlock | lvl 30 | Hillsbrad Foothills 50.5,51.8 | step 7 ..."
-- then "FR1." and the packed data
function Report.Pack(d)
  local m = d.meta
  local out = buf()
  local b = buf()
  str(b, m.version); str(b, m.client); varint(b, m.time); str(b, m.race); str(b, m.class); str(b, m.faction)
  varint(b, m.level); varint(b, m.xp); varint(b, m.xpMax); varint(b, m.map)
  varint(b, (m.x or 0) * 10000 + 0.5); varint(b, (m.y or 0) * 10000 + 0.5); str(b, m.bind, 40)
  str(b, m.plan, 60); str(b, m.stamp, 80); str(b, m.route, 400); varint(b, m.current); varint(b, m.steps)
  str(b, m.step, 80); varint(b, m.stepQ); str(b, m.stepKey, 80)
  section(out, T.meta, b)
  b = buf()
  local ids = {}; for id in pairs(d.log) do ids[#ids + 1] = id end; table.sort(ids)
  varint(b, #ids)
  for _, id in ipairs(ids) do
    local q = d.log[id]
    varint(b, id); byte(b, q.complete and 1 or 0)
    local objs = q.objectives or {}
    varint(b, #objs)
    for _, o in ipairs(objs) do varint(b, o[1]); varint(b, o[2]); byte(b, o[3] and 1 or 0) end
  end
  section(out, T.log, b)
  b = buf()
  local done = {}; for _, id in ipairs(d.completed) do done[#done + 1] = id end; table.sort(done)
  varint(b, #done); local last = 0
  for _, id in ipairs(done) do varint(b, id - last); last = id end
  section(out, T.completed, b)
  b = buf(); varint(b, #d.taxi); for _, n in ipairs(d.taxi) do str(b, n, 60) end
  section(out, T.taxi, b)
  b = buf()
  for _, list in ipairs({ d.ticks.skipped, d.ticks.manualDone }) do varint(b, #list); for _, k in ipairs(list) do str(b, k, 80) end end
  varint(b, #d.ticks.nope); for _, q in ipairs(d.ticks.nope) do varint(b, q) end
  section(out, T.ticks, b)
  b = buf(); varint(b, #d.card)
  for _, c in ipairs(d.card) do varint(b, c.i); byte(b, c.r); byte(b, KIND[c.k] or 0); varint(b, c.q) end
  section(out, T.card, b)
  b = buf(); varint(b, #d.why)
  for _, w in ipairs(d.why) do varint(b, w.t); str(b, w.k, 12); varint(b, w.lv); varint(b, w.m); str(b, w.x, d.full and 160 or 100) end
  section(out, T.why, b)
  b = buf(); varint(b, #d.errors)
  for _, e in ipairs(d.errors) do str(b, e.where, 20); varint(b, e.count); str(b, e.msg, 160); str(b, e.shown, 80); str(b, e.version, 12); varint(b, e.last or e.first) end
  section(out, T.errors, b)
  if d.where then
    b = buf(); varint(b, d.where.map)
    local wf = 0
    for i, k in ipairs({ "taxi", "indoors", "dead", "instance", "mounted", "coords" }) do if d.where[k] then wf = wf + 2 ^ (i - 1) end end
    varint(b, wf)
    section(out, T.where, b)
  end
  b = buf()
  local flags = 0
  for i, k in ipairs({ "pathLine", "pins", "hideDone", "markTarget" }) do if d.settings[k] then flags = flags + 2 ^ (i - 1) end end
  varint(b, flags)
  section(out, T.settings, b)
  local shownMap = (m.map and m.map > 0 and m.map) or (d.where and d.where.map)
  local zone = shownMap and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(shownMap)
  local head = string.format("FR report %s | %s | %s %s lvl %s | %s %.1f,%.1f | step %s: %s",
    tostring(m.version), tostring(m.plan), tostring(m.race), tostring(m.class), tostring(m.level),
    zone and zone.name or tostring(shownMap or "?"), (m.x or 0) * 100, (m.y or 0) * 100, tostring(m.current), tostring(m.step))
  return head .. "\nFR" .. Report.FORMAT .. "." .. b64(out)
end

---------------------------------------------------------------------------------------------------------------
-- reading one back (the tests; the same format as tools/report.js)
function Report.Unpack(text)
  local data = tostring(text or ""):match("FR%d+%.([%w%-_]+)")
  if not data then return nil end
  local val = {}; for i = 1, #B64 do val[B64:sub(i, i)] = i - 1 end
  local bytes = {}
  for i = 1, #data, 4 do
    local c = { val[data:sub(i, i)] or 0, val[data:sub(i + 1, i + 1)] or 0, val[data:sub(i + 2, i + 2)], val[data:sub(i + 3, i + 3)] }
    local v = c[1] * 262144 + c[2] * 4096 + (c[3] or 0) * 64 + (c[4] or 0)
    bytes[#bytes + 1] = math.floor(v / 65536) % 256
    if c[3] then bytes[#bytes + 1] = math.floor(v / 256) % 256 end
    if c[4] then bytes[#bytes + 1] = v % 256 end
  end
  local p = 1
  local function rb() local v = bytes[p]; p = p + 1; return v or 0 end
  local function rv() local n, mul = 0, 1; while true do local x = rb(); n = n + (x % 128) * mul; if x < 128 then return n end; mul = mul * 128 end end
  local function rs() local len = rv(); local t = {}; for i = 1, len do t[i] = string.char(rb()) end; return table.concat(t) end
  local d = { sections = {} }
  while p <= #bytes do
    local tag, len = rb(), rv()
    local stop = p + len
    d.sections[#d.sections + 1] = tag
    if tag == T.meta then
      d.meta = { version = rs(), client = rs(), time = rv(), race = rs(), class = rs(), faction = rs(), level = rv(), xp = rv(), xpMax = rv(), map = rv(),
        x = rv() / 10000, y = rv() / 10000, bind = rs(), plan = rs(), stamp = rs(), route = rs(), current = rv(), steps = rv(), step = rs(), stepQ = rv(), stepKey = rs() }
    elseif tag == T.log then
      d.log = {}
      for _ = 1, rv() do local id = rv(); local q = { complete = rb() == 1, objectives = {} }; for k = 1, rv() do q.objectives[k] = { rv(), rv(), rb() == 1 } end; d.log[id] = q end
    elseif tag == T.completed then
      d.completed = {}; local last = 0
      for k = 1, rv() do last = last + rv(); d.completed[k] = last end
    elseif tag == T.taxi then
      d.taxi = {}; for k = 1, rv() do d.taxi[k] = rs() end
    elseif tag == T.card then
      d.card = {}; for k = 1, rv() do d.card[k] = { i = rv(), r = rb(), k = KINDS[rb()], q = rv() } end
    end
    p = stop
  end
  return d
end

---------------------------------------------------------------------------------------------------------------
-- the window: the text selected, ready for Ctrl+C
local f
local function build()
  f = CreateFrame("Frame", "ForeverRouteReport", UIParent)
  f:SetSize(520, 300); f:SetPoint("CENTER", 0, 60); f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true); f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
  Style.Panel(f, C.bg2)
  table.insert(UISpecialFrames, "ForeverRouteReport")
  f.title = Style.Text(f, 15, C.gold, "OUTLINE"); f.title:SetPoint("TOPLEFT", 14, -12); f.title:SetText("Bug report")
  local close = Style.Button(f, "x", 18, 18, function() f:Hide() end, "Close"); close:SetPoint("TOPRIGHT", -8, -8)
  f.help = Style.Text(f, 11, C.sub); f.help:SetPoint("TOPLEFT", 14, -34); f.help:SetWidth(492)
  f.help:SetText("Press Ctrl+C to copy, then paste it with a screenshot. No character name, realm or account is in it.")
  f.full = Style.Button(f, "Full", 60, 20, function() Report.Show(not f.isFull) end, "Full: adds your finished quests, for an exact replay (too long for one Discord message)")
  f.full:SetPoint("TOPRIGHT", close, "TOPLEFT", -6, 0)
  local sf = CreateFrame("ScrollFrame", "ForeverRouteReportScroll", f, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 14, -56); sf:SetPoint("BOTTOMRIGHT", -32, 30)
  f.edit = CreateFrame("EditBox", nil, sf)
  f.edit:SetMultiLine(true); f.edit:SetAutoFocus(true); f.edit:SetFontObject(ChatFontNormal); f.edit:SetWidth(470)
  f.edit:SetScript("OnEscapePressed", function() f:Hide() end)
  -- read-only: typing puts the report back
  f.edit:SetScript("OnTextChanged", function(self, user) if user then self:SetText(f.text or ""); self:HighlightText() end end)
  sf:SetScrollChild(f.edit)
  f.size = Style.Text(f, 10, C.dim); f.size:SetPoint("BOTTOMLEFT", 14, 10)
end

function Report.Show(full)
  if not f then build() end
  local ok, text = pcall(function() return Report.Pack(Report.Gather(full)) end)
  if not ok then text = "FR report failed: " .. tostring(text) end
  f.text, f.isFull = text, full and true or false
  f.full.label:SetText(full and "Short" or "Full")
  f.edit:SetText(text); f:Show(); f.edit:SetFocus(); f.edit:HighlightText()
  f.size:SetText(string.format("%d characters%s", #text, full and " (full)" or (#text <= 1900 and " - fits a Discord message" or "")))
  return text
end

ns.On("FR_REPORT", function(full) Report.Show(full) end)
