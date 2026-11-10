// README animation data: ten simulated players on one built-in plan (tools/simplay.js logs, one per persona): how many
// actions each took to finish, and its level along the way (sampled). usage: node tools/readme-race.js <log dir> <plan> <out.json>
const fs = require('fs');
const path = require('path');
const [dir, plan, outFile] = process.argv.slice(2);
const ABOUT = {
  clean: 'plays every step as written', skip: 'skips about one quest in five', fast: 'quick at everything', slow: 'slow at everything',
  die: 'dies now and then', reload: 'reloads the UI at random', secret: 'in places the game hides answers',
  nodungeon: 'never runs a dungeon', halfdungeon: 'leaves dungeons half done', rerun: 'runs dungeons twice',
};
const order = ['clean', 'fast', 'slow', 'skip', 'die', 'reload', 'secret', 'nodungeon', 'halfdungeon', 'rerun'];
const out = [];
for (const p of order) {
  const f = path.join(dir, p + '.log'); if (!fs.existsSync(f)) continue;
  const lv = [];
  for (const line of fs.readFileSync(f, 'utf8').split('\n')) { const m = / step \d+ .*\| level (\d+) /.exec(line); if (m) lv.push(Math.min(60, +m[1])); }
  const n = lv.length, samples = [];
  for (let k = 0; k <= 60; k++) samples.push(lv[Math.min(n - 1, Math.floor((n - 1) * k / 60))] || 1);
  samples[60] = 60; // the run ends at 60 (the log's last line is "end")
  out.push({ persona: p, about: ABOUT[p] || '', actions: n, levels: samples });
}
fs.writeFileSync(outFile, JSON.stringify({ plan, personas: out }));
console.log(out.map((x) => `${x.persona} ${x.actions}`).join(', '));
