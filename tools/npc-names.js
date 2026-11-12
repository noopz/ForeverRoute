// Checks the names of the NPCs our plans use against Wowhead's WoW Forever data (the tooltip API, dataEnv=16) and lists
// the ones Forever renamed. QuestieDB names NPCs from older game data: it has "Comar Villard" where Forever has Corma
// Villard, and the addon finds NPCs by name (the Target key's /target, the "giver doesn't offer it" check) - a stale
// name quietly breaks both. Answers are cached (qdb/wowhead-npc-names.json), so a rerun only asks about new NPCs.
// usage: node tools/npc-names.js [--all] [--write]
//   --all    every NPC a quest of our faction-free data names (default: the quests in the built-in plans)
//   --write  record the renames in tools/forever-overrides.json (npcNames), which apply-overrides.js applies
const fs = require('fs');
const path = require('path');
const https = require('https');
const ROOT = path.join(__dirname, '..');
const db = JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'db.json'), 'utf8'));
const CACHE = path.join(ROOT, 'qdb', 'wowhead-npc-names.json');
const OVR = path.join(__dirname, 'forever-overrides.json');
const all = process.argv.includes('--all'), write = process.argv.includes('--write');

// the quests in the built-in plans, and every NPC they name: givers, enders, kill targets, droppers
const quests = new Set();
if (all) for (const id of Object.keys(db.quests)) quests.add(+id);
else for (const d of fs.readdirSync(path.join(ROOT, 'addon'))) {
  if (!d.startsWith('ForeverRoute_Starter_')) continue;
  const s = fs.readFileSync(path.join(ROOT, 'addon', d, 'Plan.lua'), 'utf8');
  for (const m of s.matchAll(/\bq = (\d+)/g)) quests.add(+m[1]);
}
const npcs = new Set();
for (const id of quests) {
  const q = db.quests[id]; if (!q) continue;
  for (const s of [...q.starters, ...q.finishers]) if (s.type === 'npc') npcs.add(s.id);
  for (const o of q.objectives) for (const n of [o.npc, ...(o.npcs || []), ...(o.npcDrops || [])]) if (n) npcs.add(n);
}
const cache = fs.existsSync(CACHE) ? JSON.parse(fs.readFileSync(CACHE, 'utf8')) : {};
const todo = [...npcs].filter((id) => db.npcs[id] && !(id in cache));
console.log(`${npcs.size} NPCs in ${quests.size} quests; ${todo.length} to ask Wowhead about`);

function get(id) {
  return new Promise((res) => {
    const req = https.get(`https://nether.wowhead.com/tooltip/npc/${id}?dataEnv=16`, { headers: { 'User-Agent': 'route-tools/1.0' }, timeout: 15000 }, (r) => {
      let b = ''; r.on('data', (c) => (b += c)); r.on('end', () => {
        if (r.statusCode === 404) return res({ none: true });
        if (r.statusCode !== 200) return res(null);
        try { const j = JSON.parse(b); res(j && j.name ? { name: j.name } : { none: true }); } catch (e) { res(null); }
      });
    });
    req.on('error', () => res(null)); req.on('timeout', () => { req.destroy(); res(null); });
  });
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  let n = 0, failed = 0;
  for (let i = 0; i < todo.length; i += 3) {
    const batch = todo.slice(i, i + 3);
    const got = await Promise.all(batch.map(get));
    batch.forEach((id, k) => { if (got[k]) cache[id] = got[k].name || null; else failed++; });
    n += batch.length;
    if (n % 300 < 3) { fs.writeFileSync(CACHE, JSON.stringify(cache)); console.log(`  ${n}/${todo.length}`); }
    await sleep(400); // a few requests a second: polite
  }
  fs.writeFileSync(CACHE, JSON.stringify(cache));
  const renames = {};
  for (const id of npcs) {
    const n0 = db.npcs[id] && db.npcs[id].name, n1 = cache[id];
    if (n0 && n1 && n0 !== n1) renames[id] = { from: n0, to: n1 };
  }
  const list = Object.entries(renames);
  console.log(`${list.length} renamed in Forever${failed ? ` (${failed} lookups failed: run again)` : ''}`);
  for (const [id, r] of list) console.log(`  ${id}: ${r.from} -> ${r.to}`);
  if (write) {
    const o = JSON.parse(fs.readFileSync(OVR, 'utf8'));
    o.npcNames = o.npcNames || {};
    for (const [id, r] of list) o.npcNames[id] = r.to;
    fs.writeFileSync(OVR, JSON.stringify(o, null, 2) + '\n');
    console.log('written to tools/forever-overrides.json (npcNames)');
  }
})();
