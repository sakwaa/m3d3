#!/bin/zsh
# Far cards for the tree species: renders card variants of the hand-made species (seeds
# 1-4; needs a window), splits every tree_card_* in the texture inbox into a 2 x 2 grid of
# tiles (big images were drawn in N64-sized loads), imports each tile as a 16-colour CI4
# cut-out at the most texels TMEM allows (64x64; 32x128 tiles tall, 128x32 wide: a card is
# 128x128 / 64x256 / 256x64), then puts the cards on the species presets.
#   tools/tree_import/cards.sh [render]     (render: re-render the hand-made variants first)
set -e
cd "${0:A:h}/../.."
G="${GODOT:-/Users/sakwa/Library/Application Support/Godot/app_userdata/Godots/versions/Godot_v4_7_2-stable_mono_macos_universal/Godot_mono.app/Contents/MacOS/Godot}"
PY=tools/anim_ref/.venv-pose/bin/python
W=tools/tree_import/work/cards_$(date +%Y%m%d_%H%M%S)
mkdir -p $W
if [ "$1" = "render" ]; then
	perl -e 'alarm 300; exec @ARGV' "$G" --path . tests/trees/make_cards.tscn 2>&1 | grep -E "^card|SCRIPT ERROR" || true
fi
# Split each card into its tiles (left to right, top to bottom: _t0 .. _t3).
$PY -I - <<'PYEOF'
import os
from PIL import Image
inbox = "texture_inbox"
for f in sorted(os.listdir(inbox)):
	if not f.startswith("tree_card_") or "_t" in f[-7:] or not f.endswith(".png"):
		continue
	im = Image.open(os.path.join(inbox, f)).convert("RGBA")
	a = im.width / im.height
	tw, th = (32, 128) if a < 0.5 else ((128, 32) if a > 2.0 else (64, 64))
	im = im.resize((tw * 2, th * 2), Image.LANCZOS)
	px = im.load()
	for y in range(im.height):
		for x in range(im.width):
			r, g, b, al = px[x, y]
			px[x, y] = (r, g, b, 255) if al >= 128 else (0, 0, 0, 0)
	base = f[:-4]
	for t in range(4):
		cx, cy = t % 2, t // 2
		im.crop((cx * tw, cy * th, (cx + 1) * tw, (cy + 1) * th)).save(os.path.join(inbox, "%s_t%d.png" % (base, t)))
	os.remove(os.path.join(inbox, f))
	print("split", base)
PYEOF
perl -e 'alarm 300; exec @ARGV' "$G" --headless --path . --script res://addons/n64_level_tools/textures/inbox_import.gd -- list $PWD/$W/list.json >/dev/null 2>&1
$PY -I - $W <<'PYEOF'
import json, os, sys
w = sys.argv[1]
items = json.load(open(os.path.join(w, "list.json")))["items"]
plan = []
for it in items:
	if not os.path.basename(it["file"]).startswith("tree_card_"):
		continue
	size = [it["width"], it["height"]]  # one tile, already cut to its N64 size
	plan.append({"file": it["file"], "archive": it["archive"], "category": "plants", "object": 0, "tiling": 3, "usage": 1,
		"format": 8, "size": size, "sharpen": 0.0, "tint_amount": 0.0, "tint_auto": False})
json.dump(plan, open(os.path.join(w, "plan.json"), "w"), indent=1)
print("cards to import:", len(plan))
PYEOF
perl -e 'alarm 600; exec @ARGV' "$G" --headless --path . --script res://addons/n64_level_tools/textures/inbox_import.gd -- import $PWD/$W/plan.json $PWD/$W/imported.json $PWD/$W/cards.png 2>&1 | grep -E "SCRIPT ERROR" || true
perl -e 'alarm 300; exec @ARGV' "$G" --headless --path . --import >/dev/null 2>&1 || true
perl -e 'alarm 300; exec @ARGV' "$G" --headless --path . -s res://addons/n64_level_tools/trees/assign_cards.gd 2>&1 | grep -E "card|SCRIPT ERROR"
echo "work files: $W"
