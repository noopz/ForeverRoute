# Forever Route

Leveling routes for WoW Forever, 1-60, for every Alliance race and class. A step card, an arrow and map pins tell you
what to accept, kill, hand in, train and where to travel. Skip quests or dungeons and the route keeps up.

![The human paladin plan, 1 to 60](docs/img/journey.gif)

**The card tells you the next thing to do**, counts your kills and loot, and moves on by itself:

![The card, step by step](docs/img/card.gif)

Routes aren't hand-written. A planner builds them from the quest data and the game's own terrain.

**It picks the next zone** by planning out every zone that fits your level and comparing xp per hour:

![Choosing the next zone](docs/img/planner-choice.gif)

**It keeps the quests worth doing** - and says why the rest were cut or left for later:

![Picking a zone's quests](docs/img/quest-pick.gif)

**It finds the fastest way there** across one network of roads, boats, the tram, flights, class teleports and the
Skyborne skyship:

![Finding a trip](docs/img/travel.gif)

**Every plan is played 1-60 by ten simulated players before it ships:**

![Every Alliance plan, checked](docs/img/plans.gif)

## Getting started

Install Forever Route from CurseForge or from [Releases](https://github.com/noopz/ForeverRoute/releases) and log in. A
built-in plan for your race and class loads by itself, and quests you've already done are skipped, so it works for a
character of any level. Flight paths you already know are picked up at login.

| Command | What it does |
|---|---|
| `/fr` | Show or hide the card |
| `/fr list` | The whole route |
| `/fr skip` · `/fr back` · `/fr undo` | Move through the steps by hand |
| `/fr dungeons` | Dungeon routes, as side trips you choose |
| `/fr logcheck` | Quests in your log the route won't use |
| `/fr why` | Why the addon did what it just did |
| `/fr report` | Copy a bug report to paste to us (anonymous) |
| `/fr news` | What changed in recent versions |
| `/fr options` | Settings |

**Optional: the Windows companion** replans your route from your own save every time you `/reload`, with several
paths to choose between. It isn't in the releases yet; it will come as a separate download.

What changed in each release: [CHANGELOG.md](CHANGELOG.md).

Forever Route by noopz. [CC BY-NC-SA 4.0](LICENSE): share and adapt it with credit, never sell it. The quest data it is built from is GPL-3.0 (QuestieDB); see [NOTICE](NOTICE). Contributions: [CONTRIBUTING.md](CONTRIBUTING.md).
