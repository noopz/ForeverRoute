// Checks the optimizer's work settings (optimize.js), on a made-up leg - no quest data needed:
// 1. a work setting that is not a positive number (a string, NaN, 0) falls back to the default and says so, instead of
//    making the moves NaN and the search silently do none
// 2. the safety cap is one deadline for the whole search: several runs one after another on one thread stop together
//    at the cap, not each at its own (the leg would otherwise run for runs x cap and outlive campaign.js's timeout)
// 3. the runs that go in rounds (fewer threads than runs) are reported, and the order does not depend on the threads
// usage: node tools/test-optimize-work.js
const { optimize, workFor, roundsFor, RUNS } = require('./optimize');

let fails = 0;
const check = (name, ok, got) => { console.log((ok ? 'ok   ' : 'FAIL ') + name + (ok ? '' : '  (got ' + JSON.stringify(got) + ')')); if (!ok) fails++; };

// a leg of 20 quests (pick-up and hand-in at a hub, one objective out in the wild each), 12 places on a line
function leg(nq) {
  const nL = 12, D = new Float32Array(nL * nL);
  for (let a = 0; a < nL; a++) for (let b = 0; b < nL; b++) D[a * nL + b] = Math.abs(a - b) * 30;
  const events = [];
  for (let q = 1; q <= nq; q++) {
    const hub = q % 2 ? 0 : 11, wild = 1 + ((q * 7) % 10);
    events.push({ kind: 'accept', q, loc: hub, work: 5, xp: 0, reqLevel: 1, pre: [] });
    events.push({ kind: 'obj', q, loc: wild, work: 60, xp: 0, reqLevel: 1, pre: [] });
    events.push({ kind: 'turnin', q, loc: hub, work: 5, xp: 100, qLevel: 10, reqLevel: 1, pre: [] });
  }
  const XP = Array(61).fill(1e9);
  return { events, D, nL, opts: { startLoc: 0, level: 10, xp: 0, xpToLevel: XP, xpWeight: 0, initial: events.map((_, k) => k) } };
}

(async () => {
  const { events, D, nL, opts } = leg(20);
  // 1. bad settings
  const said = [], saved = console.error; console.error = (...a) => said.push(a.join(' '));
  for (const bad of ['abc', NaN, 0, -1]) {
    said.length = 0;
    const r = await optimize(events, D, nL, { ...opts, effort: bad, runs: 1, workers: 1 });
    check(`effort ${JSON.stringify(bad)}: the search still does its default moves (${workFor(events.length).maxIt})`, r.iterations === workFor(events.length).maxIt, r.iterations);
    check(`effort ${JSON.stringify(bad)}: and says so`, said.some((s) => /effort/.test(s) && /not a positive number/.test(s)), said);
  }
  said.length = 0;
  const r1 = await optimize(events, D, nL, { ...opts, effort: 0.1, runs: 'seven', workers: 7 });
  check(`runs "seven": the default ${RUNS} runs, said`, r1.runs === RUNS && said.some((s) => /runs/.test(s)), { runs: r1.runs, said });
  console.error = saved;
  check('workFor with a NaN effort is the default work', workFor(100, NaN).maxIt === workFor(100).maxIt, workFor(100, NaN));

  // 2. the cap is shared: 4 long runs on 1 thread, a 1.5 s cap - done in about 1.5 s, not 4 x 1.5 s, every run capped
  const t = Date.now();
  const r2 = await optimize(events, D, nL, { ...opts, maxIt: 4e8, runs: 4, workers: 1, capMs: 1500 });
  const s = (Date.now() - t) / 1000;
  check(`a 1.5 s cap over 4 runs on one thread ends the whole search in time (${s.toFixed(1)} s)`, s < 4, s);
  check('every run that the deadline cut short is counted as capped', r2.capped === 4, r2.capped);

  // 3. rounds: 7 runs on 2 threads go in 4 rounds, reported; the same order as on 7 threads
  const a = await optimize(events, D, nL, { ...opts, effort: 0.05, runs: 7, workers: 2 });
  const b = await optimize(events, D, nL, { ...opts, effort: 0.05, runs: 7, workers: 7 });
  check('7 runs on 2 threads: 4 rounds reported', a.rounds === 4 && a.threads === 2, { rounds: a.rounds, threads: a.threads });
  check('7 runs on 7 threads: 1 round', b.rounds === 1, b.rounds);
  check('roundsFor agrees', roundsFor(7, 2) === 4 && roundsFor(7, 8) === 1 && roundsFor(7, 3) === 3, [roundsFor(7, 2), roundsFor(7, 8), roundsFor(7, 3)]);
  check('the same order on 2 threads and on 7', a.order.join() === b.order.join() && a.cost === b.cost, [a.cost, b.cost]);

  console.log(fails ? fails + ' failed' : 'all passed');
  process.exit(fails ? 1 : 0);
})();
