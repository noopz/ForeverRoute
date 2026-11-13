# One leveling trunk per faction (experiment, 2026-11-12)

The 51 built-in plans largely overlap after the starting zones (Alliance pairs, levels 21-50: 74-85% of quests and
80-87% of zones shared, ~90% of shared quests in the same order; Horde similar). Question: can races start in their
own zones and then join one shared trunk, with class quests and training as branches - and what does it cost?

Method: `tools/splice-trunk.js <target> <trunk> --at L` keeps the target's own steps below level L, then the trunk
plan's steps from L (minus quests the start already did, minus the trunk class's own quests and training), with the
target's own training and class-only quests put in where their level falls. `tools/score-plan.js` scores hours to 60
the planner's way (quest + kill XP by level, work, grind to 60 at the planner's flat 22 s per kill) plus the simulated
player's riding + flying hours (`simplay.js` with `FR_SIM_PLAN`). Absolute hours are below the planner's own figure (it
counts overheads this doesn't); only the comparison matters.

| class | own plan | human warrior trunk @20 | dwarf hunter trunk @20 |
|---|---|---|---|
| dwarf hunter | 95.5 h | 98.6 h (+3.2%) | (own) |
| gnome mage | 93.0 h | 93.4 h (+0.4%) | 90.5 h (-2.7%) |
| night elf druid | 95.2 h | 98.3 h (+3.3%) | 95.0 h (-0.2%) |
| human priest | 97.4 h | 97.8 h (+0.4%) | 96.2 h (-1.2%) |

All spliced plans played 1-60 by the simulated player with no broken check. A sweep of join levels 15/20/25/30 (work +
grind only) moved results by under 1 h; the trunk's source plan matters far more than where you join it.

Findings:
- A shared trunk costs nothing: the best plan's trunk is as good or better for every class tried. The per-class plans
  differ mostly by optimizer noise, not class needs (the planner's kill time is the same for every class).
- So the cheapest big win is best-of-N: build each faction's plans as today, score them, take the best as the trunk,
  and splice every race start and class branch onto it. Rebuilds then simulate one trunk per faction plus the starts.

Open: the Horde run of the same; a trunk built as a trunk by the planner (race starts joining at the first shared zone)
rather than borrowed; Skyborne (their start is elsewhere); and whether the class branches should stay fixed steps or be
optional stops the live solver fits in (Next.lua already does that for inserted stops).

## Horde (same day)

Best Horde plan by work + grind: orc hunter (53.1 h; the worst, undead priest, 57.1 h). As the trunk from level 20:

| class | own plan | orc hunter trunk @20 | joined in the start's zone (`--join zone`) |
|---|---|---|---|
| tauren warrior | 96.3 h | 99.3 h (+3.1%) | 102.2 h (+6.1%) |
| troll priest | 95.6 h | 98.6 h (+3.1%) | 99.7 h (+4.3%) |
| undead priest | 96.4 h | not valid | not valid |

Work + grind improves on the trunk (about 22 h of grinding against 25-27 h), but travel gets 5-7 h worse, and joining
where the start left off makes it worse still (more of the trunk's early zones to cross). The undead runs are not
comparable: the simulated player acted on only ~1,460 of ~2,500 steps and finished at level 61 - it outlevels the
trunk's steps and skips them as gray (the spliced trunk carries the orc hunter's levels). No spliced plan broke a check.

So for Horde a borrowed trunk costs ~3%: over the 2% bar. Alliance gains, Horde doesn't - the Horde races' starts are
further apart (Tirisfal vs Durotar/Mulgore), and the trunk's own early legs assume an orc's position. A trunk built by
the planner from each race's level-20 state would answer whether that's the borrowing or the geography.

## Zone choices on the trunk ("weaving", same day)

`tools/weave.js <trunk> <leg> <zone>`: at one of the trunk's zone boundaries, plan one leg in a runner-up zone from
the trunk's own state there (campaign.js, `forceLegs`, ~4 s), then rejoin the trunk minus what that leg did (every
step of a quest it handed in, the pick-up of one it picked up), through paths.js `--reuse` (same safety net and walking
paths as a built-in plan, ~3 s). Dwarf hunter trunk, the unchanged trunk rebuilt the same way as a control (identical
to the shipped plan), all played 1-60 by the simulated player (clean persona):

| choice | side leg | work + grind | travel (ride + fly) | broke a check | left unhanded |
|---|---|---|---|---|---|
| trunk (control) | - | 54.5 h | 41.2 h | 0 | 39 |
| Westfall instead of Redridge @16 | 89 steps, 25 hand-ins | 55.2 h (+13 quests) | 41.3 h | 0 | 40 |
| Redridge instead of Westfall @21 | 23 steps, 6 | 54.5 h | 41.2 h | 0 | 39 |
| Wetlands instead of Duskwood @23 | 17 steps, 5 | 54.5 h | 41.2 h | 0 | 39 |
| Stonetalon instead of Wetlands @24 | 20 steps, 5 | 54.5 h | 41.3 h | 0 | 38 |
| Swamp of Sorrows instead of Arathi @35 | 17 steps, 5 | 54.5 h | 41.1 h | 0 | 39 |
| Feralas instead of Tanaris @41 | 13 steps, 6 | 54.5 h | 41.0 h | 0 | 39 |
| Searing Gorge instead of Hinterlands @46 | 22 steps, 5 | 54.5 h | 41.1 h | 0 | 39 |
| Western Plaguelands instead of EPL @54 | 17 steps, 5 | 54.5 h | 41.1 h | 0 | 39 |
| Winterspring instead of Silithus @57 | 25 steps, 8 | 54.5 h | 41.4 h | 0 | 39 |

Findings: every weave rejoins cleanly and costs within noise (travel +-0.2 h of 41.2). The trunk visits zones in short
pieces (~100 legs to 60), so a choice is mostly a reorder - the same quests, done earlier - not a different route. A
zone choice is ~7 s to build and needs no full replan, so a faction trunk can carry every runner-up within 80% of the
pick's xp/h (24 on this trunk) for every class. Next: offer them in built-in plans (paths.js branch records, which the
addon already shows as "where next?"), and weaves that chain (a second choice on a woven plan).

## The tree, built as a tree (plan, 2026-11-13)

Goal: one plan per faction that every race and class rides. Race starts converge onto one trunk, class work hangs off
it as branches that complete and rejoin, and everyone ends on the same rails. Fewer plans that aren't really unique.
Borrowing a trunk from one race's plan cost Horde ~3% because that trunk assumed an orc's position and an orc's early
quests. So the trunk is planned as a trunk:

1. **Race starts (leaves to roots).** Each race is planned from level 1 to the faction's join level J. J is where the
   race plans converge (Alliance ~20: Redridge/Wetlands/Ashenvale; Horde to be measured, with Tirisfal the outlier).
   One start per race, not per race x class. Class training stays in the start, because it's tiny below J.
2. **Trunk state at J.** Level J, completed = the quests *every* race start did (intersection), position = the first
   trunk zone. A quest only some races did stays in the trunk: the races that did it skip it as already done (the addon
   already does this), and the races that didn't get the zone it belongs to. Chains begun in one race's start
   (Westfall, Darkshore, Loch Modan) carry on in the trunk for everyone.
3. **Trunk plan, class-neutral.** campaign.js with `startStateFile`, class quests and trainer visits left out, quests
   restricted to some races left out. One plan per faction from J to 60.
4. **Class work is side quests, not joins** (the player's call, 2026-11-13). Like the Cozy Sleeping Bag: a class's
   quest lines (pets, stances, totems, forms, poisons, demons ...) are self-contained routes that open at a level, with
   little variance. They are the reviewed side trips (tools/reviewed-<faction>.json): an in-path one goes in at the
   first zone change once you can do it, the rest are offered as trips of their own. Training is a side quest too: you
   go when two ranks are waiting, or when you are in a trainer's town anyway (world.js trainNow). Race-only quests above
   the join level are left to the start and, later, race side trips.
5. **Weaves.** Zone choices on the trunk (weave.js) stay as offered alternatives that rejoin.
6. **Gate.** Every race x class combination (51) spliced and played 1-60 by the simulated player: no broken check,
   hours and grind minutes within 2% of its own plan, or better. Grind minutes are a primary metric (grinding is a
   failure).

Build cost: 2 trunks + 12 race starts instead of 51 full plans. Split between the PC and the Mac (trunks on one, starts
on the other). Sims stay on the PC.

### Tools

- `tools/tree.js <alliance|horde> [--join 20] [--exp name]`: plans each race's start to the join level class-neutral,
  builds the trunk state (quests every start handed in, quests every start still holds, the most common end zone), and
  plans the trunk from there to 60 as race `<faction>`, class `none` (world.js `raceFits` / `classFits`). Writes
  `tree/<faction>[-exp]/` with `summary.json` (hours and grind minutes per piece).
- `tools/tree-assemble.js <tree dir> <race> <class>`: one race x class plan: the race's start, the trunk minus what
  the start did, training by the trainNow rule, and the class's side trips put in by paths.js --reuse (no replanning).
- `tools/score-plan.js`: grinding priced the same way as the planner (world.js `grindSeconds`), so a plan that leaves
  XP short shows what it really costs.
- The planner writes each plan's end state (`path-0.json` `endState`), in the shape `startStateFile` reads.

## First trees (2026-11-13)

Alliance and Horde trees at join 20 (planner with honest grinding, the +3 gate from 20, carried chains): every race x
class assembles from its race start, the faction trunk and its class side trips. Scored the same way (quest work plus
grinding priced as people play, tools/score-plan.js), Alliance plans come to ~67 h against 129-195 h for their own
1.4.6 plans, Horde ~72 h against 112-132 h. Every race x class of a faction is within 0.7 h of the others: the trunk
decides. The simulated player played the assembled human warrior 1-60 with no broken check; its travel was ~8 h
more than the 1.4.6 plan's (77 wild revisits): the trunk zig-zags.

- Join level: 20 beats 12 for Alliance (67.3 h vs 72.5 h): the races' own content to 20 is worth more than an earlier
  merge, though all four are in Darkshore at 12-14.
- Zig-zag: the trunk takes ~110-150 legs to 60; 40 of 107 were "no zone has 5+ hand-ins" fallbacks. Settings don't fix
  it (hopMin is only a fallback - hops are priced by real travel; minTurnins 8 made more legs; a doubled revisit penalty
  ~1% better). It is the greedy zone choice: each leg takes what's in reach now. tools/zone-order.js gives a guide-like
  order instead (each zone once per chunk of its quests, at the level they come into reach, staying on one continent),
  fed to the campaign as forceLegs. Measuring.
- The level 44-48 gap (human): the quest XP to 60 is there (3.4M with their kills vs 2.5M needed), but at 44 none of
  it is in reach: the mid-40s zones were used at 40-43 the moment they came into reach, and what's left needs mobs
  48+. Grinding there is a real gap without dungeons or elite quests, so the grind step names the dungeons that fit
  the level (group for one instead: never forced).
