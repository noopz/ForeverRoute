# Forever Route

**Leveling routes for WoW Forever, 1–60.** A step card, an arrow and map pins tell you what to pick up, kill, hand in, train, and where to travel next. Works at any level: install it at 30 and it picks up from where you are.

![The card, step by step](https://raw.githubusercontent.com/noopz/ForeverRoute/main/docs/img/card.gif)

## What it does

- **The card tells you the next thing to do** and moves on by itself as you kill, loot and hand in.
- **An arrow and map pins** point the way, with a walking line on the ground in the cities.
- **Start at any level.** The built-in plan for your race and class finds the best part of the route for your level from where you stand, and skips what you've outgrown.
- **Dungeons:** inside one, the card shows your quests for it with live progress. Dungeon runs are never forced on you; they're side trips you choose.
- **Full quest log?** The card sends you to hand-ins first.
- **Flight paths, boats, the tram and class teleports** are all part of the trip planning.

Routes aren't hand-written: a planner builds them from the quest data (QuestieDB) and the game's own terrain, picking zones by XP per hour and leaving out quests that aren't worth it. Every built-in plan is played 1–60 by simulated players before it ships.

## Getting started

Install, log in, and follow the card. Open any flight master's map once so the addon knows your flight paths.

| Command | What it does |
|---|---|
| `/fr` | Show or hide the card |
| `/fr list` | The whole route |
| `/fr skip` · `/fr back` · `/fr undo` | Move through the steps by hand |
| `/fr dungeons` | Dungeon routes, as side trips |
| `/fr logcheck` | Quests in your log the route won't use |
| `/fr why` | Why the addon did what it just did |
| `/fr report` | Copy an anonymous bug report |
| `/fr news` | What changed in recent versions |
| `/fr options` | Settings, including size and quest automation |

**Key binding:** Options › Keybindings › AddOns › "Forever Route Targeting" targets the step's NPC and marks it.

## Coverage

**Every race and class, Alliance and Horde,** including Forever's new zones (Riverglades, Shen'dralas).

## Found a problem?

Type `/fr report`, copy the text, and paste it with a screenshot into an issue at **github.com/noopz/ForeverRoute/issues** (or a comment here). It's anonymous: no character name, realm or account.

## Optional: the companion app (Windows)

Replans your route from your own save every time you `/reload`, with several paths to choose between. Coming soon as a separate download on GitHub.

---

Forever Route by noopz · [GitHub](https://github.com/noopz/ForeverRoute) · CC BY-NC-SA 4.0 (share and adapt with credit, never sell). The quest data it's built from is GPL-3.0 (QuestieDB).
