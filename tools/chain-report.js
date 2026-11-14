// Which quest-chain parts a plan leaves out, and why: every part of a chain (a quest with a prerequisite, or one that
// leads on to another) that this character could take, whose level band and zone the plan reaches, but that the plan
// never hands in. Cheap - no planning: it reads the plan's steps and the quest data. Written next to every built-in
// plan (tools/starter.js) and printed by tools/dryrun-plan.js, so a planner change that starts cutting chains shows up
// as a number, not as a tester's "why did it skip the rest of the Defias chain?". The 1.4.4 planner on the 1.0.15 data
// kept chains that the same planner on QuestieDB 1.1.0 dropped, and only a hand-written classifier found it.
//
// Each lost part gets one class:
//   picked up, never handed in   the chain's first missing part (this one, or an earlier one it needs) is accepted on
//                                the plan (or was in the log when it was planned) and never handed in: the pick-up was
//                                paid for and thrown away
//   chain head never taken       an earlier part is missing, and the first missing one is the chain's head (it needs
//                                nothing): the whole tail went with it. A head that starts in one zone and ends in
//                                another (a delivery) is marked cross-zone - those are the ones zone-by-zone planning
//                                tends to cut
//   prerequisite done, dropped   everything this part (or the first missing part before it) needs is handed in on
//                                the plan, and it was still left out (ordering, the leg ended, the log was full, ...)
//   no prerequisite, not taken   this part is a chain head itself, and the plan never took it
// Not counted, each reason on its own line under "Not counted" (the plan could not or should not take them): other
// race/class/faction, professions, reputation, spells, repeatable and holiday quests, quests Forever removed, items
// the plan can't get, quests that start from an item (the planner only takes those already in the log), quests you
// said you are not doing, an alternative already handed in, a breadcrumb whose quest the plan took, dungeon quests and
// parts behind one (dungeons are never forced on the player), and parts behind a prerequisite this character can't take.
// Quests the character handed in before the plan (its save, or the campaign's completed list) are done: they count as
// handed in for the parts after them and are never listed. End-game parts - ones the plan can first take in its last
// levels (see endGame below) - are listed apart and left out of the headline: the plan stops at its target level by
// design, so what it meets there is not a chain it cut.
//
// usage: node tools/chain-report.js <path-N.json | Route.lua> [pathId] [--race human --class warrior] [--db qdb/db.json]
//          [--out file.txt] [--json file.json] [--summary]
//   race and class (and the campaign's completed list and log, when it has them) come from the campaign.json next to
//   the plan when not given. --summary prints only the one line.
const fs = require('fs');
const path = require('path');
const W = require('./world');

const ALLIANCE = new Set(['human', 'dwarf', 'nightelf', 'gnome', 'skyborne']);
const CLASSES = ['picked up, never handed in', 'chain head never taken', 'prerequisite done, dropped', 'no prerequisite, not taken'];
const SHORT = ['picked up', 'head not taken', 'prereq done', 'not taken'];
// the steps that put the player in a zone: a flight, a hearth or a training trip only passes through it
// holiday quests are filed under these QuestieDB sorts (the same list as route2.js HOLIDAY_SORTS)
const HOLIDAY_SORTS = new Set([-22, -284, -366, -364, -369, -370, -1001, -1002, -1003, -1004, -1005, -1006, -1007, -41, -376, -374, -375, -101]);
// battlegrounds (Alterac Valley, Warsong Gulch, Arathi Basin): their quests are PvP, which a leveling plan doesn't do -
// 'Remember Alterac Valley!' was listed as lost because the plan trains in Ironforge at 59
const BATTLEGROUNDS = new Set([2597, 3277, 3358]);
const IN_ZONE = new Set(['accept', 'turnin', 'obj', 'grind']);

// quests: db.quests; npcs: db.npcs (for faction and elite checks; optional); steps: the plan's steps (k, q, lvl, zone,
// m); zoneName: area id -> zone name (the conversion's); zoneAliases: area id -> the name the planner's steps use where
// it differs (world.js PLANNER_ZONE_NAMES: 'Stormwind', not 'Stormwind City'); mapArea: uiMap id -> area id, for steps
// that carry their map; dungeonAreas: area id -> anything, for dungeon and raid areas; completed: quests handed in
// before the plan; active: the quest log the plan started from (id -> anything); nope: quests you said you won't do
function chainReport({ quests: Q, npcs = {}, steps, race, cls, zoneName = {}, zoneAliases = {}, mapArea = {}, dungeonAreas = {}, completed = [], active = {}, nope = [], leftOut = [], cfgSkipIds = [] }) {
  const faction = ALLIANCE.has(race) ? 'A' : 'H';
  // done before the plan: closed for good, and the parts after them are open
  const before = new Set(completed.map(Number));
  const inLog = new Set(Object.keys(active || {}).map(Number));
  const notDoing = new Set(nope.map(Number));
  const planHandIns = new Set(), accepted = new Set([...inLog, ...leftOut.map(Number)]); // (leftOut: picked up, never handed in)
  const cfgSkip = new Set(cfgSkipIds.map(Number));
  for (const s of steps) {
    if (s.q === undefined || s.q === '') continue;
    if (s.k === 'turnin') planHandIns.add(+s.q);
    if (s.k === 'accept') accepted.add(+s.q);
  }
  const handedIn = new Set([...before, ...planHandIns]);
  // a step's zone as an area id: by its map when it has one, else by name - either spelling, the conversion's or the
  // planner's (Stormwind steps never counted as being in Stormwind when only 'Stormwind City' was looked for)
  const areaOfName = {};
  for (const [a, n] of Object.entries(zoneName)) areaOfName[n] = +a;
  for (const [a, n] of Object.entries(zoneAliases)) areaOfName[n] = +a;
  const areaOf = (s) => (s.m && mapArea[s.m] !== undefined ? +mapArea[s.m] : areaOfName[s.zone]);
  // the levels the plan is at in each zone (only where it does something there). A step without a level is at the
  // last level the plan had (a step written without one is still the plan being there)
  const endLevel = Math.max(0, ...steps.map((s) => +s.lvl || 0));
  const levelsIn = {};
  let lastLevel = 0;
  for (const s of steps) {
    if (+s.lvl) lastLevel = +s.lvl;
    const a = IN_ZONE.has(s.k) ? areaOf(s) : undefined;
    if (a !== undefined && lastLevel) (levelsIn[a] = levelsIn[a] || new Set()).add(lastLevel);
  }
  const followers = {};
  for (const q of Object.values(Q)) for (const p of [...(q.preSingle || []), ...(q.preGroup || [])]) (followers[p] = followers[p] || []).push(q.id);
  const breadcrumbOf = {};
  for (const q of Object.values(Q)) for (const b of q.breadcrumbs || []) (breadcrumbOf[b] = breadcrumbOf[b] || []).push(q.id);
  // shown as the plan's steps name it ('Stormwind'), so a line here matches the plan's own zone headings
  const zn = (z) => zoneAliases[z] || zoneName[z] || (z > 0 ? 'area ' + z : 'sort ' + z);

  const spawnZones = (who) => {
    if (!who) return [];
    if (who.type === 'item') return (who.drops || []).flatMap((id) => ((npcs[id] || {}).spawns || []).map((p) => p.zone));
    return (who.spawns || []).map((p) => p.zone);
  };
  const startZones = (q) => [...new Set((q.starters || []).flatMap(spawnZones))];
  const endZones = (q) => [...new Set((q.finishers || []).flatMap(spawnZones))];
  // the zone a quest is filed under: its own zone when that is a real zone, else where it starts
  const homeZone = (q) => (zoneName[q.zone] ? q.zone : (startZones(q).find((z) => zoneName[z]) ?? q.zone));
  const mobsOf = (q) => (q.objectives || []).flatMap((o) => (o.npc ? [o.npc] : o.npcDrops || [])).map((id) => npcs[id]).filter(Boolean);
  const isDungeon = (q) => {
    if (dungeonAreas[q.zone]) return true;
    const spawns = mobsOf(q).flatMap((n) => n.spawns || []);
    return spawns.length > 0 && spawns.every((p) => dungeonAreas[p.zone]);
  };
  // all of its objectives' mobs elite (rank 1-3): a group quest. Kept in the report, but marked
  const isElite = (q) => { const m = mobsOf(q); return m.length > 0 && m.every((n) => n.rank >= 1 && n.rank <= 3); };

  // why this character can never take it (null: it can)
  function cannot(q) {
    if (!q) return 'not in the quest data';
    if (!W.canTake(q, race, cls)) return 'race or class';
    if (q.special & 1) return 'repeatable'; // as campaign.js leaves them out (a scripted event, special & 2, is planned: escorts, fights, explorations)
    if (HOLIDAY_SORTS.has(q.zone)) return 'holiday event';
    if (q.skill) return 'profession';
    if (q.reqSpell || q.minRep) return 'requirement';
    if (q.notInForever) return 'not in Forever';
    if (notDoing.has(q.id)) return 'you said you are not doing it';
    if (cfgSkip.has(q.id)) return 'skipped in the plan settings';
    if (isElite(q)) return 'a group quest (elite)';
    // the planner only gives a quest from a giver it can walk to: one that starts from an item (a drop, a looted
    // letter) it takes only when it is already in the log (route2.js: "item-started quests: v1 leaves them out")
    if ((q.starters || []).length && q.starters.every((s) => s.type === 'item') && !inLog.has(q.id)) return 'starts from an item, not in the log';
    if ((q.needsItems || []).length) return 'needs an item the plan cannot get';
    if (q.level <= 0 || q.level > 60) return 'level';
    if (!(q.starters || []).length || !(q.finishers || []).length) return 'no giver or ender in the data';
    const npcOf = (s) => (s.type === 'npc' ? s : null);
    if ([...q.starters, ...q.finishers].some((s) => npcOf(s) && s.friendly && s.friendly !== 'AH' && s.friendly !== faction)) return 'other faction';
    if (isDungeon(q)) return 'dungeon';
    if (BATTLEGROUNDS.has(q.zone)) return 'battleground';
    return null;
  }
  // the prerequisites it still lacks on this plan: every preGroup quest not handed in, and (when none of the
  // preSingle ones is handed in) the first preSingle one this character can take
  function missing(q) {
    const out = (q.preGroup || []).filter((p) => !handedIn.has(p));
    const single = q.preSingle || [];
    if (single.length && !single.some((p) => handedIn.has(p))) {
      const pick = single.find((p) => !cannot(Q[p])) ?? single[0];
      out.push(pick);
    }
    return out;
  }
  // walk back to the chain's first part that is missing: it is where the chain broke
  function breakPoint(q) {
    let cur = q;
    for (const seen = new Set([q.id]); ;) {
      const m = missing(cur);
      if (!m.length) return { at: cur };
      const blocked = m.find((p) => cannot(Q[p]));
      if (blocked !== undefined) return { at: cur, blocked, why: Q[blocked] ? cannot(Q[blocked]) : 'not in the quest data' };
      const next = Q[m[0]];
      if (seen.has(next.id)) return { at: cur }; // a loop in the data
      seen.add(next.id);
      cur = next;
    }
  }
  // the planner's own window: it takes a quest from maxAbove - 1 levels below it (route2.js canAccept: q.level <= level
  // + maxAbove - 1, campaign.js maxAbove = LEVEL_ABOVE + 1) and down to 6 below (campaign.js minQuestLevel)
  const maxAbove = W.levelAbove(endLevel - 1) + 1; // the gate at the plan's last levels (world.levelAbove)
  const acceptLevel = (q) => Math.max(q.reqLevel || 1, q.level - maxAbove + 1);
  const band = (q) => [acceptLevel(q), q.level + 6];
  function reached(q) {
    const [lo, hi] = band(q);
    for (const z of new Set([q.zone, ...startZones(q)])) for (const L of levelsIn[z] || []) if (L >= lo && L <= hi) return true;
    return false;
  }
  // end-game: a part the plan can first take in its last maxAbove + LEVEL_ABOVE levels. The plan takes quests up to
  // LEVEL_ABOVE above it and a chain's next parts come a level or more after the last, so what it can first take that
  // late has no levels left to be done in: a level-60 plan stops before the 57-60 chains by design, and counting them
  // buried the chains it really cut lower down under end-game XP
  const endFrom = endLevel - maxAbove - W.levelAbove(endLevel - 1) + 1;
  const endGame = (q) => endLevel > 0 && acceptLevel(q) >= endFrom;
  const isChain = (q) => (q.preSingle || []).length > 0 || (q.preGroup || []).length > 0 || (followers[q.id] || []).length > 0 || !!(q.nextInChain && Q[q.nextInChain]);
  const crossZone = (q) => { const a = startZones(q), b = new Set(endZones(q)); return a.length > 0 && b.size > 0 && !a.some((z) => b.has(z)); };

  // closed on this plan: one of a set of alternatives is handed in (the plan can only do one of them), or it is a
  // breadcrumb whose quest the plan took - it is no longer offered then (route2.js eligible)
  const closed = (q) => ((q.exclusive || []).some((e) => handedIn.has(e)) ? 'an alternative to one handed in'
    : (breadcrumbOf[q.id] || []).some((t) => accepted.has(t) || handedIn.has(t)) ? 'a breadcrumb, its quest taken' : null);
  // every named zone it starts (or ends) in: a quest with givers in two zones showed only the first
  const named = (zs) => [...new Set(zs.map(zn).filter((n) => !/^(area|sort) /.test(n)))].join(' / ') || undefined;
  const rows = [], skipped = {};
  const skip = (why) => { skipped[why] = (skipped[why] || 0) + 1; };
  const endRows = [];
  for (const q of Object.values(Q)) {
    if (handedIn.has(q.id) || !isChain(q)) continue;
    if (!reached(q)) continue;
    const no = cannot(q);
    if (no) { skip(no); continue; }
    const b = breakPoint(q);
    if (b.blocked !== undefined) { skip('behind a quest it cannot take (' + b.why + ')'); continue; }
    const at = b.at, own = at === q;
    // closed by what the plan did, for this part or the part it broke at
    const why = closed(q) || closed(at);
    if (why) { skip(own || closed(q) ? why : 'behind a part that is ' + why); continue; }
    const hasPre = (at.preSingle || []).length > 0 || (at.preGroup || []).length > 0;
    const kind = accepted.has(at.id) ? 0 : !own && !hasPre ? 1 : hasPre ? 2 : 3;
    const row = { id: q.id, name: q.name, level: q.level, xp: q.xp || 0, zone: zn(homeZone(q)), kind, elite: isElite(q),
      at: own ? null : { id: at.id, name: at.name, level: at.level, zone: zn(homeZone(at)), reached: reached(at) },
      crossZone: (kind === 1 || kind === 3) ? crossZone(at) : undefined,
      from: crossZone(at) ? named(startZones(at)) : undefined,
      to: crossZone(at) ? named(endZones(at)) : undefined };
    (endGame(q) ? endRows : rows).push(row);
  }
  const order = (a, b) => a.kind - b.kind || b.xp - a.xp || a.id - b.id;
  rows.sort(order); endRows.sort(order);
  const byClass = CLASSES.map((name, i) => { const r = rows.filter((x) => x.kind === i); return { name, parts: r.length, xp: r.reduce((s, x) => s + x.xp, 0) }; });
  const byZone = {};
  for (const r of rows) { const z = (byZone[r.zone] = byZone[r.zone] || { parts: 0, xp: 0, byClass: [0, 0, 0, 0] }); z.parts++; z.xp += r.xp; z.byClass[r.kind] += r.xp; }
  // by the quest's level: the last levels before the plan's end are cut by design (it stops at its target level), so a
  // change there means less than one in the 20s
  const BRACKETS = [[1, 19], [20, 39], [40, 49], [50, 60]];
  const byLevel = BRACKETS.map(([lo, hi]) => { const r = rows.filter((x) => x.level >= lo && x.level <= hi); return { levels: lo + '-' + hi, parts: r.length, xp: r.reduce((s, x) => s + x.xp, 0) }; });
  const crossHeads = new Set(rows.filter((r) => r.crossZone).map((r) => (r.at ? r.at.id : r.id)));
  const total = { parts: rows.length, xp: rows.reduce((s, x) => s + x.xp, 0), handedIn: planHandIns.size, crossZoneHeads: crossHeads.size, doneBefore: before.size };
  const endGameTotal = { parts: endRows.length, xp: endRows.reduce((s, x) => s + x.xp, 0), from: Math.max(1, endFrom), endLevel };
  return { rows, byClass, byZone, byLevel, total, skipped, endRows, endGame: endGameTotal };
}

// the one line: what a reports/starters.md cell and the dry run show
function summaryLine(rep) {
  const t = rep.total;
  return `chain XP lost: ${t.xp} XP in ${t.parts} part(s) (` + rep.byClass.map((c, i) => `${SHORT[i]} ${c.xp}/${c.parts}`).join(', ') +
    `; ${t.crossZoneHeads} cross-zone head(s); ${t.handedIn} hand-ins on the plan` + (t.doneBefore ? `, ${t.doneBefore} done before it` : '') + ')' +
    (rep.endGame && rep.endGame.parts ? `; end-game, not counted: ${rep.endGame.xp} XP in ${rep.endGame.parts} part(s)` : '');
}

function formatReport(rep, title) {
  const out = [];
  out.push('# Chain parts the plan leaves out' + (title ? ': ' + title : ''), '', summaryLine(rep), '');
  out.push('XP is each quest\'s own XP at its level. A part is listed when this character can take it and the plan is in');
  out.push('its zone at a level it would take it (up to ' + W.LEVEL_ABOVE + ' below the quest to 6 above), but never hands it in.');
  out.push('A part with no XP has none in the quest data (it gives an item, or only opens the rest of the chain).', '');
  const line = (r) => {
    let l = `  ${r.id} ${r.name} (${r.zone}, lvl ${r.level}, ${r.xp ? r.xp + ' xp' : 'no xp'})` + (r.elite ? ' [elite]' : '');
    if (r.at) l += ` <- ${r.at.id} ${r.at.name} (${r.at.zone}, lvl ${r.at.level}${r.at.reached ? '' : ', the plan is never there at its level'})`;
    if (r.crossZone) l += ` [cross-zone: ${r.from || '?'} -> ${r.to || '?'}]`;
    return l;
  };
  rep.byClass.forEach((c, i) => {
    out.push(`## ${c.name}: ${c.parts} part(s), ${c.xp} XP`);
    for (const r of rep.rows.filter((x) => x.kind === i)) out.push(line(r));
    out.push('');
  });
  out.push('## By quest level');
  for (const b of rep.byLevel) out.push(`  ${b.levels}: ${b.xp} XP in ${b.parts} part(s)`);
  out.push('');
  out.push('## By zone (XP lost: ' + SHORT.join(' / ') + ')');
  for (const [z, v] of Object.entries(rep.byZone).sort((a, b) => b[1].xp - a[1].xp)) out.push(`  ${z}: ${v.xp} XP in ${v.parts} part(s) (${v.byClass.join(' / ')})`);
  out.push('');
  if (rep.endRows && rep.endRows.length) {
    const e = rep.endGame;
    out.push(`## End-game, not counted: ${e.parts} part(s), ${e.xp} XP (first takeable at level ${e.from} or later; the plan ends at ${e.endLevel})`);
    for (const r of rep.endRows) out.push(line(r) + ' [' + SHORT[r.kind] + ']');
    out.push('');
  }
  const sk = Object.entries(rep.skipped);
  if (sk.length) { out.push('## Not counted (reached, not handed in, but not the plan\'s to take)'); for (const [k, v] of sk.sort((a, b) => b[1] - a[1])) out.push(`  ${k}: ${v}`); }
  return out.join('\n') + '\n';
}

// the quests a route picks up but never hands in (its leftOut, written by paths.js): counted as picked up
function loadLeftOut(file, pathId) {
  const text = fs.readFileSync(file, "utf8");
  if (/\.json$/i.test(file)) return [];
  const RF = require("./routefile");
  const id = pathId || RF.routeIds(text, /^path:/)[0];
  const at = text.indexOf("id = " + JSON.stringify(id));
  if (at < 0) return [];
  const m = /\n {4}leftOut = "([\d,]*)",/.exec(text.slice(at, at + 4000));
  return m ? m[1].split(",").filter(Boolean).map(Number) : [];
}
// a plan's steps: a planner path-N.json, or one path of a Route.lua (the first path when no id is given)
function loadSteps(file, pathId) {
  const text = fs.readFileSync(file, 'utf8');
  if (/\.json$/i.test(file)) return JSON.parse(text).steps || [];
  const RF = require('./routefile');
  const id = pathId || RF.routeIds(text, /^path:/)[0];
  return RF.steps(text, id);
}
function loadWorld(dbFile) {
  const root = path.join(__dirname, '..');
  const db = JSON.parse(fs.readFileSync(dbFile || path.join(root, 'qdb', 'db.json'), 'utf8'));
  const conv = JSON.parse(fs.readFileSync(path.join(root, 'qdb', 'conversion.json'), 'utf8')).geometry.transforms;
  const zoneName = Object.fromEntries(conv.map((t) => [t.area_id, t.target_name]));
  const mapArea = Object.fromEntries(conv.map((t) => [t.ui_map_id, t.area_id]));
  let dungeonAreas = {};
  try { dungeonAreas = require('./dungeons').loadDungeons(path.join(root, 'qdb', 'support', 'Forever', 'Zones', 'dungeons.lua')).byArea; } catch (e) { /* no dungeon list: none left out */ }
  return { quests: db.quests, npcs: db.npcs, zoneName, zoneAliases: W.PLANNER_ZONE_NAMES, mapArea, dungeonAreas };
}
// the whole report for a plan file: race and class from the campaign.json beside it unless given. opts.completed,
// opts.active (the log: id -> anything) and opts.nope are the character's state the plan was made from (a dry run
// passes its save's): without them its finished quests look lost and the quests in its log look never picked up
function reportFor(file, opts = {}) {
  let { race, cls, db, completed, active, nope } = opts;
  // the plan's own campaign.json says who it is for and which quest data it was planned on (a trial plan on older
  // QuestieDB data names its db.json there): read against other data, quests that changed would look lost
  let skip = opts.skip;
  try { const c = JSON.parse(fs.readFileSync(path.join(path.dirname(file), 'campaign.json'), 'utf8')); race = race || c.race; cls = cls || c.class; skip = skip || c.skip; if (!db && c.db) db = path.resolve(path.join(__dirname, '..'), c.db); completed = completed || c.completed; active = active || c.active; nope = nope || c.nope; } catch (e) { /* given on the command line, or not at all */ }
  if (!race || !cls) throw new Error('race and class unknown: pass --race and --class (no campaign.json beside ' + file + ')');
  const norm = (s) => String(s).toLowerCase().replace(/[^a-z]/g, '');
  return chainReport({ ...(opts.world || loadWorld(db)), steps: loadSteps(file, opts.pathId), leftOut: loadLeftOut(file, opts.pathId), cfgSkipIds: skip || [], race: norm(race), cls: norm(cls), completed: completed || [], active: active || {}, nope: nope || [] });
}

module.exports = { chainReport, summaryLine, formatReport, loadSteps, loadWorld, reportFor, CLASSES };

if (require.main === module) {
  const args = process.argv.slice(2);
  const opt = (k) => { const i = args.indexOf('--' + k); return i >= 0 ? args[i + 1] : undefined; };
  const flags = new Set(['--race', '--class', '--db', '--out', '--json']);
  const pos = args.filter((a, i) => !a.startsWith('--') && !flags.has(args[i - 1]));
  if (!pos[0]) { console.log('usage: node tools/chain-report.js <path-N.json | Route.lua> [pathId] [--race r --class c] [--db qdb/db.json] [--out f.txt] [--json f.json] [--summary]'); process.exit(2); }
  const rep = reportFor(pos[0], { pathId: pos[1], race: opt('race'), cls: opt('class'), db: opt('db') });
  const text = formatReport(rep, path.basename(path.dirname(path.resolve(pos[0]))) + '/' + path.basename(pos[0]));
  if (opt('out')) fs.writeFileSync(opt('out'), text);
  if (opt('json')) fs.writeFileSync(opt('json'), JSON.stringify(rep, null, 1));
  console.log(args.includes('--summary') || opt('out') ? summaryLine(rep) : text);
}
