// A release's notes: its section of CHANGELOG.md, for the GitHub release and the CurseForge file.
// usage: node tools/release-notes.js v1.2.1                          -> the notes (markdown)
//        node tools/release-notes.js v1.2.1 --curseforge 1234,5678   -> CurseForge upload metadata (JSON)
// Exits 1 when CHANGELOG.md has no section for the version, so a release can't go out without notes.
const fs = require('fs');
const path = require('path');
const [tag, flag, gameVersions] = process.argv.slice(2);
if (!tag) { console.error('usage: node tools/release-notes.js vX.Y.Z [--curseforge <game version ids>]'); process.exit(2); }
const v = tag.replace(/^v/, '');
const md = fs.readFileSync(path.join(__dirname, '..', 'CHANGELOG.md'), 'utf8');
const sec = md.split(/^## /m).find((p) => p.split(/[\s]/)[0] === v);
if (!sec) { console.error(`CHANGELOG.md has no section for ${v}`); process.exit(1); }
// "### Addon" in the changelog reads as "## Addon" on its own page
const notes = sec.slice(sec.indexOf('\n') + 1).trim().replace(/^### /gm, '## ') + '\n';
if (flag === '--curseforge') {
  process.stdout.write(JSON.stringify({ changelog: notes, changelogType: 'markdown', displayName: 'Forever Route ' + tag,
    gameVersions: String(gameVersions || '').split(',').filter(Boolean).map(Number), releaseType: 'release' }));
} else process.stdout.write(notes);
