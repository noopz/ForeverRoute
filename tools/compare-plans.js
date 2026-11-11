// How far a built-in plan (Starter.lua, made for a brand-new character) is from the plan the companion made for you:
// the built-in plan is followed from your real state with the addon's own rules (Engine.lua statusRaw: done, in your
// log, not offered by its giver, more than OUTLEVEL levels below you), and both plans' remaining quest hand-ins up to
// the target level are compared - which quests, how much quest XP, which zones, and what the planner estimated.
// usage: node tools/compare-plans.js <character SavedVariables dir> [targetLevel=30]
const fs = require('fs');
const path = require('path');
const RF = require('./routefile');
const { parseSavedVariables } = require('./luatable');
const ROOT = path.join(__dirname, '..');
const [charDir, tArg] = process.argv.slice(2);
if (!charDir) { console.log('usage: node tools/compare-plans.js <character SavedVariables dir> [targetLevel=30]'); process.exit(2); }
const TARGET = +(tArg || 30);
const OUTLEVEL = 6; // Engine.OUTLEVEL (addon) = campaign.js minQuestLevel = level - 6
const db = JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'db.json'), 'utf8'));
const c = parseSavedVariables(fs.readFileSync(path.join(charDir, 'ForeverRoute.lua'), 'utf8')).ForeverRouteChar || {};
const snap = c.snapshot || {};
const L = snap.level || 1;
const done = new Set((snap.completed || []).map(Number));
const inLog = new Set(Object.keys(snap.log || {}).map(Number));
const notOffered = new Set(Object.entries((c.avail && c.avail.no) || {}).filter(([, v]) => (v.lvl || 0) >= L).map(([k]) => +k));
const norm = (s) => String(s || '').toLowerCase().replace(/[^a-z]/g, '');
const key = norm(snap.race) + '-' + norm(snap.class);
const folder = path.basename(path.dirname(path.resolve(charDir))).replace(/\s/g, '');

// the two plans
const own = RF.own(fs.readFileSync(path.join(require('./game-dir').addonDir(), 'Route.lua'), 'utf8'), folder);
const starterRaw = fs.readFileSync(path.join(ROOT, 'addon', 'ForeverRoute', 'Starter.lua'), 'utf8');
const sm = new RegExp(`-- ForeverRoute starter for ${key} begin\\n[\\s\\S]*?= function\\(\\)\\n([\\s\\S]*?)\\nend\\n-- ForeverRoute starter for ${key} end`).exec(starterRaw);
if (!own || !sm) { console.log(!own ? 'no plan of yours in Route.lua for ' + folder : 'no built-in plan for ' + key); process.exit(1); }
const starter = sm[1];
const pathOf = (text, want) => { const ids = RF.routeIds(text, /^path:/); return ids.includes(want) ? want : ids[0]; };
const ownId = pathOf(own, c.routeId), stId = pathOf(starter, null);

// the addon's rules for a quest step, from your state
const status = (s) => {
  if (!s.q) return 'other';
  if (done.has(s.q)) return 'done';
  if (s.k === 'accept' && inLog.has(s.q)) return 'done';
  if (!inLog.has(s.q) && notOffered.has(s.q)) return 'not offered';
  if (!inLog.has(s.q) && s.level > 0 && s.level < L - OUTLEVEL) return 'outlevelled';
  if (s.k !== 'accept' && !inLog.has(s.q) && !done.has(s.q)) return 'todo-later'; // its accept comes first on the route
  return 'todo';
};
function remaining(text, id) {
  const steps = RF.steps(text, id);
  const turnins = [], skipped = { done: 0, 'not offered': 0, outlevelled: 0 };
  let first = null;
  const zones = [];
  for (const s of steps) {
    const st = status(s);
    if (skipped[st] !== undefined && s.k === 'turnin') skipped[st]++;
    if (st === 'todo' || st === 'todo-later') {
      if (!first) first = s;
      if (s.zone && zones[zones.length - 1] !== s.zone) zones.push(s.zone);
      if (s.k === 'turnin' && (s.lvl || L) < TARGET) turnins.push(s.q);
    }
  }
  // quest XP as you'd get it: reduced for quests well below you (world.js questXp), levelling up as you go (quest XP
  // only - kills come on top, so this is a floor)
  const W = require('./world');
  let lvl = L, cur = snap.xp || 0, xp = 0;
  for (const q of turnins) {
    const Q = db.quests[q]; if (!Q || !Q.xp) continue;
    const g = W.questXp(Q.xp, Q.level, lvl); xp += g;
    ({ level: lvl, xp: cur } = W.addXp(lvl, cur, g));
  }
  return { steps: steps.length, first, zones, turnins: new Set(turnins), xp, skipped, meta: RF.meta(text, id) };
}
const A = remaining(own, ownId), B = remaining(starter, stId);
const both = [...A.turnins].filter((q) => B.turnins.has(q));
const hours = (text, id) => { const m = new RegExp(`id = ${JSON.stringify(id)},[\\s\\S]{0,4000}?hoursTo = ([\\d.]+)`).exec(text) || new RegExp(`id = ${JSON.stringify(id)},[\\s\\S]{0,4000}?hours = ([\\d.]+)`).exec(text); return m ? +m[1] : null; };
const fmtFirst = (s) => (s ? `${s.k} ${s.name || s.text || ''} (${s.zone || '?'}, quest level ${s.level || '?'})` : 'nothing');
const L2 = [];
L2.push(`# Built-in plan vs your plan (${snap.name || folder}, level ${L}, to ${TARGET})`, '');
L2.push(`| | your plan (companion) | built-in plan (${key}, made for level 1) |`, '|---|---|---|');
L2.push(`| path | ${ownId} | ${stId} |`);
L2.push(`| picks up at | ${fmtFirst(A.first)} | ${fmtFirst(B.first)} |`);
L2.push(`| zones ahead | ${A.zones.slice(0, 8).join(' > ')} | ${B.zones.slice(0, 8).join(' > ')} |`);
L2.push(`| quest hand-ins before ${TARGET} | ${A.turnins.size} | ${B.turnins.size} |`);
L2.push(`| their quest XP (at your level as you go) | ${A.xp} | ${B.xp} |`);
L2.push(`| hand-ins passed over (done / not offered / outlevelled) | ${A.skipped.done} / ${A.skipped['not offered']} / ${A.skipped.outlevelled} | ${B.skipped.done} / ${B.skipped['not offered']} / ${B.skipped.outlevelled} |`);
L2.push(`| planner's estimate | ${hours(own, ownId) ?? '?'} h to ${TARGET} from level ${L} | ${hours(starter, stId) ?? '?'} h for 1 to ${TARGET} (a fresh character) |`);
L2.push('', `Hand-ins on both: ${both.length} (${Math.round((100 * both.length) / Math.max(1, A.turnins.size))}% of yours). Only on yours: ${A.turnins.size - both.length}. Only on the built-in plan: ${B.turnins.size - both.length}.`);
const xpTo = (() => { const XP = require('./world').XP_TO_LEVEL; let x = 0; for (let l = L; l < TARGET; l++) x += XP[l]; return x - (snap.xp || 0); })();
L2.push(`XP you need to reach ${TARGET}: ${xpTo}. Quest XP left on each plan covers ${Math.round((100 * A.xp) / xpTo)}% (yours) and ${Math.round((100 * B.xp) / xpTo)}% (built-in); kills make up the rest.`);
const out = L2.join('\n') + '\n';
fs.mkdirSync(path.join(ROOT, 'reports'), { recursive: true });
fs.writeFileSync(path.join(ROOT, 'reports', 'builtin-vs-yours.md'), out);
console.log(out);
