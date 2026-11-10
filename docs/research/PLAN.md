# Forever Route: what to fix, in order

Synthesis of the three research reports (planner-design.md, runtime-and-tests.md, world-facts.md), 2026-11-07.

## The diagnosis in one paragraph
The world is modelled in too many places that each trust the last: five in the planner (the quest simulation, the
optimizer's cost model, the step writer, the zone chooser with flat travel costs, and model-less clean-up passes) and
three "how do I get there" functions in the addon (TravelPlan, TravelTarget, TravelFor) that the card, arrow and pins
each mix differently. Every bug the player caught is two of these disagreeing, an unchecked edit, or a wrong fact
(boats, zone levels, Forever changes). Tests never simulate time, movement or reloads, so these show up only in play.

## Phase 1: stop shipping bad routes (small, mostly deletions) - DONE 2026-11-07
Status: lint-route.js audits every install (dungeon quests +5 margin) and autoplan holds back a plan that audits worse
than the installed one (at most 3 times running); real legs use exact cache keys and exact XP; the end state (position,
quest log, hearth cooldown) comes from the emitted steps, and step XP matches the simulation within 10% on 40 legs
(dungeon-run XP was missing); grind top-ups are real steps; known flight paths and the hearth cooldown reach every leg;
the addon one-place fixes shipped. Route audit (lint-route.js, tested by test-lint.js) now covers: fight/loot quest and
mob levels, travel step per zone change, no doubled travel, repeats, quest log <= 40, hearth only to where you are
bound, choice points, required level of pick-ups, pick-up -> objectives -> hand-in order; the companion never installs
a plan with an empty path; class/race of every pick-up (the companion passes the character) and prerequisites (against
the quests done at the save, written to paths-auto/done.json). Determinism: tools/test-determinism.js (two uncached
plans at once are identical, 2026-11-08). Training steps all land in Stormwind (checked by hand, not audited). Hearth cooldown: hearth steps carry
tm (planned minutes since the route began, across legs) and the audit flags two within an hour.
1. Route rules as an install gate: one shared "fold" over the emitted steps (level, XP, quest log, position, hearth)
   checks the 13 invariants (accept before turn-in; no re-accept; level gate on every step; exactly one travel step per
   zone change; only flights you know; hearth only after a bind and off cooldown across legs; log <= 40 (Forever); prerequisites;
   every accept turned in or carried; training on the trainer's map; leg-to-leg state continuity; determinism; no
   inserted stop splitting steps at the same NPC). lint-route.js uses it on every route (incl. packed side trips) and
   autoplan refuses to install a plan that fails.
2. Fix the loose leg cache: exact keys for real legs; a loose hit is re-checked from the real state; never merge
   completions or take the cached quest log.
3. End state from the emitted steps (not the simulation before optimizing); grind and training as real events; no XP
   rounding between legs.
4. Pass known flight paths and the hearth bind into every leg; carry the hearth cooldown across legs.
5. Addon quick fixes left over from one-place fixes: card up/down hint indoors only; minimap path dots near-you check;
   prerequisite check inside InsertStop/MergeSideTrips; inserted stops never split same-NPC steps.

## Open addon fixes (found by the planner audits)
- State.lua, logout snapshot: at PLAYER_LOGOUT the handler wipes its quest cache and re-reads C_QuestLog, which by
  then reports "not on quest" for every row logIDs() still lists, so the save holds the whole log with objectives = {}
  and no complete flag (seen in Testchar's save, reason "logout"). Since it is the last write of a session it replaced the
  good one. Fix: don't re-query on logout (keep the cache, or treat every ID from logIDs() as on-quest and read
  GetQuestObjectives directly); a wow-ui-sim test with IsOnQuest returning false during PLAYER_LOGOUT. Until then the
  planner side copes: snapshot.js keeps the last save that had progress (campaign/quest-progress-*.json) and fills
  blank entries from it; quests it never saw are marked unknown.

## Planner fixes, round 2 (2026-11-08)
Choice points are a marked step (_choice), not a number, so the safety net no longer moves them into the next zone
(lint-route checks them). The optimizer counts kill XP at the running level with the 40-slot log, a broken rule is a
penalty rather than Infinity, and route2 reports OPTIMIZER FALLBACK when it keeps the simulation's order
(test-optimize.js). Shared drops are shared out by spawn count at the spot and respect the level gate. In-log quests
are handed in wherever a leg passes their turn-in NPC. A dungeon runs once per path (again only with 3+ quests) and
after its quests' pick-ups (test-route2-sim.js, fixtures in tools/test-fixtures/).
Still open: accepts whose hand-in no later leg reaches (ensure-steps drops them, but the leg's end state still counts
them in the log for later legs).

## Phase 2: one world, one navigation (medium)
Status 2026-11-08: tools/world.js exists (XP table, kill XP, race/class masks, capitals, quest log 40) and the
simulation, optimizer, zone chooser, dungeon prep and audit use it - a pure refactor (uncached plans identical before
and after). Item 7 (one travel graph) is done: travel-facts.json + travel-net.json, travel.js and Travel.lua share it.
One level gate (world.js LEVEL_ABOVE = 2, the player's choice; DUNGEON_ABOVE = 4) for the simulation, optimizer, zone
chooser and audit. Still open in item 6: Forever's low-level mob XP (needs measured data), the quest log count from
the real log.
6. world.js shared by every planner stage: XP formulas (incl. Forever's lower low-level mob XP), one level gate
   (level+2) for accepts and every objective kind, quest log count from the real log.
7. One travel graph used by planner and addon alike: known flight paths (routing only through known nodes), boats as
   Forever has them (Menethil -> Southshore -> Auberdine ship, Menethil<->Theramore, Booty Bay<->Ratchet, Stormwind
   Harbor<->Auberdine, Auberdine<->Rut'theran + portal, Deeprun Tram), hearth, and danger: zone levels (fix Duskwood 20,
   Feralas 35, add the ~19 missing zones), Horde towns and blocked roads (Mor'shan Rampart; use the breach / Talondeep),
   danger corridors (Theramore->Barrens, Dun Algaz, Darkshire->STV, Tarren Mill, Hammerfall).
8. Addon: one navigation model per tick (step, trip with current leg, target, label, notes) that the card, arrow and
   pins only draw; a generation counter guarding timers; an explicit route-switch lifecycle; a motion module for speed
   and boats with explicit trip progress.

## Phase 3: tests that catch it before the player
Status 2026-11-08: withWorld harness in tests/all_test.lua (position, zone changes, level, quest log; after every
change the arrow and first pin must point at the card's step, and both checks must actually run) with scenarios for a
quest done while walking, a trip ending on arrival, a reload mid-quest, an abandon; a virtual clock (C_Timer.After
waits for w:wait), flights (take off, cross a zone mid-air, land) and boats (pier -> nothing at sea -> next step).
Route switches (side trip and back). Saves become tests: node tools/save-fixture.js <char SV dir> <name> writes
tests/save_<name>_test.lua (first: testchar_stormwind_21). Phase 3 done; add a replayed save for every in-game report.
9. Harness with a virtual clock, self-restoring fakes and helpers (walk, zone change, quest update, boat, flight,
   level-up, route switch, reload); per-tick invariants (card/arrow/pins agree; no ride through danger; chain order;
   idempotent merges; no stale state after a switch); one scenario per bug the player reported; save-to-fixture loader
   so an in-game report becomes a failing test.

## Phase 4: structure (larger)
Status 2026-11-08 (the player's choices): side trips (class quests, sleeping bag) fold into the leveling path in game
where it passes their stops (Engine.MergeSideTrips, 600 yd) and stay available as side trips; Stormwind training is
batched (world.js trainNow: two ranks waiting, or already in Stormwind; carried between legs). Forever quest changes
in tools/forever-overrides.json. Training trips are priced from where you are (travel network) at the quicker of the
two warlock trainers (cfg.trainers: Stormwind, Ironforge). Dungeons wait until their bosses are within +4.
Item 11 (optimizer cost = the audit): checked 2026-11-08 - optimize.js's cost already enforces every audit rule about
order (level floors from world.js, prerequisites, pick-up -> objectives -> hand-in, the 40-quest log, dungeon runs
after their pick-ups); the other audit rules are settled outside it (class/race when quests are chosen, travel and
hearth timing by the step writer, which also re-applies the level gate last). Item 12 drop rates: measured in game
(Drops.lua -> ForeverRouteDB.drops -> OBSERVED_DROPS in campaign.js); a full Forever table needs play data.
10. Stormwind as a city-visit node inserted when training/hand-ins are due (not riding along in every EK leg); class
    quests and the sleeping bag merged into the leveling path where it passes their stops.
11. Optimizer cost = the shared fold; per-NPC visiting with hubs only for section titles.
12. Data: Forever drop-rate table + trust measured rates sooner; new dungeons (Hall of Thanes, Ruins of Lordaeron,
    Excavation Site, Dalaran) with their quest givers; changed quests (Desolace 35, Gnarlpine 15, Khonsu removed);
    Orb of Soran'ruk; Ironforge warlock trainers; keep Incubus off the plan until seen in game.
