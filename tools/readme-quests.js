// README animation data: how one zone's quests are picked, from a route2 run on that zone (its stdout): every quest
// given in the zone, its XP, and what the planner did with it - done on this leg, left for later, or cut (and why).
// usage: node tools/readme-quests.js <route2 stdout.txt> <zone area id> <zone name> <level> <out.json>
const fs = require('fs');
const path = require('path');
const [txtFile, zoneArg, zoneName, levelArg, outFile] = process.argv.slice(2);
const zone = +zoneArg;
const db = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'qdb', 'db.json'), 'utf8'));
const txt = fs.readFileSync(txtFile, 'utf8');
const givenHere = (q) => (q.starters || []).some((s) => (s.spawns || []).some((p) => p.zone === zone));
const byName = (name) => Object.values(db.quests).find((q) => q.name === name && givenHere(q));
const rows = new Map();
// done: the hand-ins on this leg
for (const m of txt.matchAll(/Turn in (.+?) \[(\d+)\] to .*?\(\+(\d+) xp\)/g)) { const q = byName(m[1]); if (q && !rows.has(q.id)) rows.set(q.id, { name: q.name, level: +m[2], xp: +m[3], status: 'done' }); }
const section = (title) => { const i = txt.indexOf(title); if (i < 0) return ''; const rest = txt.slice(i + title.length); const j = rest.search(/\n\s*\n/); return j < 0 ? rest : rest.slice(0, j); };
// later: available, not taken this leg
for (const line of section('Available but not taken (level/time):').split('\n')) {
  const m = /^\s+(.+?) \[(\d+)\]/.exec(line); if (!m) continue; const q = byName(m[1]);
  if (q && !rows.has(q.id)) rows.set(q.id, { name: q.name, level: +m[2], xp: q.xp || 0, status: 'later', reason: +m[2] > +levelArg + 2 ? `level ${m[2]}: later` : 'next visit' });
}
// cut, with the planner's reason in a few words
const short = (r) => {
  let m;
  if ((m = /about (\d+) kills/.exec(r))) return `${m[1]} kills`;
  if (/objectives outside/.test(r)) return 'objective elsewhere';
  if (/needs an earlier quest/.test(r)) return 'chain not started';
  if ((m = /frustrating: ([^,]+)/.exec(r))) return m[1].replace(/ around the objective/, '').slice(0, 26);
  if (/elite/.test(r)) return 'elites: group quest';
  if (/low level/.test(r)) return 'gray for you';
  if (/lonely detour/.test(r)) return 'lonely detour';
  if (/not in Forever/.test(r)) return 'not in Forever';
  return r.split(':')[0].slice(0, 26);
};
for (const line of section('Skipped:').split('\n')) {
  const m = /^\s+(.+?) \[(\d+)\] \((\d+)\): (.+)$/.exec(line); if (!m) continue;
  const q = db.quests[m[3]]; if (!q || !givenHere(q) || rows.has(q.id)) continue;
  rows.set(q.id, { name: q.name, level: +m[2], xp: q.xp || 0, status: 'cut', reason: short(m[4]) });
}
// one row per quest name (a chain's steps share it: Look To The Stars three times reads as a glitch)
const seen = new Set();
const all = [...rows.values()].filter((r) => r.xp > 0).sort((a, b) => b.xp - a.xp).filter((r) => (seen.has(r.name) ? false : seen.add(r.name)));
const pick = (st, n) => all.filter((r) => r.status === st).sort((a, b) => b.xp - a.xp).slice(0, n);
const shown = [...pick('done', 8), ...pick('cut', 5), ...pick('later', 3)].sort((a, b) => b.xp - a.xp);
const count = (st) => all.filter((r) => r.status === st).length;
const out = { zone: zoneName, level: +levelArg, rows: shown, totals: { done: count('done'), cut: count('cut'), later: count('later'), xpDone: all.filter((r) => r.status === 'done').reduce((s, r) => s + r.xp, 0) } };
fs.writeFileSync(outFile, JSON.stringify(out, null, 1));
console.log(`${zoneName}: ${all.length} quests given here - done ${out.totals.done}, cut ${out.totals.cut}, later ${out.totals.later}; showing ${shown.length}`);
