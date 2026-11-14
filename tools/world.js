// The game's rules, in one place for every planner stage (the quest simulation, the optimizer, the zone chooser, the
// audit): each used to keep its own copy, and copies drift. Change a rule here and every stage follows.
//   XP_TO_LEVEL[L]      XP needed to go from level L to L+1 (Classic table; Forever uses the same)
//   killXp(mob, L)      XP for one kill of a level-`mob` creature at your level L (grey mobs give nothing)
//   addXp(level, xp, n) -> { level, xp } after gaining n XP (levels roll over; 60 is the cap)
//   RACE_BIT, CLASS_BIT the quest data's race and class masks; canTake(q, race, klass) checks a quest against them
//   CAPITAL_AREAS       capital cities by zone area id (no mobs to grind, no quests of their own for the zone choice)
//   CAPITAL_MAPS        the capitals by uiMap id (both factions: a plan only ever enters its own)
//   QUEST_LOG_MAX       quests the log holds on Forever
//   grindSeconds(k, s)  how long k kills of pure grinding take a person (rest between pulls, attention fading)
const XP_TO_LEVEL = [0, 400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600, 8800, 10100, 11400, 12900, 14400, 16000, 17700, 19400, 21300, 23200, 25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400, 44300, 47400, 50800, 54500, 58600, 62800, 67100, 71600, 76100, 80800, 85700, 90700, 95800, 101000, 106300, 111800, 117500, 123200, 129100, 135100, 141200, 147500, 153900, 160400, 167100, 173900, 180800, 187900, 195000, 202300, 209800];

// the Classic formula, corrected by what your kills really gave (tools/learn.js -> setLearned): a factor per level
// difference (mob - you), only where enough kills were seen
let XP_FACTOR = null;
function setLearned(learned) { XP_FACTOR = (learned && learned.killXpByDiff) || null; if (learned && learned.ambientShare != null) setAmbient(learned.ambientShare); }
function classicKillXp(mob, L) {
  const gray = L <= 5 ? 0 : L <= 39 ? L - Math.floor(L / 10) - 5 : L - Math.floor(L / 5) - 1;
  if (mob <= gray) return 0;
  const base = L * 5 + 45;
  return Math.round(mob >= L ? base * (1 + 0.05 * (mob - L)) : base * (1 - (L - mob) / (L - gray + 5)));
}
function killXp(mob, L) {
  const x = classicKillXp(mob, L);
  const f = XP_FACTOR && XP_FACTOR[mob - L];
  return f ? Math.round(x * f) : x;
}

// Pure grinding as people play it, not kill after kill: 2-3 pulls, then a minute or two to eat, drink and get health
// back; and after about 15 minutes with no quest progress, attention wanders (tabbing out, chatting, wandering off),
// so the rest goes half again slower. secPerKill is the fight itself (a quest's kills: tools/learn.js measures it).
// opts (cfg.grind): pullsPerRest 2.5, restSec 90, focusMin 15, distracted 1.5.
function grindSeconds(kills, secPerKill, opts) {
  const o = opts || {};
  const per = secPerKill + (o.restSec ?? 90) / (o.pullsPerRest ?? 2.5);
  const t = kills * per, focus = 60 * (o.focusMin ?? 15);
  return t <= focus ? t : focus + (t - focus) * (o.distracted ?? 1.5);
}

// The XP that comes with questing beyond a quest's own reward and its counted kills: mobs in the way, the extra pull,
// rested XP (kills pay double after a night in an inn), exploration. A player's save showed quests at 51% of the XP he
// really earned to 33 - the planner counted kills at about half the quest XP, the rest of his was this. Without it the
// planned character levels slower than real ones and "runs out" of quests that players never run out of.
// ambientShare: a share of each hand-in's quest XP (0.25 for anyone; learned from your play: tools/learn.js)
let AMBIENT = 0.25;
function setAmbient(x) { if (typeof x === 'number' && x >= 0 && x <= 1.5) AMBIENT = x; }
function ambientShare() { return AMBIENT; }
// a quest's XP at your level L: full up to 5 levels above the quest, then 20% less per level, never under 10%
function questXp(base, qLevel, L) {
  const d = L - qLevel;
  return d <= 5 ? base : Math.round(base * Math.max(0.1, 1 - 0.2 * (d - 5)));
}
// what a hand-in moves you on by: the quest's XP and the ambient XP that comes with doing it (setAmbient)
function questGain(base, qLevel, L) { return questXp(base, qLevel, L) * (1 + AMBIENT); }
function addXp(level, xp, n) {
  xp += n;
  while (level < 60 && xp >= XP_TO_LEVEL[level]) { xp -= XP_TO_LEVEL[level]; level++; }
  return { level, xp };
}

// Forever's Skyborne (one race per faction) sit above bit 32: 2^32 Alliance, 2^33 Horde (QuestieDB Forever masks:
// 4294967373 = Alliance races + 2^32). Masks that wide break JavaScript's 32-bit &, so check them with raceOk.
const RACE_BIT = { human: 1, orc: 2, dwarf: 4, nightelf: 8, undead: 16, tauren: 32, gnome: 64, troll: 128, skyborne: 2 ** 32, skybornehorde: 2 ** 33 };
function raceOk(mask, race) { const b = RACE_BIT[race]; if (!mask || !b) return true; return (BigInt(Math.round(mask)) & BigInt(b)) !== 0n; }
const CLASS_BIT = { warrior: 1, paladin: 2, hunter: 4, rogue: 8, priest: 16, shaman: 64, mage: 128, warlock: 256, druid: 1024 };
const norm = (s) => String(s || '').toLowerCase().replace(/[^a-z]/g, '');
// A faction trunk (the plan every race and class of a faction rides, docs/research/shared-trunk.md) plans as race
// "alliance" / "horde" and class "none": it takes only what every one of the faction's races may take, and no class
// quest - those are the branches. Skyborne start elsewhere and join later, so they don't narrow the trunk.
const FACTION_RACES = { alliance: ['human', 'dwarf', 'gnome', 'nightelf'], horde: ['orc', 'troll', 'tauren', 'undead'] };
const ALL_CLASSES = Object.values(CLASS_BIT).reduce((a, b) => a | b, 0);
function raceFits(mask, race) {
  const r = norm(race);
  if (FACTION_RACES[r]) return !mask || FACTION_RACES[r].every((x) => raceOk(mask, x));
  return raceOk(mask, r);
}
function classFits(mask, klass) {
  const k = norm(klass);
  if (!mask) return true;
  if (k === 'none') return (mask & ALL_CLASSES) === ALL_CLASSES;
  const cb = CLASS_BIT[k];
  return !cb || !!(mask & cb);
}
// a quest whose giver or hand-in is the other faction's (most quests in an Alliance zone have no race mask: only the
// giver says so - the Horde v9 tauren start was sent to Redridge for green quests and stopped there at 16)
function sideFits(q, faction) {
  const foe = faction === 'horde' ? 'A' : faction === 'alliance' ? 'H' : null;
  if (!q || !foe) return true;
  return ![...(q.starters || []), ...(q.finishers || [])].some((s) => s && s.friendly === foe);
}
function canTake(q, race, klass) {
  if (!q) return false;
  return raceFits(q.races, race) && classFits(q.classes, klass);
}

// zone names as the planner's steps spell them: the map conversion's names, but for the ones the first planner named
// itself and the steps still use (Stormwind, where the conversion says 'Stormwind City'). One list for the planner
// (route2.js) and the tools that read its steps back (chain-report.js): a step's zone name only matches a quest's area
// when both sides spell it the same
const PLANNER_ZONE_NAMES = { 1: 'Dun Morogh', 12: 'Elwynn Forest', 38: 'Loch Modan', 40: 'Westfall', 44: 'Redridge Mountains', 10: 'Duskwood', 11: 'Wetlands', 148: 'Darkshore', 1519: 'Stormwind', 1537: 'Ironforge' };
// area id -> zone name for the steps, from the conversion's transforms (qdb/conversion.json geometry.transforms)
function plannerZoneNames(transforms) {
  const out = { ...PLANNER_ZONE_NAMES };
  for (const t of transforms || []) if (!out[t.area_id] && t.target_name) out[t.area_id] = t.target_name;
  return out;
}

const CAPITAL_AREAS = new Set([1519, 1537, 1657, 1497, 1637, 1638]); // Stormwind, Ironforge, Darnassus, Undercity, Orgrimmar, Thunder Bluff
const CAPITAL_MAPS = new Set([1453, 1455, 1457, 1454, 1456, 1458]); // Stormwind, Ironforge, Darnassus, Orgrimmar, Thunder Bluff, Undercity
const QUEST_LOG_MAX = 40;
// how far above your level the route sends you (the player's choice, 2026-11-08: "up to +2"): quests whose level is at
// most this much above yours, and mobs at most this much above you. Dungeon quests are done in a group: a little more.
const LEVEL_ABOVE = +(process.env.FR_LEVEL_ABOVE || 2); // FR_LEVEL_ABOVE: trial runs only (what would +3 do?) - the player chose 2
// how far above you a quest or its mobs may be, by your level: on Forever yellow is up to 2 above, orange 3-4. Below 20
// it's yellow only. From 20, with talents and a kit, a class handles the first orange level (the player's rule, checked
// against Forever's colors). FR_LEVEL_ABOVE pins one value for trial runs. The extra fight time for mobs above you is
// in route2 (objective work).
const levelAbove = (L) => (process.env.FR_LEVEL_ABOVE ? LEVEL_ABOVE : L >= 20 ? 3 : 2);
// the lowest level at which something of level q is within the gate
const minLevelFor = (q) => { for (let L = 1; L <= 60; L++) if (q <= L + levelAbove(L)) return L; return 60; };
const DUNGEON_ABOVE = 4;

// training trips are batched (the player's choice, 2026-11-08): go when two ranks are waiting, or right away if the
// route is in the trainer's city anyway (nothing wasted). due: the training levels reached but not trained yet
const TRAIN_BATCH = 2;
function trainNow(due, inTrainerCity) { return due.length >= TRAIN_BATCH || (due.length > 0 && !!inTrainerCity); }

// the mobs that drop a quest item: when normal mobs drop it, elites that also do are left out - Forever's War Banners drop
// from the classic Dragonmaw camp and from 300 new elite Dragonmaw (rank 1-3: elite, rare elite, boss; 4 is a plain rare)
function droppers(o, npcs) {
  const all = (o.npcDrops || []).map((id) => npcs[id]).filter(Boolean);
  const normal = all.filter((n) => !(n.rank >= 1 && n.rank <= 3) && (n.spawns || []).length);
  return normal.length && normal.length < all.length ? normal : all;
}
// each race's start zone (QuestieDB area ids): where it spawns and quests first
const RACE_HOME = { human: 12, dwarf: 1, gnome: 1, nightelf: 141, skyborne: 16593, orc: 14, troll: 14, tauren: 215, undead: 85, skybornehorde: 16593 };
const START_ZONES = new Set(Object.values(RACE_HOME));
// a quest with work to do that the data describes none of: given and handed in by the same NPC, no objectives, and
// its text says there is work (Brewer's Trade: "Deliver the bottles of Fallrook Varietal to Dun Garok" - given and
// handed in by Brewmeister Bilger). The instant ones are not ("Wait a moment, then speak with Sirra again", the class
// spell quests with no text). route2.js keeps one that leads on as accept, one "do the work" step, hand-in;
// gen-quest-data.js offers the others at their giver
const INSTANT_RX = /^\s*(wait|speak|talk|watch|inspect|open|listen)\b/i;
function unknownWork(q) {
  if ((q.objectives || []).length) return false;
  const ids = (l) => (l || []).map((s) => s.type + s.id).sort().join();
  if (!(q.starters || []).length || ids(q.starters) !== ids(q.finishers)) return false;
  const text = (q.text || []).join(' ').trim();
  return text !== '' && !INSTANT_RX.test(text);
}
// the "do the work" label for such a quest: the first sentence of its text, at most ~70 characters
function unknownWorkLabel(q) {
  const first = ((((q.text || [])[0] || '').trim().split(/(?<=[.!?])\s/)[0]) || '').replace(/[.!]\s*$/, '').replace(/\s+/g, ' ').trim();
  if (first.length <= 70) return first || q.name;
  return first.slice(0, 69).replace(/\s+\S*$/, '').replace(/[,;:]$/, '') + '…';
}
// does this quest lead to another one (a quest lists it as a prerequisite, or it names the next in its chain)?
let FOLLOW_SRC = null, FOLLOW = null;
function leadsOn(q, quests) {
  if (FOLLOW_SRC !== quests) { FOLLOW_SRC = quests; FOLLOW = new Set(); for (const o of Object.values(quests)) for (const p of [...(o.preSingle || []), ...(o.preGroup || [])]) FOLLOW.add(+p); }
  return FOLLOW.has(+q.id) || !!(q.nextInChain && quests[q.nextInChain]);
}
// skill line ids (QuestieDB requiredSkill) by the name the game's skill list shows (the save's skills, the addon's check)
const SKILL_NAME = { 129: 'First Aid', 164: 'Blacksmithing', 165: 'Leatherworking', 171: 'Alchemy', 182: 'Herbalism',
  185: 'Cooking', 186: 'Mining', 197: 'Tailoring', 202: 'Engineering', 333: 'Enchanting', 356: 'Fishing', 393: 'Skinning',
  755: 'Jewelcrafting', 773: 'Inscription', 762: 'Riding', 633: 'Lockpicking' };
const PROFESSIONS = new Set(Object.values(SKILL_NAME).filter((n) => n !== 'Riding' && n !== 'Lockpicking'));
// false only when the save says you don't have the profession a quest needs. Its rank, a spell or a reputation are
// checked by the addon when you get to the giver (Availability.lua: Engineering 150 now can be 200 by then), and a
// plan made without a save (the built-in plans: no skills at all - a real save always lists weapon skills and
// languages) keeps the quest for the addon to check.
function hasProfessionFor(q, skills) {
  if (!q || !Array.isArray(q.skill) || !q.skill[0]) return true;
  if (!skills || !Object.keys(skills).length) return true;
  const name = SKILL_NAME[q.skill[0]];
  return !name || !!skills[name];
}
// the professions in a save, sorted (what a replan watches: people rarely change them)
const professionsOf = (skills) => Object.keys(skills || {}).filter((n) => PROFESSIONS.has(n)).sort();
module.exports = { sideFits, SKILL_NAME, PROFESSIONS, hasProfessionFor, professionsOf, questGain, setAmbient, ambientShare, levelAbove, minLevelFor, FACTION_RACES, raceFits, classFits, grindSeconds, unknownWork, unknownWorkLabel, leadsOn, RACE_HOME, START_ZONES, droppers, raceOk, XP_TO_LEVEL, killXp, classicKillXp, setLearned, questXp, addXp, RACE_BIT, CLASS_BIT, canTake, CAPITAL_AREAS, CAPITAL_MAPS, PLANNER_ZONE_NAMES, plannerZoneNames, QUEST_LOG_MAX, LEVEL_ABOVE, DUNGEON_ABOVE, TRAIN_BATCH, trainNow };
