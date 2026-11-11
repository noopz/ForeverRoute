# World facts audit (WoW Forever, Alliance gnome warlock, level 21)

Audited: `addon/ForeverRoute/Travel.lua`, `FlightMasters.lua`, `tools/campaign.js`, `tools/route2.js`,
`routes/campaign-<name>.json`, `qdb/`, and the installed QuestieDB Forever `support/Forever/Zones/*.lua`.
Date: 2026-11-07. "Confirmed" = stated by Blizzard, warcraft.wiki.gg or our own qdb. "Uncertain" = fan site only,
sources disagree, or Classic fact not re-checked for Forever. Most Forever fan sites are thin, SEO-style pages that
often contradict each other, so treat their numbers as rough.

Basic data limit: `qdb/conversion.json` says the Forever DB is a *converted Era baseline*. It assumes
"NPC/terrain world positions remain unchanged", and it lists "new content" and dungeon entrances as `not_converted`.
The DB does hold the new quests (872 quest ids above 90000, for example Hall of Thanes 96393/96394/96403 and
Excavation 98815/95646). But anything generated from Classic tables (flight masters, docks) knows nothing about new
Forever travel.

## 1. Corrections (what we have -> what's true)

| # | We have | What's true | Status | Source |
|---|---|---|---|---|
| 1 | `Travel.BOATS` has `menethilN <-> auberdine` (direct) | Forever replaced it with a 3-stop ship: Menethil -> Southshore -> Auberdine. Fan reports disagree on the return direction: some say Auberdine still goes straight to Menethil, others that it calls at Southshore both ways. We have no Southshore dock. | Route confirmed (Blizzard panel); direction uncertain | https://outputlag.com/news/world-of-warcraft-forever-adds-three-ship-routes-including-stormwind-to-auberdine/ , https://warcraft.wiki.gg/wiki/World_of_Warcraft:_Forever |
| 2 | No Auberdine <-> Rut'theran boat, no Rut'theran <-> Darnassus portal | Classic links, still there (Darnassus has no flight master; Rut'theran's Vesprystus is the flight master). Only matters for Darnassus trips (e.g. BFD/RFK quest givers). | Confirmed (Classic); Forever uncertain | https://wowforevertierlist.com/travel/boat-routes |
| 3 | Deeprun Tram not in the travel graph | Stormwind <-> Ironforge tram is listed for Forever. Entrances (qdb dungeons.lua): Stormwind 72,28 / Ironforge 84.1,53.1. About 1 min ride plus wait. Faster than flying SW->IF for training trips. | Confirmed | https://warcraft.wiki.gg/wiki/World_of_Warcraft:_Forever |
| 4 | `ZONE_MIN[1431]` Duskwood = 18 | Forever recommended level is 20 | Uncertain (Warcraft Tavern) | https://www.warcrafttavern.com/forever/guides/leveling/ |
| 5 | `ZONE_MIN[1444]` Feralas = 40 | Forever recommended level is 35 (Classic was 40) | Uncertain | same |
| 6 | `ZONE_MIN` covers only 28 maps | Missing: Tirisfal 1420, Silverpine 1421, Alterac 1416 (30), Hinterlands 1425 (40), Searing Gorge 1427 (43), Burning Steppes 1428 (50), Blasted Lands 1419 (45), Deadwind 1430 (55), WPL 1422 (50), EPL 1423 (53), Felwood 1448 (45), Un'Goro 1449 (48), Winterspring 1452 (53), Silithus 1451 (55), Moonglade 1450. New zones: Riverglades 2548 (35), Shen'dralas 2652 (40), Mount Hyjal 2482 (60), Zephras Isle 2521 (1). A missing zone counts as "safe", so a level-21 route may ride through Searing Gorge, Burning Steppes, etc. | Map IDs confirmed (areaIdToUiMapId.lua); levels from Warcraft Tavern | same |
| 7 | Danger rule uses zone minimum only | Enemy towns kill an Alliance level 21 at any zone level: Crossroads (Barrens ~52,30), Camp Taurajo (~45,59), Mor'shan Rampart (Barrens ~48,5), Splintertree Post (Ashenvale ~73,61), Tarren Mill (Hillsbrad), Hammerfall (Arathi), plus all of Durotar/Mulgore/Tirisfal/Orgrimmar 1454/TB 1456/UC 1458. Durotar and Mulgore are `ZONE_MIN=1`, so they look "safe". | Confirmed (Classic) | https://warcraft.wiki.gg/wiki/Heartswood_(quest) |
| 8 | Succubus travel hint: "ride south through Ashenvale into the Barrens" | Wiki: the Horde camp at Mor'shan Rampart blocks the direct road. Alliance should use the breach (Barrens ~49,5 / Ashenvale ~70,87), the Talondeep Path from Stonetalon, or the river north from Ratchet. Takar the Seer (Barrens 49.3,57.1) is **near Camp Taurajo**, so give Taurajo and the Crossroads on the Gold Road a wide berth. | Confirmed | https://warcraft.wiki.gg/wiki/Heartswood_(quest) , https://warcraft.wiki.gg/wiki/Devourer_of_Souls_(Stormwind) |
| 9 | Succubus chain 1716 -> 1738 -> 1739 | Correct. 1716: Gakin the Darkbinder (SW 39.2,85.2) -> Takar the Seer. 1738 Heartswood: Takar -> Gakin, Heartswood object at Ashenvale 31.55,31.57 (Ordil'Aran, Dark Strand cultists). 1739 The Binding: summoning circle in the Slaughtered Lamb (SW 39.1,84.4); rewards Succubus + Small Soul Pouch. Optional breadcrumb 1717 "Gakin's Summons" (Lago Blackwrench, IF 47.6,9.3). | Confirmed (qdb + wiki "remains in Classic and Forever") | https://warcraft.wiki.gg/wiki/Heartswood_(quest) |
| 10 | Incubus not handled | qdb contains Classic 1.14 Incubus branch 65602 "What Is Love?" (Takar -> Gakin; Unlit Torch Ashenvale 26.8,22.4, burn Archaeologist's Cart 26.7,22.6, Wooden Figurine) -> 65603 The Binding (Incubus). The wiki says these quests "do not exist in retail and Forever", but Blizzard's beta notes mention the Incubus pet and Summon Incubus. Do not route 65602/65603 until seen in game. Make sure the generic planner does not schedule them as normal quests. | Uncertain (conflicting) | https://warcraft.wiki.gg/wiki/What_Is_Love%3F , https://us.forums.blizzard.com/en/wow/t/topic/2360696 |
| 11 | Felhunter 1798/1758/1802/1804/1795 | Order correct. 1798 (Gakin or Lago Blackwrench IF) -> Strahad Farsan, Ratchet 62.6,35.5. 1758 -> Krom Stoutarm, IF library 74.2,9.4. 1802: Moldy Tome (Hillsbrad 27.8,72.8) + Tattered Manuscript (Damaged Chest, Thousand Needles 43.4,32.7). 1804: Reconstructed Tome + **3 Rods of Channeling** (Dragonmaw Shadowwarder 28-29 / Bonewarder 27, Wetlands ~45-54,42-55; also a new Forever NPC 275046 "Dragonmaw Thaumaturgist") -> Strahad. 1795: summoning circle Ratchet 62.6,35.2. | Confirmed (qdb) | https://warcraft.wiki.gg/wiki/Tome_of_the_Cabal_(Alliance) |
| 12 | Felsteed 4488 -> 4490, "it also teaches riding" | 4488 (Demisette Cloyce, SW) has an IF twin, **4487 (Briarthorn, IF 50.4,5.7)**. Accept either. Wiki marks 4488 "removed in 1.12.1"; 4490 (Strahad, Ratchet) is what rewards Summon Felsteed. Patch 1.12.1: Felsteed "comes with the Apprentice Riding skill". Forever charges 100g for riding at 40 (first mount included). Whether warlocks still get riding free is unverified. | 4490 confirmed; free riding uncertain | https://warcraft.wiki.gg/wiki/Summon_Felsteed , https://warcraft.wiki.gg/wiki/Summon_Felsteed_(2) |
| 13 | `trainer` = Stormwind only | Ironforge also has warlock trainers (Briarthorn is one, qdb IF 50.4,5.7, Forlorn Cavern area). From Wetlands or Loch Modan, Ironforge is closer. | Confirmed (qdb) | qdb/json/npcs.json id 5172 |
| 14 | `Travel.FLY` 22 yd/s straight line, any two known flight points linked | Flights run at 434% of run speed (~30 yd/s) along curved routes, so 22 yd/s straight-line is a fair estimate. But Classic flights link only along the network, through nodes you know (linked flights since 1.10). Not every pair of known flight points is connected. Alliance-side routes differ from Horde ones. | Speed confirmed; Classic routing rule likely, Forever unverified | https://warcraft.wiki.gg/wiki/Flight_path |
| 15 | `route2 killXp` uses ZD = L - gray + 5 (12 at level 21) | Classic ZD at levels 20-29 is 11 (minor). Bigger issue: Forever lowers XP from mobs below your level by about 4-20%, and from dungeon mobs (~30-40% of Classic, then +20% on Oct 8). Dungeon quest bonus XP was cut 50% (Oct 1). Elites give x2. | Patch notes confirmed; percentages fan-measured | https://us.forums.blizzard.com/en/wow/t/topic/2360696 , https://conquestcapped.com/guides/wow-forever/wow-forever-leveling/ |
| 16 | `hearthCooldownMin` 60 | Classic is 60 min (cut to 30 only in 3.1.0). No Forever source found. Keep 60, and read the real cooldown in game where the API allows. | Classic confirmed; Forever uncertain | https://vanilla-wow-archive.fandom.com/wiki/Hearthstone |

Verified correct (no change needed): run speed 7 yd/s; all `ZONE_MIN` uiMapIDs map to the named zones; the other
`ZONE_MIN` levels match Warcraft Tavern (Barrens 10, Redridge 15, Stonetalon 15, Ashenvale 18, Wetlands 20, Hillsbrad
20, Thousand Needles 25, Arathi, Desolace and STV 30, Badlands, Dustwallow and Swamp 35, Tanaris 40, Azshara 45);
Menethil (south pier) <-> Theramore and Booty Bay <-> Ratchet still run; flight masters in FlightMasters.lua are the
right Alliance ones (Ratchet's Bragok is neutral; Booty Bay Gyll, Gadgetzan Bera Stonehammer, Everlook Maethrya are
the Alliance masters in those neutral towns); warlocks train at even levels; the Stormwind coordinates are the
modern-map frame (Stormwind's map was re-framed in Forever; conversion.json confirms). FlightMasters.lua has no new
Forever flight points (Riverglades, Dalaran, Zephras) because it is generated from Classic data. *Uncertain whether
any exist.*

## 2. Missing facts to add

Travel
- **Stormwind Harbor <-> Auberdine** is the default crossing. Dock coordinates have not been published; `DOCKS.stormwind` (0.279,0.274) is a guess, so let Boats.lua learn the real pier. *Route confirmed, coordinates uncertain.*
- **Southshore dock** (Hillsbrad 1424) as a stop on the Menethil–Auberdine ship. It makes Hillsbrad, the Felhunter Moldy Tome and the Cozy Bag Arathi step reachable by boat. *Confirmed route, unknown pier.*
- **Steamwheedle Port (Tanaris) <-> Powderfuse Port (Riverglades)** ship, and a **land road Redridge -> Riverglades**. *Ship confirmed; road uncertain.*
- Boat timing: no Forever schedule has been published. `BOAT=300 s` (wait + crossing) is a fair Classic average; the full cycle is longer. *Uncertain.*
- No summoning stones in Forever (meeting stones only open the group finder). Dungeon entry is limited to 5 instances per hour. *Uncertain (fan site, consistent).*
- Flight path rule: talk to the flight master in person to learn the point. A flight can be ended early, and you dismount at the next node. *Confirmed.*
- Riding: Apprentice at 40 for 100g (first mount included), 60% speed (~11.2 yd/s). Journeyman at 60 for 1000g (100%). No flying. The planner has no mounted speed at 40+. *Riding cost confirmed by several guides; speed is Classic.*

Danger corridors (Classic facts; Forever says "Azeroth remains dangerous", no level scaling)
- **Theramore -> Barrens**: the Dustwallow roads cross level 35-45 marsh (Bloodfen raptors, Darkmist spiders). Not before ~33. The hint already says 35. *Confirmed.*
- **Wetlands Dun Algaz -> Menethil road**: level 20-28 (raptors, crocolisks, Dragonmaw at Angerfang). OK on the road from ~18, not off it. Grim Batol (east) is elite 50+. *Confirmed.*
- **Duskwood -> Stranglethorn**: north STV is 30-35 right past the border, and Rebel Camp / Nesingwary is the first safe ground. Duskwood has roaming elites: Mor'Ladim and **Stitches (hostile again in Darkshire per the Oct 8 notes)**. *Confirmed.*
- **Ashenvale <-> Barrens**: Mor'shan Rampart and Splintertree Post have Horde guards; use the breach (see row 8). *Confirmed.*
- **Hillsbrad**: Tarren Mill; Alterac Mountains (30-40) north of the road. **Arathi**: Hammerfall; the Thandol Span from Wetlands leads into 30+ Arathi. *Confirmed.*

Quests and content for this character
- **1740 The Orb of Soran'ruk** (warlock, both factions, req 20 / level 25): Doan Karhan stands next to Takar (Barrens 49.3,57.2). Needs 3 Soran'ruk Fragments + 1 Large from BFD. Pick it up during the Succubus trip. *Confirmed (qdb).*
- New dungeons, with qdb entrances: **Hall of Thanes** 13-18 (inside IF 27.6,47.8; quests Thom Filch IF 32.2,44.5, Afadra Dunwall 33.2,47.9, Old Ironforge Incursion from Earthseer Farsen in Dun Morogh, whose qdb spawn has **no zone key** (data bug)); **Ruins of Lordaeron** 15-22 (entrance above Undercity in Horde Tirisfal; the Alliance quests start inside; quests require 15); **Excavation Site: Wetlands** 26-31 per Blizzard, 24-29 per fan sites (entrance Wetlands 47.8,56.2; quests from Menethil, e.g. James Halloran 8.6,55.7, and Rethiel the Greenwarden 56.4,40.4; req 24); **City of Dalaran** 28-33 (Alterac; Horde barred; ~3950 XP per quest); later The Drowned City (STV 35-40), Krol'dok (Riverglades 40-45), Alcaz Prison (Dustwallow 48-53), Blackmaw Hold (Azshara 55-60), Shaper's Terrace (Un'Goro 58-60). *Levels confirmed (wiki); quest givers from qdb.*
- New Forever Deadmines quest **92753/92819 "Destruction in Deadmines"** (Alba Fairmoon, Westfall). *Confirmed (qdb, beta notes).*
- Classic dungeon quest hubs (Alliance): Deadmines: Sentinel Hill (Gryan Stoutmantle chain, Scout Riell) + Stormwind (Wilder Thistlenettle, Shoni, Baros Alexston for The Unsent Letter). Stockade: Warden Thelwater (SW), Nikova Raskol (Old Town), Guard Berton (Lakeshire), Councilman Millstipe (Darkshire), Motley Garmason (Wetlands Dun Modr). BFD: Gershala Nightwhisper (Auberdine), Argos Nightwhisper (SW), Dawnwatcher Shaedlass (Darnassus), Gerrig Bonegrip (IF). Gnomeregan: Tinkmaster Overspark, Klockmort Spannerspan, Master Mechanic Castpipe (IF), Ozzie Togglevolt (Kharanos), Shoni (SW). RFK: Mebok Mizzyrix (Ratchet), Treshala Fallowbrook (Darnassus), Falfindel Waywarder (Feathermoon). SM: Raleigh the Devout (Southshore), Librarian Mae Paledust (IF), Brother Crowley (SW). *Classic-confirmed; Forever unverified.*
- Changed quests worth encoding: Desolace Gelkis/Magram chain now req 35 (was 30), and Valley of Bones now maps to the new zone Shen'dralas (2652); Bounty: Gnarlpine Furbolg needs 15; Elixir of Pain XP moved to the quest; Holy Diver now gives XP; Khonsu removed (Silithus). *Confirmed (Blizzard notes, qdb maps).*
- Cozy Sleeping Bag: chain from level 14, Alliance start at Alexston Farmstead (Westfall); stacking 1% per stack up to 3, survives death, 1 h bag cooldown; ~2-3 h for the whole chain. *Uncertain (fan site).*
- Rested XP: doubles kill XP only, builds in inns/capitals; Legacy perk "Well Rested" speeds it up. Library books are open to all classes (quests at 10/20/25 books). *Confirmed (wiki).*
- Warlock: Drain Soul gives far fewer shards on damage, so plan shard farming before 1739/1795 if you need shards; pets get 2 HP per master Stamina; Grimoire costs folded into training costs. *Confirmed (beta notes).*

## Sources
- https://warcraft.wiki.gg/wiki/World_of_Warcraft:_Forever
- https://us.forums.blizzard.com/en/wow/t/topic/2360696 (Forever Beta Development Notes)
- https://outputlag.com/news/world-of-warcraft-forever-adds-three-ship-routes-including-stormwind-to-auberdine/
- https://wowforevertierlist.com/travel/boat-routes
- https://www.warcrafttavern.com/forever/guides/leveling/
- https://conquestcapped.com/guides/wow-forever/wow-forever-leveling/
- https://warcraft.wiki.gg/wiki/Heartswood_(quest), /Devourer_of_Souls_(Stormwind), /What_Is_Love%3F, /The_Binding_(Incubus,_Stormwind), /Tome_of_the_Cabal_(Alliance), /Summon_Felsteed, /Summon_Felsteed_(2), /Flight_path
- https://vanilla-wow-archive.fandom.com/wiki/Hearthstone

## Found 2026-11-09 (Mac agent, Wowhead and guides)
- **Riding:** Apprentice at 40, 100g, 60% speed (first mount included per Method); Journeyman at 60, 1000g, 100%. One riding skill for every mount; other races' mounts need Exalted. Honored with your home faction: 10% off. Sources: https://www.method.gg/wow-forever/how-to-get-a-mount-in-wow-forever-cost-requirement-and-mount-options , https://www.warcrafttavern.com/forever/guides/riding/
- **Summon Felsteed IS in Forever** (corrected 2026-11-10): Blizzard's Nov 10 hotfix notes say "Completing 'Summon Felsteed' will correctly grant the player the appropriate riding skill", and Wowhead Forever's tooltips have quests 3631/4487-4490 and spell 5784. The spellbook-changes page had listed it as removed (as it did Defensive Stance, which is also in the game). The chain is back as a level-40 warlock side trip (tools/reviewed-*.json).
- **Dungeon kill XP +50%** (hotfix, Nov 8 2026, Kaivax): "increased kill experience in dungeons by 50%" - all dungeons, kills only, not quests. https://us.forums.blizzard.com/en/wow/t/dungeon-enemy-xp-increased-november-8/2406595/1 (via the Warcraft Tavern mirror). Launch dungeon kill XP was ~70% below Classic (Method, beta data), so it is still below Classic (~0.5x, an estimate).
- **Group XP:** kill XP / 5 x 1.4 each in a full group; XP is by your own level; nobody gets XP if someone in the group is far above the mob. Quest turn-ins are not split.
- **Rested XP** doubles kill XP; 5% of a level per 8 h; cap 150% of a level. Well Fed +5% kill XP. Cozy Sleeping Bag up to 3 x 1%. Well Rested legacy talent +4% per rank. Quests more than 5 levels below you lose 10-20% per extra level. https://www.warcrafttavern.com/forever/guides/experience/

## 3. Forever's new questing zones (2026-11-11)

The map conversion had no world bounds for these, so the planner never routed there. Bounds from the client's UiMapAssignment table (build 1.60.1.70862, wago.tools), checked against Wowhead Forever (Nerlokh: Shen'dralas 21.2,23.2 converts to Desolace 58.8,89.0; Wowhead 58.5,88.5). They are in tools/map-extras.json; walk maps baked from the client like every zone.

- **Riverglades** (area 16591, map 2548, Eastern Kingdoms, 36-44): east of Redridge and Burning Steppes, south of the Badlands, north of the Swamp of Sorrows; on foot from Redridge (warcraft.wiki.gg). Ship Steamwheedle Port (Tanaris, Wharfmaster Steamfizzle 67.56,23.1) <-> Powderfuse Port (Wharfmaster Whizzbuzz 79.34,52.75), both factions. Flights: Gretchen Mayberry (Alliance, Farholde Keep 60.62,81.53) to Lakeshire, Thelsamar, Morgan's Vigil; Grakna (Horde, Rog'mar 59.58,45.13) to Stonard, Kargath, Flame Crest, Hammerfall (wowforever.be, metabot.gg). No flight master at Powderfuse. *Confirmed; dock piers and road coordinates likely.*
- **Shen'dralas** (16651, map 2652, Kalimdor, quests 38-43): south-east of Desolace, on foot through the Valley of Bones. No flight master. *Confirmed.*
- **Mount Hyjal** (616, map 2482, Kalimdor, quests 56-60): south-west of Winterspring through Darkwhisper Gorge; flights Everlook <-> Tainted Foothills (Bluebell 54.57,83.19) <-> Summit of Eternity (Fayran Elthas 68.84,43.99). QuestieDB marks both masters Alliance; Wowhead shows Cenarion Circle / no faction. *Confirmed; gorge coordinates unknown.*
- QuestieDB coverage: on 1.0.14 only 15 of Riverglades' 150 quests had a placeable giver, finisher and objectives; on 1.0.15, 120 (Shen'dralas 19 of 19). Mount Hyjal: 0 of 36 (no quest givers yet) - the plans grind there until QuestieDB fills it in.
- QuestieDB gives Wheatley (259859) a second spawn in Duskwood (60.76,12.32) that Wowhead doesn't show.
