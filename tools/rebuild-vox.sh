#!/usr/bin/env bash
# rebuild walk layers (voxnav) for zones; old files and distance caches moved to terrain-old first
cd "$(dirname "$0")/.."  # the repo root (terrain/, tools/)
ROOT="$PWD"
WOW="$(node "$ROOT/tools/game-dir.js" wow)" # the WoW folder (tools/game-dir.js)
for a in $(echo "$1" | tr ',' ' '); do
  mkdir -p terrain-old; mv -f terrain/area$a.vox.* terrain-old/ 2>/dev/null; [ -f terrain/area$a.dist.json ] && mv -f terrain/area$a.dist.json terrain-old/
  t=$(date +%s); nice -n 19 node --max-old-space-size=10000 tools/voxnav.js build "$WOW" terrain $a 2 > terrain-old/build-$a.log 2>&1 && echo "$a ok $(($(date +%s)-t))s" || echo "$a FAILED"
done
