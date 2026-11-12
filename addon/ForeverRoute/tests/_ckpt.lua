-- Checkpoints for the simulated player (tools/simplay.js, tools/simckpt.js has the whole design): a persona's state at a
-- leg boundary written as a Lua chunk that rebuilds it, and read back. Loaded before _player.lua ("_c" sorts first).
--   CK.encode(root)       -> text, lost   a chunk that returns a copy of root: every table once (shared tables stay
--                                         shared: ns.char.skipped is ns.char.progress[route].skipped), strings, numbers
--                                         and booleans; lost lists what could not be written (functions, metatables...)
--   CK.decode(text)       -> root or nil, error
--   CK.subst(root, map)   values and keys equal to a key of map are replaced (the plan's stamp and path id)
--   CK.json(v)            a small JSON writer for the checkpoint's header line (Node reads it)
--   CK.write(path, meta, text)  the file: "-- META <json>", the chunk, "-- end" (written to .tmp, then renamed)
--   CK.read(path)         -> meta text, chunk text (nil when the file is incomplete)
local CK = {}

local function num(v)
  if v ~= v then return "(0/0)" end
  if v == 1 / 0 then return "(1/0)" end
  if v == -1 / 0 then return "(-1/0)" end
  if v == math.floor(v) and v > -1e15 and v < 1e15 then return string.format("%.0f", v) end
  return string.format("%.17g", v)
end
local function lit(v, ids)
  local t = type(v)
  if t == "string" then return string.format("%q", v) end
  if t == "number" then return num(v) end
  if t == "boolean" then return v and "true" or "false" end
  if t == "table" then return "T[" .. ids[v] .. "]" end
  return nil
end

function CK.encode(root)
  local ids, list, lost = {}, {}, {}
  local function visit(t, path)
    if ids[t] then return end
    if getmetatable(t) ~= nil then lost[#lost + 1] = path .. " (has a metatable)" end
    list[#list + 1] = t; ids[t] = #list
    for k, v in pairs(t) do
      local kt, vt = type(k), type(v)
      local p = path .. "." .. tostring(k)
      if kt ~= "string" and kt ~= "number" and kt ~= "boolean" then lost[#lost + 1] = p .. " (" .. kt .. " key)"
      elseif vt == "table" then visit(v, p)
      elseif vt ~= "string" and vt ~= "number" and vt ~= "boolean" then lost[#lost + 1] = p .. " (" .. vt .. ")" end
    end
  end
  visit(root, "")
  -- one function per table: Lua 5.1 allows 2^18 constants per function, so no single function holds them all
  -- (every statement ends in ";": a line starting with "(" would otherwise call the one before)
  local out = { "local T = {};", "for i = 1, " .. #list .. " do T[i] = {} end;" }
  for n, t in ipairs(list) do
    local parts = { "(function() local t = T[" .. n .. "];" }
    for k, v in pairs(t) do
      local ks, vs = lit(k, ids), lit(v, ids)
      if ks and vs and type(k) ~= "table" then parts[#parts + 1] = "t[" .. ks .. "] = " .. vs .. ";" end
    end
    parts[#parts + 1] = "end)();"
    out[#out + 1] = table.concat(parts, "\n")
  end
  out[#out + 1] = "return T[1]"
  return table.concat(out, "\n"), lost
end

function CK.decode(text)
  local f, err = loadstring(text, "=checkpoint")
  if not f then return nil, err end
  -- (the chunk uses no globals; the simulator's own wrapping of loaded code does, so it keeps the usual environment)
  local ok, v = pcall(f)
  if not ok then return nil, v end
  if type(v) ~= "table" then return nil, "not a table" end
  return v
end

function CK.subst(root, map)
  if not next(map) then return root end
  local seen = {}
  local function walk(t)
    if seen[t] then return end
    seen[t] = true
    local rekey = {}
    for k, v in pairs(t) do
      if type(v) == "table" then walk(v) elseif map[v] ~= nil then t[k] = map[v] end
      if map[k] ~= nil then rekey[#rekey + 1] = k end
    end
    for _, k in ipairs(rekey) do local v = t[k]; t[k] = nil; t[map[k]] = v end
  end
  walk(root)
  return root
end

function CK.json(v)
  local t = type(v)
  if t == "number" then if v ~= v or v == 1 / 0 or v == -1 / 0 then return "null" end return num(v) end
  if t == "boolean" then return v and "true" or "false" end
  if t == "string" then
    return '"' .. v:gsub('[%c"\\]', function(c) local b = c:byte(); if c == '"' or c == "\\" then return "\\" .. c end return string.format("\\u%04x", b) end) .. '"'
  end
  if t ~= "table" then return "null" end
  if #v > 0 or next(v) == nil then
    local parts = {}
    for i = 1, #v do parts[i] = CK.json(v[i]) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = CK.json(k) .. ":" .. CK.json(v[k]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

function CK.write(path, meta, text)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "wb")
  if not f then return false end
  f:write("-- META ", CK.json(meta), "\n", text, "\n-- end\n")
  f:close()
  os.remove(path)
  return os.rename(tmp, path) and true or false
end

function CK.read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local all = f:read("*a")
  f:close()
  local meta, body = all:match("^%-%- META ([^\n]*)\n(.*)\n%-%- end\n$")
  return meta, body
end

ForeverRouteCkpt = CK
