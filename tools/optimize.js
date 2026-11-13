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
      const e = events[order[p]];
      const r = qIdx.get(e.q);
      // nothing before its level: quests too far above you, and kills against mobs well above you
      // (the further short of it, the worse, so a move that gets closer counts as progress)
      if (e.reqLevel > level) { bad++; pen += 1 + (e.reqLevel - level - xp / XP[level]); }
      // events that must come first (by index): a dungeon run after the pick-ups of the quests done in it, and those
      // quests' objectives in the dungeon after the run
      if (e.after) for (const a of e.after) if (posOf[a] > p) { bad++; pen++; }
      if (e.kind === 'accept') {
        for (const pq of e.pre) { const pr = qIdx.get(pq); if (pr && pr.turnin !== undefined && posOf[pr.turnin] > p) { bad++; pen++; } }
        // the log holds 40 on Forever, counting the quests you came in with
        if (++log > maxLog) { bad++; pen++; }
      } else {
        if (r.accept !== undefined && posOf[r.accept] > p) { bad++; pen++; }
        if (e.kind === 'turnin') { for (const o of r.objs) if (posOf[o] > p) { bad++; pen++; } log--; }
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
      if (e.kind === 'turnin') gain += questXp(e.xp, e.qLevel, level); // the shared rule (world.js)
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

function anneal(events, D, nLoc, opts, seed, budgetMs) {
  let s = seed >>> 0 || 1;
  const rnd = () => { s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0; return s / 4294967296; };
  const cost = makeEval(events, D, nLoc, opts);
  const n = events.length;
  let cur = Int32Array.from(opts.initial), cc = cost(cur);
  let best = cur.slice(), bc = cc;
  const t0 = Date.now();
  let T = opts.T0 || 120, it = 0;
  const tmp = new Int32Array(n);
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
  // stop once it has stopped getting better (no new best for stallMs, after a minimum amount of work scaled to the
  // problem size); the time budget stays as a cap
  // deterministic: the stop rule counts moves, not seconds, so the same plan comes out however busy the PC is
  // (same input + same seed = same route). The time budget is only a safety cap, well above normal.
  const minIt = Math.max(20000, 40 * n * n), stallIt = opts.stallIt ?? Math.max(60000, 20 * n * n), maxIt = opts.maxIt ?? Math.max(400000, 200 * n * n);
  let lastBest = Date.now(), lastBestIt = 0;
  while (it < maxIt && !(it >= minIt && it - lastBestIt > stallIt) && Date.now() - t0 < budgetMs * 4) {
    for (let inner = 0; inner < 2000; inner++, it++) {
      tmp.set(cur);
      const mv = rnd();
      if (repairP > 0 && mv < repairP) { // ALNS destroy + repair: lift a whole quest out, put each piece back where it costs least
        repair(tmp);
      } else if (mv < 0.45) { // relocate a block of 1-6 events
        const len = 1 + Math.floor(rnd() * Math.min(6, n - 1)), i = Math.floor(rnd() * (n - len + 1));
        const block = Array.from(tmp.subarray(i, i + len));
        const rest = [...tmp.subarray(0, i), ...tmp.subarray(i + len)];
        const j = Math.floor(rnd() * (rest.length + 1));
        rest.splice(j, 0, ...block); tmp.set(rest);
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
      if (nc < cc || (isFinite(nc) && rnd() < Math.exp((cc - nc) / T))) { cur.set(tmp); cc = nc; if (cc < bc) { bc = cc; best = cur.slice(); lastBest = Date.now(); lastBestIt = it; } }
    }
    T = Math.max(0.5, T * 0.97);
  }
  cost(best);
  return { order: Array.from(best), cost: bc, iterations: it, violations: cost.violations };
}

if (!isMainThread) {
  const { events, D, nLoc, opts, seed, budgetMs } = workerData;
  require('./world').setLearned(opts.learned); // kill XP as your kills really gave it (tools/learn.js)
  parentPort.postMessage(anneal(events, new Float32Array(D), nLoc, opts, seed, budgetMs));
  return;
}

function optimize(events, D, nLoc, opts) {
  const workers = opts.workers || Math.max(1, os.cpus().length - 1);
  const ev = makeEval(events, D, nLoc, opts);
  const base = ev(Int32Array.from(opts.initial)), baseViolations = ev.violations;
  return Promise.all(Array.from({ length: workers }, (_, w) => new Promise((res, rej) => {
    const wk = new Worker(__filename, { workerData: { events, D: D.buffer.slice(0), nLoc, opts, seed: 0x9e3779b9 * (w + 1), budgetMs: opts.budgetMs || 10000 } });
    wk.on('message', res); wk.on('error', rej);
  }))).then((rs) => { rs.sort((a, b) => a.cost - b.cost); return { ...rs[0], base, baseViolations, all: rs.map((r) => Math.round(r.cost)) }; });
}
module.exports = { optimize, makeEval, killXp };
