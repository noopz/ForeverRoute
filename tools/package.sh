#!/usr/bin/env bash
# The release zip: the addon (without its tests) and the built-in plans, nothing else (no planner, no companion).
# usage: tools/package.sh [version]   -> dist/ForeverRoute-<version>.zip   (version default: the TOC's)
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VER="${1:-$(sed -n 's/^## Version: *//p' addon/ForeverRoute/ForeverRoute.toc | tr -d '\r')}"
rm -rf dist && mkdir -p dist/pkg
node tools/gen-news.js >/dev/null # the in-game what's new, from CHANGELOG.md
cp -r addon/ForeverRoute dist/pkg/
rm -rf dist/pkg/ForeverRoute/tests
# your own plan (the companion writes it) is never shipped
rm -f dist/pkg/ForeverRoute/Route.lua
# ...nor listed in the TOC: the game warns "Error loading ForeverRoute/Route.lua" on every load for a file that an
# addon-site install never has (the built-in plan is used then). The companion's own install (tools/install.sh) keeps the line
T=dist/pkg/ForeverRoute/ForeverRoute.toc; grep -v '^Route[.]lua' "$T" > "$T.new" && mv "$T.new" "$T"
if grep -q '^Route.lua' dist/pkg/ForeverRoute/ForeverRoute.toc; then echo "package: Route.lua still in the TOC"; exit 1; fi
sed -i "s/^## Version: .*/## Version: $VER/" dist/pkg/ForeverRoute/ForeverRoute.toc
for d in addon/ForeverRoute_Starter_*/; do cp -r "$d" dist/pkg/; done
# every built-in plan nests under Forever Route in the game's addon list (## Group), or 51 entries fill it
missing=$(grep -L '^## Group: ForeverRoute' dist/pkg/ForeverRoute_Starter_*/*.toc 2>/dev/null); if [ -n "$missing" ]; then echo "package: built-in plans without ## Group: $missing"; exit 1; fi
# the licenses (NOTICE says which is which): the addon is CC BY-NC-SA with a few GPL quest-data files; each built-in
# plan is all quest data, so GPL
cp LICENSE dist/pkg/ForeverRoute/LICENSE
cp LICENSES/GPL-3.0.txt dist/pkg/ForeverRoute/LICENSE-GPL-3.0.txt
cp NOTICE dist/pkg/ForeverRoute/NOTICE
for d in dist/pkg/ForeverRoute_Starter_*/; do cp LICENSES/GPL-3.0.txt "$d/LICENSE-GPL-3.0.txt"; cp NOTICE "$d/NOTICE"; done
if command -v zip >/dev/null; then (cd dist/pkg && zip -qr "../ForeverRoute-$VER.zip" .)
else powershell -NoProfile -Command "Compress-Archive -Path 'dist/pkg/*' -DestinationPath 'dist/ForeverRoute-$VER.zip'"; fi
echo "dist/ForeverRoute-$VER.zip: $(ls dist/pkg | wc -l) addon folders"
