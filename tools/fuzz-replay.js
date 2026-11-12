// Mutation / fuzz test of the live "what next": drop random characters - any race and class with a built-in plan, any
// level, anywhere in the world at random coordinates, with a random history, quest log and flight paths - into the real
// login sequence (tools/replay.js on the simulator), and check that the card puts each on a sensible track. The
// scripted scenarios only cover what someone thought of; this covers what nobody did.
//
// A character is:
//   plan       a random built-in plan (addon/ForeverRoute_Starter_<race>_<class>)
//   level      2-59
//   where      near a spot where a plan of its faction quests around its level (its own mostly, another now and then),
//              or one of its faction's capitals - real places for a real player at that level
//   history    follower (did the plan up to here) | sloppy (did about half of it) | fresh (new to the addon: nothing)
//   log        some of the plan's quests around this level (some finished), a few gray stragglers, sometimes nearly full
//   flights    most of the flight paths its plan learns before this level, a few from other plans; 5% none known
//   now and then dead (a ghost), or logging in in a capital
// What's wrong is what replay.js flags "!!" (a step you can't or shouldn't do, nothing shown, a gray or too-high quest,
// an error, a far stop added first, a pick-up with the log full, ...). Every character is written out with its seed,
// so a finding is reproduced with:  node tools/replay.js --char ... --plan ... --scenarios <file> --only <id>
//
// usage: node tools/fuzz-replay.js [--n 120] [--seed 1] [--plans human_warrior,orc_shaman] [--out reports/fuzz]
//                                 [--ignore LEAVES-WORK]   (flags to count but not fail on)  [--strict]
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const ROOT = path.join(__dirname, '..');
const args = {};
for (let i = 2; i < process.argv.length; i++) { const a = process.argv[i]; if (a.startsWith('--')) { const n = process.argv[i + 1]; if (!n || n.startsWith('--')) args[a.slice(2)] = true; else { args[a.slice(2)] = n; i++; } } }
const N = +(args.n || 120), SEED = +(args.seed || 1);
const OUT = path.resolve(args.out || path.join(ROOT, 'reports', 'fuzz'));
const IGNORE = new Set(String(args.ignore || '').split(',').filter(Boolean));
fs.mkdirSync(OUT, { recursive: true });

// a small seeded generator (mulberry32): the same seed, the same characters
function rng(seed) { let a = seed >>> 0; return () => { a |= 0; a = (a + 0x6D2B79F5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
const R = rng(SEED);
const pick = (a) => a[Math.floor(R() * a.length)];
const int = (lo, hi) => lo + Math.floor(R() * (hi - lo + 1));

// the plans, their steps (k, q, level, lvl, m, x, y, npc) - first path only
const plans = fs.readdirSync(path.join(ROOT, 'addon')).filter((d) => d.startsWith('ForeverRoute_Starter_'))
  .map((d) => d.slice('ForeverRoute_Starter_'.length))
  .filter((p) => !args.plans || String(args.plans).split(',').includes(p));
const BS = String.fromCharCode(92);
function steps(planDir) {
  const t = fs.readFileSync(path.join(ROOT, 'addon', 'ForeverRoute_Starter_' + planDir, 'Plan.lua'), 'utf8');
  const out = [];
  let inMain = false;
  for (const l of t.split('\n')) {
    if (/^\s{4}id = "path:/.test(l)) { if (inMain) break; inMain = true; continue; }
    if (!inMain || !/^\s+\{ (rate = \d+, )?k = "/.test(l)) continue;
    const g = (k) => { const m = l.match(new RegExp(BS + 'b' + k + ' = ("([^"]*)"|[-0-9.]+)')); return m ? (m[2] !== undefined ? m[2] : m[1]) : undefined; };
    out.push({ k: g('k'), q: +g('q') || 0, level: +g('level') || 0, lvl: +g('lvl') || 0, m: +g('m') || 0, x: +g('x'), y: +g('y'), npc: g('npc') });
  }
  // a step without a level (a flight path, a flight) takes the level of the next one that has one, as the addon does
  let next = 0;
  for (let i = out.length - 1; i >= 0; i--) { if (out[i].lvl) next = out[i].lvl; else out[i].lvl = next; }
  return out;
}
// flight point names by flight master, per faction (FlightMasters.lua)
const fmText = fs.readFileSync(path.join(ROOT, 'addon', 'ForeverRoute', 'FlightMasters.lua'), 'utf8');
const FP = { Alliance: {}, Horde: {} };
{ let side = null; for (const l of fmText.split('\n')) { const s = l.match(/^\s{2}(Alliance|Horde) = \{/); if (s) side = s[1]; if (!side) continue; for (const m of l.matchAll(/\{ [0-9.]+, [0-9.]+, "([^"]+)", "([^"]+)" \}/g)) FP[side][m[1]] = m[2]; } }
const HORDE = new Set(['orc', 'troll', 'tauren', 'undead']);
// (Skyborne: the simulator has no such race - played as a Human of the same plan, as replay.js does)
const RACE = { nightelf: 'NightElf', undead: 'Scourge', skyborne: 'Human' };
// Real players, not impossible ones: a character is somewhere a player of its faction and level actually is - a spot
// where some plan of its faction quests around its level (a level 4 is never in Stranglethorn), near a real quest
// spot rather than a random point in a lake - and knows the flight paths a player at that level has: most of what its
// plan learned before this level (people miss a few), some from other plans of its faction at or below its level,
// none at level 4. "No flight paths known" (the flight map never opened: a real addon state) is a small share, labelled.
const SIDE_OF = (planDir) => (HORDE.has(planDir.split('_')[0]) ? 'Horde' : 'Alliance');
const planSteps = {};
const SPOTS = { Alliance: [], Horde: [] }; // { plan, m, x, y, lvl } of every located plan step
const FPS = { Alliance: [], Horde: [] };   // { name, lvl } of every flight path a plan learns
for (const p of plans) {
  const S = steps(p); planSteps[p] = S;
  const side = SIDE_OF(p);
  for (const s of S) {
    if (s.m && s.x >= 0 && s.lvl) SPOTS[side].push({ plan: p, m: s.m, x: s.x, y: s.y, lvl: s.lvl });
    if (s.k === 'fp' && s.lvl && FP[side][s.npc]) FPS[side].push({ name: FP[side][s.npc], lvl: s.lvl });
  }
}
const CAPITALS = { Alliance: [[1453, 0.6, 0.7], [1455, 0.3, 0.6], [1457, 0.4, 0.5]], Horde: [[1454, 0.5, 0.7], [1458, 0.6, 0.5], [1456, 0.4, 0.5]] };
const jitter = (v) => +Math.min(0.97, Math.max(0.03, v + (R() - 0.5) * 0.08)).toFixed(3);

// ---- the characters
const byPlan = {};
for (let n = 0; n < N; n++) {
  const plan = pick(plans);
  const [race, cls] = plan.split('_');
  const S = planSteps[plan];
  const level = int(2, 59);
  const id = `fz${SEED}-${n}`;
  const side = SIDE_OF(plan);
  // where: near a spot where a plan of this faction quests around this level - its own plan mostly, another one (off
  // its track) now and then; or one of its faction's capitals
  let at, where;
  const band = (s) => s.lvl >= level - 5 && s.lvl <= level + 3;
  const own = SPOTS[side].filter((s) => s.plan === plan && band(s));
  const other = SPOTS[side].filter((s) => s.plan !== plan && band(s));
  const roll = R();
  if (roll < 0.1 || (!own.length && !other.length)) { at = pick(CAPITALS[side]).slice(); where = 'capital'; }
  else if (roll < 0.27 && other.length) { const s = pick(other); at = [s.m, jitter(s.x), jitter(s.y)]; where = 'off its track'; }
  else { const s = pick(own.length ? own : other); at = [s.m, jitter(s.x), jitter(s.y)]; where = 'on its track'; }
  // history: the plan's quests handed in below this level - all of them, about half, or none
  const mode = pick(['follower', 'follower', 'sloppy', 'fresh']);
  const doneQ = new Set();
  if (mode !== 'fresh') for (const s of S) if (s.k === 'turnin' && s.q && s.lvl && s.lvl < level - 1 && (mode === 'follower' || R() < 0.5)) doneQ.add(s.q);
  // the log: the plan's quests around this level, some finished; a few gray stragglers; sometimes near full
  const near = [...new Set(S.filter((s) => s.k === 'accept' && s.q && !doneQ.has(s.q) && s.lvl && Math.abs(s.lvl - level) <= 2).map((s) => s.q))];
  const gray = [...new Set(S.filter((s) => s.k === 'accept' && s.q && !doneQ.has(s.q) && s.level && s.level < level - 8).map((s) => s.q))];
  const addLog = [];
  for (const q of near.sort(() => R() - 0.5).slice(0, int(0, 12))) addLog.push({ id: q, complete: R() < 0.35, level: (S.find((s) => s.q === q) || {}).level || level });
  for (const q of gray.sort(() => R() - 0.5).slice(0, int(0, 3))) addLog.push({ id: q, complete: R() < 0.5, level: (S.find((s) => s.q === q) || {}).level || 1 });
  const logPad = R() < 0.1 ? int(20, 60) : 0;
  // flights: most of what its own plan learned before this level, a few from other plans of its faction at or below it;
  // 5%: none known to the addon (the flight map never opened)
  let taxi;
  if (R() < 0.05) taxi = 'none';
  else {
    const mine = S.filter((s) => s.k === 'fp' && s.lvl && s.lvl < level && FP[side][s.npc]).map((s) => FP[side][s.npc]).filter(() => R() < 0.85);
    const extra = FPS[side].filter((f) => f.lvl < level - 2).map((f) => f.name).filter(() => R() < 0.15);
    taxi = [...new Set([...mine, ...extra])];
  }
  const sc = { id, note: `${race} ${cls} ${level}, ${mode}, ${where}, ${addLog.length} in log${logPad ? ' +' + logPad : ''}, ${taxi === 'none' ? 'flight map never opened' : taxi.length + ' flight paths'} @${at.join(',')}`,
    level, at, history: [...doneQ], log: 'none', addLog, logPad, taxi, ticks: 'none' };
  if (R() < 0.05) sc.dead = true;
  (byPlan[plan] = byPlan[plan] || []).push(sc);
}

// ---- run them, plan by plan
const results = [];
const counts = {};
let ran = 0, failed = 0;
for (const [plan, list] of Object.entries(byPlan)) {
  const [race, cls] = plan.split('_');
  const scFile = path.join(OUT, `scenarios-${SEED}-${plan}.json`);
  const jsonFile = path.join(OUT, `result-${SEED}-${plan}.json`);
  fs.writeFileSync(scFile, JSON.stringify(list, null, 1));
  const charArg = `race=${RACE[race] || race},class=${cls}`;
  try {
    execFileSync(process.execPath, [path.join(__dirname, 'replay.js'), '--char', charArg, '--plan', path.join(ROOT, 'addon', 'ForeverRoute_Starter_' + plan), '--scenarios', scFile, '--json', jsonFile, '--next', '3', '--quiet'], { stdio: ['ignore', 'pipe', 'pipe'], timeout: 900000, maxBuffer: 64 << 20 });
  } catch (e) { if (!fs.existsSync(jsonFile)) { console.log(`${plan}: the replay gave no result (${String(e.message).split('\n')[0]})`); continue; } }
  const res = JSON.parse(fs.readFileSync(jsonFile, 'utf8'));
  for (const s of res.scenarios || []) {
    ran++;
    const hard = (s.flags || []).filter((f) => f.startsWith('!!') || f === 'NO-RESULT').map((f) => f.replace(/^!! /, ''));
    const kinds = [...new Set(hard.map((f) => f.split(':')[0]))];
    for (const k of kinds) counts[k] = (counts[k] || 0) + 1;
    const real = kinds.filter((k) => !IGNORE.has(k));
    if (real.length) failed++;
    results.push({ plan, id: s.id, note: s.note, kinds, hard, card: (() => { const c = s.result && s.result.cps && s.result.cps[s.result.cps.length - 1]; const st = c && c.step; return st ? `#${st.i} ${st.k} ${st.name || ''} @${st.zone || '?'}` : null; })(), cmd: `node tools/replay.js --char ${charArg} --plan addon/ForeverRoute_Starter_${plan} --scenarios ${path.relative(ROOT, scFile).replace(/\\/g, '/')} --only ${s.id}` });
  }
  process.stdout.write(`${plan}: ${list.length}  `);
}
console.log('');
// ---- the report
const L = [`# Fuzz: ${ran} random characters (seed ${SEED})`, '', `${failed} with something a player would call wrong${IGNORE.size ? ` (not counting ${[...IGNORE].join(', ')})` : ''}.`, '', '| flag | characters |', '|---|---|'];
for (const [k, n] of Object.entries(counts).sort((a, b) => b[1] - a[1])) L.push(`| ${k}${IGNORE.has(k) ? ' (ignored)' : ''} | ${n} |`);
L.push('', '## Examples (up to 3 per flag)', '');
for (const k of Object.keys(counts)) {
  L.push(`### ${k}`);
  for (const r of results.filter((x) => x.kinds.includes(k)).slice(0, 3)) L.push(`- ${r.plan}: ${r.note}`, `  - ${r.hard.find((h) => h.startsWith(k))}`, `  - \`${r.cmd}\``);
  L.push('');
}
const report = path.join(OUT, `fuzz-${SEED}.md`);
fs.writeFileSync(report, L.join('\n'));
fs.writeFileSync(path.join(OUT, `fuzz-${SEED}.json`), JSON.stringify(results, null, 1));
console.log(L.slice(0, 8 + Object.keys(counts).length).join('\n'));
console.log('report: ' + path.relative(ROOT, report));
if (args.strict && failed) process.exit(3);
