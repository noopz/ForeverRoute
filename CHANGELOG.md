# Changelog

## 1.4.4 - 2026-11-12
- A trip with an extra change (a boat, the tram, a portal) has to save real time to win: Refuge Pointe to Stormwind is the flight to Stormwind again, not a flight to Ironforge and the tram for 3 seconds less. The walk off the tram no longer reads "from Stormwind to Stormwind".
- "Not now" on the card for a stop the route fitted in from where you are (a hand-in while you're here, a quest just behind you): it goes back to the plan's next step, and offers the stop again once you've moved on.
- Every built-in plan rebuilt with each quest's expected time to do, so the next step weighs a quick quest nearby against a long one properly; each plan played from 1 to 60 by simulated players, none broke a check.

## 1.4.3 - 2026-11-12
- No more walking over the mountains from Dun Morogh into the Wetlands: the way there is through Loch Modan and Dun Algaz, and the arrow takes it.
- The Dalaran portal to Stormwind is one way: trips no longer count on a portal from the Mage Tower to Dalaran.
- Quest items in your bank (a rested-XP stash, or put there yourself): the card says to take them out, since the quest only counts what's in your bags.
- Setting your hearthstone at the plan's inn is recognised, so the route stops asking you to do it again.
- Hover a step in the list to see why it isn't the next one yet.

## 1.4.2 - 2026-11-12
- New option: take the flight your route needs when you talk to a flight master (Options, off by default; hold Shift to choose yourself).
- What to do next is now worked out from where you are: the plan's next steps in the order that makes the whole way shortest, and finished quests whose hand-in is close by ("while you're here"). Back in town to sell or to group up, the town's hand-ins come first; a hand-in across the world is left for when the route passes it. The card says why when it leaves the plan's order. (Options: "Choose the next step from where I am".)
- Bags nearly full (or gear wearing out): the vendor visit is fitted into your way where it costs least, and the errand line says which vendor and when. A quest below you stays on your route while its chain leads to quests still worth XP.
- The hub hand-in run: out in the field, a finished quest waits for the town the route returns to (unless its chain goes on right there), so you quest a good while and then hand in a pile at once - and the card names the run: "Hand-in run here: 6 quests, about 8,400 XP". Plans hold at most 30 quests, leaving 10 slots of your log for dungeon quests and anything else you pick up.
- Long quest chains are valued as a whole when plans are made, so their first parts aren't cut; a trip to a capital has to be worth it.
- Joining the built-in plan partway: quests right next to you that still give XP are offered instead of being skipped as "behind you", and a quest worth XP close by comes before a grind step.
- Quests count as gray by the game's own line (5 levels below you early on, more later): a level 7 is no longer sent to a level 1 quest.
- A quest its giver turns down at two different levels stays off your route; once, it's tried again a level on (Forever asks more than the quest data for some). No more "your path was switched" message when you've just finished a zone.
- Every built-in plan rebuilt with the planner fixes below, and each one played from 1 to 60 by simulated players.
- NPCs Forever renamed are found by their Forever names (Corma Villard, Velarok Windblade, and two more): the Target key and the quest checks missed them.
- Steps say what the quest asks: The Missing Diplomat's fight with Tapoke Jahn said "Speak with", and some kill quests read "Speak with Mottled Boar". The escort tips are only on real escorts.
- Quests handed in at a chest or object in town (The Lost Ingots chain in Menethil) are on the route.
- Quests for Forever's new dungeons stay in the dungeon: Horrors in the Highland (Excavation Site: Wetlands) was a step outside, as if its boss were in Menethil.
- No more "hand it in" right after picking up a quest whose work the quest data doesn't describe (Brewer's Trade in Southshore, and about 90 others): one that leads to a follow-up stays on your route with a "do the work" step that says to follow your quest log, and An Alarming Request is handed in near Dalaran, not in Southshore.

## 1.4.1 - 2026-11-11
- The arrow points the way instead of herding you onto the dotted line: step off it and the line is redrawn from where you are, it looks further ahead along straight stretches, and roads only win when they're nearly on the way.
- Forever Route Targeting now really marks the NPC with a star (it was blocked by the game).
- Logging out is quick again: a timing check rebuilt the route ten times at logout and ran past the game's limit on long plans. The options window opens on screen again.
- A quest its giver turned down once you had the level for it stays off your route, instead of coming back every level.
- Hearth steps only when the game says you're bound there and the hearthstone is ready.
- Good quests nearby that the plan can't hold (giver in a city, objectives elsewhere, or work the quest data doesn't describe, like Brewer's Trade) are offered when you're at the giver.
- The quest log check lists quest items in your bags that are safe to delete.
- The Target button floats just above the card; `/fr target reset` puts it back. "Not doing this quest" no longer covers the title.
- Your path stays put when a new plan arrives, and a switch is announced in chat (`/fr paths`).
- No more stray path flashing on the map.

## 1.4.0 - 2026-11-11
- Horde: built-in plans for every Horde race and class.
- Every Alliance plan rebuilt: through Forever's new zones (Riverglades, Shen'dralas), grinding a level where the quests run out instead of sending you into dungeons.
- The built-in plans are two addons, one per faction, instead of one per race and class (a much shorter addon list).
- The arrow aims a little ahead along the path, so it no longer swings at every corner.
- Walking paths follow the roads and keep away from hostile camps (Elwynn Forest, the Wetlands so far).
- The Forever Route scale slider applies when you let go (it used to jump to its end while dragging); the card can no longer end up off the screen (`/fr card reset` brings it back).

## 1.3.2 - 2026-11-11
- The Target button stays on the card in combat.
- Built-in plans are grouped under Forever Route in the addon list.
- Scrollbars in the route list and the quest log check can be dragged and clicked.
- Option: accept route quests and hand in finished ones automatically (not when there's a reward to choose; hold Shift to skip). Off by default.
- The card no longer fades in combat by default (an option if you liked it).
- One Forever Route scale for the card, arrow, route list and every window (`/fr options` or `/fr scale`); on screens where our text is small (e.g. 4K with ElvUI), a bar offers a bigger size. Clearer grey text.
- Smaller saved files: without the companion app, walking trails and learning data aren't recorded (only the companion uses them) and old ones are cleared. `/fr storage` shows what's kept.
- A long walk inside a zone can become a flight: when a flight path you know lands clearly nearer the spot (Darkshire to Sven's camp by way of Sentinel Hill), the card and the arrow send you to the flight master first.
- Flight points now come from Forever's own flight tables: Mount Hyjal's Tainted Foothills added, both Hyjal points for the Horde too, the Riverglades flight masters at their real spots. Knowing one flight path of a zone no longer counts as knowing its other one.

## 1.3.1 - 2026-11-11
- The Target button sits with the card instead of over every window (the character sheet covers it now).
- Ctrl+drag the Target button anywhere; `/fr target reset` puts it back.
- What's new: resizable, and "Older versions" shows earlier notes.

## 1.3.0 - 2026-11-11
- Starting at any level: the built-in plan picks up where you are, choosing the best nearby part of the plan for your level.
- No more far-away stops (like another zone's flight path) put in front of you.
- In a dungeon, the card shows your quests for it with live progress, and which ones you could have picked up.
- Quest log full: the card goes to hand-ins and objectives first; pick-ups wait until there's room.
- New key: Keybindings > AddOns > "Forever Route Targeting" targets the step's NPC and marks it with a star.
- `/fr report`: copy an anonymous bug report to paste to us.
- What's new: after an update, a bar under the card links to these notes (`/fr news` any time).
- "Run to" until you can ride. Card scale up to 2.0, arrow up to 2.5.
- Correction: 1.2.1's flight path pickup doesn't work on Forever's client; the card now asks you to open any flight master's map once.

## 1.2.1 - 2026-11-11
- Map dots behind you now disappear.
- No more "Error loading ForeverRoute/Route.lua" warning.
- Travel for Riverglades, Shen'dralas and Mount Hyjal.

## 1.2.0 - 2026-11-10
- Calmer card: kill and loot steps take over only when they count; finished quests nearby are offered.
- "Won't do" quests come back if you finish them anyway.
- Route list follows you; minimap shows one pin; greyed world-map pins say why.
- Walking line along the ground in Stormwind, Elwynn and the Wetlands.
- QuestieDB 1.0.14. Elite quests and dungeons are never forced.

## 1.1.1 - 2026-11-10
- Finished quests with their NPC nearby come first.

## 1.1.0 - 2026-11-10
- First release: 1-60 routes for every Alliance race and class.
