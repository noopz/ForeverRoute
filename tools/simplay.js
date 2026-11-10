// The simulated player on a whole plan (addon tests/_player.lua): the real addon code in the simulator plays every
// step of a path the way a player would, as several personas (clean, skip, fast, slow, die, reload, secret), and
// reports what it ran into: steps it had to click done, steps that came back, getting stuck, backtracking, travel,
// where the time went (profile), and any check that failed (card / arrow / pin disagreeing, an error the addon logged).
// Each persona writes a progress log as it plays (reports/simplay-logs/<persona>.log); a watchdog stops the simulator
// when no log has grown for FR_STALL seconds (default 60) and the report shows where each one was.
// Report: reports/simplay.md.
// usage: node tools/simplay.js [plan] [personas] [steps]
//   plan      starter:<race>-<class> (the built-in plan, default starter:gnome-warlock) or char:<save folder name>
//             (that character's plan in the installed Route.lua, e.g. char:Testchar-Testrealm)
//   personas  comma list (default clean,skip,fast,slow,die,reload,secret)
//   steps     play at most this many steps (default all)
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const ROOT = path.join(__dirname, '..');
const SIM = path.join(ROOT, 'sim', 'pkg', 'wow-ui-sim-v0.1.40-forever-windows-x86_64');
const src = path.join(ROOT, 'addon', 'ForeverRoute');
const [plan = 'starter:gnome-warlock', personaArg = 'clean,skip,fast,slow,die,reload,secret', stepsArg] = process.argv.slice(2);
const personas = personaArg.split(',').filter(Boolean);
const [kind, key] = plan.split(':');
const lua = (v) => JSON.stringify(v);
// the sim plays the plan's race and class (a built-in plan's key: human-paladin), else a gnome warlock. The simulator
// has no Skyborne: a night elf stands in (the plan is loaded by its key, so only the model differs)
const SIM_RACE = { human: 'Human', dwarf: 'Dwarf', gnome: 'Gnome', nightelf: 'NightElf', skyborne: 'NightElf' }, SIM_CLASS = { warrior: 'Warrior', paladin: 'Paladin', hunter: 'Hunter', rogue: 'Rogue', priest: 'Priest', mage: 'Mage', warlock: 'Warlock', druid: 'Druid', shaman: 'Shaman' };
const [kRace, kClass] = kind === 'starter' ? key.split('-') : [];
const simRace = SIM_RACE[kRace] || 'Gnome', simClass = SIM_CLASS[kClass] || 'Warlock';
const STALL_SEC = +(process.env.FR_STALL || 60);
// FR_SIMPLAY_LOGS: a folder of its own (batches running side by side all write reports/simplay-logs)
// by default a folder per plan: batches side by side each deleted and rewrote the same clean.log... - one run's stall
// watchdog then saw its logs stop growing and stopped it as hung (a false alarm), and the reports mixed plans
const LOGS = process.env.FR_SIMPLAY_LOGS ? path.resolve(process.env.FR_SIMPLAY_LOGS) : path.join(ROOT, 'reports', 'simplay-logs', (plan || 'plan').replace(/[^A-Za-z0-9_-]+/g, '_'));
fs.mkdirSync(LOGS, { recursive: true });
const logOf = (p) => path.join(LOGS, p + '.log');
// how the plan is loaded in the sim, and which path is played
const load = kind === 'char'
  ? `ForeverRouteRoutes = nil; ForeverRouteData = nil
     assert(ForeverRouteByChar and ForeverRouteByChar[${lua(key)}], "no plan for ${key} in Route.lua")()
     ForeverRouteByChar[ns.CharKey()] = ForeverRouteByChar[${lua(key)}] -- the sim's character plays as you (a /reload finds your plan)`
  : `ForeverRouteRoutes = nil; ForeverRouteData = nil
     assert(ForeverRouteStarter and ForeverRouteStarter[${lua(key)}], "no built-in plan ${key}")()`;
const testOf = personas.map((p, n) => `
test("simulated player (${p}) on ${plan}", function()
  local sv = { routes = ForeverRouteRoutes, data = ForeverRouteData, plan = ForeverRoutePlan }
  ${load}
  local route
  for _, r in ipairs(ForeverRouteRoutes or {}) do if tostring(r.id):find("^path:") then route = r; break end end
  assert(route, "no path in the plan")
  local res = ForeverRoutePlayer.play(route, { persona = ${lua(p)}, seed = ${n + 1}, to = ${stepsArg ? +stepsArg : 'nil'}, logFile = ${lua(logOf(p))} })
  ForeverRouteRoutes, ForeverRouteData, ForeverRoutePlan = sv.routes, sv.data, sv.plan
  -- the report goes out as this test's message (the simulator shows a failing test's message in full; print goes to chat)
  local lines = {}
  for line in (ForeverRoutePlayer.summary(res, ${lua(p)}) .. "\\n"):gmatch("(.-)\\n") do lines[#lines + 1] = "SIMPLAY " .. line end
  error("SIMPLAY-REPORT\\n" .. table.concat(lines, "\\n"), 0)
end)`);

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'fr-play-'));
// FR_SIM_CACHE=1: a run that already passed is reused - keyed on exactly what it tests (the plan file, every addon file
// the sim loads, the bot, the personas). After a QuestieDB update only the plans that changed are played again.
const SIMCACHE = path.join(ROOT, 'reports', 'simplay-cache');
const simKey = (() => {
  if (!process.env.FR_SIM_CACHE || kind !== 'starter') return null;
  const h = require('crypto').createHash('sha1');
  const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else if (/\.(lua|toc|xml)$/.test(e.name)) { h.update(e.name); h.update(fs.readFileSync(p)); } } };
  walk(src);
  h.update(fs.readFileSync(path.join(ROOT, 'addon', 'ForeverRoute_Starter_' + key.replace(/-/g, '_'), 'Plan.lua')));
  h.update(personaArg + '|' + (stepsArg || ''));
  return h.digest('hex').slice(0, 24);
})();
if (simKey && fs.existsSync(path.join(SIMCACHE, simKey + '.md'))) {
  const prev = fs.readFileSync(path.join(SIMCACHE, simKey + '.md'), 'utf8');
  console.log(prev.replace(/^(# Simulated player on .*)$/m, '$1\n\n(reused: the same plan and addon already passed this run)'));
  process.exit(0);
}
(async () => {
  try {
    const dest = path.join(work, 'ForeverRoute');
    fs.cpSync(src, dest, { recursive: true, filter: (p) => !/[\\/]tests([\\/]|$)/.test(path.relative(src, p) ? '/' + path.relative(src, p) : '') });
    if (kind === 'char') fs.copyFileSync(path.join(ROOT, '..', 'Interface', 'AddOns', 'ForeverRoute', 'Route.lua'), path.join(dest, 'Route.lua'));
    fs.mkdirSync(path.join(dest, 'tests'), { recursive: true });
    for (const f of ['_harness.lua', '_player.lua']) fs.copyFileSync(path.join(src, 'tests', f), path.join(dest, 'tests', f));
    // a built-in plan lives in its own load-on-demand addon: hand the sim its file directly
    if (kind === 'starter') fs.copyFileSync(path.join(ROOT, 'addon', 'ForeverRoute_Starter_' + key.replace(/-/g, '_'), 'Plan.lua'), path.join(dest, 'tests', '_plan.lua'));
    fs.mkdirSync(path.join(work, 'wtf'), { recursive: true });
    for (const p of personas) { try { fs.unlinkSync(logOf(p)); } catch (e) {} }
    const t0 = Date.now();
    let raw = '', hung = null;
    // a fresh simulator every FR_SIM_CHUNK personas (default 3): one simulator playing all ten grew to ~17 GB
    // (its own memory - the addon's Lua heap stays flat), and two of them at once ran the PC out of memory
    const CHUNK = Math.max(1, +(process.env.FR_SIM_CHUNK || 3));
    // FR_SIM_PAR: chunks side by side (default 1, one after another). Each simulator uses about one core and peaks near
    // 6 GB, so a chunk waits for free memory before it starts; each has its own copy of the addon and settings folder
    // (play_test.lua is per chunk). Outputs are joined in chunk order, so the report reads the same either way.
    const PAR = Math.max(1, +(process.env.FR_SIM_PAR || 1));
    const starts = []; for (let c0 = 0; c0 < personas.length; c0 += CHUNK) starts.push(c0);
    const outs = starts.map(() => '');
    const runChunk = async (ci) => {
      const c0 = starts[ci], chunk = personas.slice(c0, c0 + CHUNK);
      const cw = ci === 0 ? work : fs.mkdtempSync(path.join(os.tmpdir(), 'fr-play-'));
      if (ci > 0) { fs.cpSync(dest, path.join(cw, 'ForeverRoute'), { recursive: true }); fs.mkdirSync(path.join(cw, 'wtf'), { recursive: true }); }
      fs.writeFileSync(path.join(cw, 'ForeverRoute', 'tests', 'play_test.lua'), `local ns = ForeverRoute\n${testOf.slice(c0, c0 + CHUNK).join('\n')}\n`);
      if (PAR > 1) { const t1 = Date.now(); while (os.freemem() < 7.5 * 2 ** 30 && Date.now() - t1 < 600000) await new Promise((r) => setTimeout(r, 5000)); }
      let raw1 = '';
      await new Promise((resolve) => {
        const child = spawn(path.join(SIM, 'wow-sim.exe'), ['--allow-ui-version-mismatch', '--addons-path', cw, '--session-wtf-path', path.join(cw, 'wtf'),
          '--class', simClass, '--race', simRace, 'run-tests', 'ForeverRoute'],
        { cwd: SIM, env: { ...process.env, WOW_INSTALL_PATH: path.resolve(ROOT, '..', '..') }, stdio: ['ignore', 'pipe', 'pipe'] });
        child.stdout.on('data', (d) => (raw1 += d)); child.stderr.on('data', (d) => (raw1 += d));
        // the watchdog: the logs grow while the player plays; when none has for STALL_SEC, something loops
        let lastSize = -1, lastChange = Date.now();
        const tick = setInterval(() => {
          const size = chunk.reduce((s, p) => { try { return s + fs.statSync(logOf(p)).size; } catch (e) { return s; } }, 0);
          if (size !== lastSize) { lastSize = size; lastChange = Date.now(); return; }
          if (Date.now() - lastChange > STALL_SEC * 1000) { hung = Math.round((Date.now() - t0) / 1000); try { process.kill(child.pid); } catch (e) {} }
        }, 2000);
        child.on('close', () => { clearInterval(tick); resolve(); });
      });
      outs[ci] = raw1;
      if (ci > 0 && !process.env.FR_KEEP) fs.rmSync(cw, { recursive: true, force: true });
    };
    let nextChunk = 0;
    await Promise.all(Array.from({ length: Math.min(PAR, starts.length) }, async () => { while (nextChunk < starts.length && !hung) { const ci = nextChunk++; await runChunk(ci); } }));
    raw = outs.join('');
    const out = raw.replace(/\x1b\[[0-9;]*m/g, '');
    if (process.env.FR_KEEP) fs.writeFileSync(path.join(work, 'out.txt'), out);
    const lines = out.split('\n');
    const found = lines.filter((l) => l.includes('SIMPLAY ')).map((l) => l.slice(l.indexOf('SIMPLAY ') + 8));
    // a persona's report arrives as its test's message; any other failed test is a real failure (a check broke)
    const failed = []; for (let i = 0; i < lines.length; i++) if (/✗/.test(lines[i]) && !(lines[i + 1] || '').includes('SIMPLAY-REPORT')) failed.push(lines[i].trim() + (lines[i + 1] ? '\n    ' + lines[i + 1].trim() : ''));
    const tail = (p) => { let t = ''; try { t = fs.readFileSync(logOf(p), 'utf8'); } catch (e) {} const L = t.trim().split('\n'); return t && L[L.length - 1] !== 'end' ? [p + ':', ...L.slice(-12).map((l) => '  ' + l)] : []; };
    const sum = `${personas.length} persona(s) played, ${failed.length} broke a check` + (hung ? `, HUNG (stopped after ${hung} s)` : '') + (/\d+ tests, \d+ passed/.test(out) || hung ? '' : ' (the simulator gave no result)');
    const report = [`# Simulated player on ${plan}`, '', `${new Date().toISOString().slice(0, 16)}, ${Math.round((Date.now() - t0) / 1000)} s. ${sum}`, '',
      ...(hung ? [`## Hung: no progress for ${STALL_SEC} s. Last lines of each unfinished log (reports/simplay-logs):`, '', '```', ...personas.flatMap(tail), '```', ''] : []),
      '## What the player ran into', '', '```', ...(found.length ? found : ['(no findings printed)']), '```', '',
      ...(failed.length ? ['## Runs that failed (a check broke: card/arrow/pin disagree, or the addon logged an error)', '', '```', ...failed, '```', ''] : [])].join('\n');
    fs.writeFileSync(path.join(ROOT, 'reports', 'simplay.md'), report);
    console.log(report);
    process.exitCode = hung || failed.length || !found.length ? 1 : 0;
    // only a clean pass is kept for reuse
    if (simKey && !process.exitCode) { fs.mkdirSync(SIMCACHE, { recursive: true }); fs.writeFileSync(path.join(SIMCACHE, simKey + '.md'), report); }
  } finally { if (process.env.FR_KEEP) console.log('kept ' + work); else fs.rmSync(work, { recursive: true, force: true }); }
})();
