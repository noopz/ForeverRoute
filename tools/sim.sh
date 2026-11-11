#!/usr/bin/env bash
# Render the addon in wow-ui-sim. usage: sim.sh <scene.lua> <out.png> [screenshot args...]
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="$ROOT/sim/pkg/wow-ui-sim-v0.1.40-forever-windows-x86_64"
SCENE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; OUT="$2"; shift 2
case "$OUT" in /*|?:*) ;; *) OUT="$PWD/$OUT" ;; esac
cd "$P" && export WOW_INSTALL_PATH="$(node "$ROOT/tools/game-dir.js" wow)" # the WoW folder (tools/game-dir.js)
timeout 600 ./wow-sim.exe --allow-ui-version-mismatch --addons-path "$(cygpath -w "$ROOT/addon")" --class Warlock --race Gnome --exec-lua "@$(cygpath -w "$SCENE")" screenshot --allow-ui-version-mismatch --png -o "$(cygpath -w "$OUT")" "$@" > "$ROOT/sim/last.log" 2>&1
grep -E "Lua error: .*ForeverRoute" "$ROOT/sim/last.log" | sort -u | head -10 || true
grep -qE "Lua error: .*ForeverRoute" "$ROOT/sim/last.log" || echo "no ForeverRoute errors"
