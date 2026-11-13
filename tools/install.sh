#!/usr/bin/env bash
# Run the addon's sim tests on the repo copy (addon/ForeverRoute); install it into the game only if they all pass AND
# the live check passes: the new code against your real plan file and latest save (tools/live-check.js), logging in
# the way the real game does. The live Route.lua is never touched (the companion's planner owns it).
# usage: tools/install.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/addon/ForeverRoute"
GAME="$(cygpath -u "$(node "$ROOT/tools/game-dir.js")")" # the game's _forever_ folder (tools/game-dir.js)
DEST="$GAME/Interface/AddOns/ForeverRoute"
# yes/no questions to the game go through ns.Is (Core.lua): Forever hides some answers in dungeons and combat, and
# testing a hidden one is an error. A raw call here is refused before anything runs.
# keybindings: the simulator loads none, so the file is checked here (tools/check-bindings.js)
# the in-game what's new comes from CHANGELOG.md
node "$ROOT/tools/gen-news.js" >/dev/null || { echo "NOT installed (News.lua)"; exit 1; }
node "$ROOT/tools/check-bindings.js" "$SRC" || { echo "NOT installed (Bindings.xml)"; exit 1; }
node "$ROOT/tools/check-report.js" || { echo "NOT installed (/fr report format)"; exit 1; }
RAW=$(cd "$SRC" && grep -rnE '(UnitOnTaxi|UnitIsAFK|UnitIsDeadOrGhost|UnitIsGhost|IsFlying|IsIndoors|IsInInstance|IsMounted|IsSwimming|IsResting|UnitInVehicle)[(]' --include=*.lua . | grep -v '^./tests/' | grep -v '^./Libs/')
if [ -n "$RAW" ]; then echo "$RAW"; echo "NOT installed (ask the game through ns.Is: a hidden answer is an error otherwise)"; exit 1; fi
SIM="$ROOT/sim/pkg/$(tr -d '\r\n' < "$ROOT/tools/sim-version.txt")" # (tools/sim-version.txt: the simulator in use)
R=$(cd "$SIM" && export WOW_INSTALL_PATH="$(node "$ROOT/tools/game-dir.js" wow)"; timeout 900 ./wow-sim.exe --allow-ui-version-mismatch \
  --addons-path "$(cygpath -w "$ROOT/addon")" --session-wtf-path "$(cygpath -w "$ROOT/sim/wtf")" \
  --class Warlock --race Gnome run-tests ForeverRoute 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'tests,|✗|_test.lua:[0-9]+: [^i]|_harness.lua:[0-9]+:')
echo "$R"
if ! echo "$R" | grep -qE ' 0 failed'; then echo "NOT installed (tests failed)"; exit 1; fi
# the live check, for each character the companion plans for (its settings name the save folder)
for cfg in "$ROOT"/routes/campaign-*.json; do
  CHAR=$(node -e "try{console.log(require(process.argv[1]).charDir||'')}catch(e){}" "$cfg")
  [ -n "$CHAR" ] || continue
  node "$ROOT/tools/live-check.js" "$CHAR" "" "$(cygpath -w "$SRC")"
  case $? in
    0) ;;
    3) echo "  (only the check at the spot you saved failed: installing; see above)" ;;
    *) echo "NOT installed (the live check failed: this code would not load your plan right)"; exit 1 ;;
  esac
done
# FR_TEST_ONLY=1: the tests and the live check only, nothing installed (the game stays on the version it has)
if [ -n "${FR_TEST_ONLY:-}" ]; then echo "tests passed (FR_TEST_ONLY: not installed)"; exit 0; fi
cd "$SRC" && find . -type f ! -name 'Route.lua' | while read f; do mkdir -p "$DEST/$(dirname "$f")"; cp "$f" "$DEST/$f"; done
# the built-in plans: one load-on-demand addon per faction (tools/bundle-plans.js)
node "$ROOT/tools/bundle-plans.js" "$GAME/Interface/AddOns" >/dev/null || { echo "NOT installed (bundling the plans)"; exit 1; }
# (the one-addon-per-plan folders this replaced: ours, gone)
rm -rf "$GAME/Interface/AddOns"/ForeverRoute_Starter_*
# (a Starter.lua left from before the plans moved out would still load: gone)
rm -f "$DEST/Starter.lua"
echo "installed"
