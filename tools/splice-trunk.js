// Experiment: one leveling trunk per faction instead of a plan per race and class. Splices a built-in plan's own start
// (its steps below level --at) onto another plan's steps from that level on (the trunk), the way a shared trunk with
// race starts and class branches would play:
//   - trunk quests already handed in during the start are dropped (and their pick-ups if already picked up)
//   - the trunk class's own quests (in no other class's plans) and training are dropped
//   - the target's own training and class-only quests past the cut go in where their level falls on the trunk
// The result is a Plan.lua to play with FR_SIM_PLAN (tools/simplay.js): compare hours and checks with the target's own.
// usage: node tools/splice-trunk.js <target race_class> <trunk race_class> [--at 20] [--out file]
const fs = require('fs'), path = require('path');
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf('--' + k); return i >= 0 ? args[i + 1] : d; };
const [target, trunkKey] = args.filter((a, i) => !a.startsWith('--') && !(i > 0 && args[i - 1].startsWith('--')));
const AT = +opt('at', 20);
const root = path.join(__dirname, '..', 'addon');
const read = (k) => fs.readFileSync(path.join(root, 'ForeverRoute_Starter_' + k, 'Plan.lua'), 'utf8').split(/\r?\n/);
// the first route's sections and steps (one per line), and where they sit in the file
function parse(lines) {
  const sec0 = lines.findIndex((l) => l === '    sections = {');
  let sec1 = sec0 + 1; while (lines[sec1] !== '    },') sec1++;
  const st0 = lines.findIndex((l, i) => i > sec1 && l === '    steps = {');
  let st1 = st0 + 1; while (lines[st1] !== '    },') st1++;
  const steps = lines.slice(st0 + 1, st1).map((l) => ({ line: l, k: (l.match(/\bk = "(\w+)"/) || [])[1], q: +((l.match(/\bq = (\d+)/) || [])[1] || 0), lvl: +((l.match(/\blvl = (\d+)/) || [])[1] || 0), sec: +((l.match(/\bsec = (\d+)/) || [])[1] || 0) }));
  return { sec0, sec1, st0, st1, sections: lines.slice(sec0 + 1, sec1), steps };
}
// which quests are one class's only (in no other class's plans)
const classesOf = {};
for (const d of fs.readdirSync(root)) {
  const m = d.match(/^ForeverRoute_Starter_(\w+)_(\w+)$/); if (!m) continue;
  for (const l of fs.readFileSync(path.join(root, d, 'Plan.lua'), 'utf8').split(/\r?\n/)) { const q = l.match(/\bq = (\d+)/); if (q && /\bk = "accept"/.test(l)) (classesOf[q[1]] = classesOf[q[1]] || new Set()).add(m[2]); }
}
const onlyClass = (q, cls) => { const s = classesOf[q]; return !!s && s.size === 1 && s.has(cls); };
const tCls = target.split('_')[1], kCls = trunkKey.split('_')[1];
const T = read(target), K = read(trunkKey);
const t = parse(T), k = parse(K);
const cutT = t.steps.findIndex((s) => s.lvl >= AT);
// where the trunk is joined: by level (the trunk's first step at --at), or with --join zone at the trunk's first step,
// from a few levels before, in the zone the start just left off in - you carry on where you are instead of crossing
// the world to where the trunk happens to be at that level
const zoneOf = (st) => (st.line.match(/zone = "([^"]+)"/) || [])[1];
let cutK = k.steps.findIndex((s) => s.lvl >= AT);
if (opt('join', 'level') === 'zone') {
  const z = zoneOf(t.steps[cutT - 1] || t.steps[cutT]);
  const from = k.steps.findIndex((s) => s.lvl >= AT - 4);
  const j = k.steps.findIndex((s, i) => i >= from && s.lvl <= AT + 4 && zoneOf(s) === z);
  if (j >= 0) cutK = j;
}
const start = t.steps.slice(0, cutT);
const accepted = new Set(start.filter((s) => s.k === 'accept').map((s) => s.q));
const handed = new Set(start.filter((s) => s.k === 'turnin').map((s) => s.q));
// the trunk from the cut, without what the start did and without the trunk class's own
const trunk = k.steps.slice(cutK).filter((s) => {
  if (s.k === 'train') return false;
  if (s.q && onlyClass(s.q, kCls) && kCls !== tCls) return false;
  if (s.q && handed.has(s.q)) return false;
  if (s.k === 'accept' && accepted.has(s.q)) return false;
  return true;
});
// the target's own branches past the cut: training and its class-only quests, placed by level
const branch = t.steps.slice(cutT).filter((s) => s.k === 'train' || (s.q && onlyClass(s.q, tCls) && kCls !== tCls));
const inTrunk = new Set(trunk.map((s) => s.q).filter(Boolean));
const merged = trunk.slice();
for (const b of branch) {
  if (b.q && inTrunk.has(b.q) && b.k !== 'train') continue;
  let j = merged.findIndex((s) => s.lvl > b.lvl); if (j < 0) j = merged.length;
  // (after the steps of the branch already placed for the same quest: pick-up before hand-in)
  if (b.q) for (let x = 0; x < merged.length; x++) if (merged[x].q === b.q && merged[x].branch && x >= j) j = x + 1;
  merged.splice(j, 0, { ...b, branch: true });
}
// sections: the target's for its start and branches, the trunk's (renumbered after them) for the trunk
const secOff = t.sections.length;
const out = start.concat(merged.map((s) => s.branch ? s : { ...s, line: s.line.replace(/\bsec = (\d+)/, (_, n) => 'sec = ' + (+n + secOff)) }));
const lines = out.map((s, i) => s.line.replace(/\bid = \d+/, 'id = ' + (i + 1)));
const sections = t.sections.concat(k.sections);
const res = T.slice(0, t.sec0 + 1).concat(sections, T.slice(t.sec1, t.st0 + 1), lines, T.slice(t.st1));
// the trunk's chain table too (what each quest unlocks): merged into the target's, its own entries first
const kUnl = K.findIndex((l) => l.startsWith('ForeverRouteUnlocks = {'));
let kEnd = kUnl + 1; while (K[kEnd] !== '}') kEnd++;
const endAt = res.lastIndexOf('end');
res.splice(endAt, 0, 'local trunkUnlocks = {', ...K.slice(kUnl + 1, kEnd), '}', 'for q, v in pairs(trunkUnlocks) do if ForeverRouteUnlocks[q] == nil then ForeverRouteUnlocks[q] = v end end');
const file = opt('out', path.join(__dirname, '..', 'paths-starter', `trunk-${target}-on-${trunkKey}-at${AT}${opt('join', 'level') === 'zone' ? '-zone' : ''}.lua`));
fs.mkdirSync(path.dirname(file), { recursive: true });
fs.writeFileSync(file, res.join('\n'));
console.log(`${target} on the ${trunkKey} trunk from level ${AT}: start ${start.length} steps, trunk ${trunk.length} (of ${k.steps.length - cutK}), branches ${branch.length}; own plan had ${t.steps.length}, spliced ${out.length} -> ${file}`);
