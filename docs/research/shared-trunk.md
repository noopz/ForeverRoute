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
