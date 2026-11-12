// Checkpoints for the simulated player (tools/simplay.js): a persona resumes at the last leg of the plan that has not
// changed instead of playing again from level 1. FR_SIM_CKPT=0 turns them off (built-in plans only: starter:<combo>).
//
// What a checkpoint is. The player (addon/ForeverRoute/tests/_player.lua) writes one when the furthest plan step its run
// has reached (shown, current, planned or focus) first passes a leg boundary: legs() below cuts the plan where the zone
// changes, at least MIN_LEG steps apart (about 45 legs per plan). The file is a Lua chunk that rebuilds the persona's whole state (tests/_ckpt.lua writes and reads it):
//   - the saved data: ns.char / ForeverRouteChar (skipped, manualDone, history, progress, nope, ranRun, knownTaxi, ...)
//     and ForeverRouteDB (the error log, why, learn), shared tables kept shared
//   - the world: map and position, level, the virtual clock, the quest log with each objective's progress and step
//   - the step list as the engine has it: the plan's steps plus the stops it inserted, where it inserted them
//   - the engine's own fields (current, planned, focus, view, ...; GetTime() stamps kept as ages)
//   - the player's: rng state, done steps, shown counts, guard, bags, dungeon, hearth bind, backtracking cells,
//     travel and finding counts, the findings so far, the profile, the error count the run started from
// Pending addon timers are run out first (the virtual clock moves on to the last of them), so none is lost.
// The run that writes a checkpoint puts its state back from what it wrote and goes on from there: a resumed run and
// a full one go on from the same state by construction, and anything the file could not hold shows in the full run
// too. (So with checkpoints on, a persona's run differs from one with FR_SIM_CKPT=0 by that drain and rebuild.)
//
// The key: sha1 of everything the state at that point depends on -
//   - base: this file's format version, the addon code the sim loads (every .lua/.toc/.xml of addon/ForeverRoute but
//     the tests, plus tests/_harness.lua, _player.lua, _ckpt.lua), tools/simplay.js and this file, the simulator
//     (folder name, wow-sim.exe size and date), the plan's race and class, the persona, its seed, the step limit;
//   - the plan's globals: the ForeverRoutePlan line without its stamp and the zones-later list (the Paths window's),
//     the other routes (zone route, side trips) without their meta lines, every top-level line but the stamps;
//   - plan steps 1..hi, by content (the line without its id), and the sections they use. hi is the furthest plan step
//     the run had reached (shown, current, planned, focus) plus LOOK (120: the live solver scans 90 ahead, the focus
//     rules 10) - the engine looks ahead, so the leg alone is not enough. An inserted stop past that widens hi;
//   - the quests the state holds (quest log and done, inserted stops): all their steps past hi in order, and their
//     hand-in spots (ForeverRouteEnders); ForeverRouteUnlocks entries touching any quest of steps 1..hi or those;
//     the bind and flight-path steps past hi (map and place: the engine asks about them across the whole plan).
// The header line of a checkpoint (META) records hi and the quests, so the key can be computed again on a new plan:
// a checkpoint is used when its key, recomputed on the plan being played, is the one it was stored under. Objectives
// past hi are found as "the n-th step of quest q past hi", which the key keeps the same.
// The player checks the rest before it resumes: the backtracking hubs come from the whole plan, so every hub question
// the run had asked is asked again of the new plan; a different answer (or a file it cannot read) and it plays from
// level 1, and the report says why. The plan's stamp, path id and legs in the saved data become the new plan's.
// Not covered (the reason it is a key over hi plus quests, not a proof): heuristics that compare against steps far
// ahead that are not of a quest you hold - where InsertStop puts a stop (cheapest gap over the rest of the list on that
// continent), Next's hand-ins "near you" judged by isHub/chainsOnHere around a far step. Module-local state of the
// addon not in a table it exposes (Next's last pick, Engine's progress holds, Learn's timers) starts empty in a
// resumed run; much of it is wall-clock based (GetTime() is real time in the sim), so two full runs already differ
// there.
//
// Where: reports/simplay-ckpt/<combo>/<persona>/<leg>-<key>.lua.gz (gzipped: 10-60 KB each). After each run a persona's folder keeps only the
// checkpoints that match the plan just played; the whole folder is held under FR_SIM_CKPT_MB (default 1024 MB) by
// dropping the plans touched longest ago.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const zlib = require('zlib');

const VERSION = 'frckpt-1';
const MIN_LEG = 40;
const LOOK = 120;

const sha = () => crypto.createHash('sha1');
const lineContent = (l) => l.trim().replace(/,\s*id = \d+(?=\s*[,}])/, '');
const field = (l, f, re) => { const m = new RegExp('[{,]\\s*' + f + ' = ' + re).exec(l); return m ? m[1] : undefined; };

// the plan file (Plan.lua of a built-in plan, as tools/starter.js writes it) cut into what the key reads
function parsePlan(text) {
  const L = text.split(/\r?\n/);
  const plan = { steps: [], sections: [], enders: new Map(), unlocks: [], top: [], others: [], planLine: '', pathId: null };
  let st = 'top', route = null, sub = null, routesDone = false;
  for (const l of L) {
    if (st === 'top') {
      if (l === 'ForeverRouteRoutes = {') { st = 'routes'; continue; }
      if (l === 'ForeverRouteEnders = {') { st = 'enders'; continue; }
      if (l === 'ForeverRouteUnlocks = {') { st = 'unlocks'; continue; }
      if (l.startsWith('ForeverRoutePlan = ')) { plan.planLine = l.replace(/generated = \d+,\s*/, '').replace(/,?\s*later = \{[^}]*\}/, ''); continue; }
      if (/^\s*--/.test(l) || /^ForeverRouteStarterStamp\[/.test(l) || !l.trim()) continue;
      plan.top.push(l);
    } else if (st === 'routes') {
      if (l === '}') { st = 'top'; routesDone = true; continue; }
      if (l === '  {') { route = { lines: [] }; continue; }
      if (l === '  },') {
        if (!plan.pathId && route.id && route.id.startsWith('path:')) plan.pathId = route.id;
        else plan.others.push(...route.lines.filter((x) => !/^    meta = /.test(x)));
        route = null; continue;
      }
      if (!route) throw new Error('unexpected line in ForeverRouteRoutes: ' + l.slice(0, 60));
      const main = !plan.pathId && (route.id || '').startsWith('path:');
      if (sub) { if (l === '    },') { sub = null; continue; } if (main) (sub === 'steps' ? plan.steps : plan.sections).push(l); else route.lines.push(l); continue; }
      const id = /^    id = "(.*)",$/.exec(l); if (id) { route.id = id[1]; route.lines.push(l); continue; }
      if ((l === '    steps = {' || l === '    sections = {') && (route.id || '').startsWith('path:') && !plan.pathId) { sub = l.includes('steps') ? 'steps' : 'sections'; continue; }
      if (l === '    steps = {' || l === '    sections = {') { sub = 'other'; route.lines.push(l); continue; }
      route.lines.push(l);
    } else if (st === 'enders' || st === 'unlocks') {
      if (l === '}') { st = 'top'; continue; }
      const m = /^\s*\[(-?\d+)\] = \{(.*)\},?$/.exec(l);
      if (!m) throw new Error('unexpected line in ForeverRoute' + st + ': ' + l.slice(0, 60));
      if (st === 'enders') plan.enders.set(+m[1], l.trim());
      else plan.unlocks.push({ q: +m[1], vals: m[2].split(',').map((x) => +x.trim()).filter((x) => !isNaN(x)), line: l.trim() });
    }
  }
  if (!routesDone || !plan.pathId || !plan.steps.length) throw new Error('no path route with steps in the plan');
  plan.steps = plan.steps.map((l) => ({ content: lineContent(l), k: field(l, 'k', '"([^"]*)"'), q: field(l, 'q', '(-?\\d+)'), sec: field(l, 'sec', '(\\d+)'),
    zone: field(l, 'zone', '"((?:[^"\\\\]|\\\\.)*)"'), m: field(l, 'm', '(\\d+)'), x: field(l, 'x', '([\\d.]+)'), y: field(l, 'y', '([\\d.]+)'), bind: field(l, 'bind', '"((?:[^"\\\\]|\\\\.)*)"') }));
  for (const s of plan.steps) if (s.q !== undefined) s.q = +s.q;
  plan.sections = plan.sections.map(lineContent);
  plan.globalHash = sha().update([plan.planLine, ...plan.top, '--others--', ...plan.others].join('\n')).digest('hex');
  return plan;
}

// leg boundaries: the plan step (1-based) that starts each leg after the first. A leg ends where the zone of the
// steps' section changes, at least MIN_LEG steps after the last boundary (decided going forward, so a boundary depends
// only on the steps before it and the one it falls on)
function legs(plan, min = MIN_LEG) {
  const zoneOf = (s) => (s.sec && plan.sections[s.sec - 1] && (/zone = "((?:[^"\\]|\\.)*)"/.exec(plan.sections[s.sec - 1]) || [])[1]) || s.zone || '';
  const out = []; let last = 1;
  for (let j = 2; j <= plan.steps.length; j++) {
    if (j - last >= min && zoneOf(plan.steps[j - 1]) !== zoneOf(plan.steps[j - 2])) { out.push(j); last = j; }
  }
  return out;
}

// the code the simulated player runs, and the simulator
function codeHash(root, simDir) {
  const h = sha().update(VERSION);
  const src = path.join(root, 'addon', 'ForeverRoute');
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const p = path.join(d, e.name), rel = path.relative(src, p).replace(/\\/g, '/');
      if (e.isDirectory()) { if (rel !== 'tests') walk(p); } else if (/\.(lua|toc|xml)$/.test(e.name)) { h.update(rel + '\0'); h.update(fs.readFileSync(p)); }
    }
  };
  walk(src);
  for (const f of ['_ckpt.lua', '_harness.lua', '_player.lua']) { h.update('tests/' + f + '\0'); h.update(fs.readFileSync(path.join(src, 'tests', f))); }
  for (const f of ['simplay.js', 'simckpt.js']) { h.update('tools/' + f + '\0'); h.update(fs.readFileSync(path.join(root, 'tools', f))); }
  const exe = path.join(simDir, 'wow-sim.exe');
  let st = { size: 0, mtimeMs: 0 }; try { st = fs.statSync(exe); } catch (e) {}
  h.update(['sim', path.basename(simDir), st.size, Math.round(st.mtimeMs)].join('|'));
  return h.digest('hex');
}
// everything but the plan: the code, the character, the persona
const baseOf = (code, o) => sha().update([code, o.combo, o.race, o.cls, o.persona, o.seed, o.to || ''].join('|')).digest('hex');

// the key of a checkpoint (its META: hi, quests, leg, B) on a plan; null when the plan is too short for it
function keyOf(plan, meta, base) {
  const hi = meta.hi, S = plan.steps;
  if (!(hi >= 1 && hi <= S.length)) return null;
  const h = sha().update(VERSION + '\0' + base + '\0' + plan.globalHash + '\0' + JSON.stringify({ leg: meta.leg, B: meta.B, hi }));
  // (hi at the plan's end: the run saw where the plan stops)
  if (hi >= meta.nsteps) h.update('ends at ' + S.length + '\n');
  const qs = new Set(), secs = new Set();
  for (let j = 0; j < hi; j++) { h.update(S[j].content + '\n'); if (S[j].q !== undefined) qs.add(S[j].q); if (S[j].sec) secs.add(+S[j].sec); }
  for (const n of [...secs].sort((a, b) => a - b)) h.update('sec ' + n + ' ' + (plan.sections[n - 1] || '') + '\n');
  const held = [...new Set((meta.quests || []).map(Number))].sort((a, b) => a - b);
  for (const q of held) {
    qs.add(q);
    h.update('quest ' + q + ' ' + (plan.enders.get(q) || '') + '\n');
    for (let j = hi; j < S.length; j++) if (S[j].q === q) h.update(S[j].content + '\n');
  }
  for (const u of plan.unlocks) if (qs.has(u.q) || u.vals.some((v) => qs.has(v))) h.update('unlocks ' + u.line + '\n');
  const far = new Set();
  for (let j = hi; j < S.length; j++) {
    if (S[j].k === 'bind') far.add('bind ' + [S[j].m, S[j].x, S[j].y, S[j].bind || S[j].zone].join(' '));
    if (S[j].k === 'fp') far.add('fp ' + S[j].m);
  }
  h.update([...far].sort().join('\n'));
  return h.digest('hex').slice(0, 20);
}

// a checkpoint file's text (the store keeps them gzipped: a tenth of the size), and its header (null when the file
// isn't complete)
function readText(file) {
  try { const b = fs.readFileSync(file); return (file.endsWith('.gz') ? zlib.gunzipSync(b) : b).toString('utf8'); } catch (e) { return null; }
}
// a stored checkpoint, unpacked for the simulator
function unpack(file, to) { const t = readText(file); if (t === null) throw new Error('cannot read ' + file); fs.writeFileSync(to, t); }
function readMeta(file) {
  const t = readText(file);
  if (!t || !t.startsWith('-- META ') || !t.endsWith('\n-- end\n')) return null;
  try { return JSON.parse(t.slice(8, t.indexOf('\n'))); } catch (e) { return null; }
}
const storeDir = (root, combo, persona) => path.join(root, 'reports', 'simplay-ckpt', combo, persona);
const stored = (dir) => { try { return fs.readdirSync(dir).filter((f) => /^\d{3}-[0-9a-f]{20}\.lua\.gz$/.test(f)); } catch (e) { return []; } };

// the deepest stored checkpoint whose key matches this plan -> { file, meta } or null; why says what was looked at
function pick(plan, base, dir) {
  const files = stored(dir).sort().reverse();
  for (const f of files) {
    const meta = readMeta(path.join(dir, f));
    if (!meta || meta.unsafe) continue;
    if (keyOf(plan, meta, base) === f.slice(4, 24)) return { file: path.join(dir, f), meta, of: files.length };
  }
  return { file: null, of: files.length };
}

// after a run: the checkpoints it wrote (staging dir, <leg>.lua) go into the store under their key; then the store
// keeps only those that match this plan -> { kept, added, dropped, unusable: [reasons] }
function ingest(stage, plan, base, dir) {
  fs.mkdirSync(dir, { recursive: true });
  const res = { added: 0, dropped: 0, kept: 0, unusable: [] };
  let names = []; try { names = fs.readdirSync(stage).filter((f) => /^\d{3}\.lua$/.test(f)); } catch (e) {}
  for (const f of names) {
    const meta = readMeta(path.join(stage, f));
    if (!meta) continue;
    if (meta.unsafe) { res.unusable.push('leg ' + meta.leg + ': ' + meta.unsafe); continue; }
    const key = keyOf(plan, meta, base);
    if (!key) continue;
    const to = path.join(dir, f.slice(0, 3) + '-' + key + '.lua.gz');
    fs.writeFileSync(to + '.tmp', zlib.gzipSync(fs.readFileSync(path.join(stage, f)))); fs.renameSync(to + '.tmp', to);
    res.added++;
  }
  for (const f of stored(dir)) {
    const meta = readMeta(path.join(dir, f));
    if (meta && !meta.unsafe && keyOf(plan, meta, base) === f.slice(4, 24)) res.kept++;
    else { fs.rmSync(path.join(dir, f), { force: true }); res.dropped++; }
  }
  return res;
}

// the whole store under a size: the plans whose checkpoints were touched longest ago go first (not one touched in the
// last hour - a batch may be using it)
function cap(root, mb = +(process.env.FR_SIM_CKPT_MB || 1024)) {
  const top = path.join(root, 'reports', 'simplay-ckpt');
  let combos = []; try { combos = fs.readdirSync(top); } catch (e) { return 0; }
  const info = combos.map((c) => {
    let size = 0, newest = 0;
    const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else { const s = fs.statSync(p); size += s.size; newest = Math.max(newest, s.mtimeMs); } } };
    try { walk(path.join(top, c)); } catch (e) {}
    return { c, size, newest };
  }).sort((a, b) => a.newest - b.newest);
  let total = info.reduce((s, x) => s + x.size, 0), dropped = 0;
  for (const x of info) {
    if (total <= mb * 2 ** 20) break;
    if (Date.now() - x.newest < 3600e3) continue;
    fs.rmSync(path.join(top, x.c), { recursive: true, force: true }); total -= x.size; dropped++;
  }
  return dropped;
}

module.exports = { VERSION, MIN_LEG, LOOK, parsePlan, legs, codeHash, baseOf, keyOf, readMeta, unpack, storeDir, pick, ingest, cap };
