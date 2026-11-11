#!/bin/zsh
# Tree importer: cut-out photos of real trees -> tree generator species.
#   tools/tree_import/import.sh IMAGE...        (e.g. ~/Downloads/ImageCels_\ Trees/BMPFILES/8BITBMP/*.BMP)
# 1. tree_import.py measures each photo, cuts its leaf cluster and far card (work/<run>/)
# 2. the leaf / card PNGs go through the texture inbox import (textures/plants/)
# 3. tree_import.gd writes addons/n64_level_tools/trees/species/<name>.tres
# 4. cards.sh imports the far cards (CI4) and puts them on the species
# Add unknown photos to species.json first (code -> name, archetype, real height).
# Not shipped (tools/ is export-excluded).
set -e
cd "${0:A:h}/../.."
[ $# -gt 0 ] || { echo "usage: import.sh IMAGE..."; exit 1; }
G="${GODOT:-/Users/sakwa/Library/Application Support/Godot/app_userdata/Godots/versions/Godot_v4_7_2-stable_mono_macos_universal/Godot_mono.app/Contents/MacOS/Godot}"
PY=tools/anim_ref/.venv-pose/bin/python
W=tools/tree_import/work/run_$(date +%Y%m%d_%H%M%S)
mkdir -p $W
$PY -I tools/tree_import/tree_import.py $W "$@" 2>/dev/null
for f in $W/card_*.png; do cp $f texture_inbox/tree_${f:t}; done
cp $W/leaves_*.png texture_inbox/
perl -e 'alarm 300; exec @ARGV' "$G" --headless --path . --script res://addons/n64_level_tools/textures/inbox_import.gd -- list $PWD/$W/list.json >/dev/null 2>&1
$PY -I - $W <<'PYEOF'
import json, os, sys
w = sys.argv[1]
items = json.load(open(os.path.join(w, "list.json")))["items"]
mine = {"leaves_" + f[7:] for f in os.listdir(w) if f.startswith("leaves_")}  # (cards: cards.sh, CI4)
plan = [{"file": it["file"], "archive": it["archive"], "category": "plants", "object": 0, "tiling": 3, "usage": 1,
	"sharpen": 0.0, "tint_amount": 0.0, "tint_auto": False}
	for it in items if os.path.basename(it["file"]) in mine]
json.dump(plan, open(os.path.join(w, "plan.json"), "w"), indent=1)
print("textures to import:", len(plan))
PYEOF
perl -e 'alarm 600; exec @ARGV' "$G" --headless --path . --script res://addons/n64_level_tools/textures/inbox_import.gd -- import $PWD/$W/plan.json $PWD/$W/imported.json $PWD/$W/textures.png 2>&1 | grep -E "SCRIPT ERROR" || true
perl -e 'alarm 300; exec @ARGV' "$G" --headless --path . --import >/dev/null 2>&1 || true
perl -e 'alarm 300; exec @ARGV' "$G" --headless --path . -s res://addons/n64_level_tools/trees/tree_import.gd -- $PWD/$W/analysis.json 2>&1 | grep -E "^(OK|ERR|SKIP)|SCRIPT ERROR"
tools/tree_import/cards.sh
echo "work files (masks, analysis, texture sheet): $W"
