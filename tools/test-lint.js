// Checks for lint-route.js: tiny hand-made Route.lua files with one known mistake each (or none), so the audit's
// rules are tested without running the planner.
// usage: node tools/test-lint.js
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const lint = path.join(__dirname, 'lint-route.js');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fr-lint-'));
const db = path.join(dir, 'db.json');
fs.writeFileSync(db, JSON.stringify({ quests: {}, npcs: {}, objects: {} }));
const ser = (o) => '{ ' + Object.entries(o).map(([k, v]) => k + ' = ' + (typeof v === 'string' ? JSON.stringify(v) : v)).join(', ') + ' }';
function audit(steps, who, done) {
  const f = path.join(dir, 'Route.lua');
  fs.writeFileSync(f, ['ForeverRouteData = {', '  paths = {', '  {', '    id = "path:test",', '    steps = {', ...steps.flat().map((s) => '      ' + ser(s) + ','), '    },', '  },', '  },', '}'].join('\n'));
  const doneFile = path.join(dir, 'done.json');
  if (done) fs.writeFileSync(doneFile, JSON.stringify(done));
  return execFileSync(process.execPath, [lint, f, db, 'path:test', ...(who || done ? [who || ''] : []), ...(done ? [doneFile] : [])], { encoding: 'utf8' });
}
let fails = 0;
let out = '';
const check = (name, ok) => { console.log((ok ? 'ok   ' : 'FAIL ') + name); if (!ok) { fails++; console.log(out.replace(/^/gm, '       ')); } };

// Darkshire: m 1431, Astranaar: m 1440, Stormwind: m 1453
const bindAstranaar = { k: 'bind', npc: 'Innkeeper Kimlya', m: 1440, x: 0.37, y: 0.49, zone: 'Ashenvale' };
const hearthTo = (where, m) => [{ k: 'hearth', text: where, dest: where, bindMap: m }, { k: 'goto', text: 'hand in at ' + where, m, x: 0.5, y: 0.5 }];
// a flight, then something to do there (two travel steps in a row are a separate audit finding)
const fly = (where, m) => [{ k: 'fly', dest: where, to: m, text: where }, { k: 'goto', text: 'look around ' + where, m, x: 0.5, y: 0.5 }];

// the bug the player would hit: bound at Astranaar, the route later says hearth to Darkshire
out = audit([bindAstranaar, fly('Duskwood', 1431), hearthTo('Darkshire', 1431)]);
check('hearth to a town you never bound at is flagged', /hearth to Darkshire/.test(out));
// hearth back to where the route bound you: fine
out = audit([bindAstranaar, fly('Darkshore', 1439), hearthTo('Astranaar', 1440)]);
check('hearth to the inn the route bound you at is fine', /no issues found/.test(out));
// no bind on the route: the first hearth goes to the bind you started with; a later one elsewhere is wrong
out = audit([hearthTo('Stormwind', 1453), fly('Duskwood', 1431), hearthTo('Stormwind', 1453)]);
check('hearth home to the starting bind twice is fine', /no issues found/.test(out));
out = audit([hearthTo('Stormwind', 1453), fly('Duskwood', 1431), hearthTo('Darkshire', 1431)]);
check('a second hearth somewhere else without a bind is flagged', /hearth to Darkshire/.test(out));
// a rebind moves the hearth
out = audit([hearthTo('Stormwind', 1453), fly('Duskwood', 1431), { ...bindAstranaar, m: 1431, zone: 'Duskwood' }, fly('Westfall', 1436), hearthTo('Darkshire', 1431)]);
check('hearth after a rebind goes to the new inn', /no issues found/.test(out));

// order within a quest (all in one spot in Duskwood, no travel)
const at = { m: 1431, x: 0.5, y: 0.5, zone: 'Duskwood' };
const acc = (q, extra) => ({ k: 'accept', q, name: 'Q' + q, npc: 'Giver', ...at, ...extra });
const obj = (q) => ({ k: 'obj', q, name: 'Q' + q, text: 'Kill 5 Wolf', ...at });
const tin = (q) => ({ k: 'turnin', q, name: 'Q' + q, npc: 'Giver', ...at });
out = audit([acc(901, { lvl: 21 }), obj(901), tin(901)]);
check('pick up, objective, hand in: fine', /no issues found/.test(out));
out = audit([acc(902, { lvl: 21, minLevel: 24 }), obj(902), tin(902)]);
check('a pick-up below its required level is flagged', /needs level 24/.test(out));
out = audit([obj(903), acc(903, { lvl: 21 }), tin(903)]);
check('an objective before its pick-up is flagged', /objective of Q903 before it is picked up/.test(out));
out = audit([acc(904, { lvl: 21 }), tin(904), obj(904)]);
check('a hand-in before the objectives is flagged', /hand-in of Q904 before its objectives/.test(out));
out = audit([tin(905), acc(905, { lvl: 21 })]);
check('a hand-in before the pick-up is flagged', /hand-in of Q905 before it is picked up/.test(out));
out = audit([obj(906), tin(906)]);
check('a quest already in your log (no pick-up on the route) is fine', /no issues found/.test(out));

// class and race: Yorus Barleybrew is a warrior quest; a gnome warlock can't take it
fs.writeFileSync(db, JSON.stringify({ quests: { 1698: { id: 1698, name: 'Yorus Barleybrew', level: 20, classes: 1, races: 77 }, 1738: { id: 1738, name: 'Heartswood', level: 20, classes: 256, races: 77 } }, npcs: {}, objects: {} }));
out = audit([acc(1698, { lvl: 21, name: 'Yorus Barleybrew' }), tin(1698)], 'warlock,gnome');
check("another class's quest is flagged", /Yorus Barleybrew: a class quest/.test(out));
out = audit([acc(1738, { lvl: 21, name: 'Heartswood' }), tin(1738)], 'warlock,gnome');
check('your own class quest is fine', /no issues found/.test(out));
out = audit([acc(1698, { lvl: 21, name: 'Yorus Barleybrew' }), tin(1698)]);
check('without a character, class is not checked', /no issues found/.test(out));

// prerequisites: 911 needs 910 (all of preGroup); 913 needs one of 912/914 (preSingle)
fs.writeFileSync(db, JSON.stringify({ quests: { 910: { id: 910, name: 'First', level: 20 }, 911: { id: 911, name: 'Second', level: 20, preGroup: [910] },
  912: { id: 912, name: 'Either A', level: 20 }, 913: { id: 913, name: 'After either', level: 20, preSingle: [912, 914] } }, npcs: {}, objects: {} }));
out = audit([acc(911, { lvl: 21, name: 'Second' }), tin(911)], '', []);
check('a pick-up whose prerequisite is not done is flagged', /Second: needs First \(910\) done first/.test(out));
out = audit([acc(911, { lvl: 21, name: 'Second' }), tin(911)], '', [910]);
check('a prerequisite done before the route is fine', /no issues found/.test(out));
out = audit([acc(910, { lvl: 21, name: 'First' }), tin(910), acc(911, { lvl: 21, name: 'Second' }), tin(911)], '', []);
check('a prerequisite handed in earlier on the route is fine', /no issues found/.test(out));
out = audit([acc(913, { lvl: 21, name: 'After either' }), tin(913)], '', [914]);
check('one of several alternative prerequisites is enough', /no issues found/.test(out));
out = audit([acc(913, { lvl: 21, name: 'After either' }), tin(913)], '', []);
check('none of the alternatives done is flagged', /needs one of 912\/914 done first/.test(out));

// the hearthstone's hour: tm is the planned minutes since the route began
const hearthAt = (where, m, tm) => [{ k: 'hearth', text: where, dest: where, bindMap: m, tm }, { k: 'goto', text: 'hand in at ' + where, m, x: 0.5, y: 0.5 }];
out = audit([hearthAt('Stormwind', 1453, 10), fly('Duskwood', 1431), hearthAt('Stormwind', 1453, 40)]);
check('two hearths 30 minutes apart are flagged', /hearth only 30 min after/.test(out));
out = audit([hearthAt('Stormwind', 1453, 10), fly('Duskwood', 1431), hearthAt('Stormwind', 1453, 75)]);
check('two hearths more than an hour apart are fine', /no issues found/.test(out));

if (!process.env.KEEP) fs.rmSync(dir, { recursive: true, force: true });
console.log(fails ? fails + ' failed' : 'all passed');
process.exit(fails ? 1 : 0);
