// Checks the shared game rules in world.js that the planner stages lean on: grinding priced as people play, the level
// gate by level, and the faction-trunk eligibility (race "<faction>", class "none").
// usage: node tools/test-world.js
const W = require('./world');
let fails = 0;
const check = (name, ok, info) => { console.log((ok ? 'ok   ' : 'FAIL ') + name + (ok ? '' : '  ' + JSON.stringify(info))); if (!ok) fails++; };

// grinding: rest between pulls, attention fading after 15 minutes
const g5 = W.grindSeconds(5, 22), g300 = W.grindSeconds(300, 22);
check('a short grind is the fights plus the rest between pulls (5 kills ~ 5 min)', g5 > 4 * 60 && g5 < 6 * 60, g5);
check('a long grind slows past 15 minutes (300 kills > 300 x 58 s)', g300 > 300 * 58, g300);
const xph44 = (n) => (n * W.killXp(44, 44)) / (W.grindSeconds(n, 22) / 3600);
check('grinding a level at 44 pays less than a 12k xp/h quest leg', xph44(316) < 12000, Math.round(xph44(316)));
check('cfg.grind overrides the model (no rest, no fading: fights only)', W.grindSeconds(10, 22, { restSec: 0, distracted: 1 }) === 220, W.grindSeconds(10, 22, { restSec: 0, distracted: 1 }));

// the level gate: yellow (+2) below 20, the first orange level (+3) from 20
if (!process.env.FR_LEVEL_ABOVE) {
  check('below 20: up to 2 levels above you', W.levelAbove(12) === 2 && W.levelAbove(19) === 2, [W.levelAbove(12), W.levelAbove(19)]);
  check('from 20: up to 3 levels above you', W.levelAbove(20) === 3 && W.levelAbove(45) === 3, [W.levelAbove(20), W.levelAbove(45)]);
  check('a level-23 quest opens at 20 (+3)', W.minLevelFor(23) === 20, W.minLevelFor(23));
  check('a level-21 quest opens at 19 (+2 below 20)', W.minLevelFor(21) === 19, W.minLevelFor(21));
  check('a level-22 quest waits for 20', W.minLevelFor(22) === 20, W.minLevelFor(22));
}

// trunk eligibility: every race of the faction, no class quests
const ALL_ALLIANCE = 1 | 4 | 8 | 64; // human, dwarf, night elf, gnome
check('a quest for every Alliance race is in the Alliance trunk', W.canTake({ races: ALL_ALLIANCE }, 'alliance', 'none'));
check('a quest with no race mask is in the trunk', W.canTake({}, 'alliance', 'none'));
check('a human-only quest is not in the trunk (a race branch)', !W.canTake({ races: 1 }, 'alliance', 'none'));
check('a warrior quest is not in the trunk (a class branch)', !W.canTake({ classes: 1 }, 'alliance', 'none'));
check('a warrior quest is still a warrior\'s', W.canTake({ classes: 1 }, 'human', 'warrior'));
check('a dwarf-only quest is a dwarf\'s', W.canTake({ races: 4 }, 'dwarf', 'hunter') && !W.canTake({ races: 4 }, 'human', 'hunter'));
check('Skyborne bits do not narrow the Alliance trunk', W.canTake({ races: ALL_ALLIANCE }, 'alliance', 'none'));
const ALL_HORDE = 2 | 16 | 32 | 128;
check('a quest for every Horde race is in the Horde trunk, not the Alliance one', W.canTake({ races: ALL_HORDE }, 'horde', 'none') && !W.canTake({ races: ALL_HORDE }, 'alliance', 'none'));

// ambient XP: a hand-in moves you on by its quest XP and what comes with questing (0.25 by default, learned from play)
check('a hand-in counts its quest XP plus 25% ambient by default', Math.round(W.questGain(1000, 30, 30)) === 1250, W.questGain(1000, 30, 30));
W.setAmbient(0.45);
check('a learned ambient share replaces the default', Math.round(W.questGain(1000, 30, 30)) === 1450, W.questGain(1000, 30, 30));
W.setAmbient(9);
check('an absurd ambient share is ignored', Math.round(W.questGain(1000, 30, 30)) === 1450, W.questGain(1000, 30, 30));
W.setAmbient(0.25);

// profession quests: planned unless the save says you lack the profession (its rank is checked at the giver)
const goblin = { skill: [202, 200] }, save = { Defense: [170, 170], Swords: [150, 170], Common: [300, 300] };
check('a plan without a save keeps a profession quest (the addon checks it)', W.hasProfessionFor(goblin, {}) && W.hasProfessionFor(goblin, undefined));
check('a save without Engineering drops Goblin Engineering', !W.hasProfessionFor(goblin, save));
check('a save with Engineering 150 keeps it (it can be 200 by then)', W.hasProfessionFor(goblin, { ...save, Engineering: [150, 225] }));
check('a quest that needs no profession is always kept', W.hasProfessionFor({}, save));
check('the professions a replan watches: names only, no weapon skills', JSON.stringify(W.professionsOf({ ...save, Tailoring: [50, 75], 'First Aid': [10, 75] })) === '["First Aid","Tailoring"]');

console.log(fails ? `${fails} failed` : 'all passed');
process.exit(fails ? 1 : 0);
