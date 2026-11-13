// Where the simulator (wow-ui-sim) is and how to start it, on this machine. tools/sim-version.txt names the build in use
// (wow-ui-sim-vX-forever-windows-x86_64); the same release has a Forever build for Apple Silicon Macs
// (...-forever-macos-aarch64) and Linux (...-forever-linux-x86_64), so the simulated player and the live checks run on
// a Mac too: the package for this platform is sim/pkg/<name with this platform's suffix>, the binary wow-sim(.exe).
// Without a WoW install (the game's folder: tools/game-dir.js) the simulator runs without game assets
// (WOW_SIM_CASC=0, its own switch for that): the addon's logic doesn't need them, only screenshots do.
//   SIM       the package folder         BIN   the simulator binary
//   simEnv()  the environment to start it with
const fs = require('fs'), path = require('path'), os = require('os');
const ROOT = path.join(__dirname, '..');
const PLATFORM = process.platform === 'win32' ? 'windows-x86_64' : process.platform === 'darwin' ? 'macos-aarch64' : 'linux-x86_64';
const named = fs.readFileSync(path.join(__dirname, 'sim-version.txt'), 'utf8').trim();
const name = named.replace(/(windows-x86_64|macos-aarch64|linux-x86_64)$/, PLATFORM);
const PKG = path.join(ROOT, 'sim', 'pkg', name);
// the Mac build is an app bundle ("WoW Sim Forever.app"): its binaries are in Contents/MacOS, and that is where it runs
// from (Interface/ is in Contents/Resources, which the bundle finds itself)
const APP = process.platform === 'darwin' && fs.existsSync(PKG) ? fs.readdirSync(PKG).find((f) => f.endsWith('.app')) : null;
const SIM = APP ? path.join(PKG, APP, 'Contents', 'MacOS') : PKG;
const BIN = path.join(SIM, process.platform === 'win32' ? 'wow-sim.exe' : 'wow-sim');
// a WoW install the simulator accepts: <root>/Data/data (its README)
function gameDir() { try { const g = require('./game-dir').WOW; return g && fs.existsSync(path.join(g, 'Data', 'data')) ? g : null; } catch (e) { return null; } }
function simEnv(extra) {
  const wow = gameDir();
  // Windows as always: the game-dir guess (the simulator finds the install itself when that is wrong). Elsewhere, with
  // no install: no game assets
  const where = wow || process.platform === 'win32' ? { WOW_INSTALL_PATH: wow || require('./game-dir').WOW } : { WOW_SIM_CASC: '0' };
  return { ...process.env, ...where, ...(extra || {}) };
}
module.exports = { SIM, BIN, PLATFORM, simEnv, gameDir };
if (require.main === module) console.log(JSON.stringify({ SIM, BIN, PLATFORM, exists: fs.existsSync(BIN), gameDir: gameDir(), cores: os.cpus().length }));
