// Keep the quest data current: the latest QuestieDB release from GitHub (Questie/QuestieDB, the Forever zip) becomes
// qdb/db.json, with our own fixes (tools/forever-overrides.json) on top, and everything made from it is regenerated.
//   1. GitHub's latest release; nothing to do when it's the version qdb/ was built from (unless --force)
//   2. download the Forever zip into its own new folder, qdb/questiedb/<version>/, and unpack it there - its files are
//      only read as data (nothing in it is run)
//   3. decode the baked data (extract-qdb.js) and build db.json (build-db.js: Classic XP + Forever's measured XP, drop
//      tables, our overrides) into temporary files; refused if it lost more than 5% of the quests, else swapped in
//      (the old one kept as qdb/db.old.json)
//   4. regenerate what's made from it: flight masters, vendors, dungeon quests, breadcrumbs, the other faction's towns, travel data
//   5. the planner's tests; then --install runs tools/install.sh (the addon's tests + live check) and --plans rebuilds
//      the built-in plans (tools/starters-all.sh, hours)
// Your installed QuestieDB addon in the game is never touched. usage: node tools/update-questiedb.js [--force] [--install] [--plans]
const fs = require('fs');
const path = require('path');
const https = require('https');
const { execFileSync } = require('child_process');
const ROOT = path.join(__dirname, '..');
const QDB = path.join(ROOT, 'qdb');
const STAMP = path.join(QDB, 'questiedb-version.json');
const args = new Set(process.argv.slice(2));
const log = (s) => console.log(s);
const node = (script, ...a) => execFileSync(process.execPath, ['--max-old-space-size=8000', path.join(__dirname, script), ...a], { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] });

function get(url, binary) {
  return new Promise((res, rej) => {
    https.get(url, { headers: { 'User-Agent': 'ForeverRoute-updater', Accept: binary ? 'application/octet-stream' : 'application/vnd.github+json' } }, (r) => {
      if (r.statusCode >= 300 && r.statusCode < 400 && r.headers.location) return res(get(r.headers.location, binary));
      if (r.statusCode !== 200) return rej(new Error(url + ': HTTP ' + r.statusCode));
      const chunks = []; r.on('data', (d) => chunks.push(d)); r.on('end', () => res(Buffer.concat(chunks)));
    }).on('error', rej);
  });
}

(async () => {
  // 1. the latest release
  const rel = JSON.parse((await get('https://api.github.com/repos/Questie/QuestieDB/releases/latest')).toString('utf8'));
  const version = String(rel.tag_name || '').replace(/^v/, '');
  const asset = (rel.assets || []).find((a) => /-Forever\.zip$/i.test(a.name));
  if (!version || !asset) throw new Error('no Forever zip in the latest QuestieDB release (' + rel.tag_name + ')');
  const had = fs.existsSync(STAMP) ? JSON.parse(fs.readFileSync(STAMP, 'utf8')).version : null;
  log(`QuestieDB: latest ${version} (${rel.published_at}), ours ${had || 'unknown'}`);
  if (had === version && !args.has('--force')) { log('up to date'); return; }

  // 2. download and unpack, in a folder of its own
  const dir = path.join(QDB, 'questiedb', version);
  fs.rmSync(dir, { recursive: true, force: true }); fs.mkdirSync(dir, { recursive: true });
  const zip = path.join(dir, asset.name);
  fs.writeFileSync(zip, await get(asset.browser_download_url, true));
  log(`downloaded ${asset.name} (${Math.round(fs.statSync(zip).size / 1024)} KB)`);
  const out = path.join(dir, 'files');
  if (process.platform === 'win32') execFileSync('powershell', ['-NoProfile', '-Command', `Expand-Archive -LiteralPath '${zip}' -DestinationPath '${out}' -Force`], { stdio: 'inherit' });
  else execFileSync('unzip', ['-q', zip, '-d', out], { stdio: 'inherit' });
  const find = (rel2) => { for (const base of [path.join(out, 'QuestieDB'), out]) { const p = path.join(base, rel2); if (fs.existsSync(p)) return p; } return null; };
  const toc = find('QuestieDB_Forever.toc');
  if (!toc) throw new Error('no QuestieDB_Forever.toc in ' + asset.name);
  const sup = path.join(path.dirname(toc), 'support', 'Forever');

  // 3. decode and build, into temporary files first
  const jsonTmp = path.join(QDB, 'json.new'); fs.rmSync(jsonTmp, { recursive: true, force: true });
  log(node('extract-qdb.js', toc, jsonTmp).trim().split('\n').slice(-2).join('\n'));
  const xp = ['xpDB-classic.lua', 'xpDB-traces.lua'].map((f) => path.join(sup, 'QuestXP', f)).filter((f) => fs.existsSync(f));
  const drops = ['classicItemDrops.lua', 'itemDropCorrections.lua'].map((f) => path.join(sup, 'DropTables', f)).filter((f) => fs.existsSync(f));
  const dbTmp = path.join(QDB, 'db.new.json');
  log(node('build-db.js', jsonTmp, xp.join(','), dbTmp, drops.join(',')).trim().split('\n').filter((l) => !/^forever override/.test(l)).slice(-3).join('\n'));
  const count = (f) => Object.keys(JSON.parse(fs.readFileSync(f, 'utf8')).quests).length;
  const before = fs.existsSync(path.join(QDB, 'db.json')) ? count(path.join(QDB, 'db.json')) : 0, after = count(dbTmp);
  if (before && after < before * 0.95) throw new Error(`the new data has ${after} quests, the old ${before}: not swapped in (look at ${dbTmp})`);
  // our fixes against QuestieDB as it is now (reports/overrides-check.md): the ones upstream has caught up with, and the
  // ones where upstream changed the same quest differently
  const rawTmp = path.join(QDB, 'db.raw.json');
  execFileSync(process.execPath, ['--max-old-space-size=8000', path.join(__dirname, 'build-db.js'), jsonTmp, xp.join(','), rawTmp, drops.join(',')], { cwd: ROOT, env: { ...process.env, FR_NO_OVERRIDES: '1' }, stdio: 'ignore' });
  log(node('overrides-check.js', rawTmp, path.join(ROOT, 'reports', 'overrides-check.md')).trim());
  fs.rmSync(rawTmp, { force: true });
  // what changed (reports/questiedb-delta.md): the zones touched are the legs that get re-planned
  if (fs.existsSync(path.join(QDB, 'db.json'))) log(node('qdb-delta.js', path.join(QDB, 'db.json'), dbTmp, path.join(ROOT, 'reports', 'questiedb-delta.md')).trim());
  if (fs.existsSync(path.join(QDB, 'db.json'))) fs.copyFileSync(path.join(QDB, 'db.json'), path.join(QDB, 'db.old.json'));
  fs.renameSync(dbTmp, path.join(QDB, 'db.json'));
  fs.rmSync(path.join(QDB, 'json'), { recursive: true, force: true }); fs.renameSync(jsonTmp, path.join(QDB, 'json'));
  // the support files the planner reads (dungeons), from this release
  for (const f of ['Zones/dungeons.lua']) { const s = path.join(sup, f), d = path.join(QDB, 'support', 'Forever', f); if (fs.existsSync(s)) { fs.mkdirSync(path.dirname(d), { recursive: true }); fs.copyFileSync(s, d); } }
  log(`db.json: ${before} -> ${after} quests`);

  // 4. what's made from it
  const conv = path.join(QDB, 'conversion.json'), db = path.join(QDB, 'db.json'), addon = path.join(ROOT, 'addon', 'ForeverRoute');
  node('map-extras.js');
  node('flightmasters.js', db, conv, path.join(addon, 'FlightMasters.lua'));
  node('vendors.js', db, conv, path.join(addon, 'Vendors.lua'));
  node('dungeon-quests.js', db, path.join(QDB, 'support', 'Forever', 'Zones', 'dungeons.lua'), path.join(QDB, 'client'), path.join(addon, 'DungeonQuests.lua'), conv); // (qdb/client: Map.csv + AreaTable.csv - node tools/dungeon-quests.js --fetch)
  node('gen-breadcrumbs.js');
  node('hostile-towns.js');
  node('gen-travel-data.js');
  log('regenerated: flight masters, vendors, dungeon quests, breadcrumbs, hostile towns, travel data');

  // 5. checks
  for (const t of ['test-route2-tasks.js', 'test-route2-sim.js', 'test-lint.js', 'test-travel.js', 'test-quality.js']) {
    const r = node(t).trim().split('\n').pop(); log(`${t}: ${r}`);
    if (!/all passed|skipped/.test(r)) throw new Error(t + ' failed: the data is in place, the version is not recorded');
  }
  fs.writeFileSync(STAMP, JSON.stringify({ version, published: rel.published_at, asset: asset.name, built: new Date().toISOString() }, null, 2) + '\n');
  log(`qdb/ is QuestieDB ${version} now`);
  if (args.has('--install')) execFileSync('bash', [path.join(__dirname, 'install.sh')], { cwd: ROOT, stdio: 'inherit' });
  if (args.has('--plans')) execFileSync('bash', [path.join(__dirname, 'starters-all.sh')], { cwd: ROOT, stdio: 'inherit', env: { ...process.env, FR_PERSONAS: process.env.FR_PERSONAS || 'clean,skip,fast,slow,die,reload,secret,nodungeon,halfdungeon,rerun' } });
  else log('next: tools/starters-all.sh rebuilds the built-in plans on it; the companion replans yours on your next /reload');
})().catch((e) => { console.error('update failed: ' + e.message); process.exit(1); });
