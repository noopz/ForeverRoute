// Where WoW Forever is installed: its _forever_ folder (Interface/, WTF/). Keep this repo OUTSIDE the game folder: the
// launcher checks every file in there and marks the game unplayable when it can't clear git's read-only flags.
// Looked up in order: the FR_GAME env var, game-dir.txt in the repo root (one line, not committed), the folder above
// the repo (the old layout, repo inside _forever_).
// usage from a shell: node tools/game-dir.js        -> the _forever_ folder
//                     node tools/game-dir.js wow    -> the WoW folder above it (wow-ui-sim's WOW_INSTALL_PATH)
const fs = require('fs'), path = require('path');
const ROOT = path.resolve(__dirname, '..');
function gameDir() {
  if (process.env.FR_GAME) return path.resolve(process.env.FR_GAME);
  try { const t = fs.readFileSync(path.join(ROOT, 'game-dir.txt'), 'utf8').trim(); if (t) return path.resolve(t); } catch (e) {}
  return path.resolve(fs.realpathSync(ROOT), '..');
}
const GAME = gameDir();
const WOW = path.dirname(GAME);
const addonDir = (name = 'ForeverRoute') => path.join(GAME, 'Interface', 'AddOns', name);
module.exports = { GAME, WOW, addonDir };
if (require.main === module) console.log(process.argv[2] === 'wow' ? WOW : GAME);
