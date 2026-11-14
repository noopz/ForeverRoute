// Runs paths.js and stops it once it has written its plan: the planner can stay alive after "wrote" (a worker thread),
// and a caller that waits for it to exit waits forever - tree-assemble.js hung on the dwarf hunter for an hour in two
// tree builds. Like tools/starter.js and the companion, this gives it 15 s after "wrote", then ends it.
// usage: node tools/run-planner.js <log file> <paths.js args...>   exit 0 once it wrote, else the planner's exit code
const fs = require('fs'), path = require('path');
const { spawn, execFileSync } = require('child_process');
const [logFile, ...args] = process.argv.slice(2);
if (!logFile || !args.length) { console.log('usage: node tools/run-planner.js <log file> <paths.js args...>'); process.exit(2); }
const out = fs.createWriteStream(logFile);
const p = spawn(process.execPath, ['--max-old-space-size=8000', path.join(__dirname, 'paths.js'), ...args], { cwd: path.join(__dirname, '..'), stdio: ['ignore', 'pipe', 'inherit'] });
let wrote = false, tail = '';
p.stdout.on('data', (d) => {
  out.write(d);
  tail = (tail + d).slice(-4000);
  if (!wrote && /wrote \d+ paths/.test(tail)) {
    wrote = true;
    setTimeout(() => {
      out.write('\n(planner finished but did not exit: stopped by run-planner.js)\n');
      try { if (process.platform === 'win32') execFileSync('taskkill', ['/T', '/F', '/PID', String(p.pid)], { stdio: 'ignore' }); else p.kill('SIGKILL'); } catch (e) {}
    }, 15000).unref();
  }
});
p.on('close', (code) => out.end(() => process.exit(wrote ? 0 : code ?? 1)));
