// Settings for a new character (routes/campaign-<name>.json), from its save or from what you tell it - so the planner
// works for any class, race and faction without a hand-written file. What depends on the character is filled in from
// the quest data; the rest (speeds, look-ahead, dungeons...) comes from tools/campaign-defaults.json.
//   race, class, faction, level, zone   from the save (ForeverRouteChar.snapshot), or --race --class --level --zone
//   trainers                            every <Class> Trainer in your faction's capitals (Stormwind and Ironforge for an
//                                       Alliance warlock), from the quest data
//   training levels                     every even level from yours to the target (Classic trains every 2 levels)
//   side trips, must-do quests          the reviewed ones for your faction and class (Alliance + warlock so far: other
//                                       classes get none until reviewed; the report says so)
// usage: node tools/make-character.js --save "<WTF/Account/X/<realm>/<Name-Realm>/SavedVariables>"
//        node tools/make-character.js --name Test --race nightelf --class druid --level 12 --zone 148 [--out file]
const fs = require('fs');
const path = require('path');
const { CAPITAL_AREAS, RACE_BIT, CLASS_BIT } = require('./world');
const ROOT = path.join(__dirname, '..');

const args = {}; for (let i = 2; i < process.argv.length; i += 2) args[process.argv[i].replace(/^--/, '')] = process.argv[i + 1];
const ALLIANCE = new Set(['human', 'dwarf', 'nightelf', 'gnome', 'skyborne']);
const norm = (s) => String(s || '').toLowerCase().replace(/[^a-z]/g, '');
// race keys: the game's token for undead is "Scourge"; the Horde's Skyborne (Windshaper Skyborne) are skybornehorde -
// told apart from the Alliance's by the faction (the save has it), or by the name
const raceKey = (s, faction) => {
  const r = norm(s);
  if (r === 'scourge') return 'undead';
  if (r.includes('skyborne')) return r.includes('windshaper') || r === 'skybornehorde' || norm(faction) === 'horde' ? 'skybornehorde' : 'skyborne';
  return r;
};

let me = { name: args.name, race: raceKey(args.race, args.faction), class: norm(args.class), level: +args.level || 1, zone: +args.zone || null, charDir: null };
if (args.save) {
  const st = require('./snapshot').loadCharState(args.save, path.join(ROOT, 'qdb', 'conversion.json'));
  if (!st) { console.log('no character save in ' + args.save + ' (log in with the addon once, then /reload)'); process.exit(1); }
  me = { name: st.name || path.basename(path.dirname(args.save)).split('-')[0], race: raceKey(st.race, st.faction), class: norm(st.class), level: st.level || 1, zone: st.pos ? st.pos.zone : null, charDir: args.save.replace(/\\/g, '/') };
}
if (!RACE_BIT[me.race] || !CLASS_BIT[me.class]) { console.log('unknown race or class: ' + me.race + ' ' + me.class); process.exit(1); }
const faction = ALLIANCE.has(me.race) ? 'alliance' : 'horde';
const side = faction === 'alliance' ? 'A' : 'H';

const defaults = JSON.parse(fs.readFileSync(path.join(__dirname, 'campaign-defaults.json'), 'utf8'));
const db = JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'db.json'), 'utf8'));
const conv = JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'conversion.json'), 'utf8')).geometry.transforms;
const zoneName = Object.fromEntries(conv.map((t) => [t.area_id, t.target_name]));

// trainers: "<Class> Trainer" NPCs of your faction in the capitals, one stop per capital, and each one in your race's
// home zone (Northshire and Goldshire, Anvilmar and Kharanos, Valanaar on Zephras Isle): early training without
// leaving the start zone - a Skyborne would otherwise sail to Stormwind at level 2. Route2 trains at the nearest.
const { RACE_HOME } = require('./world');
const title = me.class.charAt(0).toUpperCase() + me.class.slice(1) + ' Trainer';
const byCity = new Map();
for (const n of Object.values(db.npcs)) {
  if (!n || n.sub !== title || !(n.friendly === side || n.friendly === 'AH')) continue;
  for (const s of n.spawns || []) {
    if (s.zone === RACE_HOME[me.race]) {
      const k = s.zone + ':' + Math.round(s.x / 5) + ':' + Math.round(s.y / 5); // one per spot (two trainers side by side are one stop)
      if (!byCity.has(k)) byCity.set(k, { zone: s.zone, x: s.x, y: s.y, name: `${n.name} (${zoneName[s.zone] || 'your start zone'})`, note: `${title} ${n.name}, ${zoneName[s.zone] || 'your start zone'}` });
      continue;
    }
    if (!CAPITAL_AREAS.has(s.zone) || byCity.has(s.zone)) continue;
    byCity.set(s.zone, { zone: s.zone, x: s.x, y: s.y, name: zoneName[s.zone] || ('zone ' + s.zone), note: `${title}s in ${zoneName[s.zone] || 'the city'} (${n.name} and others)` });
  }
}
const trainers = [...byCity.values()];
const target = +args.target || defaults.targetLevel || 30; // --target 60: training stops and the plan go that far
const trainLevels = []; for (let l = Math.max(2, me.level + 1); l <= target; l++) if (l % 2 === 0) trainLevels.push(l);

// reviewed side trips and must-do quests (tools/reviewed-<faction>.json): the ones for your class and faction
let reviewed = {}; try { reviewed = JSON.parse(fs.readFileSync(path.join(__dirname, `reviewed-${faction}.json`), 'utf8')); } catch (e) {}
// a class's side trips; some are per race (a night elf hunter tames in Teldrassil, a dwarf in Dun Morogh)
const special = (reviewed.special || []).filter((s) => (!s.class || s.class === me.class) && (!s.races || s.races.includes(me.race))).map(({ class: _c, races: _r, source: _s, ...s }) => s);
// FR_INPATH=Veriganpaladin,...: a trial with these side trips built into the path (to weigh what one costs)
for (const id of (process.env.FR_INPATH || '').split(',').filter(Boolean)) for (const s of special) if (s.id === id) s.inPath = true;

const out = {
  ...defaults,
  charDir: me.charDir || undefined, character: me.name, race: me.race, class: me.class, faction, level: me.level,
  ...(me.zone ? { startZone: me.zone } : {}),
  trainers, trainer: trainers[0], trainerNote: trainers[0] && trainers[0].note, trainLevels,
  special, mustDo: reviewed.mustDo || [], bonusQuests: reviewed.bonusQuests || [], bonusNotes: reviewed.bonusNotes || {},
};
const file = args.out || path.join(ROOT, 'routes', `campaign-${norm(me.name)}.json`);
// the defaults' folders are relative: addonsDir to the game's _forever_ folder (tools/game-dir.js), dungeonFile to this
// repo. Written out in full, so the planner finds them whatever folder it is started from
if (typeof out.addonsDir === 'string' && !path.isAbsolute(out.addonsDir)) out.addonsDir = path.resolve(require('./game-dir').GAME, out.addonsDir);
if (typeof out.dungeonFile === 'string' && !path.isAbsolute(out.dungeonFile)) out.dungeonFile = path.resolve(ROOT, out.dungeonFile);
fs.writeFileSync(file, JSON.stringify(out, null, 2) + '\n');
console.log(`wrote ${file}: ${me.name}, ${me.race} ${me.class} (${faction}) level ${me.level}${me.zone ? ' in ' + zoneName[me.zone] : ''}`);
console.log(`  trainers: ${trainers.map((t) => t.name).join(', ') || 'none found'}; training at ${trainLevels.join(', ') || '-'}`);
console.log(`  side trips: ${special.map((s) => s.name).join(', ') || 'none reviewed for a ' + me.class + ' yet'}; must-do quests: ${out.mustDo.length}`);
