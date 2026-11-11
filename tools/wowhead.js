// Wowhead for the new quests you meet (quest ids 10000+: added after the original game; their quest data is younger
// and can miss what unlocks them - A Friend of the Family needs the statuette chain first and the data didn't say).
//   queue  <character SavedVariables dir>   the new quests you've met (on your path, in your log, offered or not
//          offered by a giver) -> Wowhead's tooltip service says whether Forever's data has each (dataEnv 16, the
//          only one that knows Forever's own quests); the ones still without a page read go to reports/wowhead-queue.md.
//          Run by learn.js after every save. Wowhead's quest pages need a real browser (they challenge scripts, and we
//          don't get around that): the queue is for a browser session (Playwright on the Mac) to read.
//   import <results.json>   what the browser read: [{ id, url, series: [ids in order], requires: [ids], notes: [..] }]
//          -> qdb/wowhead/<id>.json, and the series order becomes prerequisites in tools/forever-overrides.json
//          (each quest needs the one before it), applied to qdb/db.json
// usage: node tools/wowhead.js queue <charDir> | node tools/wowhead.js import <results.json>
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..');
const DIR = path.join(ROOT, 'qdb', 'wowhead');
const INDEX = path.join(DIR, 'index.json');
const NEW_QUEST_MIN = 10000; // the same line as the card's (UI/Card.lua): all original quests are below it
const DATA_ENV = 16;
const MAX_CHECKS = 25, PAUSE_MS = 700;
const [cmd, arg] = process.argv.slice(2);
fs.mkdirSync(DIR, { recursive: true });
const readJson = (f, d) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch (e) { return d; } };
const index = readJson(INDEX, {});
const db = readJson(path.join(ROOT, 'qdb', 'db.json'), { quests: {} });

async function queue(charDir) {
  const met = new Map(); // id -> how you met it
  const add = (id, how) => { id = Number(id); if (id >= NEW_QUEST_MIN && !met.has(id)) met.set(id, how); };
  // your plan: the pick-ups on the main paths
  try {
    const RF = require('./routefile');
    const folder = path.basename(path.dirname(path.resolve(charDir))).replace(/\s/g, '');
    const text = RF.own(fs.readFileSync(path.join(require('./game-dir').addonDir(), 'Route.lua'), 'utf8'), folder);
    for (const m of text.matchAll(/k = "accept"[^}]*?q = (\d+)/g)) add(m[1], 'on your plan');
  } catch (e) {}
  // your save: quest log, and what givers offered or didn't
  try {
    const { parseSavedVariables } = require('./luatable');
    const c = parseSavedVariables(fs.readFileSync(path.join(charDir, 'ForeverRoute.lua'), 'utf8')).ForeverRouteChar || {};
    for (const id of Object.keys((c.snapshot && c.snapshot.log) || {})) add(id, 'in your quest log');
    for (const id of Object.keys((c.avail && c.avail.no) || {})) add(id, 'its giver did not offer it');
    for (const id of Object.keys((c.avail && c.avail.seen) || {})) add(id, 'offered to you');
  } catch (e) {}
  // existence in Forever's Wowhead data: once per quest
  let checks = 0;
  for (const id of met.keys()) {
    if (index[id] && index[id].checked) continue;
    if (checks++ >= MAX_CHECKS) break;
    try {
      const r = await fetch(`https://nether.wowhead.com/tooltip/quest/${id}?dataEnv=${DATA_ENV}`);
      const j = r.status === 200 ? await r.json() : null;
      index[id] = { ...(index[id] || {}), checked: new Date().toISOString(), inForever: r.status === 200 ? true : r.status === 404 ? false : undefined, name: (j && j.name) || (db.quests[id] && db.quests[id].name) };
    } catch (e) { /* offline: next time */ }
    await new Promise((s) => setTimeout(s, PAUSE_MS));
  }
  for (const [id, how] of met) index[id] = { ...(index[id] || {}), met: index[id] && index[id].met || how, name: (index[id] && index[id].name) || (db.quests[id] && db.quests[id].name) };
  fs.writeFileSync(INDEX, JSON.stringify(index, null, 1));
  const todo = [...met.keys()].filter((id) => !index[id].read).sort((a, b) => a - b);
  const notIn = [...met.keys()].filter((id) => index[id].inForever === false);
  const L = ['# New quests to read on Wowhead', '',
    `Quests added after the original game that you've met, with no Wowhead page read yet (${todo.length}). A browser session reads`,
    'each page (Playwright; Wowhead challenges scripts and we do not get around that) and saves what it found as JSON:',
    '`[{ "id": 98191, "url": "...", "series": [98189, 98191], "requires": [98189], "notes": ["short summaries of useful comments"] }]`',
    'then: `node tools/wowhead.js import <that file>`. The page is the Forever (or Classic) one that shows the quest.', ''];
  for (const id of todo) L.push(`- ${id} ${index[id].name || '?'} (${index[id].met}${index[id].inForever === false ? ', NOT in Forever\'s Wowhead data' : ''}) - https://www.wowhead.com/forever/quest=${id}`);
  if (notIn.length) L.push('', `Not in Forever's Wowhead data at all (likely not in the game): ${notIn.join(', ')}`);
  fs.mkdirSync(path.join(ROOT, 'reports'), { recursive: true });
  fs.writeFileSync(path.join(ROOT, 'reports', 'wowhead-queue.md'), L.join('\n') + '\n');
  console.log(`wowhead: ${met.size} new quests met, ${todo.length} to read, ${notIn.length} not in Forever's data`);
}

function importResults(file) {
  const res = readJson(file, null);
  if (!Array.isArray(res)) { console.log('expected a JSON list of { id, series, requires, notes }'); process.exit(2); }
  const OV = path.join(__dirname, 'forever-overrides.json');
  const ov = readJson(OV, { quests: {} });
  ov.quests = ov.quests || {};
  const changes = [];
  for (const r of res) {
    const id = Number(r.id); if (!id) continue;
    fs.writeFileSync(path.join(DIR, id + '.json'), JSON.stringify(r, null, 1));
    index[id] = { ...(index[id] || {}), read: new Date().toISOString() };
    // what unlocks it: the quest before it in its series, and any it says it requires
    // an item to bring that isn't one of its objectives: the plan can't get it (route2 leaves such quests out)
    const items = (r.needsItems || []).map(Number).filter(Boolean);
    if (items.length && db.quests[id] && JSON.stringify(db.quests[id].needsItems || []) !== JSON.stringify(items)) {
      ov.quests[id] = { ...(ov.quests[id] || {}), needsItems: items, _whyItems: `Wowhead (${r.url || 'quest page'}): needs item ${items.join(', ')} brought in` };
      changes.push(`${id} ${db.quests[id].name}: needs item ${items.join(', ')}`);
    }
    // a series is a fact about every quest in it: each one needs the one before it (not only the page's own quest)
    const series = (r.series || []).map(Number).filter(Boolean);
    const needs = new Map(); // quest -> what it needs
    // ...unless the order can't be right: a quest doesn't need one several levels above it (a series read backwards
    // once made Young Crocolisk Skins [22] need Highland Hides [28] - the wiki has it the other way round)
    const lvl = (x) => (db.quests[x] && db.quests[x].level) || 0;
    for (let k = 1; k < series.length; k++) {
      if (lvl(series[k - 1]) > lvl(series[k]) + 2) { changes.push(`skipped: ${series[k]} needing ${series[k - 1]} (level ${lvl(series[k - 1])} before ${lvl(series[k])}: the series order looks wrong, check the page)`); continue; }
      needs.set(series[k], [series[k - 1]]);
    }
    needs.set(id, [...new Set([...(needs.get(id) || []), ...(r.requires || []).map(Number)])]);
    for (const [qid, need0] of needs) {
      const q = db.quests[qid];
      if (!q) continue;
      const cur = (ov.quests[qid] && ov.quests[qid].preSingle) || q.preSingle || [];
      const have = new Set([...cur, ...(q.preGroup || [])]);
      const missing = need0.filter((x) => x && x !== qid && !have.has(x));
      if (!missing.length) continue;
      ov.quests[qid] = { ...(ov.quests[qid] || {}), preSingle: [...new Set([...cur, ...missing])], _why: `Wowhead (${r.url || 'quest page'}): needs ${missing.join(', ')} first - the quest data did not say` };
      changes.push(`${qid} ${q.name || ''}: needs ${missing.join(', ')} first`);
    }
  }
  fs.writeFileSync(OV, JSON.stringify(ov, null, 2) + '\n');
  fs.writeFileSync(INDEX, JSON.stringify(index, null, 1));
  const applied = require('./apply-overrides');
  const dbFile = path.join(ROOT, 'qdb', 'db.json');
  const full = JSON.parse(fs.readFileSync(dbFile, 'utf8'));
  const done = applied.apply(full);
  if (done.length) { fs.writeFileSync(dbFile + '.tmp', JSON.stringify(full)); fs.renameSync(dbFile + '.tmp', dbFile); }
  console.log(`imported ${res.length} page(s); ${changes.length} new prerequisite(s):\n` + changes.join('\n'));
}

if (cmd === 'queue' && arg) queue(arg);
else if (cmd === 'import' && arg) importResults(arg);
else { console.log('usage: node tools/wowhead.js queue <charDir> | node tools/wowhead.js import <results.json>'); process.exit(2); }
