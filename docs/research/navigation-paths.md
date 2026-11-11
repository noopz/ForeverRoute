# Navigation on the map: the walking line and the minimap pins

Scope: the dotted walking line (`UI/Pins.lua`, `Nav.lua`, `tools/navgrid.js`) and where minimap pins sit. Two things
were wrong in game:

1. The line was the planner's precomputed path (`step.wp`), made from where the *plan* expected you. From anywhere else
   its first piece was a straight line from you to the next waypoint, over walls. In Stormwind (Trade District 66.1, 70.8
   to Bolvar 80.0, 38.0) the minimap showed dots running into blank minimap.
2. Numbered pins on the minimap walked with the player: a pin kept its offset from the arrow.

Both are fixed on branch `nav-paths`. Numbers below were measured on this branch (sizes with `node tools/navgrid.js
stats`, times and memory in wow-ui-sim, whose Lua VM is not the game's: read the times as an order of magnitude and
check them in game with `/fr nav`).

## 1. The pin that walked with you

### Cause: a recycled frame, not coordinates and not HereBeDragons' maths

`Pins.Update` rebuilt its pins from one shared pool: each rebuild returned every frame to the pool and handed them out
again, for the world map and the minimap alike, after calling `p:Show()` itself.

HereBeDragons-Pins takes over a frame only when it actually places it:

- a minimap pin is parented to the minimap on `AddMinimapIcon*`, anchored and shown in `drawMinimapPin`;
- a world-map pin is parented to a map canvas pin, anchored and shown in `OnAcquired` - which `HandlePin` only reaches
  if the world map is on a map that shows the pin. `WorldMapFrame:GetMapID()` is nil until the map has been opened
  once, and afterwards it stays on the last map looked at; it does not follow you while closed.

So: a frame is a minimap pin, anchored `CENTER` to `Minimap` at some offset. The pins are rebuilt (a step came near,
you stood on it, the step changed). That frame comes back from the pool as a *world-map* pin. The world map is closed
on another zone (or was never opened), so `HandlePin` returns early and never touches it. It is still parented to the
minimap, still anchored at its old offset, and we had just called `Show()` on it. Result: a pin at a fixed offset from
your arrow, until the next rebuild. The path dots had the same bug (one pool for world and minimap dots), so dots
could be left in blank minimap the same way, on top of the wall-crossing first segment.

It shows most in a city because that is where the world map is usually stale (you looked at the zone map outside,
then walked in) and where steps are close together, so pins are rebuilt often.

Reproduced in the simulator before the fix (`all_test.lua`, "no pin is left behind on the minimap when the pins are
rebuilt"): with the world map on no map, three frames of ours were visible on the minimap that HereBeDragons was not
placing.

A second, smaller cause sat behind it: `AddMinimapIconMap` binds a pin to a uiMap, and HereBeDragons draws it only
while `C_Map.GetBestMapForUnit` returns exactly that map (or a child, with `showInParentZone`). If the game resolves
you on another map than the step's (a keep's or district's own map), the pin is never positioned at all - and with our
own `Show()` it stayed wherever it last was. The second new test shows this (the pin was not drawn when the player's
map id differed).

### What was ruled out

- **The planner's coordinates for Stormwind.** Forever's Stormwind map is not Classic's: `qdb/conversion.json` maps
  Classic's rectangle (left 1381, top -8279, 1344 x 896 yd) to Forever's (left 1723, top -7996, 1738 x 1158 yd).
  Classic's Trade District centre (60, 60) lands on (66.1, 70.8) and Bolvar (78.2, 18.0) on (80.2, 38.4): exactly what
  the player read in game. The plan's coordinates and the game's map agree. (Wowhead's Stormwind pages use another
  frame; they are not ground truth here.)
- **The minimap's scale.** The Forever client has `C_Minimap.GetViewRadius` (the simulator's API surface for build
  16001 has it and returns a radius), so HereBeDragons-Pins 17 asks the game for the radius instead of using its
  Classic zoom table; the indoor/outdoor guess is not involved.
- **The minimap's shape.** A square minimap (DaylightUI) only changes where HereBeDragons clips or slides a pin at the
  edge, not where it puts one inside. A minimap frame that is not square (width differs from height) *would* misplace
  pins, more the further away they are: `/fr nav` says so if it sees one.
- **Another addon's newer HereBeDragons-Pins.** LibStub keeps the highest MINOR; the placement code is the same in
  every recent version, and the bug above is on our side of the API.

### The fix (`UI/Pins.lua`)

- A frame keeps its job for life: separate pools for world-map pins, minimap pins, world-map dots, minimap dots.
- A frame is handed to HereBeDragons hidden and unanchored; HereBeDragons shows it when it places it. We never `Show()`.
- Minimap pins and dots are added by world position (`AddMinimapIconWorld`), not bound to a uiMap. Nearness is already
  checked in yards (`Pins.Near`), so the map binding added nothing but the failure above.
- `Pins.Sweep()` runs after every rebuild: anything of ours that is visible, parented to the minimap and not in
  HereBeDragons' minimap registry is hidden (and noted in `/fr why`). It should never find anything now.

### Telling the causes apart in game

`/fr nav` prints what the game itself says: your uiMap (C_Map and HereBeDragons), your world position, the minimap's
size, scale, zoom, view radius and shape, the target's map and world position and its distance from you, where the
minimap pin is and where it belongs by those positions, the game's rectangle for the map against the one the walk map
was baked for, and how many stray frames the sweep just hid.

| What you see | Cause | How to check |
|---|---|---|
| The pin keeps the same offset from your arrow as you walk; zoom does not change it | a stray frame (the bug above) | `/fr nav`: "stray frames ... hidden" above 0 |
| The pin stays on one spot of the ground, but that spot is not the NPC; the gap in pixels grows as you zoom in and is the same from every side | the step's coordinates (one NPC's database position) | stand on the NPC: `/fr nav` "target ... N yd from you" reads the error in yards |
| The pin is right when you stand on it and further off the further you walk away; it moves along the line through you | minimap scale or a non-square minimap | `/fr nav`: view radius, width x height; "pin at ... belongs at ..." differ |
| Every pin of a map is off by the same vector | the map rectangle the plan was made for is not the game's | `/fr nav`: "the game says ... the walk map was made for ... THEY DIFFER" |

The report from Elwynn (one pick-up badge about an icon's width beside the game's own "!" for that NPC, the same after
walking and zooming) fits either the first row - the frozen pin was left where the NPC's pin was when you came within
15 yd of it, which is close to the NPC but not on it - or, if the gap was the same on the ground rather than on the
screen, the second (that NPC's position in QuestieDB). The
first is gone with this fix; if the badge is still off for that NPC, the second row's check gives the yards, and the
fix is an entry in `tools/forever-overrides.json`.

## 2. The walking line: approaches

What it has to do: start where you stand, follow walkable ground, stay fixed on the map while you walk, be found again
when you stray or the step changes, cost little in Lua 5.1 (no bit library, no file IO), and stay small enough to ship
for every zone. The source is the planner's walk map (`tools/voxnav.js`): 2-yd columns with every walkable floor,
0.45 million floors in Stormwind, 1.7 million in Elwynn, 2.2 million in the Wetlands, about 130 million for all 46
zones.

| | Approach | Stormwind | Elwynn | Wetlands | Search | Verdict |
|---|---|---|---|---|---|---|
| A | Keep `step.wp`, join it from where you are with a straight piece | 0 | 0 | 0 | none | what we had: the straight piece crosses walls |
| B | Layered coarse grid read in place from base64 (the interrupted attempt): 8 chars a node, 8 yd city / 16 yd outdoors | 376 KB | 332 KB | 434 KB | A* forward, about 30 table and string reads a node | works, too big: 1.14 MB for three zones, 30-40 MB for all |
| C | **One byte a square, packed (this branch)**: 4 yd city / 8 yd outdoors | **137 KB** | **95 KB** | **109 KB** | A* from the target, one `string.byte` a square | chosen |
| C' | the same at 8 yd city / 16 yd outdoors | 49 KB | 34 KB | - | fewer squares | the fallback if size matters more than the minimap |
| C'' | the same at 4 yd outdoors | - | 258 KB | - | 4x the squares | no visible gain on a map |
| D | Rectangles or a nav mesh (merge open squares, search regions, pull the line through portals) | not built | | | fewest nodes | most code in Lua (portals, funnel); the packed grid already costs about 0.5 B a square in open country |
| E | Road graph (skeleton of the walkable space) plus a region map to find your nearest node | not built | | | tiny | the region map is the grid again; lines hug the middle of open ground |

B's sizes are the files the interrupted attempt left; C's are the files in `addon/ForeverRoute/Nav/`. Zipped (what a
download costs), C is 67 KB, 56 KB and 65 KB.

Why C is so much smaller than B at four times the resolution: B stored for every node a position, a height and 27
edge bits, in base64. C stores one byte for a square (which of its 8 neighbours you can step in from), and open
country is long runs of the same byte and rows equal to the row above, which the packing removes. Heights are kept
only where a square has more than one level.

## 3. The design that was built

### The graph (`tools/navgrid.js`)

- Squares of 4 yd (city), 8 yd (outdoors) or 16 yd (the six biggest zones: the Barrens, Stranglethorn, Darkshore, Feralas, Tanaris, Winterspring), aligned to the walk map.
- The walk map's floors inside a square that are joined both ways are one *patch*. All water in a square is one patch.
- Kept: patches in a strongly connected part of the zone with at least 500 floors (0.2% of the zone): ground you can
  walk to *and back* from. Roofs you could only drop from and pits are gone.
- In each square the biggest patch (the lowest on a tie) is the **base** node. A small patch joined both ways to a
  neighbouring square's base is merged into it (the strip of a terrace that pokes into the next square).
- Any other patch is an **overlay** node: a bridge deck over the canal, an upper floor, a ledge. Overlay nodes that
  the network can do without (every way in reaches each way out within 4 steps without it) are dropped, unless they
  belong to a structure of 20 floors or more (about a room), which is kept whole.
- A node is joined to a neighbour wherever the walk map has a step between their floors; drops are one way.
  Lifts (`travel-facts.json` LIFTS) and recorded trails are links with their own cost, never cheaper than the squares
  are apart (a trail whose points sat a little closer than the squares' middles had become a highway: the first
  Stormwind line followed the player's own recorded walk, 560 yd where 525 was possible), and left out where plain
  steps get there about as fast.

Every chain of nodes the search can return is walkable on the walk map by construction; `navgrid.js test` checks it
("walking these very squares") and compares with the walk map's own shortest way between the same floors.

### What ships

`Nav/Nav<uiMap>.lua` sets `ForeverRouteNavData[uiMap]` (a global, so the data can move to load-on-demand addons):

- `base`: the bytes, row by row, as tokens of an 85-character alphabet: a run of one byte, a copy of the row above, or
  literals; each zone has its own table of its 84 commonest bytes as single characters.
- `swim`: one bit a square, as runs.
- `over`: overlay nodes in square order, each with its height, the base node's height for that square, and its links
  as one character each (which neighbouring square, which node there, which way).
- `far`: the few links between squares that are not neighbours (lifts, trails), 10 characters each.
- `solo`: base nodes nothing steps into from a neighbouring base (their byte is 0).

Everything is on one line per field: a line break inside a long string would be rewritten by git on Windows.

### In game (`Nav.lua`)

- **Unpack** a zone the first time you need it into two Lua strings (one character a square: the byte, and water) and
  small tables for the overlay. The last two zones stay unpacked.
- **Search**: A* from the target back to you, octile distance to your square as the estimate, weight 1.2. One
  `string.byte` gives a square's 8 possible steps; a table per byte value lists the set bits (no bit library).
  Swimming costs 1.5x, like the planner. It stops when it reaches a node of the square you stand in.
- **Straighten**: wherever the straight run of squares between two points of the result is walkable too (each step
  checked against the bytes) and no dearer, the points between go. Overlay nodes are never skipped.
- **The line** is a list of world points; the first is where you stand, the last the target.
- **When you stray** more than 30 yd, the way from your new square is read off the same search (it left a pointer
  toward the target in every square it looked at). Only where it never looked does a new search start.
- **When the target changes** (step, trip leg, zone), `Arrow.SetTarget` asks for a new line. The line is always for
  what the arrow points at, so the two cannot disagree, and the arrow's distance is the line's length.
- All of it runs in a coroutine, `Nav.BUDGET_MS` (2 ms) a frame.

Height: the game gives addons no z. The target's height is the planner's (`step.z`), which picks the right floor of
its square. Yours is not known: the search accepts any node of your square and so takes the level with the shortest
way; after straying it prefers the level the old line had there.

### Drawing (`UI/Pins.lua`)

Dots sit at whole multiples of a spacing counted in yards-still-to-walk from the target, so a dot's place does not
depend on where the line starts. Walking removes the dots behind you and nothing else moves. World map: a dot about
every 1% of the map's width, at most 200. Minimap: a dot every 10 yd for the next 300 yd, none within 14 yd of you.
Both by world position.

Zones without a walk map keep the planned path on the world map as before (shown only while you are on it); its
minimap dots stay behind `ns.db.miniPath`, because that path still starts where the plan expected you.

### Across zones and trips

The line's target is the arrow's: for a trip (`Travel.Plan` through `Engine.TravelFor`) that is the first leg's
waypoint - the zone crossing, the flight master, the pier. A walk map covers its map's whole rectangle, and
rectangles overlap, so `Nav.MapFor` takes the map you are on if it holds both you and the target, else the target's
map, else any that holds both. From Goldshire to the Trade District the line runs on Elwynn's walk map through the
gate (tested). After the border the zone change re-targets the arrow and the line continues on the city's finer map.
No line is drawn for a target on another continent or in a zone without a walk map.

### Indoors and several levels

Bridges, upper floors and ledges are overlay nodes with real links, so the line takes the bridge and not the canal
below it, and the stairs to an upper floor. Lifts are links (cost 200 yd, like the planner). What is not right yet:
with your own height unknown, standing under a bridge or on the floor below the target can start the line on the
wrong level until you move. Ironforge, Undercity and Thunder Bluff have not been baked or looked at in game.

## 4. Measurements

### Size

| Zone | Squares | Overlay nodes | File | Zipped | Unpacked in memory |
|---|---|---|---|---|---|
| Stormwind City, 4 yd | 435 x 290 | 6,534 | 136,617 B | 67 KB | 580 KB |
| Elwynn Forest, 8 yd | 434 x 290 | 2,154 | 94,649 B | 56 KB | 238 KB |
| Wetlands, 8 yd | 517 x 345 | 3,363 | 108,564 B | 65 KB | 384 KB |

All 46 zones with a walk map, baked with the same settings (`node tools/navgrid.js stats all`): **5.55 MB** of Lua
text (cities 0.75 MB, outdoor zones 5.06 MB), **3.1 MB zipped**. The biggest: Mulgore 300 KB, Ashenvale 264 KB,
the Barrens 222 KB (at 16 yd), Azshara 222 KB, Undercity 201 KB. With the 40 outdoor zones at 16 yd instead of 8: 2.05 MB for them, **2.8 MB** in all (about 1.6 MB zipped).

### CPU (simulator)

| Walk | Line | Squares looked at | Search | With straightening |
|---|---|---|---|---|
| Stormwind: across the Trade District | 433 yd, 18 points | 168 | 5 ms | 8 ms |
| Stormwind: Trade District to Bolvar | 534 yd, 16 points | 1,167 | 25 ms | 31 ms |
| Stormwind: canals to the Keep | 732 yd, 23 points | 3,603 | 86 ms | 94 ms |
| Stormwind: harbour to the Trade District | 935 yd, 32 points | 6,653 | 164 ms | 176 ms |
| Stormwind: harbour to the Keep | 1,263 yd, 33 points | 12,450 | 332 ms | 350 ms |
| Elwynn: Goldshire to Eastvale | 1,392 yd, 16 points | 318 | 10 ms | 21 ms |
| Elwynn: corner to corner | 2,263 yd, 26 points | 802 | 25 ms | 40 ms |
| Wetlands: Menethil to the middle | 2,127 yd, 23 points | 3,185 | 99 ms | 129 ms |
| Wetlands: Menethil round the bay | 4,645 yd, 39 points | 12,321 | 454 ms | 529 ms |

About 25-35 microseconds a square in the simulator. At 2 ms a frame a typical line is there within 5 to 50 frames;
the worst here takes about 260 (4 seconds at 60 fps, with the game running on). Unpacking a zone is 170-320 ms of work, once per zone, in the same 2 ms slices (the
line of the first step in a new zone appears a second or two later). Straying costs no search when the old one had
looked at your new spot (it usually has). Idle cost: one distance check every half second.

Memory: the unpacked zone (table above) plus the last search's tables, 0.1-0.8 MB for the walks above (1.6 MB for
the two longest).

### Accuracy

| Walk | Line | The walk map's own shortest way | Straight |
|---|---|---|---|
| Stormwind: Trade District to Bolvar | 534 yd | 525 yd | 450 yd |
| Stormwind: harbour to the Keep | 1,264 yd | 1,249 yd | 914 yd |
| Elwynn: Goldshire to Eastvale | 1,392 yd | 1,363 yd | 1,324 yd |
| Elwynn: corner to corner | 2,263 yd | 2,101 yd | 2,031 yd |
| Wetlands: Menethil to the middle | 2,127 yd | 2,058 yd | 1,926 yd |
| Wetlands: round the bay | 4,645 yd | 4,602 yd | 2,525 yd |

1 to 8% longer than the planner's optimum (the weight of 1.2 and 8 directions), and no yard of any of them is on a
square without ground or beside one (`offGround` in the tests samples every yard).

## 5. Tests (`tests/all_test.lua`)

- no pin is left behind on the minimap when the pins are rebuilt; the pin sits at the step, moves by exactly what you
  walk, and does not depend on the map id the game reports
- the walk maps unpack to their size and a square's byte only points at squares with ground
- Stormwind, Trade District to Bolvar: on the ground every yard, at least 10% longer than the straight line (which
  itself crosses more than 20 yd of walls), within 15% of the walk map's own way
- Elwynn, Goldshire to Eastvale: on the ground, within 12% of the walk map's way, straightened to under 60 points
- the live line: starts where you stand, is on the minimap and the world map, every dot on the ground; after 80 yd
  along it only the dots behind you are gone and none of the others moved
- straying gives a new line from where you are; 10 yd aside does not; a new step gets its own line
- cost: a search runs in slices, looks at a bounded number of squares, knows the ground along its own line; only
  two zones stay unpacked
- across a border: Goldshire to the Trade District on Elwynn's walk map; no map for another continent or a zone
  without a walk map

`tools/navtest.sh` runs the suite from a worktree (it borrows the simulator of the main checkout).

## 6. Recommendation and what is left for all zones

Ship C as built. For every zone:

1. `node tools/navgrid.js build all` (a few minutes; needs `terrain/` and `qdb/conversion.json`). Add it to the
   step that rebuilds the walk maps (`tools/rebuild-vox.sh`), so a new trail or a rebuilt zone re-bakes its file.
2. Do not list 46 data files in the main `.toc`: 5.5 MB of strings would sit in memory from login. Put them in two
   load-on-demand addons (`ForeverRoute_NavEK`, `ForeverRoute_NavKalimdor`, 2.9 and 3.0 MB at 8 yd) and have `Nav.Data`
   call `C_AddOns.LoadAddOn` for the continent you are on. The data files already write to a global for this. If the
   download matters more than the minimap outdoors, bake outdoor zones at 16 yd instead.
3. Look at the cities with lifts and stacked levels in game (Ironforge, Undercity, Thunder Bluff, Darnassus) before
   trusting them; the bake works for them (Thunder Bluff 32 KB, Darnassus 99 KB, Ironforge 121 KB, Orgrimmar 162 KB, Undercity 201 KB)
   but nothing has been checked there.
4. Zephras Isle and the battlegrounds have no walk map yet (`terrain/` has no `area*.vox` for them).

Risks:

- The simulator is not the game. The pin fix follows from HereBeDragons' code and is reproduced in the simulator, but
  the real minimap has not been seen with it; `/fr nav` is there to settle it in one look.
- Lua speed in the client is unknown; the 2 ms budget bounds the cost per frame whatever it is, only the wait grows.
- The walk maps are the planner's: where they have a gap (a door the building data closes), the line goes round or is
  missing, and the planned path is drawn instead. Recorded trails fix those, as they do for the planner.
- A line is only drawn when one walk map holds both you and the target; a long ride through three zones shows the
  line to the first crossing, not the whole way.
