#!/usr/bin/env bash
# Rebuild the built-in plans with a pool of workers pulling from one queue - resumable.
#
#   * a plan is DONE when its check report (reports/starters/<combo>.txt) says its simulated players played it, and is
#     newer than the last change to the planner's code (tools/route2.js, campaign.js, paths.js, starter.js, ...): run
#     this again any time - after a crash, a reboot, a Ctrl+C - and it does only what's left. A planner change makes
#     every plan stale again, as it should.
#   * workers take the next plan nobody has claimed (reports/queue/<combo>, made atomically with mkdir), so no worker
#     idles while another has a backlog, and each plays its simulated players side by side (FR_SIM_PAR).
#   * each plan runs through tools/starters-all.sh exactly as a batch would (audit, backtrack check, simulated players,
#     the reports/starters.md line), in its own lock slot.
#
# usage: tools/rebuild-queue.sh [workers=3] [combos...]     (no combos: all 51 built-in plans)
#        FR_SIM_PAR=2 (players side by side per worker), FR_PERSONAS (as starters-all.sh), FR_FORCE=1 (ignore DONE)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
WORKERS=${1:-3}; shift || true
ALL="human-warrior human-paladin human-rogue human-priest human-mage human-warlock human-hunter dwarf-warrior dwarf-paladin dwarf-hunter dwarf-rogue dwarf-priest dwarf-shaman nightelf-warrior nightelf-hunter nightelf-rogue nightelf-priest nightelf-druid gnome-warrior gnome-rogue gnome-mage gnome-warlock gnome-priest skyborne-hunter skyborne-druid skyborne-mage skyborne-rogue skyborne-warrior orc-hunter orc-mage orc-rogue orc-shaman orc-warlock orc-warrior tauren-druid tauren-hunter tauren-shaman tauren-warrior troll-hunter troll-mage troll-priest troll-rogue troll-shaman troll-warlock troll-warrior undead-mage undead-paladin undead-priest undead-rogue undead-warlock undead-warrior"
COMBOS=${*:-$ALL}
# one simulator per simulated player (FR_SIM_CHUNK=1), a plan's three side by side (FR_SIM_PAR=3): a simulator is one
# core and ~6 GB, and simplay.js waits for 7.5 GB free before starting one - 3 workers fill 8 cores / 62 GB without
# running out (the default chunk of 3 played a plan's players one after another on one core: an hour a plan)
export FR_SIM_CHUNK=${FR_SIM_CHUNK:-1} FR_SIM_PAR=${FR_SIM_PAR:-3} FR_SKIP_DATA=1
# the planner's code: a plan built before its last change is stale
PLANNER="tools/route2.js tools/campaign.js tools/paths.js tools/starter.js tools/ensure-steps.js tools/world.js tools/waypoints.js tools/optimize.js tools/quality.js tools/travel.js qdb/db.json tools/forever-overrides.json tools/campaign-defaults.json"
STAMP=$(ls -t $PLANNER 2>/dev/null | head -1)
done_already() {
  local r="reports/starters/$1.txt"
  [ "${FR_FORCE:-}" = 1 ] && return 1
  [ -f "$r" ] && [ "$r" -nt "$STAMP" ] && grep -q "persona(s) played" "$r" && ! grep -qE "persona\(s\) played, [1-9][0-9]* broke" "$r"
}
Q=reports/queue
if ls -d reports/starters.lock* >/dev/null 2>&1; then echo "a batch is running (reports/starters.lock*): stop it first"; exit 3; fi
rm -rf "$Q"; mkdir -p "$Q"
left=0; for c in $COMBOS; do done_already "$c" || left=$((left + 1)); done
echo "== $left of $(echo $COMBOS | wc -w) plans to build (newest planner change: $STAMP), $WORKERS workers, $FR_SIM_PAR players each"
worker() {
  local w=$1
  for c in $COMBOS; do
    done_already "$c" && continue
    mkdir "$Q/$c" 2>/dev/null || continue   # (someone else has it)
    echo "[w$w $(date +%H:%M)] $c"
    FR_BATCH_SLOT="q$w" bash tools/starters-all.sh "$c" > "$Q/$c/log" 2>&1
    echo "[w$w $(date +%H:%M)] $c: $(tail -1 reports/starters.md | cut -c1-120)"
  done
}
for w in $(seq 1 "$WORKERS"); do worker "$w" & done
wait
left=0; for c in $COMBOS; do done_already "$c" || left=$((left + 1)); done
echo "== finished; $left not done (see reports/starters/<combo>.txt)"
