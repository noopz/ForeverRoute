// Turn a character's save into a test: when something looks wrong in game, save (reload or log out), run this, and
// the moment becomes tests/save_<name>_test.lua - your position, level, quest log (with objective progress) and done
// quests, replayed through the addon's test harness. The test checks what must always hold: card, arrow and pins agree,
// the step shown is not one you have already done (a done hand-in, a pick-up of a quest done or in your log), and the
// addon logs no error while it runs. Add your own expectation to the generated file if you know what the card should
// have shown. The live check (tools/live-check.sh) builds its test with saveTestLua too.
// usage: node tools/save-fixture.js <character SavedVariables dir or ForeverRoute.lua> <name>
const fs = require('fs');
const path = require('path');
const { parseSavedVariables } = require('./luatable');

const lua = (v) => (typeof v === 'string' ? JSON.stringify(v) : typeof v === 'boolean' || typeof v === 'number' ? String(v) : 'nil');
function readChar(src) {
  const file = fs.statSync(src).isDirectory() ? path.join(src, 'ForeverRoute.lua') : src;
  return parseSavedVariables(fs.readFileSync(file, 'utf8')).ForeverRouteChar || {};
}
// the test file's text (null without a snapshot with a position). opts: title, top (Lua after the save table),
// prelude (Lua run first inside the test), after (Lua run last inside the test)
function saveTestLua(c, name, opts = {}) {
  const s = c.snapshot;
  if (!s || !s.pos) return null;
  const L = [];
  L.push(`-- Replayed save "${name}": ${s.name || '?'} level ${s.level}, ${new Date((s.time || 0) * 1000).toISOString()} (${s.reason || 'save'}).`);
  L.push('-- Written by tools/save-fixture.js. Add expectations below if you know what the card should have shown.');
  L.push('local ns = ForeverRoute');
  L.push('local save = {');
  L.push(`  level = ${lua(s.level)}, m = ${lua(s.pos.map)}, x = ${lua(s.pos.x)}, y = ${lua(s.pos.y)},`);
  L.push(`  route = ${lua(c.routeTitle || s.routeId)},`);
  L.push('  completed = { ' + (s.completed || []).join(', ') + ' },');
  L.push('  log = {');
  for (const [id, q] of Object.entries(s.log || {})) {
    const objs = (q.objectives || []).map((o) => `{ have = ${lua(o[0])}, need = ${lua(o[1])}, finished = ${lua(!!o[2])}, text = ${lua(o[3] || '')} }`);
    L.push(`    [${id}] = { complete = ${lua(!!q.complete)}, objectives = { ${objs.join(', ')} } },`);
  }
  L.push('  },');
  L.push('}');
  if (opts.top) L.push(opts.top);
  L.push(`
test("${opts.title || 'replayed save ' + name}: card, arrow and pins agree, and the step shown is not one you have already done", function()
${opts.prelude || ''}
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
${opts.after || ''}
end)
`);
  return L.join('\n');
}
module.exports = { saveTestLua, readChar, lua };

if (require.main === module) {
  const [src, name0] = process.argv.slice(2);
  if (!src || !name0) { console.log('usage: node tools/save-fixture.js <character SavedVariables dir or ForeverRoute.lua> <name>'); process.exit(2); }
  const name = name0.replace(/[^A-Za-z0-9_]+/g, '_');
  const c = readChar(src);
  const text = saveTestLua(c, name);
  if (!text) { console.log('no snapshot with a position in ' + src + ' (reload or log out in game first)'); process.exit(1); }
  const out = path.join(__dirname, '..', 'addon', 'ForeverRoute', 'tests', `save_${name}_test.lua`);
  fs.writeFileSync(out, text);
  const s = c.snapshot;
  console.log(`wrote ${out}: level ${s.level}, ${Object.keys(s.log || {}).length} quests in the log, ${(s.completed || []).length} done`);
}
