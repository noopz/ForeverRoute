# Changelog

What changed in each release of Forever Route. Each version has up to three parts: **Addon** (what you see in the
game), **Plans** (the built-in routes, rebuilt or not) and **Data** (quest data and game facts behind them).

## 1.2.1 - 2026-11-11

### Addon
- **Flight paths you already know are picked up at login.** Before, the addon only learned them when you opened a
  flight master's map, so a character starting the addon at level 30 was sent walking everywhere. It now reads them
  from the world map, and again whenever you discover a new one.
- **The walking line's dots behind you now go away.** Each time the arrow re-aimed at the same step, a second copy of
  the line was drawn and never cleared.
- **No more "Error loading ForeverRoute/Route.lua" warning** at every login for anyone without the companion app.

### Plans
- Unchanged from 1.2.0.

### Data
- Travel for Forever's new zones: Riverglades (by land from Redridge, and the Powderfuse ship), Shen'dralas and Mount
  Hyjal, with their flight masters, map positions and walking maps.

## 1.2.0 - 2026-11-10

### Addon
- **The card stays calm.** A kill or loot step takes over only when your kills or loot count for it. At an NPC with a
  finished quest, that hand-in shows wherever the plan has it, and a "Ready nearby" line offers finished quests close
  by.
- **Quests you marked "Won't do" come back** when you finish them anyway. The quest log check lists them with Bring
  back, scrolls, and keeps its text clear of the buttons.
- **The route list follows you.** Done steps are hidden, "Now" comes first, then "Next on your plan". Paths show their
  next 5 zones.
- **Map pins.** The minimap shows one pin, for the card's step. On the world map, steps you can't do yet are grey and
  say why.
- **A walking line from where you stand**, along the ground, in Stormwind, Elwynn Forest and the Wetlands so far.
  Minimap pins no longer drift.
- The card can be moved in combat. Built-in plans show which build they are.

### Plans
- Unchanged from 1.1.1.

### Data
- QuestieDB 1.0.14.
- Start zones are kept. Elite quests and dungeon runs are never forced on you. Quest items come from normal mobs, not
  elites.
- Summon Felsteed is back for warlocks. The Menethil ship is Forever's one-way loop.

## 1.1.1 - 2026-11-10

### Addon
- A quest that's ready to hand in, with its NPC in your town and nearer than the planned step, comes first however
  late the plan has it (deliveries, quests finished early). Then the plan resumes.

## 1.1.0 - 2026-11-10

First public release: leveling routes for WoW Forever, 1-60, for every Alliance race and class. The addon and 28
built-in plans.
