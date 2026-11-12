// The in-game "what's new" (UI/News.lua) from CHANGELOG.md: the last few versions' lines, as addon/ForeverRoute/News.lua.
// Run by tools/install.sh and tools/package.sh, so the game and the changelog never disagree.
// usage: node tools/gen-news.js [CHANGELOG.md] [out News.lua] [versions=4]
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..');
const [src = path.join(ROOT, 'CHANGELOG.md'), out = path.join(ROOT, 'addon', 'ForeverRoute', 'News.lua'), n = '4'] = process.argv.slice(2);
const md = fs.readFileSync(src, 'utf8');
const versions = [];
for (const part of md.split(/^## /m).slice(1)) {
  const head = part.split(/\r?\n/)[0];
  const m = /^(\d+\.\d+\.\d+)\s*-?\s*(\S*)/.exec(head);
  if (!m) continue;
  // "- item" lines; markdown `code` and **bold** kept as plain text
  const items = part.split(/\r?\n/).slice(1).filter((l) => /^\s*-\s+/.test(l)).map((l) => l.replace(/^\s*-\s+/, '').replace(/[`*]/g, '').trim());
  versions.push({ version: m[1], date: m[2] || '', items });
  if (versions.length >= +n) break;
}
const L = (s) => JSON.stringify(s);
const lines = ['-- Generated from CHANGELOG.md by tools/gen-news.js. Edit CHANGELOG.md, not this file.', 'local _, ns = ...', 'ns.NEWS = {'];
for (const v of versions) lines.push(`  { version = ${L(v.version)}, date = ${L(v.date)}, items = { ${v.items.map(L).join(', ')} } },`);
lines.push('}', '');
fs.writeFileSync(out, lines.join('\n'));
console.log(`news: ${versions.map((v) => v.version).join(', ')} -> ${path.relative(ROOT, out)}`);
