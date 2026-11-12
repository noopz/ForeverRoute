# Live routing: what to do next

How the addon decides the step on the card, why it works this way, and what's left to do. Code: `addon/ForeverRoute/Horizon.lua` (the solver), `addon/ForeverRoute/Next.lua` (candidates, travel, hysteresis, reasons), the hook in `Engine.RefreshInner`. Planner side: `tools/route2.js` (`chainTail`, `awayHubShare`).

## The problem

Levelling by quests is a **pickup-and-delivery problem with prizes**, solved twice:

- **Offline (the planner).** It chooses which quests to do and in what order, from level 1 to 60.
  - A quest is a request: picked up at its giver, its objectives worked, delivered at its hand-in.
  - The quest log is the vehicle's capacity: +1 on pick-up, -1 on hand-in.
  - Chains are precedence.
  - XP is the prize. It shrinks as you outlevel the quest, so it depends on the path taken.
  - Travel is multimodal: walking, flights you must first discover, boats, and a hearthstone with a cooldown.
- **Live (the addon).** The same problem, re-solved continuously as the player deviates: steps done out of order, quests picked up or skipped, deaths, a quest-giver that has nothing, and the player starting mid-way. This is dynamic vehicle routing.

What WoW adds:
- **Interruptions that don't end the plan.** You go back to town because your bags are full, you go off to group for a dungeon, or you train in a capital. You come back.
- **Opportunistic moments.** You're in a town for one reason and have hand-ins there. A guide that says "while you're here: hand in X" feels like a guide.

## Where we were (before)

There was one global step order, scanned from step 1 on every refresh, and patched by about 30 rules:
- statuses: behind you, outlevelled, gray, breadcrumbed, hearth passed, went ahead, flight to nothing;
- reordering: standing at it, ready close by, progress;
- insertions: finished quests' hand-ins with no cost limit, side quests, side trips.

Each rule had its own radius or threshold, and cost appeared only in isolated places. **Nothing ever compared "do this now" with "do something else" in time.**

The "sent to Stormwind for one hand-in" reports had several causes:
1. **The plans themselves.** Every Alliance plan had 21–29 capital stopovers with at most one hand-in. The planner's guard for trips to another zone's hub (`awayHubShare`) had no default, so it was off.
2. **Passed hearth steps.** When you weren't bound there, the hearth was passed but its destination kept.
3. **Unbounded insertion of finished off-plan hand-ins.** A single-stop city visit couldn't absorb them, so they became round trips.
4. **A built-in-plan player ahead of the plan** pulled back to an old hand-in.

## The live algorithm (now)

**Rolling horizon** (receding-horizon / model-predictive control, as in dynamic vehicle routing):
1. From the true state (position, quest log, statuses), solve a small problem over the next stops.
2. Show the first stop.
3. Re-solve when something changes: a quest event, 30 yards of movement, or 5 seconds.

**Candidates** (`Next.Pick`):
- **Planned:** the plan's next doable located steps (pick-up, objective, hand-in, flight path, train, bind), up to 14.
  - Steps that are travel (fly, hearth, boat) aren't stops. Travel is costed between stops instead.
  - A step without a place (grind, note) or a "go to" step (a dungeon run) ends the window. It stays where the plan has it.
  - While the plan's next step is a trip, the trip is the step.
  - A pick-up not yet offered (an earlier chain quest not handed in) isn't a candidate.
- **Optional prizes:**
  - Finished quests whose hand-in is within 500 yd, wherever the plan has them. Prize = what coming back later costs: the hand-in, 30 s for carrying it, and the detour from the plan's own way.
  - Stops the route inserted for off-plan quests. Prize = the quest's XP at your XP rate.

- **The hub loop (the dopamine factor).** Quest for a good while, return to a hub, hand in a pile and watch the XP bar climb: WoW is built around that loop, and the guide sets it up rather than chipping it away. An early hand-in (one the plan has further on) is offered only at a hub or where its chain goes on right there.
  - A hub is a place with 4 or more plan steps within 70 yd (`Next.HUB_STEPS`, `Next.HUB_YD`).
  - Its chain goes on there when the quest it opens is picked up within 150 yd.
  - A lone hand-in in the field waits for the plan's hub visit.
  - The card names a hand-in run of 3 or more: "Hand-in run here: 6 quests, about 8,400 XP" (`Next.Batch`).
- **Room for the player.** Plans hold at most 30 quests (`maxLog` = 40 - 10 in `route2.js`), leaving 10 log slots for dungeon quests, stragglers and anything else the player picks up. The live solve uses the game's real limit, and those quests count in the load.
- **Errands as prizes.** With your bags nearly full or your gear wearing out, this map's three nearest vendors (repairers for repair). Prize by free slots: 0 = 900 s (every kill's loot lost), 1 = 500, 2 = 300, 3 = 200, 4 = 120, 5 = 80, 6 = 50. Repair adds 120-720 s below 35% durability. The solve fits the visit where it costs least. The card shows the plan's step, and the errand line names the vendor and when ("now - it's on your way" / "after the next 2 stops").
- **Chains live.** A quest below you (outlevelled, or a gray hand-in) stays while its chain leads to a quest still worth XP to you (`Engine.LeadsToWorth`). A quest the chain leads to that is not on this plan counts as worth it.

**Cost model.** One currency, seconds:
- **Travel:** straight-line yards × 1.25 ÷ your speed. Past 900 yd or across the sea, the trip planner's time (flights, boats, hearth), remembered per pair of steps until you learn a flight path.
- **Service:** accept 8 s, hand-in 10 s, objective 90 s, flight path 15 s, train 40 s, bind 15 s.
- **The plan is the cost-to-go.** A window is scored by its own time plus the time to finish the rest of the window's planned stops in plan order from where it ends, then on to the plan's first stop past the window (the anchor). Plan order skips any stop that can't be done yet (pick-up first, log room). That is the real length of the route from here, so a reorder wins only when it really is shorter.
- **Deferral is an option.** A prize not taken is left for later at no cost, which is exactly what the prize says it's worth. A hand-in across the world isn't worth the trip (its prize is about a minute); one beside you is.
- **Stability.** Passing over a planned stop costs 45 s, scaled by how far the chosen stop takes you (in full at 60 s or more). Doing what's right here isn't the confusing kind of out of order; being sent somewhere else is (Fox et al., plan stability).
- **Capacity:** a pick-up never takes the log over its maximum.

**Search.** A beam over sequences of up to 6 stops with states merged (restricted dynamic programming: same stops done, same last stop means one state, and the better one is kept), 60 kept per depth. 24 candidates solve well under 250 ms in the simulator, and the real window is smaller.

**Hysteresis.** A new pick must beat keeping the current one by 40 s, or the card stays (no flip-flopping as you walk). A "while you're here" prize bypasses the margin: it's an interrupt on the way, not a change of course.

**What the player is plainly doing wins.**
- A later step your kills or loot count for, held for 90 s after the last.
- A step you chose (Do it now).
- The plan's own step while it's counting: a circle you wander into doesn't take over.

**Explanation.** The card's dim line under a step picked out of plan order says why ("while you're here - it saves coming back for it later" / "on the way - the whole route from here is shorter this way") and the plan's next step. `Next.Deferred()` lists the finished quests left for later. `/fr why` logs each pick with its reason.

**Off switch.** Options: "Choose the next step from where I am" (`smartNext`, on by default). Off brings back plan order and the old reordering rules. Their tests run in that mode.

## The planner (offline) changes

- **Chain value** (`chainTail`). A quest is worth what it leads to: the XP of the quests it opens, 0.6 per step deeper, leaving out those done or not for this race, class or level (the precedence-constrained knapsack: a predecessor's worth is set by its successors). Used in three places:
  - hub choice: a capital hand-in that opens a chain is worth the trip;
  - a leg's reward value: zones that move chains on score higher;
  - the frustration cut: a mildly annoying first part of a valuable chain stays.
- **`awayHubShare` = 1.0.** A trip to a hub in another zone must earn at least the XP rate the leg has been making, or it waits until the route passes it.
- **Measured on the human warrior plan:** 133.1 h → 128.2 h to level 60. City-only stretches fell from 42 to 36. Most of the rest pair a hand-in with class training, which you must make anyway.

## Verified

- Solver tests (`tests/horizon_test.lua`):
  - no far trip for one hand-in;
  - "while you're here";
  - plan order kept unless really shorter;
  - log capacity;
  - pick-up before objective before hand-in;
  - speed.
- Engine tests (`tests/next_test.lua`):
  - a hand-in at the NPC far down the plan;
  - a far off-plan hand-in deferred;
  - back to town with full bags: the town's hand-in, then the plan from there;
  - town flight path and pick-ups first;
  - Chef Grual's chain;
  - farming the plan's own step;
  - hysteresis;
  - the off switch.
- Replays of a real save (`tools/replay.js --matrix`):
  - logging in in Stormwind or Ironforge now shows that city's finished hand-in instead of a trip back to the Wetlands;
  - a full log shows a hand-in, not an impossible pick-up;
  - 0 scenarios flagged, against 1 before.
- Replays of the built-in plan: no new problems flagged. The remaining flags are the known "leaves work" metric.

## Next (in order of value)

1. **Chain commitment live.** Add a started chain's remaining value as soft commitment so the live rules can't drop its next part.
   - Precompute chain value per stage offline and ship it with the plan.
   - Exempt in-progress chains from Outlevelled and BehindYou.
2. **"Why not X?"** Re-score with X forced first: one solve, and show the difference in minutes. The solver already supports this (`first`).
3. **The interrupt channel in the UI.** Show "while you're here" as its own dismissible line over the main target, as the research recommends, rather than replacing the card's step.
4. **Offline search upgrade.** ALNS with chain-level moves (remove or insert a whole chain, truncate its tail) over the zone legs, plus a sliding-window pass across leg seams (POPMUSIC). Evaluate whole routes by simulation, since XP depends on the path.
5. **Learned service times** (objective time and drop rates) from the community data channel, in place of the flat 90 s.

## Sources

- Ropke & Pisinger, *An ALNS heuristic for the PDPTW*, Transportation Science 40(4) 2006.
- Vansteenwegen et al., *The orienteering problem: a survey*, EJOR 209(1) 2011; Gunawan et al., EJOR 255(2) 2016.
- Pillac et al., *A review of dynamic vehicle routing problems*, EJOR 225(1) 2013.
- Fox, Gerevini, Long & Serina, *Plan stability: replanning versus plan repair*, ICAPS 2006.
- Malandraki & Dial 1996 (restricted DP); Kool et al. 2022, *Deep Policy Dynamic Programming*.
- Kellerer, Pferschy & Pisinger, *Knapsack Problems* (precedence-constrained knapsack).
- Sutton, Precup & Singh, *Between MDPs and semi-MDPs*, AIJ 1999 (options, interruption).
- Diehl, Bock & Schlöder 2005 (real-time iteration: warm-started, one step per sample).
- Ichoua, Gendreau & Potvin, Transportation Science 2000 (diversion).
- Miller, *Explanation in AI*, AIJ 2019 (contrastive explanations).
