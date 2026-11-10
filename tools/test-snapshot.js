// Checks for snapshot.js: a save written while logging out lists the quest log with every quest blank (no objectives,
// no "complete" flag). The planner must then use the progress from the last save that had it, not plan the quests anew.
// usage: node tools/test-snapshot.js
const fs = require('fs');
const os = require('os');
const path = require('path');

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fr-snap-'));
process.env.FR_PROGRESS_MEMORY = path.join(dir, 'memory');
const { loadCharState } = require('./snapshot');
const charDir = path.join(dir, 'char'); fs.mkdirSync(charDir);
const save = (time, reason, log) => fs.writeFileSync(path.join(charDir, 'ForeverRoute.lua'), 'ForeverRouteChar = {\n["snapshot"] = {\n["name"] = "Testchar",\n["level"] = 21,\n["xp"] = 100,\n["xpMax"] = 25200,\n["time"] = ' + time + ',\n["reason"] = "' + reason + '",\n["log"] = {\n' + log + '},\n},\n}\n');
let fails = 0;
const check = (name, ok) => { console.log((ok ? 'ok   ' : 'FAIL ') + name); if (!ok) fails++; };

// a normal save: 56 finished, 91 half done
save(1000, 'reload', '[56] = { ["complete"] = true, ["objectives"] = { { 1, 1, true, "Skeleton Fingers: 1/1" } } },\n[91] = { ["complete"] = false, ["objectives"] = { { 1, 1, true, "Shadowhide Pendant: 1/1" }, { 0, 1, false, "Gnoll Paw: 0/1" } } },\n');
let st = loadCharState(charDir);
check('a normal save reads as it is', st.log[56].complete === true && st.log[91].objectives.length === 2 && !st.log[91].unknown);
// the logout save: both blank, plus a quest picked up since (1738) that no earlier save had
save(2000, 'logout', '[56] = { ["objectives"] = {} },\n[91] = { ["objectives"] = {} },\n[1738] = { ["objectives"] = {} },\n');
st = loadCharState(charDir);
check('a finished quest stays finished through a blank logout save', st.log[56].complete === true && st.log[56].remembered);
check('half-done objectives come back from the last good save', st.log[91].objectives.length === 2 && st.log[91].objectives[0].done === true && st.log[91].objectives[1].done === false);
check('a quest no save had progress for is marked unknown', st.log[1738].unknown === true && st.log[1738].complete === false);
check('the source line says so', /left them blank/.test(st.source));
// reading the blank save again (every planner leg does) keeps the remembered progress
st = loadCharState(charDir);
check('reading the blank save twice keeps the progress', st.log[56].complete === true && st.log[91].objectives.length === 2);
// next session: 91 is now finished and 56 handed in (gone from the log)
save(3000, 'reload', '[91] = { ["complete"] = true, ["objectives"] = { { 1, 1, true, "Shadowhide Pendant: 1/1" }, { 1, 1, true, "Gnoll Paw: 1/1" } } },\n');
st = loadCharState(charDir);
check('a newer good save wins', st.log[91].complete === true && !st.log[56]);

fs.rmSync(dir, { recursive: true, force: true });
console.log(fails ? fails + ' failed' : 'all passed');
process.exit(fails ? 1 : 0);
