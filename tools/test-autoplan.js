// The companion's "reload to get the new plan" decision (routefile.js aheadChanges): something new ahead of you, or
// something your plan still sends you to that the new one dropped - not steps you've done since, not reordering.
// usage: node tools/test-autoplan.js
const RF = require('./routefile');
let fails = 0;
const check = (name, ok, info) => { console.log((ok ? 'ok   ' : 'FAIL ') + name + (ok ? '' : '  ' + JSON.stringify(info))); if (!ok) fails++; };
const plan = (lines) => 'ForeverRouteRoutes = {\n  {\n    id = "path:A",\n    steps = {\n' + lines.map((l) => '      ' + l + ',\n').join('') + '    },\n  },\n}\n';
const accept = (q, npc) => `{ k = "accept", q = ${q}, npc = "${npc}" }`;
const turnin = (q, npc) => `{ k = "turnin", q = ${q}, npc = "${npc}" }`;
const fp = (npc, zone) => `{ k = "fp", npc = "${npc}", zone = "${zone}" }`;
const snap = { completed: [], log: {}, taxi: ['Astranaar, Ashenvale'] };
// the evening it went wrong: your plan had a Stonetalon flight-path detour, the new one doesn't
const yours = plan([fp('Teloren', 'Stonetalon Mountains'), turnin(1009, 'Talen'), accept(1010, 'Orendil')]);
const next = plan([turnin(1009, 'Talen'), accept(1010, 'Orendil')]);
const c1 = RF.aheadChanges(yours, next, 'path:A', snap);
check('a step your plan still sends you to, dropped by the new plan: a change (reload)', c1.changed && c1.dropped.length === 1, c1);
// you got that flight path since: dropping it is no change
const c2 = RF.aheadChanges(yours, next, 'path:A', { ...snap, taxi: ['Astranaar, Ashenvale', 'Stonetalon Peak, Stonetalon Mountains'] });
check('...but not once you have that flight path', !c2.changed, c2);
// a quest you finished since drops out of the new plan: no change
const c3 = RF.aheadChanges(plan([accept(1010, 'Orendil'), turnin(1009, 'Talen')]), plan([turnin(1009, 'Talen')]), 'path:A', { ...snap, log: { 1010: { complete: false } } });
check('a quest you picked up since drops out: no change', !c3.changed, c3);
// reordered: no change; something new: a change
check('the same steps in another order: no change', !RF.aheadChanges(yours, plan([accept(1010, 'Orendil'), fp('Teloren', 'Stonetalon Mountains'), turnin(1009, 'Talen')]), 'path:A', snap).changed);
const c5 = RF.aheadChanges(next, plan([turnin(1009, 'Talen'), accept(1033, 'Shindrell'), accept(1010, 'Orendil')]), 'path:A', snap);
check('a new step ahead: a change', c5.changed && c5.added.length === 1, c5);
console.log(fails ? fails + ' failed' : 'all passed');
process.exitCode = fails ? 1 : 0;
