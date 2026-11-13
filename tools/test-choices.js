// Checks that a "where next?" choice point stays on the step at the zone boundary through the safety net
// (ensure-steps.js), which inserts accept/objective steps for quests already in your log, drops pick-ups that are never
// handed in, adds missing travel steps and removes repeated ones. The addon matches the choice to a step id exactly,
// so a stale number put the prompt deep inside the next zone (after the travel and the first quests there).
// usage: node tools/test-choices.js   (from the repo, needs qdb/)
const path = require('path');
const { makeEnsure } = require('./ensure-steps');
const ROOT = path.resolve(__dirname, '..');
const db = require(path.join(ROOT, 'qdb', 'db.json'));
const conv = require(path.join(ROOT, 'qdb', 'conversion.json')).geometry.transforms;
const ensure = makeEnsure(db, conv);
const RR = 1433, DW = 1431; // Redridge Mountains, Duskwood
const rr = { m: RR, x: 0.3, y: 0.4, zone: 'Redridge Mountains' }, dw = { m: DW, x: 0.7, y: 0.4, zone: 'Duskwood' };
let fails = 0;
const check = (name, ok, info) => { console.log((ok ? 'ok   ' : 'FAIL ') + name + (ok ? '' : '  ' + JSON.stringify(info))); if (!ok) fails++; };
const show = (out) => out.map((s, i) => `${i + 1}:${s.k}:${s.q || s.dest || ''}${s._choice ? '*' : ''}`).join(' ');

// 1. the safety net adds the pick-up and objectives of a quest that was in your log before the boundary
{
  const steps = [
    { k: 'turnin', q: 92, name: 'Redridge Goulash', ...rr, sec: 1 }, // in your log: accept + 3 objectives get added
    { k: 'fly', dest: 'Duskwood', to: DW, text: 'Duskwood', sec: 2, _choice: 2 },
    { k: 'accept', q: 57, name: 'The Night Watch', ...dw, sec: 3 },
    { k: 'turnin', q: 57, name: 'The Night Watch', ...dw, sec: 3 },
  ];
  const out = ensure(steps), at = out.choiceAt(2);
  check('steps added before the boundary: the choice moves with the travel step', at > 0 && out[at - 1].k === 'fly' && out[at - 1].dest === 'Duskwood' && out.length > steps.length, show(out));
}
// 2b. quests already in your log, finished, planned from a capital: their put-back pick-ups and objectives are done at
// once, so no flights to them (Stormwind - Duskwood - Wetlands - Stormwind opened a plan with three hand-ins ready)
{
  const SW = { m: 1453, x: 0.4, y: 0.85, zone: 'Stormwind City' };
  const steps = [
    { k: 'turnin', q: 335, name: 'A Noble Brew', ...SW, sec: 1 },
    { k: 'turnin', q: 293, name: 'Cleansing the Eye', ...SW, sec: 1 },
    { k: 'turnin', q: 322, name: 'Blessed Arm', ...SW, sec: 1 },
  ];
  const out = ensure(steps, { done: [], active: [335, 293, 322] });
  const flights = out.filter((x) => x.k === 'fly');
  check('finished quests in your log: their put-back steps bring no flights', flights.length === 0 && out.some((x) => x.ensured), show(out));
  const out2 = ensure(steps, { done: [], active: [] });
  check('...but a quest not in your log still gets the trip to its giver', out2.some((x) => x.k === 'fly'), show(out2));
}
// 2. the first step of a leg is a pick-up that is never handed in on the route: the choice goes to the next step
{
  const steps = [
    { k: 'accept', q: 20, name: 'Blackrock Menace', ...rr, sec: 1 },
    { k: 'turnin', q: 20, name: 'Blackrock Menace', ...rr, sec: 1 },
    { k: 'accept', q: 173, name: 'Worgen in the Woods', ...rr, sec: 2, _choice: 3 }, // never handed in: dropped
    { k: 'accept', q: 92, name: 'Redridge Goulash', ...rr, sec: 2 },
    { k: 'turnin', q: 92, name: 'Redridge Goulash', ...rr, sec: 2 },
  ];
  const out = ensure(steps), at = out.choiceAt(3);
  check('dropped pick-up on the boundary: the choice is on the step after it', at > 0 && out[at - 1].q === 92 && out[at - 1].k !== 'obj' && !out.some((s) => s.q === 173), show(out));
}
// 3. two travel steps to the same place: the repeat goes, its choice stays on the one that is kept
{
  const steps = [
    { k: 'turnin', q: 20, name: 'Blackrock Menace', ...rr, sec: 1 },
    { k: 'fly', dest: 'Duskwood', to: DW, text: 'Duskwood', sec: 1 },
    { k: 'fly', dest: 'Duskwood', to: DW, text: 'Duskwood', sec: 2, _choice: 4 },
    { k: 'accept', q: 57, name: 'The Night Watch', ...dw, sec: 3 },
    { k: 'turnin', q: 57, name: 'The Night Watch', ...dw, sec: 3 },
  ];
  const out = ensure(steps), at = out.choiceAt(4);
  check('repeated travel step removed: the choice is on the travel step that stays', at > 0 && out[at - 1].k === 'fly' && out.filter((s) => s.k === 'fly').length === 1, show(out));
}
// 4. no travel step into the zone (the leg starts with a quest there): the added travel step gets the choice
{
  const steps = [
    { k: 'accept', q: 20, name: 'Blackrock Menace', ...rr, sec: 1 },
    { k: 'turnin', q: 20, name: 'Blackrock Menace', ...rr, sec: 1 },
    { k: 'accept', q: 57, name: 'The Night Watch', ...dw, sec: 2, _choice: 5 },
    { k: 'turnin', q: 57, name: 'The Night Watch', ...dw, sec: 2 },
  ];
  const out = ensure(steps), at = out.choiceAt(5);
  check('travel step added at the boundary: you choose before you go', at > 0 && out[at - 1].k === 'fly' && out[at - 1].to === DW && out[at].q === 57, show(out));
}
// a pick-up before its prerequisite (The Black Shield needs one of James Hyal / They Call Him Smiling Jim): across legs it
// landed before them and the audit flagged it - the safety net leaves the quest out unless a prerequisite is in first
{
  const bs = Object.values(db.quests).find((q) => q.name === 'The Black Shield' && (q.preSingle || []).includes(1282));
  const q2 = (id, name) => [{ k: 'accept', q: id, name, m: 1445, x: 0.5, y: 0.5, sec: 1 }, { k: 'turnin', q: id, name, m: 1445, x: 0.5, y: 0.5, sec: 1 }];
  const without = ensure(q2(bs.id, bs.name), { done: [], active: [] });
  check('a pick-up with no prerequisite done: left out', !without.some((x) => x.q === bs.id) && without.dropped >= 1, without.map((x) => x.k + ' ' + x.q));
  const withPre = ensure([...q2(1282, 'They Call Him Smiling Jim'), ...q2(bs.id, bs.name)], { done: [], active: [] });
  check('the same pick-up after one of its prerequisites: kept', withPre.filter((x) => x.q === bs.id).length === 2, withPre.map((x) => x.k + ' ' + x.q));
  const done = ensure(q2(bs.id, bs.name), { done: [1302], active: [] });
  check('a prerequisite done before the route counts', done.filter((x) => x.q === bs.id).length === 2, done.map((x) => x.k + ' ' + x.q));
}
console.log(fails ? fails + ' failed' : 'all passed');
process.exit(fails ? 1 : 0);
