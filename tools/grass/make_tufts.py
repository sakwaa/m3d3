"""Draws the grass tuft cut-out the grass layer scatters over its mat (and its far card):
a fan of tapered blades from a point at the bottom, dark at the root, light at the tips,
N64 style (a few flat greens, 1-bit alpha). Writes texture_inbox/grass_tuft.png for the
texture import (category plants, tiling None, usage Decal).
Run: tools/anim_ref/.venv-pose/bin/python -I tools/grass/make_tufts.py [OUT_DIR]
"""
import math
import os
import random
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "texture_inbox")
SS = 4
W, H = 32, 32
GREENS = [(46, 74, 26), (64, 98, 32), (86, 124, 40), (112, 150, 54), (142, 174, 74)]


def blade(d, x0, y0, length, lean, width, rnd):
	"""A tapered blade from (x0, y0) up, leaning `lean` (radians), curving a little."""
	pts_l, pts_r = [], []
	steps = 10
	curve = rnd.uniform(-0.25, 0.25)
	for i in range(steps + 1):
		t = i / steps
		a = lean + curve * t * t
		x = x0 + math.sin(a) * length * t
		y = y0 - math.cos(a) * length * t
		w = width * (1.0 - t) ** 0.8
		nx, ny = math.cos(a), math.sin(a)
		pts_l.append((x - nx * w, y - ny * w))
		pts_r.append((x + nx * w, y + ny * w))
	return pts_l + pts_r[::-1]


def main():
	os.makedirs(OUT, exist_ok=True)
	rnd = random.Random("tuft")
	im = Image.new("RGBA", (W * SS, H * SS), (0, 0, 0, 0))
	d = ImageDraw.Draw(im)
	n = 16
	blades = []
	for i in range(n):
		lean = (i / (n - 1) - 0.5) * 1.5 + rnd.uniform(-0.15, 0.15)
		length = H * SS * rnd.uniform(0.6, 0.97) * (1.0 - 0.3 * abs(lean))
		blades.append((abs(lean) + rnd.random() * 0.3, lean, length))
	blades.sort(reverse=True)  # outer (darker, behind) first
	for depth, lean, length in blades:
		x0 = W * SS / 2 + rnd.uniform(-1.5, 1.5) * SS
		poly = blade(d, x0, H * SS - SS, length, lean, SS * rnd.uniform(1.1, 1.6), rnd)
		shade = max(0, min(len(GREENS) - 1, int((1.0 - depth * 0.6) * len(GREENS)) - rnd.randint(0, 1)))
		d.polygon(poly, fill=GREENS[shade] + (255,))
		# Light tip.
		tip = blade(d, x0, H * SS - SS, length, lean, SS * 1.0, rnd)[3:8]
		if len(tip) > 2:
			d.polygon(tip + [poly[-4]], fill=GREENS[min(shade + 1, len(GREENS) - 1)] + (255,))
	small = im.resize((W, H), Image.LANCZOS)
	px = small.load()
	for y in range(H):
		for x in range(W):
			r, g, b, a = px[x, y]
			px[x, y] = (r, g, b, 255) if a >= 110 else (0, 0, 0, 0)
	out = os.path.join(OUT, "grass_tuft.png")
	small.save(out)
	print("wrote", out)


if __name__ == "__main__":
	main()
