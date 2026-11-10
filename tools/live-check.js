// The live check: the addon's code run in the simulator against YOUR real plan file and YOUR latest save, logging in
// the way the real game does - a fresh login with a realm name the planner never saw (Forever reports a layer like
// "CAMWOW US2 Realm 8 PvP", not the WTF folder), and with the name not known yet. Checks: your plan loads, never
// another character's, your path is in it, and at the spot you saved the card shows a step you haven't done, with
// arrow and pins agreeing and no error logged. The unit tests use made-up worlds; this is the one that uses yours.
// Run by tools/install.sh before every install and by the companion before every plan goes in.
// usage: node tools/live-check.js <character SavedVariables dir> [Route.lua to check] [addon source dir]
//   exit 0 = passed (or nothing to check: no save / no sim), 1 = your plan does not load right (blocks installs),
//   3 = only the check at the spot you saved failed (worth a look; does not block a fresh plan)
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { saveTestLua, readChar, lua } = require('./save-fixture');

const ROOT = path.join(__dirname, '..');
const [charDir, routeFile0, src0] = process.argv.slice(2);
if (!charDir) { console.log('usage: node tools/live-check.js <character SavedVariables dir> [Route.lua] [addon dir]'); process.exit(2); }
const routeFile = routeFile0 || path.join(ROOT, '..', 'Interface', 'AddOns', 'ForeverRoute', 'Route.lua');
const src = src0 || path.join(ROOT, 'addon', 'ForeverRoute');
const SIM = path.join(ROOT, 'sim', 'pkg', 'wow-ui-sim-v0.1.40-forever-windows-x86_64');
const skip = (why) => { console.log('live check skipped: ' + why); process.exit(0); };
if (!fs.existsSync(path.join(SIM, 'wow-sim.exe'))) skip('no simulator');
if (!fs.existsSync(routeFile)) skip('no plan file');
let c; try { c = readChar(charDir); } catch (e) { skip('no save in ' + charDir); }
// the character, from its save folder (".../<Name>-<Realm>/SavedVariables"): the planner names its block after it
const folder = path.basename(path.dirname(path.resolve(charDir))).replace(/\s/g, '');
const name = folder.split('-')[0];

const top = `
local LIVE = { name = ${lua(name)}, folder = ${lua(folder)} }
-- log in as the real game would: this name and realm, this character's own save (ForeverRouteChar), then load the plan
local function login(nm, realm, char)
  local sv = { un = UnitName, rn = GetRealmName, char = ForeverRouteChar }
  UnitName = function(u, ...) if u == "player" then return nm end return sv.un(u, ...) end
  GetRealmName = function() return realm end
  ForeverRouteChar = char
  ForeverRouteRoutes, ForeverRouteData, ForeverRoutePlan = nil, nil, nil
  local ok, r = pcall(ns.LoadMyPlan)
  UnitName, GetRealmName, ForeverRouteChar = sv.un, sv.rn, sv.char
  if not ok then error(r, 0) end
  return r, #ns.Routes()
end
test("live: the plan file holds a plan for " .. LIVE.folder, function()
  assertTrue(type(ForeverRouteByChar) == "table", "Route.lua did not load (no ForeverRouteByChar)")
  assertTrue(type(ForeverRouteByChar[LIVE.folder]) == "function", "no block for " .. LIVE.folder)
end)
test("live: another character never gets your plan", function()
  local ok, n = login("Someoneelse", "CAMWOW US2 Realm 8 PvP", {})
  -- nothing of yours: no plan, or the built-in one for its race and class (Starter.lua)
  assertTrue(not (ns.planKey and ns.planKey.found), "a character with another name loaded the plan " .. tostring(ns.planKey and ns.planKey.found))
  assertTrue((not ok and n == 0) or (ns.planKey and ns.planKey.starter), "a character with another name loaded a plan that isn't the built-in one")
end)
test("live: fresh login with a realm name the planner never saw (a layer): your plan loads", function()
  local ok, n = login(LIVE.name, "CAMWOW US2 Realm 41 PvP", {})
  assertTrue(ok, "no plan loaded"); assertTrue(n > 0, "the plan loaded but has no routes")
end)
test("live: the name isn't known yet at login: the key saved last time finds your plan", function()
  local ok, n = login("Unknown", "", { charKey = LIVE.name .. "-SomeRealmId" })
  assertTrue(ok and n > 0, "no plan loaded with the saved key")
end)
test("live: the plan this character matched before is used again on a new layer", function()
  local ok, n = login(LIVE.name, "Layer 3", { planBlock = LIVE.folder })
  assertTrue(ok and n > 0, "the remembered plan was not used")
end)`;
const text = saveTestLua(c, 'live', {
  title: 'live: your path at the spot you saved',
  top,
  prelude: '  local ok = login(LIVE.name, "CAMWOW US2 Realm 8 PvP", {}); assertTrue(ok, "no plan loaded")',
});
if (!text) skip('no snapshot with a position in the save (reload in game first)');

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'fr-live-'));
try {
  const dest = path.join(work, 'ForeverRoute');
  fs.cpSync(src, dest, { recursive: true, filter: (p) => !/[\\/]tests([\\/]|$)/.test(path.relative(src, p) ? '/' + path.relative(src, p) : '') });
  fs.copyFileSync(routeFile, path.join(dest, 'Route.lua'));
  fs.mkdirSync(path.join(dest, 'tests'), { recursive: true });
  const harness = [path.join(src, 'tests', '_harness.lua'), path.join(ROOT, 'addon', 'ForeverRoute', 'tests', '_harness.lua')].find((f) => fs.existsSync(f));
  fs.copyFileSync(harness, path.join(dest, 'tests', '_harness.lua'));
  fs.writeFileSync(path.join(dest, 'tests', 'live_test.lua'), text);
  fs.mkdirSync(path.join(work, 'wtf'), { recursive: true });
  // the results go to stderr as well as stdout: keep both
  const r = spawnSync(path.join(SIM, 'wow-sim.exe'), ['--allow-ui-version-mismatch', '--addons-path', work, '--session-wtf-path', path.join(work, 'wtf'),
    '--class', 'Warlock', '--race', 'Gnome', 'run-tests', 'ForeverRoute'],
  { cwd: SIM, env: { ...process.env, WOW_INSTALL_PATH: path.resolve(ROOT, '..', '..') }, encoding: 'utf8', timeout: 600000, maxBuffer: 1 << 26, stdio: ['ignore', 'pipe', 'pipe'] });
  let out = String(r.stdout || '') + '\n' + String(r.stderr || '') + (r.error ? '\n' + r.error.message : '');
  out = out.replace(/\x1b\[[0-9;]*m/g, '');
  if (process.env.FR_KEEP) fs.writeFileSync(path.join(work, 'out.txt'), out); // FR_KEEP=1: keep the work folder to look at
  const sum = (out.match(/^.*\d+ tests, \d+ passed, \d+ failed.*$/m) || [''])[0].trim();
  const bad = out.split('\n').filter((l) => /✗|live_test\.lua:\d+: [^i]|_harness\.lua:\d+:/.test(l)).slice(0, 12);
  console.log('live check (' + folder + ', ' + path.basename(routeFile) + '): ' + (sum || 'the simulator gave no result'));
  for (const l of bad) console.log('  ' + l.trim());
  const failed = out.split('\n').filter((l) => /✗/.test(l));
  const hard = failed.filter((l) => !/your path at the spot you saved/.test(l));
  process.exitCode = / 0 failed/.test(sum) ? 0 : (!sum || hard.length) ? 1 : 3;
} finally { if (process.env.FR_KEEP) console.log('kept ' + work); else fs.rmSync(work, { recursive: true, force: true }); }
