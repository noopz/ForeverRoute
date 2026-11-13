// The chain-loss report (tools/chain-report.js) on a made-up world (tools/test-fixtures/chain-report.json: zones A-G,
// a dungeon, a battleground; the plan only flies through D, calls E by another name than the zone list (as the planner
// says 'Stormwind' for 'Stormwind City'), is in F only on a step with no level, in G only on a step placed by its map,
// and ends at level 20 in C): which chain parts count as lost, under which class, and which the plan was never meant
// to take - for a human, an orc, and a character that had done a quest and had one in its log before the plan.
// usage: node tools/test-chain-report.js
const path = require('path');
const { chainReport, summaryLine, formatReport, CLASSES } = require('./chain-report');
const W = require('./world');
const fx = require(path.join(__dirname, 'test-fixtures', 'chain-report.json'));
let fails = 0;
const check = (name, ok, info) => { console.log((ok ? 'ok   ' : 'FAIL ') + name + (ok ? '' : '  ' + JSON.stringify(info))); if (!ok) fails++; };
const rep = chainReport(fx);
const row = (id) => rep.rows.find((r) => r.id === id);
const classOf = (id) => (row(id) ? CLASSES[row(id).kind] : 'not listed');
check('a head picked up and never handed in: it and its followers are "picked up"', [1, 2, 3].every((id) => classOf(id) === CLASSES[0]), [1, 2, 3].map(classOf));
check('...and the followers name the head they were lost at', row(3) && row(3).at && row(3).at.id === 1, row(3));
check('a cross-zone head never taken: "not taken", marked cross-zone', classOf(4) === CLASSES[3] && row(4).crossZone === true, row(4));
check('...its follower: "chain head never taken", cross-zone, from both its givers\' zones to Zone B', classOf(5) === CLASSES[1] && row(5).crossZone && row(5).from === 'Zone A / Zone C' && row(5).to === 'Zone B', row(5));
check('a part whose prerequisite is handed in: "prerequisite done"', classOf(7) === CLASSES[2] && classOf(8) === CLASSES[2], [classOf(7), classOf(8)]);
check('...a part behind it is lost at that part (prerequisite done)', classOf(9) === CLASSES[2] && row(9).at.id === 8, row(9));
check('one of a choice of prerequisites handed in is enough (the other one is for another race)', classOf(29) === CLASSES[2] && !row(29).at, row(29));
check('another class\'s chain is not counted', !row(10) && !row(11));
check('a dungeon quest and the part behind it are not counted (dungeons are never forced)', !row(12) && !row(13) && rep.skipped['behind a quest it cannot take (dungeon)'] === 1, rep.skipped);
check('a chain the plan never reaches at its level is not counted', !row(14) && !row(15));
check('a quest that leads nowhere and needs nothing is not a chain part', !row(16));
check('an alternative to one handed in is not counted', !row(18) && rep.skipped['an alternative to one handed in'] === 2, rep.skipped);
check('...and a part that needs the other alternative is not counted either', !row(34) && !row(35) && rep.skipped['behind a part that is an alternative to one handed in'] === 1, rep.skipped);
check('a breadcrumb whose quest the plan took is not counted', !row(20) && rep.skipped['a breadcrumb, its quest taken'] === 1, rep.skipped);
check('battleground quests are not counted', !row(22) && !row(23));
check('a chain the plan can first take in its last levels is end-game: listed apart, not counted', !row(24) && !row(25) && rep.endRows.map((x) => x.id).sort().join() === '24,25' && rep.endGame.xp === 4900 && rep.endGame.from === 16, rep.endGame);
check('the steps\' name for a zone (Zone E, as \'Stormwind\') is the zone list\'s Zone E City: its chain is counted', classOf(40) === CLASSES[3] && classOf(41) === CLASSES[1] && row(40).zone === 'Zone E', [classOf(40), row(40)]);
check('a step with no level is at the plan\'s last level: the chain in Zone F is counted', classOf(42) === CLASSES[3] && classOf(43) === CLASSES[1]);
check('a step with a map is placed by its map, not its name: the chain in Zone G is counted', classOf(44) === CLASSES[3] && classOf(45) === CLASSES[1]);
check('a chain head that starts from an item is not counted (the planner leaves those out), nor what is behind it', !row(38) && !row(39) && rep.skipped['starts from an item, not in the log'] === 1 && rep.skipped['behind a quest it cannot take (starts from an item, not in the log)'] === 1, rep.skipped);
check('quests it can never take get their own lines under "not counted"', rep.skipped['race or class'] === 2 && rep.skipped['dungeon'] === 1 && rep.skipped['battleground'] === 2 && rep.skipped['other faction'] === 3, rep.skipped);
check('...and the report prints them', /## Not counted[^]*\n  race or class: 2\n/.test(formatReport(rep)));
check('a part with no XP in the data says so', /41 Q41 \(Zone E, lvl 8, no xp\)/.test(formatReport(rep)));
check('a chain behind another faction\'s giver is not counted', !row(26) && !row(27));
check('a flight or hearth into a zone is not being there: the chain in Zone D is not counted', !row(31) && !row(32));
check('XP per class: 600 / 9300 / 5300 / 13000', rep.byClass.map((c) => c.xp).join() === '600,9300,5300,13000', rep.byClass);
check('XP per zone: Zone A 6300 in 8, Zone B 500 in 1', rep.byZone['Zone A'].xp === 6300 && rep.byZone['Zone A'].parts === 8 && rep.byZone['Zone B'].xp === 500, rep.byZone);
check('total 28200 XP in 15 parts, one cross-zone head', rep.total.xp === 28200 && rep.total.parts === 15 && rep.total.crossZoneHeads === 1, rep.total);
check('the summary line says it', summaryLine(rep) === 'chain XP lost: 28200 XP in 15 part(s) (picked up 600/3, head not taken 9300/4, prereq done 5300/4, not taken 13000/4; 1 cross-zone head(s); 7 hand-ins on the plan); end-game, not counted: 4900 XP in 2 part(s)', summaryLine(rep));

// a Horde character on the same plan: the Horde givers' chain is its own, the Alliance givers' are not
const horde = chainReport({ ...fx, race: 'orc' });
const hRow = (id) => horde.rows.find((r) => r.id === id);
check('an orc: the Horde chain is counted (head not taken, then its follower)', hRow(36) && hRow(36).kind === 3 && hRow(37) && hRow(37).kind === 1, horde.rows.map((r) => r.id));
check('...and the Alliance givers\' chains are another faction\'s', !hRow(1) && !hRow(7) && !hRow(40) && horde.skipped['other faction'] > 10, horde.skipped);

// a character with a quest done before the plan (Q4) and one in its log (the item-started Q38)
const mid = chainReport({ ...fx, completed: [4], active: { 38: {} } });
const mRow = (id) => mid.rows.find((r) => r.id === id);
check('done before the plan: not listed, and the part after it has its prerequisite done', !mRow(4) && mRow(5) && mRow(5).kind === 2 && mid.total.doneBefore === 1, mRow(5));
check('in the log before the plan and never handed in: "picked up" (an item-started one too), and its follower with it', mRow(38) && mRow(38).kind === 0 && mRow(39) && mRow(39).kind === 0 && mRow(39).at.id === 38, [mRow(38), mRow(39)]);
check('...the hand-ins on the plan are the plan\'s own, the done-before ones are said apart', mid.total.handedIn === 7 && /7 hand-ins on the plan, 1 done before it\)/.test(summaryLine(mid)), summaryLine(mid));

// the planner and the report name zones from one list: Stormwind is 'Stormwind' in both
const names = W.plannerZoneNames([{ area_id: 1519, target_name: 'Stormwind City' }, { area_id: 331, target_name: 'Ashenvale' }]);
check('the planner\'s zone names: Stormwind stays Stormwind, others from the conversion', names[1519] === 'Stormwind' && names[331] === 'Ashenvale' && W.PLANNER_ZONE_NAMES[1519] === 'Stormwind', names);
console.log(fails ? fails + ' failed' : 'all passed');
process.exitCode = fails ? 1 : 0;
