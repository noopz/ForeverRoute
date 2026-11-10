# ForeverRoute runtime and tests: why bugs reach the player first

Scope: the addon (`addon/ForeverRoute`) and `tests/all_test.lua`. Every claim below comes from reading the code. File:line references are to the current tree.

## 1. Systemic causes

**C1. Three travel planners, and each consumer picks a different one.**

| Function | Method | Danger rule | Boats |
|---|---|---|---|
| `Engine.TravelPlan` (Engine.lua:359) | ride/fly heuristic | no | no |
| `Engine.TravelTarget` (:329) | `TravelPlan`, else the nearest flight master | no | no |
| `Engine.TravelFor` (:409) | Dijkstra `Travel.Plan`, falling back to `TravelPlan` | yes | yes |

Who uses which:
- **Arrow** (Arrow.lua:206-214) uses `TravelTarget`, then overrides it with `TravelFor` unless the trip is a ride.
- **Pins** (Pins.lua:104) use only `TravelTarget`.
- **Card** (Card.lua:396-415) uses `TravelFor`, or `TravelPlan` for fly steps.
- **ShowOnMap** (Core.lua:261) uses `TravelTarget`.
- **InsertStop** (Engine.lua:641-647) uses both.

So the arrow and the pin can disagree about the same step. `TravelPlan` also rides without any distance cap when no closer flight path is known (Engine.lua:401-402). These gaps produced: "fly to the Barrens" when only boats work, the 9.2k-yard ride, the danger ride, and "fly" and "hearth" shown together.

**C2. Steps are identified by index, but the list changes underneath.**
- `InsertStop` does `table.insert(list, best, new)` (Engine.lua:675). It fixes `focus` and `view`, but nothing else.
- The arrow returns early when `target.index == i and not force` (Arrow.lua:202).
- The pins cache on the index string plus the map (Pins.lua:94).

When a stop is inserted at the current index (the case the test at all_test.lua:1055 expects, `at == 1`), the Card shows the new step while the arrow and pins keep the old one. Any insertion inside the pinned window leaves the pins stale. Separately, `Boats.Apply` rewrites `s.x/y` (Boats.lua:26), but Engine's `worldOf` cache (Engine.lua:531) keeps the old world coordinates. This is the "stale targets after route switches" class.

**C3. Event fan-out and context-free timers.**
- `FR_ROUTE_CHANGED` has 10 listeners and `FR_STATE` has 6, including two separate `Refresh` calls (Engine.lua:311, 751).
- A route switch schedules inserts at +0.5 s (:753), the merge at +0.6 s (:728) and an arrow re-target at +0 s (Arrow.lua:244). At load the schedule is +3, +3.5 and +4 s, plus refreshes at +1 and +3 s.
- The callbacks act on whatever `ForeverRouteData` is current when they fire, so a second switch inside the window hits the wrong route. That is the mechanism behind "hand-ins inserted into side trips" (patched by a route-type check at :736) and "merge not re-running" (patched with the `_merged` flag on the list, :689).

**C4. Scattered mutable state and in-place route mutation.**
- Runtime state is spread over:
  - `Engine.current/planned/focus/view/lastTrip`;
  - `Arrow.aboard/hiddenFor` and the local `target`;
  - `Card.planReady/lastRow`;
  - module locals such as `lastHave`, `onTaxi`, `batch`, `keyCache`, `prereqOf`;
  - `ns.char.skipped/manualDone/history`, which are aliases into `progress[rid]` (Core.lua:211).
- Route tables are edited in place by `InsertStop`, `Boats.Apply` and `MergeSideTrips` (`steps._merged`). `SelectRoute` drops steps only for packed routes (Core.lua:198).
- So inserted stops survive a route switch in memory but not a `/reload`. They are then re-derived from a different position and can land somewhere else.
- `FR_ROUTE_CHANGED` resets only `focus` and `lastHave` (Engine.lua:615).

**C5. Layering is inverted, and rendering has side effects.**
- `TravelFor` reads `ns.Arrow.aboard` (Engine.lua:428) and writes both `Engine.lastTrip` and `Why` on every call. The Card calls it for the viewed step, and the arrow learns docks from `lastTrip` (Arrow.lua:113).
- Live reordering runs only from the arrow's `OnUpdate`, after `if not target then return end` (Arrow.lua:104, 124). A hearth, grind or note step, or a boat ride, switches it off.
- `Offers.Current()` is called by `Card.Layout` and writes `ns.char.dingLevel/dingAt` (Offers.lua:61). Whether a ding counts as shown depends on whether a layout ran before the +1 s timer of `PLAYER_LEVEL_UP`. That is the shape of "silent at 20".

**C6. Fixes are local, so the same rule ends up in several copies.**
- The up/down hint is gated on `Arrow.Indoors()` in the arrow (Arrow.lua:154). The card still prints "up/down N yd" with no indoors check (Card.lua:363).
- `Pins.Near` gates minimap pins, but the path dots go to the minimap unconditionally (Pins.lua:315).
- `Engine.Available` checks chain prerequisites only for reordering (:553), not in `InsertStop` or `MergeSideTrips`.

**C7. The tests check units, not the running pipeline.**
- 39 tests save and restore globals by hand, each with its own fake world.
- No test advances time, so no `C_Timer` callback ever runs, although the simulator supports `async_test`. The whole cascade in C3 is untested.
- No test compares components with each other. "every step renders" (:57) only checks for no errors.
- The merge test inserts a travel step "the order must hold too" (:1317-1318) and then asserts nothing.

| Bug | Cause |
|---|---|
| boat: arrow back at the departure dock | C1, C5 (re-plans from mid-sea; no trip-in-progress state) |
| boats-only, 9.2k ride, danger ride, fly+hearth | C1 |
| hand-ins in side trips; merge not re-run | C3, C4 |
| chained stop before its prerequisite; Chef Grual; reorder ignoring flight-path steps | C6, C5 |
| far pins on the player; up/down outdoors | C6 |
| flight-path step ticked at another zone's flight map | C3 (an event's meaning depends on context) |
| silent level-up; XP label on the wrong trip | C5, C4 |
| stale Card/arrow; path swapped on reload | C2, C3, C4 |
| reload prompt constantly | `PlaySoundFile` signal not injectable, so not testable |
| wall-of-text card | the note is one concatenated string from a priority chain |

## 2. Cleaner runtime, done incrementally

**A. Generation counter (about 20 lines).**
- `Engine.gen` is bumped by `InsertStop`, `SelectRoute`, `Boats.Apply` and `MergeSideTrips`. Each bump also clears `keyCache` and `worldOf`.
- The Pins key and the arrow's early return include `gen`. The arrow compares the step table, not the index.
- Timers capture `gen` and drop themselves if it has changed.

**B. One travel function.**
- `Travel.For(step, from)` returns `{legs, target, label}` and replaces `TravelPlan`, `TravelTarget` and `TravelFor`.
- Fold the ride/fly heuristic into the Dijkstra graph: a "first stop" node, plus the flight masters on the player's map.
- Cap ride length whenever an alternative exists.

**C. Navigation model.**
`Nav.Compute()` runs after `Refresh`, on zone change, on a leg change and when boarding or leaving a boat. It produces:
```
{ gen, step(ref), index, title, details{}, notes{{kind,text}}, trip={legs,leg,aboard}, target={m,x,y,r,label}, pins{} }
```
Card, Arrow, Pins and ShowOnMap render only this, via `FR_NAV`. Typed `notes` rows fix the wall-of-text card.

**D. Motion module.**
- Move speed, `aboard` and `onTaxi` from Arrow into `State.Motion`.
- One 1 Hz ticker drives `UpdateFocus`, `Arrived` and the Boats tick, whether or not the arrow has a target.
- Trips have explicit progress: boarding means leg k is done and the trip is pinned to leg k+1 until landing.

**E. Lifecycle and scheduler.**
- Events only set dirty flags.
- One coalesced `Engine.Tick()` runs a fixed order: state → `Boats.Apply` → inserts and merges → `Refresh` → focus → nav → render.
- `Engine.SwitchRoute(r)` resets every piece of transient state, bumps `gen` and runs the pipeline synchronously. It replaces the 10 listeners and their timers.

**F. Derived, idempotent step lists.**
- `r.steps` stays read-only. Decided inserts are stored per route as `{key, afterKey, step}`.
- `effective = derive(base, inserts, docks)` is rebuilt on each `gen` bump, so inserts survive a reload in the same place and replaying them changes nothing.
- The prerequisite check moves inside `InsertStop`.

**G. Pure rendering.**
- The ding bookkeeping moves to the `PLAYER_LEVEL_UP` handler.
- `Why` and `lastTrip` are written only by `Nav.Compute`, and only on change.
- The ready-signal probe becomes injectable (`Card.ReadySignal`).

## 3. Test strategy

### Harness (`tests/harness.lua`)
- **Setup and teardown.** `Sim.new{level, pos, quests, completed, taxi, routes, indoors}` fakes:
  - `State.Quest/IsCompleted/OnQuest/Position`, the HBD position and conversion functions, `C_Map.GetMapInfo`;
  - `UnitLevel/XP/OnTaxi`, `IsIndoors`, `GetBindLocation`, `GetTime/time`;
  - `C_Timer.After/NewTicker`, through a virtual-clock queue.

  `sim:done()` restores everything automatically.
- **World fixture.** `tests/world.lua`: zone offsets and continents generated once from the planner's zone data, replacing the per-test `off` tables.
- **Verbs.**
  - `advance(sec)` runs due timers and the ticker;
  - `walk(m,x,y,speed)` ticks the arrow driver (expose `Arrow._tick`);
  - `zone(m)`;
  - `accept/progress/complete/turnin(q)`;
  - `openTaxi{}`;
  - `fly(to)`;
  - `boat(a,b)` moves at 25 yd/s with no taxi;
  - `levelUp(n)`;
  - `switch(id)`;
  - `reload()` keeps the saved variables, calls each module's `_reset()`, refires `ADDON_LOADED`/`FR_LOADED` and advances 5 s.
- **Observers.**
  - `card()` gives plain title, detail, note and rows;
  - `arrow()` (expose `Arrow._target`);
  - `pins()` (expose `Pins._used`);
  - `why(kind)` wraps `ns.Why`, bypasses the 120 s dedupe and returns new entries.

### Invariants, checked inside every `advance`
1. **Coherence:** the arrow's step is the shown step (by identity). Pin #1 equals the arrow's target, or the current trip leg. The card title matches the shown step or leg 1.
2. **Travel safety:**
   - no ride with an endpoint in, or a segment sampled across, a zone with `ZONE_MIN > level + DANGER_ABOVE`;
   - no ride over 3000 yd when a flight or boat exists;
   - legs are contiguous;
   - no flight leg crosses continents.
3. **Chain order** in the effective list: accept, then obj, then turnin. For each `p` in `prereqOf[q]` that is present, turnin(p) comes before accept(q). No duplicate inserted `(k,q)`.
4. Special and dungeon routes hold no `applyInserts` hand-ins.
5. **Idempotence:** running `ApplyInserts` and `MergeSideTrips` a second time returns false and leaves the list unchanged.
6. **Switching:** `A → B → A` gives the same observers as a fresh `A`, `focus == nil`, and no references to B's steps.
7. Minimap pins and dots appear only within `NEAR_YD`.
8. **Why:** no `reorder` entry names a step for which `Available()` is false. Every `insert` entry's index holds that step afterwards.

### Scenario tests, one per reported bug (about 15 lines each)
- **Boat crossing:** Stormwind with a Barrens hand-in. "Boat"; walk to the dock; board; mid-sea the arrow is "aboard", not pointing at the departure dock; land; leg 2.
- **Danger:** Theramore at level 21 → the Barrens is a flight. Westfall → Redridge at 12 without flight paths is not a 9 km ride.
- **Side trip:** enter it, complete a quest, advance: nothing inserted. Leave and re-enter: the merge re-ran and gives an identical list.
- **Chef Grual:** standing at Grual before Jitters' quest is in: no focus.
- **Flight map in Westfall:** the Duskwood flight-path step stays open.
- **Insertion at the current index:** the arrow and pins follow the new step. This fails today (C2).
- **Reload:** the same shown step, path and insert positions.
- **Level-up:** `levelUp(20)` gives a row and a chat line containing "Level 20".
- **Ready signal:** an injected "empty file" probe shows no row.

### Property sweeps over the real Route.lua
With a fixed seed:
- For each route and step, place the player at the previous step and check invariants 1, 2 and 7.
- For random `(level, taxi subset, position)` tuples, run `Travel.For` and check invariant 2.

This turns "every step renders" from "no errors" into "consistent and safe".

### Player reports become fixtures
`State.Snapshot` already saves position, level, the quest log, completed quests, taxi, `routeId` and `routeStep`, and Why and chat are in the saved variables. Add `Sim.fromSnapshot(snap)`, plus a tool that copies the snapshot and the last 30 Why lines into `tests/fixtures/<bug>.lua`. Every in-game report then starts as a failing test, and the Why lines point at the wrong decision.

## 4. Ranking (bugs prevented ÷ effort)

| # | Proposal | Effort | Prevents |
|---|---|---|---|
| 1 | Quick fixes: Card up/down outdoors (Card.lua:363), minimap path dots (Pins.lua:315), `worldOf` after `Boats.Apply`, the missing merge-test assertion | XS | 3 latent repeats |
| 2 | A. `gen` counter plus timer guards | XS | stale arrow/pins, timer races (~4) |
| 3 | Test accessors plus invariant 1 in the existing all-steps loop | S | Card/Arrow/Pins disagreements (~6) |
| 4 | Harness: virtual clock, auto-restore, world fixture | M | event and timer ordering (C3, ~5); enables the rest |
| 5 | Travel invariants plus the property sweep | S after #4 | the 4 travel bugs |
| 6 | Chain-order and idempotence invariants; prerequisite check in `InsertStop` | S | chain and merge bugs (3) |
| 7 | Snapshot→fixture plus Why capture | S–M | future regressions |
| 8 | B. one `Travel.For` | M | C1 for good |
| 9 | E. lifecycle and scheduler | M | side-trip, reload and stale-state bugs (~4) |
| 10 | C+D. Nav model and Motion | L | the C1, C2 and C5 classes; a Card that can be tested as data |
| 11 | F. derived, persisted inserts | L | insert drift after reload |

Do 1–7 first. They are cheap, and they put a harness in place that guards the refactors in 8–11.
