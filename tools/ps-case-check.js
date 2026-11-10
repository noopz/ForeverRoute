// PowerShell variable names are case-insensitive: $f overwrote $F (the fonts), $p the point list $P, $k the palette $K.
// This flags any variable written in two casings in a script (and its dot-sourced kit), so it's caught before a render
// comes out blank. usage: node tools/ps-case-check.js <script.ps1> [...]   (exit 1 on a clash)
const fs = require('fs');
const path = require('path');
let bad = 0;
for (const f of process.argv.slice(2)) {
  const files = [f];
  const src = fs.readFileSync(f, 'utf8');
  for (const m of src.matchAll(/\. \(Join-Path \$PSScriptRoot '([^']+)'\)/g)) files.push(path.join(path.dirname(f), m[1]));
  const seen = new Map();
  for (const file of files) {
    if (!fs.existsSync(file)) continue;
    for (const m of fs.readFileSync(file, 'utf8').matchAll(/\$(?:script:)?([A-Za-z_][A-Za-z0-9_]*)/g)) {
      const k = m[1].toLowerCase();
      if (!seen.has(k)) seen.set(k, new Set());
      seen.get(k).add(m[1]);
    }
  }
  const clash = [...seen.values()].filter((s) => s.size > 1).map((s) => [...s].map((v) => '$' + v).join(' / '));
  console.log(path.basename(f) + ': ' + (clash.length ? 'CLASH ' + clash.join(', ') : 'ok'));
  if (clash.length) bad++;
}
process.exitCode = bad ? 1 : 0;
