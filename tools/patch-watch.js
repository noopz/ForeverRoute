// What changed on WoW Forever since the last check, and what of it could touch our plans. Reads (and remembers what it
// has seen in reports/patch-watch-state.json):
//   1. Blizzard's blue posts in the Forever forums (hotfix threads, announcements): the blue tracker, full post text
//   2. the Forever development notes thread: posts that are new or were edited
//   3. Wowhead's Forever spellbook changes, per class: spells whose status (new / removed / updated) or level changed
//      (a "removed" there is not proof - Defensive Stance was listed removed and is in the game, buffed: check the
//      spell's tooltip, https://nether.wowhead.com/tooltip/spell/<id>?dataEnv=16, before acting on it)
//   4. a new QuestieDB release (tools/update-questiedb.js takes it in)
// Each note's lines that name something the planner models (transport, XP, drops, elites, a quest, NPC or zone in our
// data, a spell our side trips teach) are marked, with what to look at. Writes reports/patch-watch.md (newest first).
// Only public pages, one request a second, no getting around anything that refuses a script.
// usage: node tools/patch-watch.js [--all]   (--all: report everything in reach, not only what is new)
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..');
const STATE = path.join(ROOT, 'reports', 'patch-watch-state.json');
const OUT = path.join(ROOT, 'reports', 'patch-watch.md');
const FORUM = 'https://us.forums.blizzard.com/en/wow';
const FOREVER_CATS = new Set([346, 347, 348, 352]); // WoW: Forever and its subcategories (general, community, bug report)
const DEV_NOTES = 2360696; // "WoW Forever Beta Development Notes"
const CLASSES = ['warrior', 'paladin', 'hunter', 'rogue', 'priest', 'shaman', 'mage', 'warlock', 'druid'];
const H = { headers: { 'User-Agent': 'ForeverRoute-patch-watch (github.com/noopz/ForeverRoute)', Accept: 'application/json' } };
const all = process.argv.includes('--all');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const readJson = (f, d) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch (e) { return d; } };
const hash = (s) => require('crypto').createHash('sha1').update(s).digest('hex').slice(0, 12);
const text = (html) => String(html || '').replace(/<br\s*\/?>|<\/(p|li|h\d)>/gi, '\n').replace(/<li>/gi, '- ').replace(/<[^>]+>/g, '').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;|&rsquo;/g, "'").replace(/&nbsp;/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
async function get(url, json = true) { const r = await fetch(url, H); await sleep(1000); if (!r.ok) throw new Error(url + ': HTTP ' + r.status); return json ? r.json() : r.text(); }

// ---- what the planner models: words and names worth a look when a note mentions them
const db = readJson(path.join(ROOT, 'qdb', 'db.json'), { quests: {}, npcs: {} });
const conv = readJson(path.join(ROOT, 'qdb', 'conversion.json'), { geometry: { transforms: [] } }).geometry.transforms;
const TOPICS = [
  [/\b(boat|ship|zeppelin|portal|tram|skyship|skycutter|flight (path|master)|transport|teleport)/i, 'travel: tools/travel-facts.json'],
  [/\b(experience|xp\b|rested|leveling|level cap)/i, 'XP: the planner\'s rates (tools/world.js, learned rates)'],
  [/\b(drop rate|drop chance|loot)/i, 'drops: quest item rates (tools/forever-overrides.json, ForeverRouteDB.drops)'],
  [/\b(elite|respawn|spawn)/i, 'mobs: elites and spawns the planner avoids or counts'],
  [/\b(quest|chain|breadcrumb|prerequisite|objective)/i, 'quests: QuestieDB data or tools/forever-overrides.json'],
  [/\b(dungeon|instance)/i, 'dungeons: dungeon runs in the plans'],
  [/\b(mount|riding)/i, 'riding: MOUNT level and speed in tools/travel-facts.json'],
  [/\b(trainer|class quest|stance|totem|pet|form)\b/i, 'class quests: tools/reviewed-*.json'],
];
const names = new Map(); // lower-case name -> what it is
const addName = (n, what) => { if (n && n.length >= 8 && !names.has(n.toLowerCase())) names.set(n.toLowerCase(), what); };
for (const t of conv) addName(t.target_name, 'zone');
for (const f of ['reviewed-alliance.json', 'reviewed-horde.json']) {
  const R = readJson(path.join(__dirname, f), { special: [] });
  for (const s of R.special || []) {
    addName(s.name && s.name.replace(/\s*\(.*$/, ''), 'side trip ' + s.id + ' (' + f + ')');
    for (const q of s.quests || []) if (db.quests[q]) addName(db.quests[q].name, 'quest ' + q + ' in side trip ' + s.id);
    for (const w of String(s.tag || '').split(/[,+]/)) addName(w.trim(), 'reward of side trip ' + s.id);
  }
  for (const q of R.mustDo || []) if (db.quests[q]) addName(db.quests[q].name, 'must-do quest ' + q);
}
const nameRe = names.size ? new RegExp('\\b(' + [...names.keys()].sort((a, b) => b.length - a.length).map((n) => n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|') + ')\\b', 'i') : null;
function relevant(body) {
  const hits = [];
  for (const line of body.split('\n').map((l) => l.trim()).filter(Boolean)) {
    const why = new Set();
    for (const [re, w] of TOPICS) if (re.test(line)) why.add(w);
    const m = nameRe && line.match(nameRe); if (m) why.add(names.get(m[1].toLowerCase()) + ' ("' + m[1] + '")');
    if (why.size) hits.push({ line: line.length > 220 ? line.slice(0, 217) + '...' : line, why: [...why] });
  }
  return hits;
}

(async () => {
  const state = readJson(STATE, { seenPosts: [], devNotes: {}, spellbook: {}, questiedb: null, checked: null });
  const seen = new Set(state.seenPosts);
  const items = []; // { at, source, title, url, body, hits }
  const notes = [];

  // 1. blue posts in the Forever forums (the tracker, newest first; back until a page has nothing new)
  try {
    let before = '', pages = 0;
    for (;;) {
      const j = await get(`${FORUM}/groups/blizzard-tracker/posts.json${before ? '?before=' + encodeURIComponent(before) : ''}`);
      const posts = j.posts || []; if (!posts.length) break;
      let fresh = 0;
      for (const p of posts) {
        if (!(FOREVER_CATS.has(p.category_id) || /forever/i.test(p.topic_title || ''))) continue;
        if (seen.has(p.id) && !all) continue;
        fresh++;
        let body = text(p.excerpt);
        try { body = text((await get(`${FORUM}/posts/${p.id}.json`)).cooked) || body; } catch (e) {}
        items.push({ at: p.created_at, source: 'Blue post', title: p.topic_title, url: `${FORUM}/t/${p.topic_slug}/${p.topic_id}/${p.post_number}`, body, who: p.name || p.username });
        seen.add(p.id);
      }
      pages++;
      if ((!fresh && state.checked && !all) || pages >= 8) break;
      before = posts[posts.length - 1].created_at;
    }
  } catch (e) { notes.push('blue posts: ' + e.message); }

  // 2. the development notes thread: new or edited posts
  try {
    const t = await get(`${FORUM}/t/${DEV_NOTES}.json`);
    for (const p of (t.post_stream && t.post_stream.posts) || []) {
      if (!p.staff && !/blizzard/i.test(p.primary_group_name || '')) continue;
      const h = hash(p.cooked || ''), was = state.devNotes[p.id];
      if (was === h && !all) continue;
      items.push({ at: p.updated_at || p.created_at, source: was ? 'Development notes (edited)' : 'Development notes', title: t.title, url: `${FORUM}/t/${t.slug}/${DEV_NOTES}/${p.post_number}`, body: text(p.cooked), who: p.name || p.username });
      state.devNotes[p.id] = h;
    }
  } catch (e) { notes.push('development notes: ' + e.message); }

  // 3. Wowhead's Forever spellbook changes, per class
  for (const c of CLASSES) {
    try {
      const html = await get(`https://www.wowhead.com/forever/changes/spellbook/${c}`, false);
      const now = {};
      for (const m of html.matchAll(/"key":"([^"]+)","name":"[^"]*","tab":\d+,"ranks":\[/g)) {
        const e = html.slice(m.index, m.index + 20000).match(/\],"icon":"[^"]*","level":(\d+),"status":"([a-z]+)"/);
        if (e && !now[m[1]]) now[m[1]] = e[2] + '@' + e[1];
      }
      if (!Object.keys(now).length) { notes.push(`Wowhead ${c}: no spell list in the page (layout changed?)`); continue; }
      const was = state.spellbook[c];
      if (was) {
        const diff = [];
        for (const [k, v] of Object.entries(now)) if (was[k] !== v) diff.push(`- ${k}: ${was[k] || 'not listed'} -> ${v}`);
        for (const k of Object.keys(was)) if (!now[k]) diff.push(`- ${k}: ${was[k]} -> not listed`);
        if (diff.length) items.push({ at: new Date().toISOString(), source: 'Wowhead spellbook changes', title: `${c}: ${diff.length} spell(s) changed`, url: `https://www.wowhead.com/forever/changes/spellbook/${c}`, body: diff.join('\n') + '\n(a "removed" is not proof: check the spell tooltip, dataEnv 16)' });
      }
      state.spellbook[c] = now;
    } catch (e) { notes.push(`Wowhead ${c}: ${e.message}`); }
  }

  // 4. QuestieDB
  try {
    const rel = await get('https://api.github.com/repos/Questie/QuestieDB/releases/latest');
    const latest = String(rel.tag_name || '').replace(/^v/, '');
    const ours = (readJson(path.join(ROOT, 'qdb', 'questiedb-version.json'), {}) || {}).version;
    if (latest && latest !== ours) items.push({ at: rel.published_at, source: 'QuestieDB', title: `QuestieDB ${latest} is out (ours: ${ours || 'none'})`, url: rel.html_url, body: 'Take it in: node tools/update-questiedb.js (re-plans only the legs it touches; the report lists what changed).' });
    state.questiedb = latest;
  } catch (e) { notes.push('QuestieDB: ' + e.message); }

  // the report: newest first, the lines worth a look marked
  for (const it of items) it.hits = it.source === 'QuestieDB' ? [] : relevant(it.body);
  items.sort((a, b) => String(b.at).localeCompare(String(a.at)));
  const stamp = new Date().toISOString();
  const L = [`## Checked ${stamp.slice(0, 16).replace('T', ' ')} UTC: ${items.length} new`, ''];
  for (const it of items) {
    L.push(`### ${it.source}: ${it.title}`, `${String(it.at).slice(0, 10)}${it.who ? ' - ' + it.who : ''} - ${it.url}`, '');
    if (it.hits.length) { L.push('**Could touch the plans:**'); for (const h of it.hits) L.push(`- ${h.line}  \n  _look at: ${h.why.join('; ')}_`); L.push(''); }
    L.push('<details><summary>Full text</summary>', '', it.body.split('\n').map((l) => '    ' + l).join('\n'), '', '</details>', '');
  }
  if (notes.length) L.push('Could not read: ' + notes.join('; '), '');
  const old = fs.existsSync(OUT) ? fs.readFileSync(OUT, 'utf8').replace(/^# .*\n+/, '') : '';
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, '# Forever changes (tools/patch-watch.js)\n\n' + L.join('\n') + '\n' + old);
  state.seenPosts = [...seen].slice(-2000); state.checked = stamp;
  fs.writeFileSync(STATE, JSON.stringify(state, null, 1));
  console.log(`${items.length} new since the last check; ${items.reduce((n, it) => n + it.hits.length, 0)} lines could touch the plans -> ${path.relative(ROOT, OUT)}`);
  for (const it of items.slice(0, 15)) console.log(`  ${String(it.at).slice(0, 10)}  ${it.source}: ${it.title}${it.hits.length ? '  [' + it.hits.length + ' to look at]' : ''}`);
  if (notes.length) console.log('could not read: ' + notes.join('; '));
})().catch((e) => { console.error('patch-watch failed: ' + e.message); process.exit(1); });
