#!/usr/bin/env bash
# Every built-in plan: each Alliance race and class Forever allows (Mac agent, Wowhead/Zockify/Method, 2026-11-09) is
# planned from level 1 to 60 (tools/starter.js), audited (lint-route.js), and played by the simulated player
# (tools/simplay.js, personas below). One line per plan in reports/starters.md; the full output per plan in
# reports/starters/<race>-<class>.txt. Skyborne starts on Zephras Isle.
# usage: tools/starters-all.sh [combo ...]   (default: all)   FR_PERSONAS=clean,skip,nodungeon FR_SIM_PAR=n FR_SIM_CACHE=0
#        FR_SIM_CKPT=0: each simulated player plays from level 1 (by default it resumes at the last leg of the plan that
#        is unchanged since its last run: tools/simckpt.js)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# one batch at a time: a stopped batch whose script kept running once doubled every planner and simulator, and the
# PC ran out of memory (planners died without a word). FR_BATCH_SLOT=2 allows a second batch on its own lock.
LOCK="$ROOT/reports/starters.lock${FR_BATCH_SLOT:-}"
if ! mkdir "$LOCK" 2>/dev/null; then echo "another batch is running ($LOCK; remove it if not)"; exit 3; fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
COMBOS=${*:-"human-warrior human-paladin human-rogue human-priest human-mage human-warlock human-hunter dwarf-warrior dwarf-paladin dwarf-hunter dwarf-rogue dwarf-priest dwarf-shaman nightelf-warrior nightelf-hunter nightelf-rogue nightelf-priest nightelf-druid gnome-warrior gnome-rogue gnome-mage gnome-warlock gnome-priest skyborne-hunter skyborne-druid skyborne-mage skyborne-rogue skyborne-warrior orc-hunter orc-mage orc-rogue orc-shaman orc-warlock orc-warrior tauren-druid tauren-hunter tauren-shaman tauren-warrior troll-hunter troll-mage troll-priest troll-rogue troll-shaman troll-warlock troll-warrior undead-mage undead-paladin undead-priest undead-rogue undead-warlock undead-warrior"}
PERSONAS=${FR_PERSONAS:-clean,skip,nodungeon}
# the simulated players run side by side (tools/simplay.js waits for free memory before each one starts): two per batch
# when several batches run at once, three for one alone. A plan whose route didn't change reuses its passing run.
if [ -z "${FR_SIM_PAR:-}" ]; then
  if ls -d "$ROOT"/reports/starters.lock* 2>/dev/null | grep -qv "^$LOCK$"; then export FR_SIM_PAR=2; else export FR_SIM_PAR=3; fi
fi
export FR_SIM_CACHE=${FR_SIM_CACHE:-1}
mkdir -p reports/starters
SUM=reports/starters.md
[ -f "$SUM" ] || printf '# Built-in plans\n\n| plan | to level | hours | steps | audit | simulated player |\n|---|---|---|---|---|---|\n' > "$SUM"
for c in $COMBOS; do
  race=${c%-*}; cls=${c#*-}; out=reports/starters/$c.txt
  rm -rf "paths-starter/$c"
  node tools/starter.js "$race" "$cls" 60 "${FR_PATHS:-1}" > "$out" 2>&1 || { echo "| $c | planner failed | | | | |" >> "$SUM"; continue; }
  line=$(grep -e "h, [0-9]* steps" "$out" | head -1)
  lvl=$(echo "$line" | sed -E 's/.*: 1 -> ([0-9]+).*/\1/'); hrs=$(echo "$line" | sed -E 's/.*~([0-9.]+) h.*/\1/'); stp=$(echo "$line" | sed -E 's/.*h, ([0-9]+) steps.*/\1/')
  F=paths-starter/$c/Route.lua; issues=0
  for id in $(grep -oE '^ {4}id = "path:[^"]+"' "$F" | sed -E 's/.*"(.*)"/\1/'); do
    a=$(node tools/lint-route.js "$F" qdb/db.json "$id" "$cls,$race"); echo "$a" >> "$out"
    n=$(echo "$a" | tail -n +2 | grep -vc "no issues found"); issues=$((issues + n))
  done
  bt=$(node tools/backtrack.js "$F" | sed -n 2p); echo "$bt" >> "$out"
  back=$(echo "$bt" | sed -E 's/wild revisits: ([0-9]+).*thin trips ([0-9]+) of ([0-9]+).*/\1 \/ \2 of \3/')
  FR_STALL=90 node tools/simplay.js "starter:$c" "$PERSONAS" >> "$out" 2>&1
  sim=$(grep -E "persona\(s\) played" "$out" | tail -1 | sed -E 's/^[^,]*, [0-9]+ s\. //')
  finds=$(sed -n '/What the player/,$p' "$out" | grep -E "^  (tick|back|loop|stuck|trip) x" | sed -E 's/ x([0-9]+):.*/ \1/' | sort | uniq -c | awk '{print $2"="$3}' | tr '\n' ' ')
  echo "| $c | $lvl | $hrs | $stp | $issues | $back | $sim ${finds} |" >> "$SUM"
done
echo "done" >> reports/starters/ALLDONE
