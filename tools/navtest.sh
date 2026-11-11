#!/usr/bin/env bash
# Run the addon's tests in wow-ui-sim from this checkout (a worktree borrows the simulator of the main checkout).
# usage: tools/navtest.sh [filter-for-grep]   -> failing tests and the result line
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN="${FR_MAIN:-D:/git/ForeverRoute}"
P="$ROOT/sim/pkg/wow-ui-sim-v0.1.40-forever-windows-x86_64"; [ -d "$P" ] || P="$MAIN/sim/pkg/wow-ui-sim-v0.1.40-forever-windows-x86_64"
OUT="${TMPDIR:-/tmp}/fr-navtest.log"
GD="$ROOT/tools/game-dir.js"; [ -f "$ROOT/game-dir.txt" ] || GD="$MAIN/tools/game-dir.js"
cd "$P" && WOW_INSTALL_PATH="$(node "$GD" wow)" ./wow-sim.exe --allow-ui-version-mismatch --addons-path "$(cygpath -w "$ROOT/addon")" --session-wtf-path "$(cygpath -w "$ROOT/sim-wtf")" --class Warlock --race Gnome run-tests ForeverRoute > "$OUT" 2>&1
grep -a -A3 "✗" "$OUT" | head -${2:-60}
[ -n "$1" ] && grep -a "$1" "$OUT" | head -40
grep -a "tests, " "$OUT"
