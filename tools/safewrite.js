// Replace a shared cache file that other planners may be reading or writing at the same time (three batches side by
// side, the companion's replans). On Windows a rename onto a file someone has open fails: retry briefly, then give up
// quietly - a cache is only a speed-up, and a failed write once failed a whole leg and ended a plan at level 28.
// replaceCache(file, text) -> true if written
const fs = require('fs');
function replaceCache(file, text) {
  const tmp = file + '.' + process.pid + '.' + Math.random().toString(36).slice(2, 8) + '.tmp';
  try { fs.writeFileSync(tmp, text); } catch (e) { return false; }
  for (let k = 0; k < 7; k++) {
    try { fs.renameSync(tmp, file); return true; } catch (e) {
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 40 * (k + 1)); // a short pause, then again
    }
  }
  try { fs.unlinkSync(tmp); } catch (e) {}
  return false;
}
module.exports = { replaceCache };
