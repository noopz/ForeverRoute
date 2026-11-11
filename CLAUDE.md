# Forever Route

A leveling-route addon for WoW Forever plus the planner that builds its routes. `addon/` is what players install
(`ForeverRoute` and the built-in plans `ForeverRoute_Starter_<race>_<class>`); `tools/` is the planner, the
simulator harness and the release tooling; `docs/research/` holds the facts the planner relies on, with sources.

## Versioning

Two things change at different speeds: the addon's code, and the built-in plans (data the planner produces). One
release version covers the download; the plans carry their own stamp.

**Release version `vMAJOR.MINOR.PATCH`**: the git tag, the zip name and the CurseForge file. `tools/package.sh`
writes it into `ForeverRoute.toc`. In the repo the TOC's version is only a placeholder.

| Part  | Bump it for |
|-------|-------------|
| PATCH | Bug fixes in the addon, and/or **rebuilt built-in plans**: planner improvements, a new QuestieDB, Forever hotfixes taken in. Nothing new for the player to learn. |
| MINOR | Something the player notices as new: new coverage (Horde plans), a new window or button, a changed card behaviour, or planner changes that reshape routes broadly. |
| MAJOR | A breaking change: saved data reset or migrated, the companion must be updated with it, or the plan format changes. |

**Plans stamp**: `tools/starter.js` stamps every built-in plan as
`plans <YYYY-MM-DD> · QuestieDB <version> · planner <commit>`. It goes in the plan's TOC (`## Version`, `## X-Plans`),
its file header and `ForeverRouteStarterStamp`, and the route list shows it on a built-in plan. A bug report then
says which plan someone had, apart from the addon version.

**Release notes** come in three parts:
- **Addon**: fixes and features.
- **Plans**: rebuilt or not, and why.
- **Data**: the QuestieDB version, and the Forever hotfixes and patch notes covered (`tools/patch-watch.js`).

**When to ship**:
- **Addon fixes:** as soon as the addon's tests (`tools/install.sh` runs them) and the live check pass.
- **Plans:** after the planner or its data changed enough to matter. All plans are rebuilt (`tools/starters-all.sh`)
  and must pass the route audit (`tools/lint-route.js`) and the simulated players. Never ship a plan that fails
  either.
- **Triggers for a rebuild:** a new QuestieDB release, and Forever hotfixes or patch notes that touch quests, XP,
  drops or travel. Run `node tools/patch-watch.js` to see what changed since the last check.

## Releasing

1. Build the release on the squashed `public` branch, never on development history.
2. Scan it for personal data (character names, local paths, account names, tokens) before pushing.
3. Push it, then tag `vX.Y.Z`. `.github/workflows/release.yml` packages the zip and uploads it to GitHub Releases
   and to CurseForge. CurseForge reviews each file before it goes public.

## Facts

Check game facts against Wowhead's WoW Forever data (`https://nether.wowhead.com/tooltip/<type>/<id>?dataEnv=16`)
and Blizzard's Forever posts, not Classic sources or memory. A "removed" on Wowhead's spellbook-changes pages is not
proof. Defensive Stance and Summon Felsteed were listed as removed and are both in the game.
