// Checks for learn.js with made-up play: kill XP corrections per level difference, minutes per kill from timed steps,
// and new incidents reported once. usage: node tools/test-learn.js
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const { classicKillXp, setLearned, killXp } = require('./world');

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fr-learn-'));
const sv = path.join(dir, 'ForeverRoute.lua');
// at level 21: 10 kills of level-22 mobs that gave 80% of the formula; 3 kills of level-15 mobs (too few to use)
const f22 = classicKillXp(22, 21), f15 = classicKillXp(15, 21);
const pace = Array.from({ length: 7 }, (_, i) => `{ ["k"] = "Kill", ["need"] = 10, ["sec"] = ${150 + i * 10} }`).join(', ');
fs.writeFileSync(sv, `ForeverRouteDB = { ["learn"] = {
  ["killxp"] = { [21] = { [22] = { ["n"] = 10, ["xp"] = ${Math.round(f22 * 10 * 0.8)} }, [15] = { ["n"] = 3, ["xp"] = ${f15 * 3} } } },
  ["pace"] = { ${pace} },
  ["incidents"] = { { ["kind"] = "skipped", ["t"] = 1000, ["step"] = 7, ["what"] = "obj Kill 10 Wolf", ["lvl"] = 21 } },
  ["items"] = {
    [276242] = { ["name"] = "Replica Dartol's Rod of Transformation", ["toy"] = true, ["use"] = "Use: Transforms you into a furbolg." },
    [211527] = { ["name"] = "Cozy Sleeping Bag", ["use"] = "Use: Place your sleeping bag." },
  },
} }`);
let fails = 0;
const check = (name, ok, extra) => { console.log((ok ? 'ok   ' : 'FAIL ') + name + (ok ? '' : ' ' + (extra || ''))); if (!ok) fails++; };
const run = () => execFileSync(process.execPath, [path.join(__dirname, 'learn.js'), sv, '', dir], { encoding: 'utf8', env: { ...process.env, FR_REPORTS: dir } });

run();
const out = JSON.parse(fs.readFileSync(path.join(dir, 'learned.json'), 'utf8'));
check('kill XP correction learned for mobs one level above you', Math.abs(out.killXpByDiff[1] - 0.8) < 0.01, JSON.stringify(out.killXpByDiff));
check('too few kills: no correction', out.killXpByDiff[-6] === undefined);
check('minutes per kill from timed kill steps (median 18 s)', out.secPerKill === 18, String(out.secPerKill));
check('a toy reward makes its quest a fun one (Raene\'s Cleansing, 1046)', /Dartol/.test(out.funQuests[1046] || ''), JSON.stringify(out.funQuests));
check('a plain useful item is not "fun"', out.funQuests[79976] === undefined);
const inc = fs.readFileSync(path.join(dir, 'incidents.md'), 'utf8');
check('a new incident goes into the report', /skipped/.test(inc) && /Kill 10 Wolf/.test(inc));
run();
const inc2 = fs.readFileSync(path.join(dir, 'incidents.md'), 'utf8');
check('an incident is reported once, not on every run', inc2.split('skipped').length === 2);
// the correction reaches the shared kill XP rule
setLearned(out);
check('killXp applies the correction', killXp(22, 21) === Math.round(f22 * out.killXpByDiff[1]));
check('killXp leaves other level differences alone', killXp(21, 21) === classicKillXp(21, 21));
setLearned(null);

fs.rmSync(dir, { recursive: true, force: true });
console.log(fails ? fails + ' failed' : 'all passed');
process.exit(fails ? 1 : 0);
