// Reading a Route.lua (the plan file the addon loads) - one reader for every tool, so they can't drift apart (the
// companion once stopped reading steps at the first kill step, because its own pattern expected "{ k =" first).
//   blocks(text)          per-character blocks (ForeverRouteByChar["Name-Realm"]): Map name -> { inner, whole }
//   own(text, name)       that character's plan text (an older single-plan file is all one character's)
//   routeIds(text, re)    route ids in order (re filters, e.g. /^path:/)
//   steps(text, id, n)    the steps of a route as objects (k, q, name, text, lvl, m, x, y, tm, ...), at most n
//   meta(text, id)        { legs: [...], dropped: [...] } of a path
const BLOCK_RE = /-- ForeverRoute plan for (\S+) begin\n[\s\S]*?\nForeverRouteByChar\[[^\]]+\] = function\(\)\n([\s\S]*?)\nend\n-- ForeverRoute plan for \1 end\n/g;
function blocks(text) {
  const m = new Map();
  for (const b of (text || '').matchAll(BLOCK_RE)) m.set(b[1], { inner: b[2], whole: b[0] });
  return m;
}
function own(text, name) { const b = blocks(text); return b.size ? (b.has(name) ? b.get(name).inner : '') : (text || ''); }

function routeIds(text, filter) {
  const ids = [...(text || '').matchAll(/^ {4}id = "([^"]+)",/gm)].map((m) => m[1]);
  return filter ? ids.filter((id) => filter.test(id)) : ids;
}
// where a route starts: its id line (or the first path when no id is given or found)
function startOf(text, id) {
  let at = id ? text.indexOf('    id = ' + JSON.stringify(id) + ',') : -1;
  if (at < 0) at = text.indexOf('    id = "path:');
  return at;
}
const STEP_LINE = /^ {6}\{ .*\bk = "/; // a step line (kill/collect steps start with their drop rate, not k)
function steps(text, id, n) {
  const at = startOf(text || '', id); if (at < 0) return [];
  const st = text.indexOf('    steps = {', at); if (st < 0) return [];
  const out = [];
  for (const l of text.slice(st).split('\n').slice(1)) {
    if (!STEP_LINE.test(l)) break;
    const o = {};
    for (const m of l.matchAll(/(\w+) = ("([^"]*)"|-?[\d.]+|true|false)/g)) o[m[1]] = m[3] !== undefined ? m[3] : (m[2] === 'true' ? true : m[2] === 'false' ? false : +m[2]);
    out.push(o);
    if (n && out.length >= n) break;
  }
  return out;
}
function meta(text, id) {
  const at = startOf(text || '', id); if (at < 0) return null;
  const end = text.indexOf('    steps = {', at);
  const head = text.slice(at, end < 0 ? at + 4000 : end);
  const legs = /legs = "([^"]*)"/.exec(head), dropped = /dropped = "([^"]*)"/.exec(head);
  return { legs: legs ? legs[1].split(' > ') : [], dropped: dropped ? dropped[1].split(', ') : [] };
}
// what changed on your path between the plan you have and a new one, for "reload to get it" (tools/autoplan.js):
//   added    steps in the new plan's next 15 that yours doesn't have soon (next 80) - something new to do
//   dropped  steps in your plan's next 15 that the new one doesn't have soon and that you haven't done (snap: the save's
//            snapshot) - your plan would still send you there (a flight-path detour the new plan dropped once went
//            unannounced: only additions were counted)
// Order alone is not a change.
const stepKey = (s) => (s.k || '') + ':' + (s.q !== undefined ? s.q : '') + ':' + (s.npc || s.dest || s.text || '');
function doneNow(s, snap) {
  if (!snap) return false;
  const completed = new Set((snap.completed || []).map(Number)), log = snap.log || {};
  if (s.q !== undefined && s.q !== '') {
    if (completed.has(+s.q)) return true;
    const inLog = log[s.q] || log[String(s.q)];
    if (s.k === 'accept' && inLog) return true;
    if (s.k === 'obj' && inLog && inLog.complete) return true;
    return false;
  }
  // a flight path in the step's zone that you know (the addon's Engine.KnowsFlightIn: "Stonetalon Peak, Stonetalon
  // Mountains" counts for Stonetalon Mountains)
  if (s.k === 'fp' && s.zone) {
    const z = String(s.zone).toLowerCase().replace(/ city$/, '').replace(/^the /, ''), first = z.split(' ')[0];
    return (Array.isArray(snap.taxi) ? snap.taxi : Object.keys(snap.taxi || {})).some((t) => { t = String(t).toLowerCase(); return t.includes(z) || (first.length >= 5 && t.includes(first)); });
  }
  return false;
}
function aheadChanges(oldText, newText, id, snap) {
  const oldSteps = steps(oldText, id, 80), newSteps = steps(newText, id, 80);
  if (!oldSteps.length || !newSteps.length) return { changed: true, added: [], dropped: [] };
  const oldKeys = new Set(oldSteps.map(stepKey)), newKeys = new Set(newSteps.map(stepKey));
  const added = newSteps.slice(0, 15).map(stepKey).filter((k) => !oldKeys.has(k));
  const dropped = oldSteps.filter((s) => !doneNow(s, snap)).slice(0, 15).filter((s) => !newKeys.has(stepKey(s))).map(stepKey);
  return { changed: added.length > 0 || dropped.length > 0, added, dropped };
}
module.exports = { blocks, own, routeIds, steps, meta, stepKey, aheadChanges };
