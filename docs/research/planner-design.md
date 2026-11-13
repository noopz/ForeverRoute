# Planner design review: why the eye keeps beating the planner

Scope: tools/route2.js, optimize.js, campaign.js, paths.js, ensure-steps.js, lint-route.js, autoplan.js (commit 7152156).
Read-only review. Line numbers are from that commit.

## Root cause

The world gets modelled **five times**, and each model trusts the one before it:

1. **The route2 sim** (l.364-598) picks the quests, levels up, binds, hearths and grinds. It also **writes the leg's end state** (`stateOut`, l.601).
2. **optimize.js `makeEval`** reorders the sim's events with a different cost model.
3. **writeRoute** (l.712) re-derives level, hearth, bind, FP and training for the steps the player actually sees.
4. **campaign.js** ranks zones with flat costs (`hop()` l.52) and chains legs using the state from (1).
5. **Post-passes** (`carryDeliveries`, the dedupe at campaign l.373, `ensureSteps`, `flyLater`) edit the steps with no model at all.

lint-route.js has its own thresholds, and nothing runs it. Every bug listed is either a disagreement between two of these models or an edit no model checks.

## 1. Wrong or inconsistent assumptions, and the bugs they cause

| Assumption | Where | Bug class |
|---|---|---|
| The next leg starts from the **sim's** state, but the player follows the **optimized** order | route2 l.601-608 writes `stateOut` before `optimize` (l.642). campaign l.335 chains it | Wrong start `pos`. The level includes sim-only **grind** XP (l.595 is never an event). Minutes ≠ the route's |
| Side-zone pickups are dropped from the optimizer but kept in the sim state | route2 l.651-655. Their `do` events stay (l.660). `accepted` → `stateOut.active` | Ghost quests in later legs. ensure l.59-62 re-adds their accepts, which brings back the Stormwind detour |
| Three level models, different thresholds | sim `canAccept` l.351 (+2). `tooHigh` l.350 only when `kills>0`. optimizer `reqLevel` l.656/662. writeRoute l.797. lint l.21-22 (**+3**) | Lint passes quests the planner refuses. Object/explore objectives in high camps are never checked. Carry/ensure inserts have no `lvl` |
| Chained XP is quantized | campaign l.335 (5%/leg). `looseView` l.88 (**25%**) | Level drift. A loose cache hit can level you up to 25% early (The Night Watch, early Duskwood) |
| The loose leg cache trusts the cached state | campaign `run()` l.103-110: `completed` = cached ∪ real, `active` = the cached run's. `looseView` drops `start` and quests outside the zone | Invented completions, lost cross-zone progress, re-accepts that l.373 only half removes (the objective steps stay). This is the **repeated objectives** / **forgetting completions** bug |
| The capital rides along in every leg, and a hop inside a leg costs about 2 min | `legConfig` l.195 adds 1519. `travelSec` l.92-98 = walk + 120 s. `hop()` = 12 min | Stormwind looks cheap to `bestHub` l.486 and `hearthValue`, which gives **mid-zone Stormwind detours and the Stormwind hearth**. The `mainHub` fix (l.522) only patches the sim |
| Fly anywhere | `FLIGHT` = the first flight master (l.87). `cfg.flightPaths` is **never passed** (only read at l.333/717). No-FM zones cost a flat 600 s | Flight paths you don't have, "learn FP" for known ones, no boats/danger/ride modelling |
| Hearth resets every leg | writeRoute l.763. The leg joins (campaign l.343-365) ignore the hearth. `train` doesn't move `here` (l.804) | Two hearths inside the cooldown, fly+hearth duplicates (patched in ensure l.96), missing hearths |
| Optimizer log starts at 0 | optimize l.18, cap hard-coded at 20. The sim's `maxLog` (l.376) ignores `passActive` | Log overflow |
| Optimizer work ≠ sim work | sim shares work at one spot (l.412). The optimizer sums it. Shared drops cost 0 and can come before their kills. `preSingle`>1 is dropped (l.656) | Batches split apart. Zone ranking uses the sim's minutes (evals run `optimize:false`, l.294) |
| Hubs decide what gets visited | `bestHub` scores only `realHubs` (l.313). Lone NPCs only within `detourYards` (l.467-469) or via `workLoners` once the loop is empty (l.567) | Dropped lone hand-ins (Raene's Cleansing), poor ordering around them |
| Greedy + look-ahead + beam on inconsistent sim minutes | `lookaheadPick`, `beamSearch`. `candidates` l.39 has no notion of danger | A zone too early (Duskwood) |
| No gate before install | autoplan `check()` l.70-80 is structural only. lint checks only the first path, skips packed branches, and nothing calls it | Every bug reaches the player first |

## 2. A sound formulation, built incrementally from what exists

### 2a. One world module (`tools/world.js`), imported by every stage
- `XP_TO_LEVEL`, `questXpAt` and `killXp`, which are copied today in route2, optimize l.36, campaign l.388 and paths l.29.
- `gate(state, step)` with **one** `MAX_ABOVE = 2`. It covers accepts, objectives of every kind (for object/explore objectives, the highest hostile spawn level in the area) and location danger.
- `Travel`, a small graph. Nodes: flight masters, inns, docks, zone entrances. Edges: `fly` only between **known** FPs (seeded from `st.taxi`), `walk`, `boat`, `hearth` (state-dependent), and `ride`, with a `danger(zone, level)` block (for example Dustwallow below 35). `cost(a, b, state)` returns seconds plus the travel steps. route2 `travelSec`, campaign `hop()` and the leg joins (campaign l.343-365) all use it.

### 2b. One state, one transition function
```js
State = { level, xp, clock, pos, log: {qid: {objDone: bool[]}}, completed: Set, fpKnown: Set,
          hearth: {at, readyAt} | null, trainedAt, sharedProgress: {qid#obj: frac} }
apply(state, step) -> { state', violations[] }    // pure; uses world.gate + world.Travel
```
- **Steps are the only currency.** The sim becomes a *proposal generator* (which quests, in what initial order), and grind and train become real events. writeRoute serializes `fold(apply, start, steps)`, and travel, hearth and bind steps come from `Travel.cost` while folding.
- **`stateOut` = the fold over the emitted steps**, never the sim's variables.
- **The optimizer cost = the same fold.** Use a precomputed `D` from `Travel` plus an inline hearth option, and any violation costs Infinity. The log count starts at the real log size. Shared drops come after their source kills, and work at one spot is shared the way the sim shares it.

### 2c. Campaign
- Chain legs with the exact folded state. Quantize only inside eval cache keys.
- Treat a loose cache hit as a candidate only. Re-fold its steps from the **real** start and accept it only if nothing is violated. Use the re-folded state, and delete the union at l.107.
- Replace "1519 in every leg" with a **city-visit node** that the campaign inserts when training is due or deliveries pay off, costed by `Travel`. `carryDeliveries` and the here-leg become its quest list.

### 2d. Hubs only for presentation
Visiting is per NPC. Every eligible task is either scheduled or skipped with a reason. `never` (l.636) with "unreached" fails lint.

## 3. Hard invariants (lint-route plus asserts in the fold). "Broken by" = current code that can violate it

1. **Accept before progress** (unless the quest is in the starting log). Broken by: `sideOnly` (route2 l.651), loose-cache plans.
2. **No re-accept or repeated objective while a quest is open.** Broken by: the loose cache's `active` (campaign l.103-110). l.373 removes only the accept.
3. **Level**, where L = the folded level from the real start: an accept needs q.level ≤ L+2 and reqLevel ≤ L, and any objective needs mob/area level ≤ L+2. Broken by: xp rounding (campaign l.88, l.335), grind XP left out of the steps, the `kills>0`-only check (route2 l.350/662), unchecked carry/ensure inserts, and lint's +3.
4. **Exactly one travel step (or one boat chain) between steps on different maps**, and its destination = the next map. Broken by: `train` counted as travel without moving (ensure l.93), `flyLater`, leg joins.
5. **Feasible travel**: you can only fly to a known (or already learned) FP, and never through a blocked zone. Broken by: `cfg.flightPaths` is never set.
6. **Hearth**: a bind comes first, the destination = the bind, the cooldown counts across legs, and no fly+hearth to the same place. Broken by: route2 l.763, the sim/writeRoute bind mismatch.
7. **Log ≤ 20, counting quests from other zones.** Broken by: optimize l.18, route2 l.376, carry inserts.
8. **Every objective comes before its turn-in, at the real objective spot** (ensure l.70 puts them at the turn-in index).
9. **Prerequisites**, including `preSingle` with several options. Broken by: route2 l.656.
10. **Closure**: every accept is turned in or explicitly carried, and every eligible quest is scheduled or has a stated reason. Broken by: ensure l.48-50, hub-gated visiting.
11. **Training** happens on the trainer's map, with travel there and back. Broken by: writeRoute l.799-804.
12. **State continuity**: leg k+1's start = the fold of leg k's emitted steps. Broken by: route2 l.601 combined with campaign l.335.
13. **Determinism**: the same input gives the same steps. Broken by: the cache depending on what is in it (loose matches), and a leg whose search hits the optimizer's safety cap (optimize.js anneal, stopAt; cfg.optimizeCapSec, one deadline for the leg's whole search): route2 says OPTIMIZER CAP, campaign logs it and keeps that leg out of the cache. (2026-11-12: the wall-clock budget this item first named is gone - the work is a number of moves in a fixed number of runs, optimize.js workFor/RUNS, not seconds and not one run per core; the cap is far above a normal search.)

Lint every route (including packed branches, dungeon routes and specials) in paths.js after `ensure()`, and make autoplan `check()` refuse the install on 1-7, 9, 11 or 12.

## 4. Proposals ranked by bugs prevented / effort

| # | Proposal | Effort | Prevents |
|---|---|---|---|
| 1 | **Lint as a gate.** Port the invariants to a `checkRoute(steps, startState)` fold, run it in paths.js on every route, and block the install in autoplan. Use one `MAX_ABOVE` | S (1 day) | Catches every class above before you do. Whatever the planner still gets wrong becomes a failing check instead of a bug report |
| 2 | **Fix the loose cache**: exact keys for real legs; re-fold and validate on loose hits; no `completed` union | S | Repeated objectives, invented or forgotten completions, levels skewed by up to 25% |
| 3 | **`stateOut` from the emitted steps** (fold in writeRoute), grind/train as events, drop the 5% quantization, drop the `sideOnly` ghosts from the state | S-M | Wrong start position, level drift between legs, ghost quests and their Stormwind accept detours |
| 4 | **`world.js`**: shared xp/level gates (including object/explore area level), with the log count started from the real log | S-M | Too-high quests and objectives (all three level estimates), log overflow |
| 5 | **Pass `st.taxi`/`st.bind` into route2**; hearth state carried across legs; one hearth/fly emitter | S | Wrong FP steps, missing or duplicate hearths, two hearths inside the cooldown |
| 6 | **Travel graph** (known FPs, boats, danger blocks) used by `travelSec`, `hop()` and the leg joins | M-L | "Fly anywhere", the in-leg vs between-leg cost skew, unsafe rides, Duskwood too early (with the danger term) |
| 7 | **Capital as a city-visit node**, not a ride-along zone | M | Stormwind detours, Stormwind hearth, side-zone pickup hacks (route2 l.648-653, mainHub l.522, `flyLater`) |
| 8 | **Optimizer cost = the shared fold** (hearth/train/log/shared work/precedence for shared drops) | M | Optimizer/sim/writeRoute order disagreements. Batched objectives stay batched |
| 9 | **Per-NPC visiting** (hubs only for display) plus the closure invariant | M-L | Silently dropped lone hand-ins, "pick up in the town you stand in" |
| 10 | **Forever drop-rate prior**: trust `observedDrops` with fewer kills (Bayesian blend), and keep a curated override table for known Forever changes | S | Bad drop counts (Blackrock Menace) |

Start with **1-3**. They are mostly deletions and one shared fold function, and they turn "the player catches it by eye" into "the build refuses to install it". Then 4-5. Items 6-9 are the real model work, and they become safe to do once every stage is graded by the same fold.
