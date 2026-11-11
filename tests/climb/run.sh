#!/bin/zsh
# Climb regression: runs every scripted scenario headless and prints the last line of each
# (state and position), or PASS / FAIL for the tower route. Not shipped (tests/ is excluded).
#   tests/climb/run.sh            all
#   tests/climb/run.sh tower      just the tower route
# Scenario scenes read CLIMB_TEST; render.tscn also takes SHOTS / OUT / CAMSIDE / CAMBACK /
# CAMLOW / NOLABEL / POSELOG / HEADLOG / BENCH (see render.gd). The climb sandbox level is
# regenerated with: godot --headless --path . tests/climb/gen_sandbox.tscn
cd "${0:A:h}/../.."
G="${GODOT:-/Users/sakwa/Library/Application Support/Godot/app_userdata/Godots/versions/Godot_v4_7_2-stable_mono_macos_universal/Godot_mono.app/Contents/MacOS/Godot}"
run() { CLIMB_TEST=$2 perl -e 'alarm 200; exec @ARGV' "$G" --headless --path . tests/climb/$1.tscn 2>&1 | grep -E "$3|SCRIPT" | tail -1; }
if [ "$1" != "tower" ]; then
	for t in up side inner over down plain jump; do printf "%-10s " $t; run boxes_basic $t "^[0-9]"; done
	for t in leap leapside back ledge ceiling grip fall attack catch letgo vineledge; do printf "%-10s " $t; run boxes_phases $t "^[0-9]"; done
	for t in over30 over40 lean38 flatten noledge ledgeok lip ceil ceilup; do printf "%-10s " $t; run sandbox_cases $t "^[0-9]"; done
fi
for t in p0 p0gap p1 p2 p3 p4 grip; do printf "%-10s " $t; run tower_route $t "PASS|FAIL"; done
