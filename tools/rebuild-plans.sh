#!/usr/bin/env bash
# Rebuilding the built-in plans, always from current data: first the latest QuestieDB release is taken in (if there
# is a new one: tools/update-questiedb.js rebuilds qdb/), then Forever's patch notes and hotfixes since the last check
# are swept (tools/patch-watch.js -> reports/patch-watch.md: lines that could touch the plans are marked), then every
# plan is rebuilt (tools/starters-all.sh). A new QuestieDB or a marked patch-note line is printed before the rebuild
# starts, so it's read, not discovered afterwards.
# usage: tools/rebuild-plans.sh [combos...]   (no combos: what starters-all.sh does by default)
#        FR_SKIP_DATA=1 tools/rebuild-plans.sh ...   to rebuild without the data steps (offline)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ -z "${FR_SKIP_DATA:-}" ]; then
  before=$(node -e 'try{console.log(require("./qdb/questiedb-version.json").version)}catch(e){console.log("?")}')
  echo "== QuestieDB: built from $before; checking for a newer release"
  node tools/update-questiedb.js || { echo "QuestieDB update failed: fix it or rerun with FR_SKIP_DATA=1"; exit 1; }
  after=$(node -e 'try{console.log(require("./qdb/questiedb-version.json").version)}catch(e){console.log("?")}')
  [ "$before" != "$after" ] && echo "== QuestieDB updated: $before -> $after (overrides re-applied by the update; check tools/overrides-check.js)"
  echo "== Forever patch notes and hotfixes since the last check"
  node tools/patch-watch.js || echo "(patch-watch failed: read the forums by hand before shipping)"
  echo "== Are our Forever corrections still right? (QuestieDB caught up, or a patch note changed them)"
  node tools/overrides-audit.js --prune; [ $? -eq 3 ] && echo "   ^ look at these before shipping; mark reviewed ones in tools/overrides-reviewed.json"
fi
echo "== Rebuilding plans"
exec bash tools/starters-all.sh "$@"
