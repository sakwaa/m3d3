"""Draws a fern clump cut-out (forest undergrowth: LevelData scatter sets, CROSS style), N64
style like tools/vine_leaves: a few flat greens, 1-bit alpha, lit from the top left. Fronds
arch up and out from one root point (bottom middle), each a curved stalk with leaflets that
shrink towards its tip; the back fronds darker. Writes texture_inbox/fern_clump.png for the
usual texture import (category plants, tiling None, usage Decal).
Run: tools/anim_ref/.venv-pose/bin/python -I tools/ferns/make_fern.py [OUT_DIR]
Not shipped (tools/ is export-excluded); the imported texture is.
"""
import math
import os
import random
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "texture_inbox")
SS = 8  # supersampling, then a hard alpha threshold
W, H = 64, 64

GREENS = [(22, 44, 18), (32, 62, 24), (44, 82, 30), (60, 104, 38), (82, 128, 50)]


def frond(d, root, angle, length, droop, shade, rng):
	"""One frond: a stalk from `root` leaving at `angle` (radians from straight up, + right),
	bending down by `droop`, leaflets either side shrinking to the tip."""
	steps = 28
	pts = []
	for i in range(steps + 1):
		t = i / steps
		a = angle + droop * t * t * (1.0 if angle >= 0 else -1.0)
		if i == 0:
			x, y = root
		else:
			x, y = pts[-1]
			seg = length / steps
			x += math.sin(a) * seg
			y -= math.cos(a) * seg
		pts.append((x, y))
	dark = GREENS[max(shade - 1, 0)]
	mid = GREENS[shade]
	light = GREENS[min(shade + 1, len(GREENS) - 1)]
	# Leaflets: from a third of the way up, both sides, angled forward along the frond.
	for i in range(5, steps, 2):
		t = i / steps
		x0, y0 = pts[i]
		x1, y1 = pts[min(i + 1, steps)]
		dx, dy = x1 - x0, y1 - y0
		n = math.hypot(dx, dy) or 1.0
		dx, dy = dx / n, dy / n
		size = length * 0.2 * (1.0 - t) ** 0.8 + length * 0.02
		for side in (-1, 1):
			# (perpendicular, swept towards the tip)
			px, py = -dy * side, dx * side
			tipx = x0 + (px * 0.85 + dx * 0.5) * size
			tipy = y0 + (py * 0.85 + dy * 0.5) * size + size * 0.12
			w = size * 0.28
			poly = [(x0 - dx * w, y0 - dy * w), (tipx, tipy), (x0 + dx * w * 1.6, y0 + dy * w * 1.6)]
			# Lit from the top left: leaflets on the left / upper side lighter.
			col = light if (side < 0) == (angle >= 0) else mid
			if rng.random() < 0.2:
				col = dark
			d.polygon(poly, fill=col + (255,))
	d.line(pts, fill=dark + (255,), width=max(int(SS * 0.9), 1))


def main():
	rng = random.Random(7)
	im = Image.new("RGBA", (W * SS, H * SS), (0, 0, 0, 0))
	d = ImageDraw.Draw(im)
	root = (W * SS * 0.5, H * SS * 0.97)
	# Back fronds first (darker, more upright), then the front ones arching out.
	fronds = []
	for k in range(5):
		fronds.append((rng.uniform(-0.5, 0.5), H * SS * rng.uniform(0.7, 0.85), rng.uniform(0.3, 0.6), 1))
	for k in range(6):
		side = -1 if k % 2 == 0 else 1
		fronds.append((side * rng.uniform(0.5, 1.15), H * SS * rng.uniform(0.6, 0.78), rng.uniform(0.7, 1.2), rng.choice([2, 3])))
	for a, length, droop, shade in fronds:
		frond(d, root, a, length, droop, shade, rng)
	small = im.resize((W, H), Image.LANCZOS)
	px = small.load()
	for y in range(H):
		for x in range(W):
			r, g, b, a = px[x, y]
			px[x, y] = (r, g, b, 255) if a >= 128 else (0, 0, 0, 0)
	os.makedirs(OUT, exist_ok=True)
	path = os.path.join(OUT, "fern_clump.png")
	small.save(path)
	print("wrote", path)


if __name__ == "__main__":
	main()
