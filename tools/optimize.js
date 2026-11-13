// Route order optimizer: pickup-and-delivery with precedence, level and log-size rules.
// Simulated annealing over the event sequence, run on several worker threads with different seeds; best wins.
// optimize(events, D, opts) -> Promise<{ order, cost, base, violations, baseViolations }>
//   events: [{ kind: 'accept'|'obj'|'turnin', q, i?, loc, work, xp, reqLevel, pre: [qid], after?: [event index], kills?, mobLevel?, killXp?, grind? }]
//   D: Float32Array n_loc*n_loc travel seconds between locations (loc = index)
const { Worker, isMainThread, parentPort, workerData } = require('worker_threads');
const os = require('os');

// XP for one kill of a mob of level `mob` at your level L (Classic formula; grey mobs give nothing). The simulation
// (route2.js) uses this same function, so the optimizer counts the levels you gain the way the simulation did.
const { killXp, questXp } = require('./world'); // the shared rules (tools/world.js)
// a broken rule costs far more than any route can save, but it is a number, not Infinity: annealing that starts from an
// order with a broken rule (the simulation's own order, when the model here disagrees with it) can still climb out one
// move at a time, instead of only escaping when a single move happens to fix every broken rule at once
const PENALTY = 1e6;

function makeEval(events, D, nLoc, opts) {
  const XP = opts.xpToLevel;
  const n = events.length;
  const maxLog = opts.maxLog || 40, log0 = opts.log0 || 0;
  const qIdx = new Map(); // qid -> {accept, objs[], turnin}
  events.forEach((e, k) => { const r = qIdx.get(e.q) || { objs: [] }; if (e.kind === 'accept') r.accept = k; else if (e.kind === 'turnin') r.turnin = k; else r.objs.push(k); qIdx.set(e.q, r); });
  const posOf = new Int32Array(n);
  // the rule checks as flat per-event lists, worked out once (the search evaluates an order millions of times, and a
  // Map lookup per event per evaluation was a good part of its time): KIND 0 pick-up, 1 objective, 2 hand-in; ACC
  // the event's own quest pick-up (-1 none); MUST the events that have to come before it - for a pick-up the hand-ins
  // of its prerequisite quests, for a hand-in its own quest's objectives; AFTER the events it lists in 'after'
  const KIND = new Uint8Array(n), ACC = new Int32Array(n), REQ = new Float64Array(n), AFTER = [], MUST = [];
  events.forEach((e, k) => {
    const r = qIdx.get(e.q);
    KIND[k] = e.kind === 'accept' ? 0 : e.kind === 'turnin' ? 2 : 1;
    ACC[k] = r.accept !== undefined ? r.accept : -1;
    REQ[k] = e.reqLevel > 0 ? e.reqLevel : -Infinity; // no level given: never too high (as 'undefined > level' was)
    AFTER[k] = Int32Array.from(e.after || []);
    MUST[k] = KIND[k] === 0 ? Int32Array.from((e.pre || []).map((pq) => qIdx.get(pq)).filter((pr) => pr && pr.turnin !== undefined).map((pr) => pr.turnin))
      : KIND[k] === 2 ? Int32Array.from(r.objs) : new Int32Array(0);
  });
  // backtracking (route2.js gives each place: hub or wild, and its area of the wild): going back to a wild area you had
  // left (moved beyond the neighbouring areas) costs revisitSec; a trip from a hub out to one wild thing and back to a
  // hub costs thinSec. Clustering out in the wild beats bouncing - the player's rule, ahead of raw time.
  const hub = opts.locHub, cellOf = opts.locCell;
  let cellId = null, nCells = 0, cellXY = null, state = null, here = null, nHere = 0;
  if (hub && cellOf) {
    const ids = new Map(); cellId = new Int32Array(nLoc); cellXY = [];
    cellOf.forEach((c, i) => { const k = c.join(':'); if (!ids.has(k)) { ids.set(k, ids.size); cellXY.push(c); } cellId[i] = ids.get(k); });
    nCells = ids.size; state = new Uint8Array(nCells); // 0 never, 1 here (or next door), 2 left
    here = new Int32Array(nCells); // the areas marked 1 (a short list: only the ones you are around)
  }
  const near = (a, b) => cellXY[a][0] === cellXY[b][0] && Math.abs(cellXY[a][1] - cellXY[b][1]) <= 1 && Math.abs(cellXY[a][2] - cellXY[b][2]) <= 1;
  // returns total seconds (minus the finishing-level bonus) plus PENALTY per broken rule; cost.violations is the
  // number of broken rules in the order it was last called with (0 = an order the player can really follow)
  function cost(order) {
    for (let p = 0; p < n; p++) posOf[order[p]] = p;
    let t = 0, loc = opts.startLoc, level = opts.level, xp = opts.xp, log = log0, bad = 0, pen = 0;
    let back = 0, revisits = 0, thin = 0, wildRun = 0, wildLoc = -1, lastHub = -1;
    if (state) { state.fill(0); nHere = 0; }
    for (let p = 0; p < n; p++) {
      const k = order[p], e = events[k], kind = KIND[k];
      // nothing before its level: quests too far above you, and kills against mobs well above you
      // (the further short of it, the worse, so a move that gets closer counts as progress)
      if (REQ[k] > level) { bad++; pen += 1 + (e.reqLevel - level - xp / XP[level]); }
      // events that must come first (by index): a dungeon run after the pick-ups of the quests done in it, and those
      // quests' objectives in the dungeon after the run
      const af = AFTER[k]; for (let a = 0; a < af.length; a++) if (posOf[af[a]] > p) { bad++; pen++; }
      // a pick-up after its prerequisites' hand-ins, a hand-in after its own quest's objectives
      const mu = MUST[k]; for (let a = 0; a < mu.length; a++) if (posOf[mu[a]] > p) { bad++; pen++; }
      if (kind === 0) {
        // the log holds 40 on Forever, counting the quests you came in with
        if (++log > maxLog) { bad++; pen++; }
      } else {
        if (ACC[k] >= 0 && posOf[ACC[k]] > p) { bad++; pen++; }
        if (kind === 2) log--;
      }
      if (e.loc !== loc) {
        t += D[loc * nLoc + e.loc];
        if (state) {
          const c = cellId[e.loc];
          if (hub[e.loc]) {
            // back at a hub: a trip out for just one thing, far enough to be a trip, is thin
            if (wildRun === 1 && lastHub >= 0 && D[lastHub * nLoc + wildLoc] > 60) { back += opts.thinSec || 0; thin++; }
            wildRun = 0; lastHub = e.loc;
          } else {
            if (state[c] === 2) { back += opts.revisitSec || 0; revisits++; }
            if (state[c] !== 1) { state[c] = 1; here[nHere++] = c; }
            wildRun++; wildLoc = e.loc;
          }
          // the wild areas you are now away from (beyond next door) are left
          let k2 = 0;
          for (let k = 0; k < nHere; k++) { const h = here[k]; if (h !== c && !near(h, c)) state[h] = 2; else here[k2++] = h; }
          nHere = k2;
        }
        loc = e.loc;
      }
      t += e.work;
      // xp: kills during objectives at the level you are at by then (as the simulation and the step writer count
      // it), dungeon runs and grinds as their fixed figure, and quest turn-ins; quest xp shrinks once you outlevel it
      let gain = e.kills > 0 && e.mobLevel != null ? e.kills * killXp(e.mobLevel, level) : e.killXp || 0;
      if (kind === 2) gain += questXp(e.xp, e.qLevel, level); // the shared rule (world.js)
      xp += gain; while (level < 60 && xp >= XP[level]) { xp -= XP[level]; level++; }
    }
    cost.violations = bad;
    cost.revisits = revisits; cost.thin = thin;
    // reward finishing higher: convert leftover xp shortfall vs base into time at the zone's xp/sec
    return t + back - opts.xpWeight * (level * 100000 + xp) + PENALTY * pen;
  }
  cost.violations = 0;
  return cost;
}

// The search's work: moves per run for a leg of n events, times opts.effort (1 = the default; quick plans take less).
// Chosen on 14 real legs of five plans (tools/test-optimize.js --budget; 17 to 167 events): legs up to ~50 events
// reach their best order in 250k moves; a 100-event leg needed about 2M (1M left the 14 legs 1591 s above the best
// found in sum, 2M 255 s, 4M no better); the 167-event leg still gained from 4M. So 200 n^2 moves, 200k to 4M. Most
// legs of a plan are small: 20000 n with a 500k floor (as good on these legs) took 1.7x the work over the 87 legs of
// the human warrior plan. A move costs time in proportion to n: ~5-15 s for a leg of 100-170 events, all runs
// together, on a busy 8-core PC.
// (an effort that is not a positive number would make the moves NaN and the search silently do none: 1 then;
// optimize() has already said so when it came from a config)
const workFor = (n, effort = 1) => { if (!(effort > 0 && Number.isFinite(effort))) effort = 1; return { maxIt: Math.max(2000, Math.round(effort * Math.min(4e6, Math.max(2e5, 200 * n * n)) / 2000) * 2000) }; };
// independent runs (seeds) per leg, best wins: seven, the number of threads it had on an 8-core PC (one run per thread
// then). Four runs were clearly worse on the big legs (569 s above the best in sum, against 255 s with seven, at 2M moves).
// On a PC with fewer threads the seven runs go in rounds, one after another (ceil(7 / threads): 2 on a 4-core PC, 4 on
// a 2-core one), and the search takes that many times as long - the price of the same plan on every PC. route2.js and
// campaign.js say so (optimize returns rounds; roundsFor works it out up front). Fewer runs would cut that wait, but
// the only evidence is against it: on three fresh legs (test-optimize.js --budget 1 --runs 3,5,7; 35 to 125 events)
// three runs lost 35 s, five and seven tied - legs too easy to tell; the 14-leg set is what showed four worse than
// seven, so seven stays until five or six is measured there.
const RUNS = 7;
const threadsFor = (runs, workers) => Math.max(1, Math.min(runs, workers || os.cpus().length - 1));
const roundsFor = (runs = RUNS, workers) => Math.ceil(runs / threadsFor(runs, workers));
// a work setting from a config (effort, runs, cap): unset is the default; anything else that is not a positive number
// (a string, NaN, 0, a negative) would have made the moves NaN and the search do no moves at all, without a word - so
// it falls back to the default and says so
function positive(v, def, name) {
  if (v === undefined || v === null) return def;
  if (typeof v === 'number' && Number.isFinite(v) && v > 0) return v;
  console.error(`optimizer: ${name} ${JSON.stringify(v)} is not a positive number - using ${def === undefined ? 'the default' : def}`);
  return def;
}

function anneal(events, D, nLoc, opts, seed) {
  let s = seed >>> 0 || 1;
  const rnd = () => { s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0; return s / 4294967296; };
  const cost = makeEval(events, D, nLoc, opts);
  const n = events.length;
  let cur = Int32Array.from(opts.initial), cc = cost(cur);
  let best = cur.slice(), bc = cc;
  const t0 = Date.now();
  let T = opts.T0 || 120, it = 0;
  const tmp = new Int32Array(n), blk = new Int32Array(6);
  // ALNS-style destroy and repair (Ropke & Pisinger 2006): the other moves shift events a few at a time and never see
  // a quest as a whole - its pick-up, objectives and hand-in sit far apart. This one takes every event of one quest
  // out and reinserts them in order (pick-up, then each objective, then the hand-in, each after the one before) at the
  // cheapest of a sample of positions: near events at the same place, plus a few at random. Rare (FR_OPT_REPAIR, the
  // share of moves; 0 turns it off): each one costs about a hundred evaluations.
  const repairP = opts.repairP ?? +(process.env.FR_OPT_REPAIR ?? 0);
  const byLoc = new Map(); events.forEach((e, k) => { const l = byLoc.get(e.loc) || []; l.push(k); byLoc.set(e.loc, l); });
  const rank = (e) => (e.kind === 'accept' ? 0 : e.kind === 'turnin' ? 2 : 1);
  function repair(arr) {
    const q = events[arr[Math.floor(rnd() * n)]].q;
    const out = [], rest = [];
    for (let k = 0; k < n; k++) (events[arr[k]].q === q ? out : rest).push(arr[k]);
    if (out.length === n) return;
    out.sort((x, y) => rank(events[x]) - rank(events[y]));
    let seq = rest, from = 0;
    for (const ev of out) {
      // candidate slots (insert before seq[j], j from 'from' to seq.length): after events at the same place, and some at random
      const cand = new Set([seq.length]);
      const posIn = new Map(); seq.forEach((x, j) => posIn.set(x, j));
      for (const x of byLoc.get(events[ev].loc) || []) { const j = posIn.get(x); if (j !== undefined && j >= from) { cand.add(j + 1); cand.add(j); } }
      for (let r = 0; r < 12; r++) cand.add(from + Math.floor(rnd() * (seq.length - from + 1)));
      let bestJ = -1, bestC = Infinity;
      const left = out.slice(out.indexOf(ev) + 1);
      for (const j of cand) {
        if (j < from || j > seq.length) continue;
        const trial = seq.slice(0, j).concat([ev], seq.slice(j), left);
        tmp2.set(trial);
        const c = cost(tmp2);
        if (c < bestC) { bestC = c; bestJ = j; }
      }
      seq = seq.slice(0, bestJ).concat([ev], seq.slice(bestJ)); from = bestJ + 1;
    }
    arr.set(seq);
  }
  const tmp2 = new Int32Array(n);
  // nothing to order (a leg left with no events, or one): the order it came in
  if (n < 2) return { order: Array.from(cur), cost: cc, iterations: 0, violations: cost.violations };
  // a fixed number of moves (workFor), not seconds: same input + same seed = same route, however busy the PC is. The
  // temperature falls from T0 to TMIN over the first 80% of them and the rest polish at TMIN. It used to fall by a
  // fixed 3% per 2000 moves, so it was cold after ~360k moves whatever the leg's size: on the big legs every move
  // after that (a million or more) found next to nothing, and the stop rule waited for it to stall. On 14 real
  // legs, same seeds, the old search ended 2406 s above the best orders known in sum, this one 522 s (cost seconds:
  // 18 min less travel and work in all, 3 fewer backtracks; better on every leg of 47+ events, worse on none).
  // opts.capMs is a safety stop only, far above a normal run. It is one deadline for the whole optimize() call
  // (opts.deadline, set there), not one per run: a thread doing several runs in turn would otherwise get the cap once
  // per run, and the leg could outlive the time campaign.js gives its process.
  const maxIt = opts.maxIt ?? workFor(n, opts.effort).maxIt;
  const stopAt = opts.deadline || (opts.capMs ? t0 + opts.capMs : 0);
  const TMIN = 0.5, cool = Math.pow(TMIN / T, 2000 / (maxIt * 0.8));
  let capped = false;
  while (it < maxIt) {
    if (stopAt && Date.now() > stopAt) { capped = true; break; }
    for (let inner = 0; inner < 2000; inner++, it++) {
      tmp.set(cur);
      const mv = rnd();
      if (repairP > 0 && mv < repairP) { // ALNS destroy + repair: lift a whole quest out, put each piece back where it costs least
        repair(tmp);
      } else if (mv < 0.45) { // relocate a block of 1-6 events: lift tmp[i, i+len) out, put it back before rest[j]
        const len = 1 + Math.floor(rnd() * Math.min(6, n - 1)), i = Math.floor(rnd() * (n - len + 1));
        const j = Math.floor(rnd() * (n - len + 1));
        // in place (building the two arrays was a third of a move's time): the events between slide over by len
        blk.set(tmp.subarray(i, i + len));
        if (j < i) tmp.copyWithin(j + len, j, i); else if (j > i) tmp.copyWithin(i, i + len, j + len);
        tmp.set(blk.subarray(0, len), j);
      } else if (mv < 0.75) { // reverse a segment (2-opt)
        let i = Math.floor(rnd() * n), j = Math.floor(rnd() * n); if (i > j) [i, j] = [j, i];
        if (j - i > 60) j = i + 60;
        for (; i < j; i++, j--) { const x = tmp[i]; tmp[i] = tmp[j]; tmp[j] = x; }
      } else if (mv < 0.9) { // swap two events
        const i = Math.floor(rnd() * n), j = Math.floor(rnd() * n); const x = tmp[i]; tmp[i] = tmp[j]; tmp[j] = x;
      } else { // pull all events at one location next to the first of them (batching)
        const i = Math.floor(rnd() * n), L = events[tmp[i]].loc;
        const same = [], other = [];
        for (let k = 0; k < n; k++) (events[tmp[k]].loc === L && k > i ? same : other).push(tmp[k]);
        const at = other.indexOf(tmp[i]) + 1; other.splice(at, 0, ...same); tmp.set(other);
      }
      const nc = cost(tmp);
      if (nc < cc || (isFinite(nc) && rnd() < Math.exp((cc - nc) / T))) { cur.set(tmp); cc = nc; if (cc < bc) { bc = cc; best = cur.slice(); } }
    }
    T = Math.max(TMIN, T * cool);
  }
  cost(best);
  return { order: Array.from(best), cost: bc, iterations: it, violations: cost.violations, capped };
}

// one run's seed: run r gets the seed worker r had when there was one run per thread
const seedOf = (r) => 0x9e3779b9 * (r + 1);

if (!isMainThread) {
  const { events, D, nLoc, opts, runs } = workerData;
  require('./world').setLearned(opts.learned); // kill XP as your kills really gave it (tools/learn.js)
  const Df = new Float32Array(D);
  parentPort.postMessage(runs.map((r) => ({ ...anneal(events, Df, nLoc, opts, seedOf(r)), run: r })));
  return;
}

// opts.runs independent runs (seeds), best wins. The number of runs is part of the input, not of the PC: it used to be
// one per thread (cores - 1), so the same save planned on a 4-core and an 8-core PC came out different, and the leg
// cache (campaign.js runKey leaves the thread count out) handed one PC's legs to the other. Threads (opts.workers,
// default cores - 1) now only decide how many runs go at once.
function optimize(events, D, nLoc, opts0) {
  const capMs = positive(opts0.capMs, undefined, 'cap (optimizeCapSec x 1000)');
  const opts = { ...opts0, effort: positive(opts0.effort, 1, 'effort (optimizeEffort)'), capMs, deadline: capMs ? Date.now() + capMs : 0 };
  const runs = Math.max(1, Math.round(positive(opts0.runs, RUNS, 'runs (optimizeRuns)')));
  const threads = threadsFor(runs, opts.workers);
  const ev = makeEval(events, D, nLoc, opts);
  const base = ev(Int32Array.from(opts.initial)), baseViolations = ev.violations;
  return Promise.all(Array.from({ length: threads }, (_, t) => new Promise((res, rej) => {
    const mine = []; for (let r = t; r < runs; r += threads) mine.push(r);
    const wk = new Worker(__filename, { workerData: { events, D: D.buffer.slice(0), nLoc, opts, runs: mine } });
    wk.on('message', res); wk.on('error', rej);
  }))).then((parts) => {
    // ties go to the lower run, so the winner never depends on which thread finished first
    const rs = parts.flat().sort((a, b) => a.cost - b.cost || a.run - b.run);
    return { ...rs[0], base, baseViolations, runs, threads, rounds: Math.ceil(runs / threads), capped: rs.filter((r) => r.capped).length,
      all: rs.slice().sort((a, b) => a.run - b.run).map((r) => Math.round(r.cost)) };
  });
}
module.exports = { optimize, makeEval, killXp, anneal, workFor, RUNS, roundsFor, positive };
