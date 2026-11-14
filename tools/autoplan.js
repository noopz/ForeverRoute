// Automatic replanning: watches the character's SavedVariables (written on every /reload and logout) and replans
// from the real state, then installs Route.lua into the addon so the next /reload has a route that matches what you
// actually did. Two passes:
//   fast: the main paths + dungeon routes (a few minutes), after every save
//   full: also the zone-choice branches (~30 min), only after 10 quiet minutes and at most once an hour
// A plan is installed only if it checks out and is newer than what's installed; the copy is atomic (temp + rename).
// usage: node autoplan.js <campaign.json> <addonDir>
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');

const [cfgPath, addonDir] = process.argv.slice(2);
const ROOT = path.resolve(__dirname, '..');
const base = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
const charSV = path.join(base.charDir, 'ForeverRoute.lua');
const logFile = path.join(ROOT, 'autoplan.log');
const log = (m) => { const line = new Date().toLocaleTimeString() + '  ' + m; fs.appendFileSync(logFile, line + '\n'); console.log(line); };
const mtime = (f) => { try { return fs.statSync(f).mtimeMs; } catch (e) { return 0; } };

const running = { fast: null, full: null }, cancelled = { fast: false, full: false };
// stop a plan and everything it started (only our own process tree)
function cancel(kind) {
  const p = running[kind]; if (!p) return;
  cancelled[kind] = true;
  try { require('child_process').execFileSync('taskkill', ['/T', '/F', '/PID', String(p.pid)], { stdio: 'ignore' }); } catch (e) {}
  running[kind] = null;
}
// modified (not new, untracked) files under tools/ or routes/ in the repo
function codeBeingEdited() {
  try {
    const out = require('child_process').execFileSync('git', ['status', '--porcelain', '--', 'tools', 'routes'], { cwd: ROOT, encoding: 'utf8', timeout: 20000, stdio: ['ignore', 'pipe', 'ignore'] });
    return out.split('\n').some((l) => l.trim() && !l.startsWith('??'));
  } catch (e) { return false; } // no git: plan as before
}
function runPlan(kind) {
  const work = path.join(ROOT, kind === 'full' ? 'paths-auto-full' : 'paths-auto');
  fs.mkdirSync(work, { recursive: true });
  // a starting zone you asked for in game (ForeverRouteChar.requestZone, set from the Paths window)
  let requestZone = null;
  try { const m = /\["requestZone"\] = "([^"]+)"/.exec(fs.readFileSync(charSV, 'utf8')); if (m) requestZone = m[1]; } catch (e) {}
  // the zone your current path goes to next (ForeverRouteChar.routeLegs): the replan keeps a path starting there
  let followZone = null, followLegs = null, followId = null;
  try {
    const t = fs.readFileSync(charSV, 'utf8');
    const L = /\["routeLegs"\] = "([^"]+)"/.exec(t); if (L) followLegs = L[1].split('>').map((z) => z.trim()).filter(Boolean);
    const I = /\["routeTitle"\] = "(path:[^"]+)"/.exec(t); if (I) followId = I[1];
  } catch (e) {}
  try { const m = /\["routeLegs"\] = "([^">]+)/.exec(fs.readFileSync(charSV, 'utf8')); if (m) followZone = m[1].trim(); } catch (e) {}
  // the settings as they are now (side trips, must-do quests...): read fresh for every plan - the copy read at start-up
  // missed the Incubus quests added later
  let now = base; try { now = JSON.parse(fs.readFileSync(cfgPath, 'utf8')); } catch (e) { log('  could not read ' + cfgPath + ' (' + e.message + '), using the settings from start-up'); }
  // the walking you recorded in cities and indoors (account SavedVariables) -> terrain trails for the pathfinder
  try {
    const accountSV = path.join(now.charDir, '..', '..', '..', 'SavedVariables', 'ForeverRoute.lua');
    if (fs.existsSync(accountSV)) require('child_process').execFileSync(process.execPath, [path.join(__dirname, 'trails.js'), accountSV, path.resolve(ROOT, now.conversion), path.resolve(ROOT, now.terrainDir)], { cwd: ROOT, timeout: 60000, stdio: 'ignore' });
  } catch (e) { log('  trails import failed: ' + String(e.message).split('\n')[0]); }
  // what your play taught the addon (XP per kill, pace, incidents) -> paths-auto/learned.json for the planner, and
  // reports/learned.md + reports/incidents.md for you (new incidents also become replayed-save tests)
  try {
    const accountSV = path.join(now.charDir, '..', '..', '..', 'SavedVariables', 'ForeverRoute.lua');
    if (fs.existsSync(accountSV)) {
      const said = require('child_process').execFileSync(process.execPath, [path.join(__dirname, 'learn.js'), accountSV, now.charDir], { cwd: ROOT, timeout: 60000, encoding: 'utf8' }).trim();
      if (said && !/0 XP corrections, pace not yet, 0 new incidents/.test(said)) log('  ' + said);
    }
  } catch (e) { log('  learning failed: ' + String(e.message).split('\n')[0]); }
  // the fast pass reuses the last dungeon routes and polishes less; the full pass does everything carefully
  // (and gives a zone that timed out no second, longer try - campaign.js runEval: that is for the full pass and the
  // tree builds; the fast pass has to land in a few minutes)
  const cfg = { ...now, routesOut: path.join(work, 'Route.lua'), requestZone, followZone, followLegs, followId, ...(kind === 'fast' ? { reuseDungeons: path.join(ROOT, 'paths-auto-full', 'dungeons.json'), optimizeEffort: 0.5, evalRetrySec: 0 } : { beam: 4 }) };
  if (requestZone) log('  you asked to start in ' + requestZone);
  const cfgFile = path.join(work, 'campaign.json'); fs.writeFileSync(cfgFile, JSON.stringify(cfg));
  const args = ['--max-old-space-size=8000', path.join(__dirname, 'paths.js'), cfgFile, '3', kind === 'full' ? '2' : '0', '--work', work];
  return new Promise((res) => {
    const t0 = Date.now(), save = mtime(charSV);
    const p = running[kind] = spawn(process.execPath, args, { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, FR_FROM_SAVE: String(Math.floor(save / 1000)) } });
    try { os.setPriority(p.pid, 19); } catch (e) {}
    let out = '', finished = false;
    p.stdout.on('data', (d) => {
      out += d;
      if (!finished && /wrote \d+ paths/.test(out)) {
        finished = true;
        setTimeout(() => {
          if (running[kind] !== p) return;
          out += '\n(planner finished but did not exit: stopped by the watchdog)\n';
          try { require('child_process').execFileSync('taskkill', ['/T', '/F', '/PID', String(p.pid)], { stdio: 'ignore' }); } catch (e) {}
        }, 10000);
      }
    });
    p.stderr.on('data', (d) => (out += d));
    p.on('close', (code) => { running[kind] = null; const wasCancelled = cancelled[kind]; cancelled[kind] = false; fs.writeFileSync(path.join(work, 'last-run.log'), out); res({ code: finished ? 0 : code, out, file: cfg.routesOut, save, minutes: (Date.now() - t0) / 60000, cancelled: wasCancelled && !finished }); });
  });
}

// sanity checks before anything reaches the game
function check(file) {
  if (!fs.existsSync(file)) return 'no output';
  const t = fs.readFileSync(file, 'utf8');
  if (t.length < 100000) return 'too small (' + t.length + ' bytes)';
  if (!/^ForeverRouteRoutes = \{$/m.test(t) || !t.trimEnd().endsWith('}')) return 'not a complete route file';
  const routes = (t.match(/^ {4}id = "/gm) || []).length;
  if (routes < 1) return 'no routes';
  // a plan with no leveling path (the zone ranking found nothing to start in): only dungeon and class routes - the
  // addon would put you on a dungeon route. Never installed (17:47, 2026-11-13: 'it is forcing me into Gnomeregan')
  if (!/^ {4}id = "path:/m.test(t)) return 'no leveling path in it (only dungeon / class routes)';
  const opens = (t.match(/\{/g) || []).length, closes = (t.match(/\}/g) || []).length;
  if (opens !== closes) return `unbalanced braces (${opens} vs ${closes})`;
  return null;
}
// the addon can't read files, but it can ask whether a sound file would play: a valid silent wav means "a new plan
// is installed - reload to get it", an empty file means nothing new
const signalFile = path.join(addonDir, 'signal', 'ready.wav');
function silentWav() {
  const rate = 22050, n = 2205, data = n * 2, b = Buffer.alloc(44 + data);
  b.write('RIFF', 0); b.writeUInt32LE(36 + data, 4); b.write('WAVE', 8); b.write('fmt ', 12); b.writeUInt32LE(16, 16);
  b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22); b.writeUInt32LE(rate, 24); b.writeUInt32LE(rate * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34);
  b.write('data', 36); b.writeUInt32LE(data, 40);
  return b;
}
// "a newer plan than yours": one file per plan that is now out of date, named after that plan's stamp
// (signal/newer-<generated>.wav). The addon checks the name for the plan it has loaded. Names are never reused or
// deleted while relevant, so the game remembering a file can't cause a false prompt.
const stampsFile = path.join(ROOT, 'installed-plans.json');
function markNewer(oldText, newText, ahead) {
  const stamp = (t) => { const m = /generated = (\d+)/.exec((t || '').slice(0, 400)); return m ? m[1] : null; };
  let list = []; try { list = JSON.parse(fs.readFileSync(stampsFile, 'utf8')); } catch (e) {}
  const o = stamp(oldText), n = stamp(newText);
  if (o && !list.includes(o)) list.push(o);
  if (ahead) {
    // every older plan is now outdated for what is ahead of you
    try { fs.mkdirSync(path.dirname(signalFile), { recursive: true }); for (const g of list) { const f = path.join(path.dirname(signalFile), 'newer-' + g + '.wav'); if (!fs.existsSync(f)) fs.writeFileSync(f, silentWav()); } } catch (e) {}
  }
  // (a quiet install marks nothing: the plan you have is as good as the new one for what's ahead of you)
  if (n && !list.includes(n)) list.push(n);
  list = list.slice(-40);
  fs.writeFileSync(stampsFile, JSON.stringify(list));
  // tidy: signal files for plans no longer in the list
  try { for (const f of fs.readdirSync(path.dirname(signalFile))) { const m = /^newer-(\d+)\.wav$/.exec(f); if (m && !list.includes(m[1])) fs.unlinkSync(path.join(path.dirname(signalFile), f)); } } catch (e) {}
}
function signal(ready) {
  // ready: a valid silent wav. Not ready: no file at all (the game says an empty file "would play" too)
  try {
    if (ready) { fs.mkdirSync(path.dirname(signalFile), { recursive: true }); fs.writeFileSync(signalFile + '.tmp', silentWav()); fs.renameSync(signalFile + '.tmp', signalFile); }
    else if (fs.existsSync(signalFile)) fs.unlinkSync(signalFile);
  } catch (e) {}
}
// which zones a quest touches (giver, objectives' mobs/objects, hand-in) and which quests it unlocks - loaded once
let QZ = null;
function zonesOfQuest(id) {
  if (!QZ) {
    const db = JSON.parse(fs.readFileSync(path.resolve(ROOT, base.db), 'utf8'));
    const zs = (list) => (list || []).flatMap((x) => (x.spawns || []).map((sp) => sp.zone));
    const unlocks = {};
    for (const [qid, q] of Object.entries(db.quests)) for (const pre of [...(q.preGroup || []), ...(q.preSingle || [])]) (unlocks[pre] = unlocks[pre] || []).push(+qid);
    QZ = { db, zs, unlocks, cache: {} };
  }
  if (QZ.cache[id]) return QZ.cache[id];
  const q = QZ.db.quests[id]; const out = new Set();
  if (q) {
    for (const z of [...QZ.zs(q.starters), ...QZ.zs(q.finishers)]) out.add(z);
    for (const o of q.objectives || []) {
      if (o.npc && QZ.db.npcs[o.npc]) for (const sp of QZ.db.npcs[o.npc].spawns || []) out.add(sp.zone);
      if (o.object && QZ.db.objects[o.object]) for (const sp of QZ.db.objects[o.object].spawns || []) out.add(sp.zone);
    }
    // follow-ups it unlocks count too (a chain that continues in another zone)
    for (const nx of QZ.unlocks[id] || []) { const n = QZ.db.quests[nx]; if (n) for (const z of [...QZ.zs(n.starters), ...QZ.zs(n.finishers)]) out.add(z); }
  }
  return (QZ.cache[id] = out);
}
// a quest only matters to the replan if it reaches outside the zone you're in
const beyondZone = (id, zone) => { const z = zonesOfQuest(id); return !zone || z.size === 0 || [...z].some((x) => x !== zone); };
// what in a save actually matters for the route (position, XP within the level and kill counts don't)
function routeSig() {
  try {
    const st = require('./snapshot').loadCharState(base.charDir, path.resolve(ROOT, base.conversion));
    if (!st) return null;
    const t = fs.readFileSync(charSV, 'utf8');
    const req = /\["requestZone"\] = "([^"]+)"/.exec(t);
    const zone = st.pos && st.pos.zone;
    // zone-local quests are handled live in game: only quests reaching beyond this zone count
    const log = Object.entries(st.log || {}).filter(([id]) => beyondZone(+id, zone)).map(([id, q]) => id + ':' + (q.complete ? 1 : 0)).sort();
    const completed = (st.completed || []).filter((id) => beyondZone(+id, zone));
    // your professions (not their ranks: those climb all the time, and the addon checks a rank at the giver)
    const profs = require('./world').professionsOf(st.skills);
    return JSON.stringify([profs, st.level, st.pos && st.pos.zone, [...completed].sort((a, b) => a - b), log, [...(st.nope || []), ...(st.notOffered || [])].sort(), [...(st.taxi || [])].sort(), st.bind, req && req[1]]);
  } catch (e) { return null; }
}
const installedSave = () => { try { const m = /fromSave = (\d+)/.exec(ownOf(fs.readFileSync(path.join(addonDir, 'Route.lua'), 'utf8')).slice(0, 400)); return m ? +m[1] : 0; } catch (e) { return 0; } };
// the next steps of the followed path (or the first path) in a Route.lua text, as short keys
const RF = require('./routefile'); // the shared plan-file reader
let lastAdded = []; // the steps changesAhead found new (for the change note)
function changesAhead(oldText, newText) {
  lastAdded = [];
  let id = null, snap = null;
  try { const c = require('./luatable').parseSavedVariables(fs.readFileSync(charSV, 'utf8')).ForeverRouteChar || {}; id = c.routeTitle || null; snap = c.snapshot || null; } catch (e) {}
  // what you do counts, not the order: something new in your next steps, or something your plan still sends you to
  // that the new plan dropped
  const ch = RF.aheadChanges(oldText, newText, id, snap);
  lastAdded = ch.added;
  const show = (l) => l.slice(0, 5).map((k) => k.replace(/:$/, '')).join(', ') + (l.length > 5 ? ' ...' : '');
  if (ch.added.length) log('  what changed ahead of you: ' + show(ch.added));
  if (ch.dropped.length) log('  no longer on your path: ' + show(ch.dropped));
  return ch.changed;
}
// what changed on your path, in one line for the card (shown once after you reload): the zone order (kept unless a
// zone stopped being worth doing - then which and why) and quests new in the next stretch. null if nothing did.
function pathsOf(text) {
  return RF.routeIds(text, /^path:/).map((id) => ({ id, ...RF.meta(text, id) }));
}
function changeNote(oldText, newText, added) {
  let id = null; try { const m = /\["routeTitle"\] = "([^"]+)"/.exec(fs.readFileSync(charSV, 'utf8')); if (m) id = m[1]; } catch (e) {}
  const was = pathsOf(oldText).find((p) => p.id === id);
  if (!was) return null;
  // your path in the new plan: the one sharing the longest start with yours (ids change when the order does)
  const shared = (p) => { let k = 0; while (k < p.legs.length && p.legs[k] === was.legs[k]) k++; return k; };
  const now = pathsOf(newText).sort((a, b) => shared(b) - shared(a))[0];
  const parts = [];
  if (now && now.legs.join() !== was.legs.join()) {
    parts.push('zones now ' + now.legs.slice(0, 4).join(' > ') + (now.dropped.length ? ' (' + now.dropped.join(', ') + ' dropped: finished or outlevelled)' : ''));
  }
  const names = [...new Set((added || []).map((k) => { const q = /:(\d+):/.exec(k); const m = q && new RegExp('q = ' + q[1] + ', name = "([^"]+)"').exec(newText); return m ? m[1] : null; }).filter(Boolean))];
  if (names.length) parts.push('new soon: ' + names.slice(0, 3).join(', ') + (names.length > 3 ? ' and ' + (names.length - 3) + ' more' : ''));
  return parts.length ? parts.join('; ') : null;
}
// one Route.lua for all your characters: a block per character ("Name-Realm", from the save folder), each a function the
// addon calls only for the character logged in. This companion rewrites its own block and keeps the others as they are.
const ME = path.basename(path.dirname(base.charDir)).replace(/\s/g, '');
const blocksOf = (text) => RF.blocks(text);
// your plan's own text inside a Route.lua (an older single-plan file is all yours)
const ownOf = (text) => RF.own(text, ME);
function wrapAll(own, oldRaw) {
  const block = (name, inner) => `-- ForeverRoute plan for ${name} begin\nForeverRouteByChar = ForeverRouteByChar or {}\nForeverRouteByChar[${JSON.stringify(name)}] = function()\n${inner}\nend\n-- ForeverRoute plan for ${name} end\n`;
  const others = [...blocksOf(oldRaw)].filter(([n]) => n !== ME).map(([, b]) => b.whole);
  return block(ME, own) + others.join('');
}
function install(r, kind) {
  const bad = r.code ? 'planner exited ' + r.code : check(r.file);
  if (bad) { log(`${kind} plan NOT installed: ${bad}`); return false; }
  const m = /fromSave = (\d+)/.exec(fs.readFileSync(r.file, 'utf8').slice(0, 400));
  const from = m ? +m[1] : 0;
  if (from < installedSave()) { log(`${kind} plan skipped: a newer plan is already installed`); return false; }
  const dest = path.join(addonDir, 'Route.lua');
  // install gate: a plan that audits worse than the installed one waits (at most 3 times in a row, so a stale plan
  // never sticks)
  const issues = audit(r.file, false);
  // a broken plan (an empty path, or one the audit can't read) never goes in, not even after refusals
  if (issues === Infinity) { log(`${kind} plan NOT installed: it is broken (an empty path, or the audit could not read it)`); audit(r.file, true); return false; }
  if (lastIssues === null) lastIssues = fs.existsSync(dest) ? audit(dest, false) : Infinity;
  if (issues > lastIssues && refused < 3) { refused++; log(`${kind} plan NOT installed: the audit found ${issues} issue(s), the installed plan has ${lastIssues}`); audit(r.file, true); return false; }
  if (issues > lastIssues) log(`  installing anyway after ${refused} refusals (audit ${issues} vs ${lastIssues})`);
  refused = 0; lastIssues = issues;
  let oldRaw = ''; try { oldRaw = fs.readFileSync(dest, 'utf8'); } catch (e) {}
  const oldText = ownOf(oldRaw); // your previous plan (other characters' blocks are not compared)
  const summary = r.out.split('\n').filter((l) => /^ {2}\S.* -> \d+ \(/.test(l)).map((l) => l.trim().split(':')[0]).slice(0, 3).join(' | ');
  const newText = fs.readFileSync(r.file, 'utf8');
  const ahead = changesAhead(oldText, newText);
  // the card tells you once, after you reload, what changed on your path and why
  const note = changeNote(oldText, newText, lastAdded);
  if (note) log('  change note: ' + note);
  const own = newText + (note ? '\nForeverRoutePlan.changeNote = ' + JSON.stringify(note) + '\n' : '');
  fs.writeFileSync(dest + '.tmp', wrapAll(own, oldRaw));
  // the live check: the installed addon code loads this plan file as the real game would (a fresh login, a realm name
  // the planner never saw) and shows a sane step where you saved. A plan your addon can't load never goes in.
  const lc = liveCheck(dest + '.tmp');
  if (lc === 1) { log(`${kind} plan NOT installed: the live check failed (the addon would not load it right)`); try { fs.unlinkSync(dest + '.tmp'); } catch (e) {} return false; }
  fs.renameSync(dest + '.tmp', dest);
  markNewer(oldText, newText, ahead);
  if (ahead) signal(true); else log('  (nothing ahead of you on your path changed - installed quietly, no reload needed)');
  log(`${kind} plan installed (${r.minutes.toFixed(1)} min, from your ${new Date(from * 1000).toLocaleTimeString()} save): ${summary}`);
  audit(dest, true);
  return true;
}

// tools/live-check.js on a candidate plan file with the installed addon code: 0 passed (or nothing to check), 1 the
// plan doesn't load right, 3 only the check at the spot you saved failed (logged, and the plan still goes in)
function liveCheck(file) {
  const r = require('child_process').spawnSync(process.execPath, [path.join(__dirname, 'live-check.js'), base.charDir, file, addonDir], { encoding: 'utf8', timeout: 660000 });
  const out = String(r.stdout || '').trim();
  for (const l of out.split('\n').slice(0, 8)) if (l) log('  ' + l);
  return r.status === 1 ? 1 : r.status === 3 ? 3 : 0;
}

// audit each main path of a plan; returns the issue count (Infinity if the audit can't run), logs when asked
let lastIssues = null, refused = 0;
function audit(file, show) {
  let total = 0;
  const ids = [...fs.readFileSync(file, 'utf8').matchAll(/^ {4}id = "(path:[^"]+)",/gm)].map((m) => m[1]).filter((id) => !/branch|special/.test(id));
  // the quests you had done when you saved (the plans start from that save): the audit checks prerequisites against it
  const doneFile = path.join(ROOT, 'paths-auto', 'done.json');
  let doneArg = [];
  try {
    const st = require('./snapshot').loadCharState(base.charDir, path.resolve(ROOT, base.conversion));
    if (st && Array.isArray(st.completed)) { fs.writeFileSync(doneFile, JSON.stringify({ done: st.completed, log: Object.keys(st.log || {}).map(Number) })); doneArg = [doneFile]; }
  } catch (e) { /* no snapshot: prerequisites unchecked */ }
  for (const id of ids.slice(0, 3)) {
    try {
      const out = require('child_process').execFileSync(process.execPath, [path.join(__dirname, 'lint-route.js'), file, path.join(ROOT, 'qdb', 'db.json'), id, (base.class || '') + ',' + (base.race || ''), ...doneArg], { encoding: 'utf8', timeout: 120000, maxBuffer: 1 << 24 });
      const lines = out.trim().split('\n'), clean = lines[1] === 'no issues found';
      if (!clean) total += lines.length - 1;
      // an empty path is a broken plan, not a clean one (a full pass once installed three 0-step paths)
      if (/^0 steps/.test(lines[0])) { total = Infinity; if (show) log(`  audit ${id}: no steps at all - broken plan`); }
      if (show) log(`  audit ${id}: ${lines[0]}, ${clean ? 'no issues' : (lines.length - 1) + ' issue(s)'}`);
      if (show && !clean) for (const l of lines.slice(1, 6)) log('    ' + l);
    } catch (e) { total = Infinity; if (show) log(`  audit ${id} failed: ${String(e.message).split('\n')[0]}`); }
  }
  return total;
}

// the files of this process (autoplan.js and the tools modules it loaded), as they were when it started
const ownFiles = () => Object.keys(require.cache).filter((f) => f.startsWith(__dirname) && f.endsWith('.js'));
const mtimeOf = (f) => { try { return fs.statSync(f).mtimeMs; } catch (e) { return 0; } };
const ownStamp = {}; // file -> mtime when first seen (a module loaded later is recorded when it shows up, not a change)
function ownCodeChanged() {
  let changed = false;
  for (const f of ownFiles()) { const m = mtimeOf(f); if (!(f in ownStamp)) ownStamp[f] = m; else if (ownStamp[f] !== m) changed = true; }
  return changed;
}
(async () => {
  log('autoplan watching ' + charSV);
  ownCodeChanged(); // the stamp at start
  let planned = 0, lastFull = 0, busyFast = false, busyFull = false, seen = 0, lastSig = null;
  let waitLogged = false;
  setInterval(async () => {
    // never plan with half-edited planner code: while tools/ or routes/ have uncommitted changes (someone is working on
    // the planner), plans wait and the installed one stays. A full pass once installed three empty paths that way.
    if (!busyFast && !busyFull && codeBeingEdited()) {
      if (!waitLogged) { log('planner code is being edited (uncommitted changes) - replans wait until it is committed'); waitLogged = true; }
      return;
    }
    if (waitLogged) { log('planner code committed - replanning resumes'); waitLogged = false; }
    // this process's own code changed (autoplan.js, or a module it loaded - routefile.js decides "reload to get it"):
    // exit while idle; the companion starts it again in 10 s with the new code. Otherwise its own changes would only
    // arrive when the companion restarts.
    if (!busyFast && !busyFull && ownCodeChanged()) { log('my own code changed - restarting with it'); process.exit(0); }
    // "Replan now" from the companion app: a trigger file newer than the last plan
    const trig = mtime(path.join(ROOT, 'replan-now.txt'));
    if (trig > planned && !busyFast) { planned = 0; }
    const m = Math.max(mtime(charSV), trig > 0 && planned === 0 ? trig : 0);
    const quietFor = Date.now() - mtime(charSV);
    // fast pass: a new save, settled for 20 s (the game writes several files)
    // any new save means you reloaded, so whatever plan was ready is now loaded in game
    if (m > seen) { seen = m; signal(false); }
    if (!busyFast && m > planned && (quietFor > 20000 || planned === 0)) {
      const sig = routeSig(), forced = trig > 0 && m === trig;
      if (sig && sig === lastSig && !forced) { planned = m; log('save (' + new Date(m).toLocaleTimeString() + '): nothing on your route changed - keeping the current plan'); return; }
      lastSig = sig;
      busyFast = true; planned = m;
      if (busyFull) { cancel('full'); log('  stopped the full replan (it was planning from an older save); it runs again when you are quiet'); }
      log('new save (' + new Date(m).toLocaleTimeString() + '): replanning');
      const r = await runPlan('fast'); install(r, 'fast'); busyFast = false;
    }
    // full pass with branches: only when the fast pass is up to date with the latest save, that save is 10+ minutes
    // old (measured now), at most hourly, and never alongside another plan
    const now = mtime(charSV);
    if (!busyFull && !busyFast && planned >= now && Date.now() - now > 10 * 60000 && Date.now() - lastFull > 60 * 60000 && now > lastFull) {
      busyFull = true; lastFull = Date.now();
      log('quiet for a while: full replan with zone choices');
      const r = await runPlan('full'); if (r.cancelled) lastFull = 0; else install(r, 'full'); busyFull = false;
    }
  }, 15000);
})();
