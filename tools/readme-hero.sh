#!/usr/bin/env bash
# Rebuild the README's hero GIFs from the built-in plans (paths-starter/, reports/starters.md).
# Needs playwright-core and a Chromium: see tools/readme-render.js (PLAYWRIGHT_CORE, FR_CHROME).
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
node tools/readme-hero.js journey human-paladin "$T/journey.json" && node tools/readme-render.js journey "$T/journey.json" docs/img/journey.gif 5 500
node tools/readme-hero.js card human-paladin "$T/card.json" 1 34 && node tools/readme-render.js card "$T/card.json" docs/img/card.gif 5 400
node tools/readme-hero.js think human-paladin "$T/think.json" 12 && node tools/readme-render.js think "$T/think.json" docs/img/planner-choice.gif 6 400
# the grid: the shipped plans, with the simulated player's verdicts from the gates of the trees that shipped them
# (FR_GATES: their gate.json files, default tree/alliance-v10 and tree/horde-v10)
node tools/readme-hero.js grid "$T/grid.json" ${FR_GATES:-tree/alliance-v10/gate.json tree/horde-v10/gate.json} && node tools/readme-render.js grid "$T/grid.json" docs/img/plans.gif 6 500
rm -rf "$T"
