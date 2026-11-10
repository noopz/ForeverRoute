// A long-lived route2: campaign.js hands it one leg or zone evaluation after another (process.send), instead of
// starting a node process per run. Starting node and parsing the 11 MB quest database was ~150 ms of a ~250 ms
// zone evaluation, and a 1-60 plan runs over a thousand of them. The files route2 reads with readJsonCached
// (db.json, items.json) stay parsed here between runs, keyed by path and modification time, so an edited file is
// read again. route2 must not change what it reads from them (checked end to end: a plan made with hosts is the
// same as one made with a process per run).
// Protocol: { id, db, cfg, out } in -> { id, code, out, err } back (code 0 ok; stdout and stderr text as captured).
const path = require('path');
const util = require('util');
const R2 = path.join(__dirname, 'route2.js');
global.__FR_JSON = global.__FR_JSON || {};
// the planner that started us is gone: nothing left to do
process.on('disconnect', () => process.exit(0));
let busy = false;
process.on('message', async (job) => {
  if (busy) { process.send({ id: job.id, code: 1, out: '', err: 'host busy' }); return; }
  busy = true;
  const out = [], err = [];
  const saved = { log: console.log, error: console.error, warn: console.warn, info: console.info };
  console.log = console.info = (...a) => { out.push(util.format(...a)); };
  console.error = console.warn = (...a) => { err.push(util.format(...a)); };
  let code = 0;
  try {
    process.argv = [process.argv[0], R2, job.db, job.cfg, job.out];
    delete require.cache[R2];
    const m = require(R2);
    if (m && m.done) await m.done;
  } catch (e) {
    code = 1; err.push(String((e && e.stack) || e));
  }
  Object.assign(console, saved);
  busy = false;
  process.send({ id: job.id, code, out: out.join('\n') + (out.length ? '\n' : ''), err: err.join('\n') });
});
process.send({ ready: true });
