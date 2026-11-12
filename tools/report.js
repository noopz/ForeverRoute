// Decode a /fr report (UI/Report.lua) pasted by a player: prints what it says, and with --save writes it as a
// character save (ForeverRouteChar) that the replay tools (tools/save-fixture.js, tools/live-check.js, tools/replay.js)
// load like a real one - so a report from anyone can be replayed in the simulator.
// usage: node tools/report.js <file with the pasted report | -> [--save <out ForeverRoute.lua>] [--json]
const fs = require('fs');

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
const T = { meta: 1, log: 2, completed: 3, taxi: 4, ticks: 5, why: 6, errorsOld: 7, card: 8, settings: 9, where: 10, errors: 11 };
const KINDS = ['accept', 'turnin', 'obj', 'fly', 'fp', 'hearth', 'train', 'bind', 'goto', 'grind', 'bonus', 'special'];
const REASONS = ['?', 'done', 'todo', 'blocked', 'wait', 'notready', 'later', 'skipped by you', 'ticked by you', "won't do",
  'outlevelled', 'gray hand-in', 'breadcrumb', 'behind you (joined mid-plan)', 'not offered'];

function decode(text) {
  const m = /FR(\d+)\.([A-Za-z0-9_-]+)/.exec(String(text));
  if (!m) throw new Error('no "FR1." block in the text');
  const s = m[2], bytes = [];
  for (let i = 0; i < s.length; i += 4) {
    const c = [0, 1, 2, 3].map((k) => (i + k < s.length ? B64.indexOf(s[i + k]) : -1));
    const v = c[0] * 262144 + c[1] * 4096 + Math.max(0, c[2]) * 64 + Math.max(0, c[3]);
    bytes.push(Math.floor(v / 65536) % 256);
    if (c[2] >= 0) bytes.push(Math.floor(v / 256) % 256);
    if (c[3] >= 0) bytes.push(v % 256);
  }
  let p = 0;
  const rb = () => bytes[p++] || 0;
  const rv = () => { let n = 0, mul = 1; for (;;) { const x = rb(); n += (x % 128) * mul; if (x < 128) return n; mul *= 128; } };
  const rs = () => { const len = rv(); const b = Buffer.from(bytes.slice(p, p + len)); p += len; return b.toString('utf8'); };
  const d = { format: +m[1], head: String(text).split(/\r?\n/).find((l) => l.startsWith('FR report')) || '' };
  while (p < bytes.length) {
    const tag = rb(), len = rv(), stop = p + len;
    if (tag === T.meta) {
      d.meta = { version: rs(), client: rs(), time: rv(), race: rs(), class: rs(), faction: rs(), level: rv(), xp: rv(), xpMax: rv(), map: rv(),
        x: rv() / 10000, y: rv() / 10000, bind: rs(), plan: rs(), stamp: rs(), route: rs(), current: rv(), steps: rv(), step: rs(), stepQ: rv(), stepKey: rs() };
    } else if (tag === T.log) {
      d.log = {};
      for (let n = rv(); n > 0; n--) { const id = rv(); const q = { complete: rb() === 1, objectives: [] }; for (let k = rv(); k > 0; k--) q.objectives.push([rv(), rv(), rb() === 1]); d.log[id] = q; }
    } else if (tag === T.completed) {
      d.completed = []; let last = 0; for (let n = rv(); n > 0; n--) { last += rv(); d.completed.push(last); }
    } else if (tag === T.taxi) {
      d.taxi = []; for (let n = rv(); n > 0; n--) d.taxi.push(rs());
    } else if (tag === T.ticks) {
      d.ticks = { skipped: [], manualDone: [], nope: [] };
      for (let n = rv(); n > 0; n--) d.ticks.skipped.push(rs());
      for (let n = rv(); n > 0; n--) d.ticks.manualDone.push(rs());
      for (let n = rv(); n > 0; n--) d.ticks.nope.push(rv());
    } else if (tag === T.card) {
      d.card = []; for (let n = rv(); n > 0; n--) d.card.push({ i: rv(), reason: REASONS[rb()] || '?', k: KINDS[rb() - 1] || '?', q: rv() });
    } else if (tag === T.why) {
      d.why = []; for (let n = rv(); n > 0; n--) d.why.push({ t: rv(), k: rs(), lv: rv(), m: rv(), x: rs() });
    } else if (tag === T.errorsOld) {
      d.errors = []; for (let n = rv(); n > 0; n--) d.errors.push({ where: rs(), count: rv(), msg: rs(), shown: rs() });
    } else if (tag === T.errors) {
      d.errors = []; for (let n = rv(); n > 0; n--) d.errors.push({ where: rs(), count: rv(), msg: rs(), shown: rs(), version: rs(), last: rv() });
    } else if (tag === T.where) {
      const map = rv(), f = rv(); d.where = { map };
      ["taxi", "indoors", "dead", "instance", "mounted", "coords"].forEach((k, i) => { d.where[k] = !!(f & (1 << i)); });
    } else if (tag === T.settings) {
      const f = rv(); d.settings = {}; ['pathLine', 'pins', 'hideDone', 'markTarget'].forEach((k, i) => { d.settings[k] = !!(f & (1 << i)); });
    }
    p = stop;
  }
  return d;
}

// the report as a SavedVariablesPerCharacter file: ForeverRouteChar with the snapshot the replay tools read
function toSave(d) {
  const L = (v) => (typeof v === 'string' ? JSON.stringify(v) : typeof v === 'boolean' || typeof v === 'number' ? String(v) : 'nil');
  const m = d.meta || {};
  const out = ['ForeverRouteChar = {'];
  out.push(`  ["routeTitle"] = ${L(m.route || '')},`);
  const set = (name, keys) => { out.push(`  ["${name}"] = {`); for (const k of keys) out.push(`    [${typeof k === 'number' ? k : L(k)}] = true,`); out.push('  },'); };
  set('skipped', (d.ticks && d.ticks.skipped) || []);
  set('manualDone', (d.ticks && d.ticks.manualDone) || []);
  set('nope', (d.ticks && d.ticks.nope) || []);
  set('knownTaxi', d.taxi || []);
  out.push('  ["snapshot"] = {');
  out.push(`    ["reason"] = "report", ["time"] = ${m.time || 0}, ["version"] = 1, ["race"] = ${L(m.race)}, ["class"] = ${L(m.class)}, ["faction"] = ${L(m.faction)},`);
  out.push(`    ["level"] = ${m.level || 1}, ["xp"] = ${m.xp || 0}, ["xpMax"] = ${m.xpMax || 0}, ["bind"] = ${L(m.bind || '')},`);
  out.push(`    ["pos"] = { ["map"] = ${m.map || 0}, ["x"] = ${m.x || 0}, ["y"] = ${m.y || 0} },`);
  out.push(`    ["routeId"] = ${L(m.route || '')}, ["routeStep"] = ${m.current || 0},`);
  out.push(`    ["completed"] = { ${(d.completed || []).join(', ')} },`);
  out.push(`    ["taxi"] = { ${(d.taxi || []).map(L).join(', ')} },`);
  out.push('    ["log"] = {');
  for (const [id, q] of Object.entries(d.log || {})) {
    out.push(`      [${id}] = { ["complete"] = ${q.complete}, ["objectives"] = { ${q.objectives.map((o) => `{ ${o[0]}, ${o[1]}, ${o[2]} }`).join(', ')} } },`);
  }
  out.push('    },');
  out.push('  },');
  out.push('}');
  return out.join('\n') + '\n';
}

module.exports = { decode, toSave };

if (require.main === module) {
  const args = process.argv.slice(2);
  const src = args[0];
  if (!src) { console.log('usage: node tools/report.js <file with the pasted report | -> [--save <out ForeverRoute.lua>] [--json]'); process.exit(2); }
  const text = fs.readFileSync(src === '-' ? 0 : src, 'utf8');
  const d = decode(text);
  if (args.includes('--json')) { console.log(JSON.stringify(d, null, 1)); }
  else {
    const m = d.meta || {};
    console.log(d.head || '(no first line)');
    console.log(`addon ${m.version} (client ${m.client}) · ${m.race} ${m.class} ${m.faction} level ${m.level} (${m.xp}/${m.xpMax} xp) · map ${m.map} ${(m.x * 100).toFixed(1)},${(m.y * 100).toFixed(1)} · hearth ${m.bind}`);
    console.log(`plan: ${m.plan} ${m.stamp} · route ${m.route} · step ${m.current} of ${m.steps}: ${m.step} (q${m.stepQ}, ${m.stepKey})`);
    console.log(`quest log ${Object.keys(d.log || {}).length} · completed ${(d.completed || []).length}${(d.completed || []).length ? '' : ' (short report: not included)'} · flight paths ${(d.taxi || []).length} · skipped ${(d.ticks || {}).skipped?.length || 0} · ticked ${(d.ticks || {}).manualDone?.length || 0} · won't do ${(d.ticks || {}).nope?.length || 0}`);
    if (d.card && d.card.length) console.log('steps before the card: ' + d.card.map((c) => `#${c.i} ${c.k}${c.q ? ' q' + c.q : ''}: ${c.reason}`).join(' | '));
    for (const w of d.why || []) console.log(`  why ${new Date(w.t * 1000).toISOString().slice(11, 19)} ${w.k} lvl${w.lv} map${w.m}: ${w.x}`);
    if (d.where) console.log(`where: map ${d.where.map}` + ["taxi", "indoors", "dead", "instance", "mounted"].filter((k) => d.where[k]).map((k) => ' · ' + k).join('') + (d.where.coords ? '' : ' · no coordinates from the game'));
    for (const e of d.errors || []) console.log(`  error x${e.count} ${e.where}${e.version ? ' (version ' + e.version + (e.last ? ', last ' + new Date(e.last * 1000).toISOString().slice(0, 16) : '') + ')' : ''}: ${e.msg}${e.shown ? ' (card: ' + e.shown + ')' : ''}`);
  }
  const si = args.indexOf('--save');
  if (si > 0) { fs.writeFileSync(args[si + 1], toSave(d)); console.log('wrote ' + args[si + 1]); }
}
