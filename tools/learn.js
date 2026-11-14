// What your play taught the addon (ForeverRouteDB.learn, recorded by Learn.lua) -> corrections for the planner and a
// report for you. Run by the companion before every replan.
//   kill XP   per level difference (mob - you): what kills really gave / what the Classic formula says, once at least
//             MIN_KILLS kills of that difference were seen  -> learned.killXpByDiff (world.js applies it)
//   pace      seconds per kill on "Kill N ..." steps (the median of steady work)    -> learned.secPerKill (route2)
//   incidents new ones since the last run go to reports/incidents.md, and the first few each run become replayed-save
//             tests (tools/save-fixture.js) so a route mistake you hit once is checked on every change from then on
// usage: node tools/learn.js <account ForeverRoute.lua> <character SavedVariables dir> [outDir]
const fs = require('fs');
const path = require('path');
const { parseSavedVariables } = require('./luatable');
const { classicKillXp } = require('./world');

const MIN_KILLS = 8, MIN_PACE = 5, MAX_FIXTURES_PER_RUN = 3;
const [accountSV, charDir, outDir0] = process.argv.slice(2);
const ROOT = path.join(__dirname, '..');
const outDir = outDir0 || path.join(ROOT, 'paths-auto');
const reports = process.env.FR_REPORTS || path.join(ROOT, 'reports'); // FR_REPORTS: tests write elsewhere
fs.mkdirSync(outDir, { recursive: true }); fs.mkdirSync(reports, { recursive: true });

const sv = fs.existsSync(accountSV || '') ? parseSavedVariables(fs.readFileSync(accountSV, 'utf8')) : {};
const L = (sv.ForeverRouteDB && sv.ForeverRouteDB.learn) || {};
const out = { updated: new Date().toISOString(), killXpByDiff: {}, samples: {} };
const lines = [`# What your play taught the planner (${out.updated.slice(0, 16).replace('T', ' ')})`, ''];

// kill XP
const byDiff = {};
for (const [pl, row] of Object.entries(L.killxp || {})) for (const [ml, c] of Object.entries(row || {})) {
  const d = +ml - +pl, f = classicKillXp(+ml, +pl);
  if (!(c && c.n > 0 && f > 0)) continue;
  const b = byDiff[d] || (byDiff[d] = { n: 0, xp: 0, formula: 0 });
  b.n += c.n; b.xp += c.xp; b.formula += f * c.n;
}
lines.push('## XP per kill (measured vs the Classic formula)', '', '| mob level vs you | kills | measured / formula |', '|---|---|---|');
for (const d of Object.keys(byDiff).map(Number).sort((a, b) => a - b)) {
  const b = byDiff[d], ratio = b.xp / b.formula;
  out.samples['xp' + d] = b.n;
  const used = b.n >= MIN_KILLS;
  if (used) out.killXpByDiff[d] = +Math.min(1.5, Math.max(0.3, ratio)).toFixed(3);
  lines.push(`| ${d > 0 ? '+' : ''}${d} | ${b.n} | ${ratio.toFixed(2)}${used ? '' : ' (not used yet: under ' + MIN_KILLS + ' kills)'} |`);
}
if (!Object.keys(byDiff).length) lines.push('| - | 0 | no kills recorded yet |');

// pace
const kills = (L.pace || []).filter((p) => p && p.k === 'Kill' && p.need > 0 && p.sec > 0).map((p) => p.sec / p.need).sort((a, b) => a - b);
lines.push('', '## Pace', '');
if (kills.length >= MIN_PACE) {
  const med = kills[kills.length >> 1];
  out.secPerKill = Math.round(Math.min(90, Math.max(8, med)));
  lines.push(`Kill steps: ${kills.length} timed, median ${med.toFixed(1)} s per kill -> the planner now uses ${out.secPerKill} s (was 22).`);
} else lines.push(`Kill steps timed: ${kills.length} (the planner keeps 22 s per kill until ${MIN_PACE}).`);
const collect = (L.pace || []).filter((p) => p && p.k === 'Collect');
if (collect.length) lines.push(`Collect steps timed: ${collect.length} (drop rates are learned separately, from your loot).`);

// time per zone: where the hours really went
const zoneNames = (() => { try { return Object.fromEntries(JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'conversion.json'), 'utf8')).geometry.transforms.map((t) => [t.ui_map_id, t.target_name])); } catch (e) { return {}; } })();
const zones = Object.entries(L.zones || {}).filter(([, z]) => z && z.sec > 0).sort((a, b) => b[1].sec - a[1].sec);
lines.push('', '## Time per zone (steady play, no flights or breaks)', '');
if (zones.length) {
  lines.push('| zone | hours | steps done | steps per hour | levels |', '|---|---|---|---|---|');
  for (const [m, z] of zones) lines.push(`| ${zoneNames[m] || 'map ' + m} | ${(z.sec / 3600).toFixed(1)} | ${z.steps || 0} | ${z.sec > 600 ? Math.round((z.steps || 0) / (z.sec / 3600)) : '-'} | ${z.lvlFrom || '?'}-${z.lvlTo || z.lvlFrom || '?'} |`);
  out.zones = Object.fromEntries(zones.map(([m, z]) => [m, { sec: z.sec, steps: z.steps || 0 }]));
} else lines.push('Nothing timed yet.');

// fun quest rewards (Learn.lua asked the game): toys, transforms, disguises, pets -> those quests are worth a detour
const FUN = /transform|turns? you into|disguise|costume|illusion|change[sd]? your appearance|companion|vanity pet/i;
const rewardQuests = (() => { // item -> quests that give it (the same list the addon scanned)
  try {
    const t = fs.readFileSync(path.join(ROOT, 'addon', 'ForeverRoute', 'FunCandidates.lua'), 'utf8'), m = {};
    for (const x of t.matchAll(/^ {2}\[(\d+)\] = \{ ([\d, ]+) \}/gm)) m[x[1]] = x[2].split(',').map((s) => +s.trim());
    return m;
  } catch (e) { return {}; }
})();
out.funQuests = {};
const funLines = [];
for (const [id, it] of Object.entries(L.items || {})) {
  if (!it || !(it.toy || FUN.test(it.use || ''))) continue;
  const what = (it.name || 'item ' + id) + (it.toy ? ' (a toy' + (it.use ? ': ' + it.use.replace(/^Use:\s*/, '') : '') + ')' : it.use ? ' (' + it.use.replace(/^Use:\s*/, '') + ')' : '');
  for (const q of rewardQuests[id] || []) out.funQuests[q] = what;
  funLines.push(`- ${what} - quest${(rewardQuests[id] || []).length > 1 ? 's' : ''} ${(rewardQuests[id] || []).join(', ')}`);
}
lines.push('', '## Fun quest rewards (asked the game)', '', `${Object.keys(L.items || {}).length} reward items checked so far.`);
lines.push(...(funLines.length ? funLines : ['None found yet (the addon checks a few a second while you play).']));

// ambient XP (world.js setAmbient): what your leveling really earned beyond quest rewards and the kills the planner counts
// for them - XP to your level, minus the quest XP of what you've handed in at full value, minus the kills the planner
// already counts (half the quest XP, cfg.supplyKillShare), as a share of the quest XP. Needs 100+ quests done to mean
// anything; kept between 0 and 1
try {
  const W = require('./world');
  const st = require('./snapshot').loadCharState(charDir, path.join(ROOT, 'qdb', 'conversion.json'));
  const db = JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'db.json'), 'utf8'));
  if (st && st.level > 10 && (st.completed || []).length >= 100) {
    let earned = st.xp || 0; for (let l = 1; l < st.level; l++) earned += W.XP_TO_LEVEL[l];
    let qx = 0; for (const id of st.completed) { const q = db.quests[id]; if (q && q.xp > 0) qx += q.xp; }
    if (qx > 0) {
      const share = Math.min(1, Math.max(0, (earned - qx * 1.5) / qx));
      out.ambientShare = +share.toFixed(2);
      lines.push('', '## XP beyond quests', '', `Quests you've done paid about ${Math.round(qx / 1000)}k XP of the ${Math.round(earned / 1000)}k you earned to level ${st.level}; with the kills the planner counts for them, the rest - kills on the way, rested XP, exploration - is ${Math.round(share * 100)}% of the quest XP again. The planner adds that to each hand-in (it was 25%).`);
    }
  }
} catch (e) {}
fs.writeFileSync(path.join(outDir, 'learned.json'), JSON.stringify(out, null, 1));

// incidents: new since the last run
const stateFile = path.join(outDir, 'learn-state.json');
let state = {}; try { state = JSON.parse(fs.readFileSync(stateFile, 'utf8')); } catch (e) {}
const incidents = (L.incidents || []).filter(Boolean);
const fresh = incidents.filter((i) => (i.t || 0) > (state.lastIncident || 0));
lines.push('', '## Incidents', '', `${incidents.length} recorded, ${fresh.length} new since the last plan.`);
const incFile = path.join(reports, 'incidents.md');
if (fresh.length) {
  const add = fresh.map((i) => `- ${new Date(i.t * 1000).toISOString().slice(0, 16).replace('T', ' ')} **${i.kind}** - ${i.dungeon ? 'in ' + i.dungeon : (i.what || '?')} (step ${i.step}, level ${i.lvl}, map ${i.m} ${i.x},${i.y}, route ${i.route}${i.from ? ', was on ' + i.from : ''}${i.arrow ? ', arrow on step ' + i.arrow : ''})`);
  if (!fs.existsSync(incFile)) fs.writeFileSync(incFile, '# Incidents from play (newest last)\n\n');
  fs.appendFileSync(incFile, add.join('\n') + '\n');
  // the first few become replayed-save tests (the save closest to the moment: the one written at the next reload)
  let made = 0;
  for (const i of fresh) {
    if (made >= MAX_FIXTURES_PER_RUN || !charDir) break;
if (i.kind === 'died') continue; // a death is not a route mistake: it stays in the report (camp avoidance), not a test
    const name = 'incident_' + String(i.kind).replace(/\W+/g, '_') + '_' + i.t;
    try { require('child_process').execFileSync(process.execPath, [path.join(__dirname, 'save-fixture.js'), charDir, name], { stdio: 'ignore', timeout: 30000 }); made++; } catch (e) {}
  }
  if (made) lines.push(`${made} new replayed-save test(s) in addon/ForeverRoute/tests (save_incident_*).`);
  state.lastIncident = Math.max(...fresh.map((i) => i.t || 0));
  fs.writeFileSync(stateFile, JSON.stringify(state));
}
// why the arrow hid (Arrow.lua logs each change to ForeverRouteDB.why): "it stopped showing" questions answered
const hid = ((sv.ForeverRouteDB && sv.ForeverRouteDB.why) || []).filter((w) => w && w.k === 'arrow' && /^hidden: /.test(w.x || ''));
const byWhy = {};
for (const w of hid) { const r = w.x.slice(8).replace(/^no position for this step: .*/, 'no position for a step'); byWhy[r] = (byWhy[r] || 0) + 1; }
lines.push('', '## Arrow hidden (why)', '');
lines.push(...(hid.length ? Object.entries(byWhy).sort((a, b) => b[1] - a[1]).map(([r, n]) => `- ${n}x ${r}`) : ['Nothing recorded yet.']));
for (const w of hid.filter((w) => /no position/.test(w.x)).slice(-5)) lines.push(`  - ${w.x.slice(8)} (map ${w.m})`);

// addon errors (ForeverRouteDB.log): the ones seen since the last run, so none goes unnoticed between sessions
const errs = ((sv.ForeverRouteDB && sv.ForeverRouteDB.log) || []).filter((e) => e && e.msg);
const newErrs = errs.filter((e) => (e.last || 0) > (state.lastError || 0));
lines.push('', '## Addon errors', '', newErrs.length ? `${newErrs.length} new since the last plan (fix these first):` : `none new (${errs.length} older on record).`);
const newKinds = []; // a new kind of error (ours or BugSack's) becomes a replayed-save test, below
for (const e of newErrs.slice(0, 10)) {
  const kindNew = (e.first || 0) > (state.lastError || 0);
  if (kindNew) newKinds.push(e.where + ' ' + e.msg);
  lines.push(`- ${kindNew ? '**new** ' : ''}${e.count}x \`${String(e.msg).slice(0, 160)}\` (${e.where}, level ${e.level}, map ${e.map}, version ${e.version}${e.plan ? ', plan ' + e.plan : ''})`);
  // what you were doing (addon versions from 2026-11-08 on): the step on the card and the addon's last decisions
  if (e.shown) lines.push(`  - on the card: step ${e.shown}${e.routeId ? ' (' + e.routeId + ')' : ''}${e.combat ? ', in combat' : ''}${e.taxi ? ', on a flight' : ''}`);
  for (const r of (e.recent || []).slice(-6)) lines.push(`  - before it: ${r}`);
}
if (newErrs.length) { state.lastError = Math.max(...newErrs.map((e) => e.last || 0)); fs.writeFileSync(stateFile, JSON.stringify(state)); }

// BugGrabber (BugSack's error catcher, if installed): it hooks the game's own error handler, so it sees what our
// guards can't - errors outside them, blocked/forbidden protected calls and Blizzard code tainted by us. Ours only, grouped
// by a signature (file:line + the message with numbers taken out), new ones first.
const bugFile = accountSV && path.join(path.dirname(accountSV), '!BugGrabber.lua');
if (bugFile && fs.existsSync(bugFile)) {
  let bugs = [];
  try { bugs = (parseSavedVariables(fs.readFileSync(bugFile, 'utf8')).BugGrabberDB || {}).errors || []; } catch (e) {}
  const ours = bugs.filter((b) => b && /ForeverRoute/.test(String(b.message || '') + String(b.stack || '')));
  const sig = (b) => String(b.message || '').replace(/^\[string "[^"]*"\]/, '').replace(/\d+(\.\d+)?/g, 'N').slice(0, 140);
  const groups = {};
  for (const b of ours) { const k = sig(b), g = groups[k] || (groups[k] = { n: 0, last: 0, msg: b.message, stack: b.stack, sessions: new Set() }); g.n += b.counter || 1; g.last = Math.max(g.last, b.time || 0); g.sessions.add(b.session); }
  // errors from before this report existed (2026-11-08 14:00) count as already seen: those were fixed in the code since
  const BUG_CUTOFF = 1794177000;
  const seenSigs = new Set([...(state.bugSigs || []), ...Object.entries(groups).filter(([, g]) => g.last < BUG_CUTOFF).map(([k]) => k)]);
  const list = Object.entries(groups).sort((a, b) => (seenSigs.has(a[0]) - seenSigs.has(b[0])) || b[1].last - a[1].last);
  const fresh = list.filter(([k]) => !seenSigs.has(k));
  lines.push('', '## Errors BugSack caught', '', ours.length ? `${list.length} kinds (${fresh.length} new since the last plan):` : 'none from ForeverRoute.');
  for (const [k, g] of list.slice(0, 12)) {
    const kind = /ADDON_ACTION_(BLOCKED|FORBIDDEN)|tainted by/.test(g.msg) ? 'TAINT ' : '';
    const at = (String(g.stack || '').match(/ForeverRoute\/[^\]:"]+:\d+/) || [''])[0];
    lines.push(`- ${seenSigs.has(k) ? '' : '**new** '}${kind}${g.n}x \`${String(g.msg).slice(0, 160)}\`${at ? ' at ' + at : ''} (last ${new Date(g.last * 1000).toISOString().slice(0, 16).replace('T', ' ')}, ${g.sessions.size} session${g.sessions.size > 1 ? 's' : ''})`);
  }
  if (fresh.length) { state.bugSigs = [...seenSigs, ...fresh.map(([k]) => k)].slice(-500); fs.writeFileSync(stateFile, JSON.stringify(state)); }
  for (const [, g] of fresh) newKinds.push(String(g.msg));
}
// each new kind of error: your save at that time becomes a replayed test (tests/save_error_*), which fails while the
// addon logs any error replaying it - so an error you hit once is checked on every change until it's gone
if (newKinds.length && charDir) {
  let made = 0;
  for (const k of newKinds) {
    if (made >= 2) break;
    const slug = k.replace(/^Interface\/AddOns\/ForeverRoute\//, '').replace(/[^A-Za-z0-9]+/g, '_').slice(0, 40);
    try { require('child_process').execFileSync(process.execPath, [path.join(__dirname, 'save-fixture.js'), charDir, 'error_' + slug + '_' + Math.floor(Date.now() / 1000)], { stdio: 'ignore', timeout: 30000 }); made++; } catch (e) {}
  }
  if (made) lines.push('', `${made} new replayed-save test(s) for new errors in addon/ForeverRoute/tests (save_error_*).`);
}

// new quests you've met (ids 10000+): checked against Forever's Wowhead data and queued for a browser to read their
// pages (tools/wowhead.js; reports/wowhead-queue.md). Not in tests (FR_REPORTS) and never fatal.
if (charDir && !process.env.FR_REPORTS) {
  try {
    const said = require('child_process').execFileSync(process.execPath, [path.join(__dirname, 'wowhead.js'), 'queue', charDir], { encoding: 'utf8', timeout: 60000 }).trim();
    lines.push('', '## New quests on Wowhead', '', said + ' (list: reports/wowhead-queue.md)');
  } catch (e) { lines.push('', '## New quests on Wowhead', '', 'not checked this time (' + String(e.message).split('\n')[0] + ')'); }
}

fs.writeFileSync(path.join(reports, 'learned.md'), lines.join('\n') + '\n');
console.log(`learned: ${Object.keys(out.killXpByDiff).length} XP corrections${out.ambientShare != null ? ', ambient ' + out.ambientShare : ''}, ${out.secPerKill ? out.secPerKill + ' s/kill' : 'pace not yet'}, ${fresh.length} new incidents`);
