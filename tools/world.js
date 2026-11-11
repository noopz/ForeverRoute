// The game's rules, in one place for every planner stage (the quest simulation, the optimizer, the zone chooser, the
// audit): each used to keep its own copy, and copies drift. Change a rule here and every stage follows.
//   XP_TO_LEVEL[L]      XP needed to go from level L to L+1 (Classic table; Forever uses the same)
//   killXp(mob, L)      XP for one kill of a level-`mob` creature at your level L (grey mobs give nothing)
//   addXp(level, xp, n) -> { level, xp } after gaining n XP (levels roll over; 60 is the cap)
//   RACE_BIT, CLASS_BIT the quest data's race and class masks; canTake(q, race, klass) checks a quest against them
//   CAPITAL_AREAS       capital cities by zone area id (no mobs to grind, no quests of their own for the zone choice)
//   CAPITAL_MAPS        the capitals by uiMap id (both factions: a plan only ever enters its own)
//   QUEST_LOG_MAX       quests the log holds on Forever
const XP_TO_LEVEL = [0, 400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600, 8800, 10100, 11400, 12900, 14400, 16000, 17700, 19400, 21300, 23200, 25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400, 44300, 47400, 50800, 54500, 58600, 62800, 67100, 71600, 76100, 80800, 85700, 90700, 95800, 101000, 106300, 111800, 117500, 123200, 129100, 135100, 141200, 147500, 153900, 160400, 167100, 173900, 180800, 187900, 195000, 202300, 209800];

// the Classic formula, corrected by what your kills really gave (tools/learn.js -> setLearned): a factor per level
// difference (mob - you), only where enough kills were seen
let XP_FACTOR = null;
function setLearned(learned) { XP_FACTOR = (learned && learned.killXpByDiff) || null; }
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

// a quest's XP at your level L: full up to 5 levels above the quest, then 20% less per level, never under 10%
function questXp(base, qLevel, L) {
  const d = L - qLevel;
  return d <= 5 ? base : Math.round(base * Math.max(0.1, 1 - 0.2 * (d - 5)));
}
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
function canTake(q, race, klass) {
  if (!q) return false;
  const rb = RACE_BIT[norm(race)], cb = CLASS_BIT[norm(klass)];
  if (q.races && rb && !raceOk(q.races, norm(race))) return false;
  if (q.classes && cb && !(q.classes & cb)) return false;
  return true;
}

const CAPITAL_AREAS = new Set([1519, 1537, 1657, 1497, 1637, 1638]); // Stormwind, Ironforge, Darnassus, Undercity, Orgrimmar, Thunder Bluff
const CAPITAL_MAPS = new Set([1453, 1455, 1457, 1454, 1456, 1458]); // Stormwind, Ironforge, Darnassus, Orgrimmar, Thunder Bluff, Undercity
const QUEST_LOG_MAX = 40;
// how far above your level the route sends you (the player's choice, 2026-11-08: "up to +2"): quests whose level is at
// most this much above yours, and mobs at most this much above you. Dungeon quests are done in a group: a little more.
const LEVEL_ABOVE = +(process.env.FR_LEVEL_ABOVE || 2); // FR_LEVEL_ABOVE: trial runs only (what would +3 do?) - the player chose 2
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
module.exports = { RACE_HOME, START_ZONES, droppers, raceOk, XP_TO_LEVEL, killXp, classicKillXp, setLearned, questXp, addXp, RACE_BIT, CLASS_BIT, canTake, CAPITAL_AREAS, CAPITAL_MAPS, QUEST_LOG_MAX, LEVEL_ABOVE, DUNGEON_ABOVE, TRAIN_BATCH, trainNow };
