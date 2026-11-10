-- Replayed save "error_learn_Interface_AddOns_ForeverRoute_Lear_1794195222": Testchar level 24, 2026-11-09T03:33:20.000Z (logout).
-- Written by tools/save-fixture.js. Add expectations below if you know what the card should have shown.
local ns = ForeverRoute
local save = {
  level = 24, m = 1455, x = 0.5013863326498941, y = 0.1075782899936513,
  route = "path:Darkshore-Ashenvale-RedridgeMountains-Wetlands-Duskwood",
  completed = { 5, 9, 12, 13, 19, 20, 22, 34, 35, 36, 40, 64, 65, 89, 91, 94, 103, 104, 109, 115, 118, 119, 120, 121, 125, 127, 128, 129, 130, 131, 132, 135, 141, 142, 151, 152, 153, 155, 163, 166, 167, 168, 169, 170, 176, 178, 179, 180, 182, 183, 214, 218, 219, 224, 233, 234, 237, 244, 246, 248, 249, 263, 267, 282, 287, 291, 307, 310, 311, 313, 314, 315, 317, 318, 319, 320, 343, 373, 384, 389, 399, 400, 412, 413, 414, 416, 417, 418, 419, 420, 432, 433, 436, 971, 1097, 1198, 1199, 1200, 1338, 1599, 1688, 1689, 1715, 1716, 1738, 1739, 2040, 2160, 3115, 3361, 3364, 3365, 3741, 5541, 6387, 6388, 6391, 6392, 65602, 65603, 79008, 86667, 91723, 92744, 92909, 95041, 95213, 95214, 95998, 95999, 96056, 96057, 96101, 96102, 96139, 96390, 96391, 96392, 96393, 96394, 96395, 96403, 96408, 96604, 96605, 96606, 96607, 96608, 96626, 96627, 96628, 96629, 96630, 96634, 96638, 96646, 96652, 96655, 96656, 96658, 96659, 96661, 97234, 97237, 97277, 97894, 97908, 97924, 97925, 97936, 97937, 97949, 97950, 97960, 97961, 97971, 97972, 97973, 98247, 98248, 98319, 98321, 98322, 98323, 98326, 98386, 98387, 98407, 98423, 99158, 99159, 99160, 99161, 99162, 99582 },
  log = {
    [56] = { complete = false, objectives = { { have = 0, need = 8, finished = false, text = "0/8 Skeletal Warrior slain" }, { have = 0, need = 6, finished = false, text = "0/6 Skeletal Mage slain" } } },
    [143] = { complete = true, objectives = { { have = 1, need = 1, finished = true, text = "Magistrate Solomon wants you to take his written plea to Gryan Stoutmantle in Westfall." } } },
    [164] = { complete = true, objectives = { { have = 1, need = 1, finished = true, text = "Deliver the supplies to Sven." } } },
    [165] = { complete = true, objectives = {  } },
    [344] = { complete = true, objectives = {  } },
    [353] = { complete = true, objectives = { { have = 1, need = 1, finished = true, text = "Deliver the Package for Stormpike to Mountaineer Stormpike in Loch Modan." } } },
    [391] = { complete = false, objectives = { { have = 0, need = 1, finished = false, text = "0/1 Head of Bazil Thredd" } } },
    [982] = { complete = false, objectives = { { have = 0, need = 1, finished = false, text = "0/1 Silver Dawning's Lockbox" }, { have = 0, need = 1, finished = false, text = "0/1 Mist Veil's Lockbox" } } },
    [991] = { complete = true, objectives = {  } },
    [1008] = { complete = false, objectives = { { have = 0, need = 20, finished = false, text = "0/20 Wrathtail Head" } } },
    [1054] = { complete = false, objectives = { { have = 0, need = 1, finished = false, text = "0/1 Dal Bloodclaw's Skull" } } },
    [1056] = { complete = true, objectives = {  } },
    [1070] = { complete = true, objectives = {  } },
    [1275] = { complete = false, objectives = { { have = 5, need = 8, finished = false, text = "5/8 Corrupted Brain Stem" } } },
    [1740] = { complete = false, objectives = { { have = 3, need = 3, finished = true, text = "3/3 Soran'ruk Fragment" }, { have = 0, need = 1, finished = false, text = "0/1 Large Soran'ruk Fragment" } } },
    [79192] = { complete = true, objectives = {  } },
    [96047] = { complete = true, objectives = { { have = 1, need = 1, finished = true, text = "Raise your first aid skill to 20" } } },
    [96050] = { complete = false, objectives = { { have = 1, need = 1, finished = false, text = "Raise your fishing skill to 20" } } },
  },
}

test("replayed save error_learn_Interface_AddOns_ForeverRoute_Lear_1794195222: card, arrow and pins agree, and the step shown is not one you have already done", function()

  local quests = {}
  for _, id in ipairs(save.completed) do quests[id] = { on = false, done = true, objectives = {} } end
  for id, q in pairs(save.log) do quests[id] = { on = true, complete = q.complete, objectives = q.objectives } end
  local route = (save.route and ns.ResolvePath and ns.ResolvePath(save.route)) or ns.MainRoutes()[1]
  assertNotNil(route, "no route to replay on")
  ForeverRouteTest.withWorld(route, function(w)
    local i = w:shown()
    assertNotNil(i, "no step shown for this save")
    local s = ns.Steps(route)[i]
    local q = s and s.q and quests[s.q]
    if s and q then
      if s.k == "accept" then assertTrue(not (q.done or q.on), "the card asks you to pick up a quest you already have or did (step " .. i .. ")") end
      if s.k == "turnin" or s.k == "obj" then assertTrue(not q.done, "the card shows a step of a quest you already handed in (step " .. i .. ")") end
    end
  end, { anyTarget = true, at = { m = save.m, x = save.x, y = save.y, level = save.level, quests = quests } })

end)
