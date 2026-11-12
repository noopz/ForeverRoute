// Trips players reported, as checks on tools/travel.js (the same rules as the addon's Travel.lua).
// usage: node test-travel.js
const path = require('path');
const T = require('./travel');
T.init(path.join(__dirname, '..', 'qdb', 'conversion.json'));
// Testchar at 21: Auberdine, Darkshire, Ironforge, Lakeshire, Sentinel Hill, Stormwind, Thelsamar, Theramore
const KNOWN_FP = new Set([1439, 1431, 1455, 1433, 1436, 1453, 1432, 1445]);
let fail = 0;
const check = (name, r, ok) => { const good = ok(r); if (!good) fail++; console.log((good ? 'ok   ' : 'FAIL ') + name + ': ' + T.describe(r)); };
const SW = { m: 1453, x: 0.62, y: 0.72 }, XROADS = { m: 1413, x: 0.52, y: 0.30 };
const hows = (r) => (r ? r.legs.map((l) => l.how) : []);
const nodesOf = (r) => (r ? r.legs.flatMap((l) => [l.from, l.to, ...(l.via || [])]) : []);
const via = (r, id) => nodesOf(r).some((n) => n.id === id || n.id === 'dock-' + id);
// a point in the Barrens inside Mor'shan Rampart (the Horde fort on the Ashenvale road)
const atRampart = (n) => [n.m === 1413 && [n.x, n.y], n.m2 === 1413 && [n.x2, n.y2]].some((p) => p && p[0] > 0.44 && p[0] < 0.485 && p[1] > 0.02 && p[1] < 0.09);

// "you cant fly to barrens ever, i have to boat" / "the run from dustwallow is impossible" (Dustwallow 35 at 21)
check('Stormwind -> Crossroads at 21: a boat, never a ride out of Theramore', T.plan(SW, XROADS, { level: 21, knownFP: KNOWN_FP }),
  (r) => r && hows(r).includes('boat') && !r.legs.some((l) => l.how === 'ride' && (l.from.id === 'theramore' || l.from.id === 'fp1445')));
// Mor'shan Rampart: Ashenvale -> Barrens only through the breach
check("Astranaar -> Crossroads: never past Mor'shan Rampart", T.plan({ m: 1440, x: 0.36, y: 0.50 }, XROADS, { level: 21, knownFP: KNOWN_FP }), (r) => r && !nodesOf(r).some(atRampart));
// no straight line over the mountains: Ironforge -> Menethil goes through Loch Modan
check('east Dun Morogh -> south Wetlands on foot: no crossing over the mountains (Loch Modan, Dun Algaz)', T.plan({ m: 1426, x: 0.86, y: 0.40 }, { m: 1437, x: 0.50, y: 0.75 }, { level: 22, knownFP: new Set() }), (r) => r && !nodesOf(r).some((n) => (n.m === 1426 && n.m2 === 1437) || (n.m === 1437 && n.m2 === 1426)) && nodesOf(r).some((n) => n.m === 1432 || n.m2 === 1432));
check('Ironforge -> Menethil on foot: through Loch Modan', T.plan({ m: 1455, x: 0.55, y: 0.48 }, { m: 1437, x: 0.10, y: 0.60 }, { level: 21, knownFP: new Set() }), (r) => r && nodesOf(r).some((n) => n.m === 1432 || n.m2 === 1432));
// "to get back i should be told to take the FP": Stormwind -> Darkshire with the flight path known
check('Stormwind -> Darkshire: fly', T.plan(SW, { m: 1431, x: 0.75, y: 0.45 }, { level: 21, knownFP: KNOWN_FP }), (r) => r && hows(r).includes('fly') && !hows(r).includes('boat'));
// no Menethil flight path: fly to Thelsamar, ride in
check('Stormwind -> Menethil without its flight path: fly then ride', T.plan(SW, { m: 1437, x: 0.10, y: 0.60 }, { level: 21, knownFP: KNOWN_FP }), (r) => r && hows(r)[hows(r).length - 1] === 'ride' && hows(r).includes('fly'));
// level 12 has no business riding through Duskwood (20)
check('Westfall -> Darkshire at 12: no safe way on foot', T.plan({ m: 1436, x: 0.56, y: 0.47 }, { m: 1431, x: 0.75, y: 0.45 }, { level: 12, knownFP: new Set([1453, 1436]) }), (r) => r === null);
// Menethil -> Auberdine: Forever's ship calls at Southshore on the way
check('Menethil -> Auberdine: via Southshore', T.plan({ m: 1437, x: 0.05, y: 0.58 }, { m: 1439, x: 0.37, y: 0.44 }, { level: 21, knownFP: new Set() }), (r) => r && via(r, 'southshore'));
// mounted from 40: the same ride across Westfall takes about 1/1.6 the time
{
  const a = T.plan({ m: 1436, x: 0.3, y: 0.3 }, { m: 1436, x: 0.6, y: 0.7 }, { level: 39, knownFP: new Set() });
  const b = T.plan({ m: 1436, x: 0.3, y: 0.3 }, { m: 1436, x: 0.6, y: 0.7 }, { level: 40, knownFP: new Set() });
  check('riding across Westfall at 40 (mounted) vs 39 (running)', b, () => a && b && Math.abs(a.sec / b.sec - 11.2 / 7) < 0.05);
}
// the other faction's towns cost extra: an Alliance ride through the Crossroads costs HOSTILE_SEC more than the same
// ride for a Horde player (for whom the Crossroads is home)
{
  const from = { m: 1413, x: 0.52, y: 0.22 }, to = { m: 1413, x: 0.52, y: 0.40 }; // north of the Crossroads to south of it
  const a = T.plan(from, to, { level: 30, knownFP: new Set(), faction: 'alliance' });
  const h = T.plan(from, to, { level: 30, knownFP: new Set(), faction: 'horde' });
  check('riding past the Crossroads costs an Alliance player more than a Horde one', a, () => a && h && a.sec > h.sec);
}
// Darnassus has no flight master and its walk map never reached Teldrassil's: the Rut'theran portal is the way out
// (without it every trip from the city was "no way", and the planner priced dungeon runs from there at 600+ minutes)
check("Darnassus -> Tanaris: through the Rut'theran portal", T.plan({ m: 1457, x: 0.42, y: 0.86 }, { m: 1446, x: 0.5, y: 0.3 }, { level: 44, knownFP: new Set([1438, 1439, 1446]) }), (r) => r && via(r, 'rutheranPortal'));
check("Teldrassil -> Darnassus: up the portal", T.plan({ m: 1438, x: 0.55, y: 0.92 }, { m: 1457, x: 0.4, y: 0.8 }, { level: 10, knownFP: new Set() }), (r) => r && via(r, 'darnassusPortal'));
// Moonglade for a druid: Teleport: Moonglade from anywhere (one way), the druids' hippogryph back to Rut'theran; nobody
// else has either (the druid class quests at 10 and 14 go there, and every trip was "no way")
check('druid, Darnassus -> Moonglade: Teleport: Moonglade', T.plan({ m: 1457, x: 0.4, y: 0.8 }, { m: 1450, x: 0.56, y: 0.31 }, { level: 14, knownFP: new Set(), race: 'nightelf', class: 'druid' }), (r) => r && r.legs.some((l) => l.how === 'spell'));
check("druid, Moonglade -> Darkshore: the druids' hippogryph to Rut'theran", T.plan({ m: 1450, x: 0.56, y: 0.31 }, { m: 1439, x: 0.39, y: 0.44 }, { level: 14, knownFP: new Set(), race: 'nightelf', class: 'druid' }), (r) => r && via(r, 'moongladeDruid'));
check('a level-14 warrior has no way to Moonglade', T.plan({ m: 1457, x: 0.4, y: 0.8 }, { m: 1450, x: 0.56, y: 0.31 }, { level: 14, knownFP: new Set(), race: 'nightelf', class: 'warrior' }), (r) => !r || !r.legs.some((l) => l.how === 'spell'));
check('a level-9 druid has no teleport yet', T.plan({ m: 1457, x: 0.4, y: 0.8 }, { m: 1450, x: 0.56, y: 0.31 }, { level: 9, knownFP: new Set(), race: 'nightelf', class: 'druid' }), (r) => !r || !r.legs.some((l) => l.how === 'spell'));
// mages: Teleport: Stormwind and Ironforge at 20, Darnassus at 30 (one way, from anywhere)
check('mage 20, Stranglethorn -> Ironforge: Teleport: Ironforge', T.plan({ m: 1434, x: 0.38, y: 0.5 }, { m: 1455, x: 0.3, y: 0.1 }, { level: 20, knownFP: new Set(), race: 'gnome', class: 'mage' }), (r) => r && r.legs.some((l) => l.how === 'spell'));
check('mage 25 has no Teleport: Darnassus yet', T.plan({ m: 1433, x: 0.3, y: 0.5 }, { m: 1457, x: 0.41, y: 0.82 }, { level: 25, knownFP: new Set(), race: 'human', class: 'mage' }), (r) => !r || !r.legs.some((l) => l.how === 'spell' && /Darnassus/.test(l.text || l.to || '')));
check('a level-19 mage has no teleport yet', T.plan({ m: 1434, x: 0.38, y: 0.5 }, { m: 1455, x: 0.3, y: 0.1 }, { level: 19, knownFP: new Set(), race: 'gnome', class: 'mage' }), (r) => !r || !r.legs.some((l) => l.how === 'spell'));
// ---- Horde: the zeppelins, their own lands, their own spells; none of the Alliance's crossings
const H = (level, extra = {}) => ({ level, knownFP: new Set(), faction: 'horde', ...extra });
const ORG = { m: 1454, x: 0.45, y: 0.64 }, UC_GATE = { m: 1420, x: 0.62, y: 0.66 }, GROMGOL = { m: 1434, x: 0.32, y: 0.28 };
check('horde, Orgrimmar -> Undercity gates at 20: the zeppelin', T.plan(ORG, UC_GATE, H(20)), (r) => r && via(r, 'durotarZeppelin') && via(r, 'tirisfalZeppelin'));
check("horde, Tirisfal -> Grom'gol at 30: the zeppelin straight there", T.plan(UC_GATE, GROMGOL, H(30)), (r) => r && via(r, 'tirisfalZeppelin') && via(r, 'gromgolZeppelin') && !via(r, 'durotarZeppelin'));
check("alliance, Stormwind -> Grom'gol: never a zeppelin", T.plan(SW, GROMGOL, { level: 30, knownFP: KNOWN_FP }), (r) => !nodesOf(r).some((n) => /Zeppelin/.test(n.id || '')));
check('horde, Crossroads -> Wetlands at 25: never the Theramore or Auberdine boats', T.plan(XROADS, { m: 1437, x: 0.5, y: 0.4 }, H(25)), (r) => !['menethilS', 'theramore', 'auberdine', 'southshore', 'stormwind'].some((d) => via(r, d)));
check('horde, level 3 in Mulgore -> Bloodhoof Village: a ride (their own start zone is not a level-60 zone)', T.plan({ m: 1412, x: 0.45, y: 0.75 }, { m: 1412, x: 0.47, y: 0.58 }, H(3)), (r) => r && hows(r).every((h) => h === 'ride'));
check('horde, level 6 Durotar -> Orgrimmar: a ride', T.plan({ m: 1411, x: 0.52, y: 0.42 }, ORG, H(6)), (r) => r !== null);
check("alliance, level 20 still can't ride through Durotar", T.plan({ m: 1413, x: 0.62, y: 0.37 }, { m: 1411, x: 0.52, y: 0.42 }, { level: 20, knownFP: new Set() }), (r) => r === null);
check('horde mage 20, Stranglethorn -> Orgrimmar: Teleport: Orgrimmar', T.plan({ m: 1434, x: 0.38, y: 0.5 }, ORG, H(20, { race: 'troll', class: 'mage' })), (r) => r && r.legs.some((l) => l.how === 'spell' && l.to.dock === 'mageOrgrimmar'));
check('horde mage 25 has no Teleport: Thunder Bluff yet', T.plan({ m: 1433, x: 0.3, y: 0.5 }, { m: 1456, x: 0.3, y: 0.3 }, H(25, { race: 'troll', class: 'mage' })), (r) => !r || !r.legs.some((l) => l.how === 'spell' && l.to.dock === 'mageThunderBluff'));
check('horde mage never gets Teleport: Stormwind', T.plan({ m: 1434, x: 0.38, y: 0.5 }, SW, H(40, { race: 'undead', class: 'mage' })), (r) => !r || !r.legs.some((l) => l.how === 'spell' && /^mage(Stormwind|Ironforge|Darnassus)$/.test(l.to.dock || '')));
check('tauren druid, Moonglade -> Mulgore: the wind rider to Thunder Bluff, never Rut\'theran', T.plan({ m: 1450, x: 0.44, y: 0.46 }, { m: 1412, x: 0.47, y: 0.58 }, H(16, { race: 'tauren', class: 'druid' })), (r) => r && via(r, 'moongladeDruidH') && !via(r, 'rutheranFlight'));
check('horde, flying from Orgrimmar to the Crossroads: Horde flight masters', T.plan(ORG, XROADS, H(20, { knownFP: new Set([1454, 1413]) })), (r) => r && hows(r).includes('fly'));
// ---- getting into Undercity (its lifts) and up to Thunder Bluff (its lifts)
check('horde, Orgrimmar -> inside Undercity at 20: the zeppelin and the lifts', T.plan(ORG, { m: 1458, x: 0.66, y: 0.44 }, H(20)), (r) => r && via(r, 'tirisfalZeppelin') && r.sec < 1200);
check('horde, Mulgore -> Thunder Bluff (on the mesa): a ride up the lifts', T.plan({ m: 1412, x: 0.47, y: 0.58 }, { m: 1456, x: 0.45, y: 0.6 }, H(12)), (r) => r !== null && r.sec < 600);
console.log(fail ? fail + ' failed' : 'all passed');
process.exit(fail ? 1 : 0);
