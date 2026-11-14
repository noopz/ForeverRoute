// Hours to 60 for a plan file, counted the planner's way (tools/route2.js, tools/world.js): walk the steps in order,
// quest XP at each hand-in (scaled for your level then), kill XP for each objective's kills (route2's flat secPerKill
// per kill, mobs at the quest's level), the objectives' work time, and - for whatever XP the steps leave short of 60 -
// grinding at your level. Travel is not walked here: pass the simulated player's riding + flying hours (simplay.js
// "travel:" line) with --travel. Built to compare plans of the same shape (the shared-trunk experiment,
// tools/splice-trunk.js), not to replace the planner's own estimate.
// usage: node tools/score-plan.js <Plan.lua> [--travel hours] [--secPerKill 22]
const fs = require('fs'), path = require('path');
const W = require('./world');
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf('--' + k); return i >= 0 ? +args[i + 1] : d; };
const SPK = opt('secPerKill', 22), travelH = opt('travel', 0);
const db = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'qdb', 'db.json'), 'utf8'));
const lua = fs.readFileSync(args[0], 'utf8').split(/\r?\n/);
// the first route's steps
const s0 = lua.findIndex((l) => /^\s*steps = \{$/.test(l));
let level = 1, xp = 0, workS = 0, grindS = 0, quests = 0, killS = 0;
const add = (n) => { const r = W.addXp(level, xp, n); level = r.level; xp = r.xp; };
for (let i = s0 + 1; !/^\s*\},$/.test(lua[i]) && level < 60; i++) {
  const l = lua[i];
  const k = (l.match(/\bk = "(\w+)"/) || [])[1];
  const q = +((l.match(/\bq = (\d+)/) || [])[1] || 0);
  const qLevel = +((l.match(/\blevel = (\d+)/) || [])[1] || level);
  if (k === 'obj') {
    const work = +((l.match(/\bwork = (\d+)/) || [])[1] || 90);
    workS += work;
    const kills = /\bkill|\bloot = true|Collect|Kill/i.test(l) ? Math.round(work / SPK) : 0;
    for (let n = 0; n < kills && level < 60; n++) add(W.killXp(qLevel, level));
  } else if (k === 'turnin' && q && db.quests[q]) {
    quests++;
    add(W.questGain(db.quests[q].xp || 0, db.quests[q].level || qLevel, level)); // the quest and what comes with it (world.js)
  }
}
// what's left to 60: grind mobs at your level
while (level < 60) { const per = W.killXp(level, level) || 1; const need = W.XP_TO_LEVEL[level] - xp; const n = Math.ceil(need / per); grindS += W.grindSeconds(n, SPK); add(n * per); } // grinding as people do it (world.grindSeconds), a level at a time
const hours = (workS + grindS) / 3600 + travelH;
console.log(JSON.stringify({ plan: path.basename(path.dirname(args[0])) + '/' + path.basename(args[0]), quests, workH: +(workS / 3600).toFixed(1), grindH: +(grindS / 3600).toFixed(1), travelH, hours: +hours.toFixed(1) }));
