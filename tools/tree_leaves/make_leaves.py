"""Draws the leaf-cluster cut-out textures the tree generator puts on its leaf cards (one
per species), N64 style: a few flat greens, 1-bit alpha, lit from the top left. Writes
PNGs (RGBA) into texture_inbox/ for the usual texture import (category plants).
Run: tools/anim_ref/.venv-pose/bin/python -I tools/tree_leaves/make_leaves.py [OUT_DIR]
Not shipped (tools/ is export-excluded); the imported textures are.
"""
import math
import os
import random
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "texture_inbox")
SS = 4  # supersampling, then a hard alpha threshold


def shade(base, k):
	return tuple(max(0, min(255, int(c * k))) for c in base)


def palmate(cx, cy, r, ang, lobes=5, depth=0.45):
	"""Sycamore / maple: palmate leaf with `lobes` pointed lobes."""
	pts = []
	n = lobes * 2
	for i in range(n * 3):
		t = i / (n * 3)
		a = ang - math.pi * 0.85 + t * math.pi * 1.7
		phase = (t * n) % 2.0
		rr = r * (1.0 - depth * (1.0 - abs(1.0 - phase)))  # points at the lobe tips
		pts.append((cx + math.cos(a) * rr, cy + math.sin(a) * rr))
	pts.append((cx, cy))
	return pts


def lobed(cx, cy, r, ang, lobes=4):
	"""Oak: oblong leaf with rounded lobes down each side."""
	pts = []
	steps = 48
	for i in range(steps):
		t = i / steps * 2 * math.pi
		along = math.cos(t)  # -1 stem .. 1 tip
		w = 0.55 * math.sin(t) * (1.0 - 0.25 * along)
		w *= 1.0 + 0.28 * math.cos(t * lobes * 2)  # wavy margin
		x, y = along * r, w * r
		ca, sa = math.cos(ang), math.sin(ang)
		pts.append((cx + x * ca - y * sa, cy + x * sa + y * ca))
	return pts


def lance(cx, cy, length, width, ang):
	"""Willow: long narrow leaf."""
	pts = []
	for i in range(16):
		t = i / 16 * 2 * math.pi
		x, y = math.cos(t) * length * 0.5, math.sin(t) * width * 0.5
		ca, sa = math.cos(ang), math.sin(ang)
		pts.append((cx + x * ca - y * sa, cy + x * sa + y * ca))
	return pts


def lit(x, y, w, h, light):
	"""Brightness for a leaf at (x, y): lighter towards the top left, darker inside."""
	nx, ny = x / w - 0.5, y / h - 0.5
	return 0.72 + light * (-nx * 0.35 - ny * 0.6)


def broadleaf(name, size, greens, leaf, count, leaf_r, rnd, stems=True):
	w, h = size
	im = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
	d = ImageDraw.Draw(im)
	cx, cy = w * SS / 2, h * SS / 2
	# A clump: leaves scattered in a rough disc (denser in the middle), back to front.
	pts = []
	for _ in range(count):
		a = rnd.uniform(0, 2 * math.pi)
		r = math.sqrt(rnd.random()) * (w * SS * 0.5 - leaf_r * SS * 1.1)
		pts.append((cx + math.cos(a) * r, cy + math.sin(a) * r * 0.9, a))
	pts.sort(key=lambda p: p[1])
	if stems:
		for x, y, a in pts[::3]:
			d.line([(cx, h * SS), (x, y)], fill=shade(greens[0], 0.5) + (255,), width=SS)
	for x, y, a in pts:
		k = lit(x / SS, y / SS, w, h, 1.0) + rnd.uniform(-0.12, 0.12)
		g = greens[min(len(greens) - 1, max(0, int((k - 0.45) * len(greens))))]
		ang = math.atan2(y - h * SS, x - cx) + rnd.uniform(-0.6, 0.6)
		d.polygon(leaf(x, y, leaf_r * SS * rnd.uniform(0.8, 1.15), ang), fill=g + (255,))
	return im


def needles(name, size, greens, rnd):
	"""Fir: a flat spray seen from above, twig along the card (left -> right), twiglets
	off both sides, short needles."""
	w, h = size
	im = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
	d = ImageDraw.Draw(im)
	y0 = h * SS / 2
	twig = greens[0]

	def spray(x0, y0, x1, y1, n, nl):
		d.line([(x0, y0), (x1, y1)], fill=shade(twig, 0.6) + (255,), width=SS)
		for i in range(n):
			t = i / n
			x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
			a = math.atan2(y1 - y0, x1 - x0)
			for side in (-1, 1):
				na = a + side * rnd.uniform(0.9, 1.3)
				ll = nl * (1.0 - 0.5 * t) * rnd.uniform(0.8, 1.1)
				k = lit(x / SS, y / SS, w, h, 1.0) + rnd.uniform(-0.15, 0.1)
				g = greens[min(len(greens) - 1, max(0, int((k - 0.45) * len(greens))))]
				d.line([(x, y), (x + math.cos(na) * ll, y + math.sin(na) * ll)], fill=g + (255,), width=SS)

	main_n = 18
	for i in range(main_n):
		t = i / main_n
		x = SS * 2 + t * (w * SS - SS * 6)
		side = 1 if i % 2 else -1
		reach = h * SS * 0.42 * (1.0 - 0.6 * t)
		spray(x, y0, x + reach * 0.55, y0 + side * reach, 7, SS * 3.2)
	spray(SS * 2, y0, w * SS - SS * 2, y0, 22, SS * 4.0)
	return im


def streamers(name, size, greens, rnd):
	"""Willow: thin branchlets hanging straight down the card, narrow leaves along them."""
	w, h = size
	im = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
	d = ImageDraw.Draw(im)
	n = 7
	for i in range(n):
		x0 = (i + 0.5 + rnd.uniform(-0.3, 0.3)) / n * w * SS
		length = h * SS * rnd.uniform(0.75, 0.98)
		sway = rnd.uniform(-1, 1) * SS * 3
		d.line([(x0, 0), (x0 + sway, length)], fill=shade(greens[0], 0.6) + (255,), width=SS)
		y = SS * 2
		while y < length:
			t = y / length
			x = x0 + sway * t
			for side in (-1, 1):
				ang = math.pi / 2 + side * rnd.uniform(0.25, 0.5)
				k = 0.95 - 0.35 * t + rnd.uniform(-0.12, 0.12)
				g = greens[min(len(greens) - 1, max(0, int((k - 0.45) * len(greens))))]
				ll = SS * rnd.uniform(5.5, 7.5)
				d.polygon(lance(x + math.cos(ang) * ll * 0.5, y + math.sin(ang) * ll * 0.5, ll, SS * 1.6, ang), fill=g + (255,))
			y += SS * rnd.uniform(2.5, 3.5)
	return im


def finish(im, size, path):
	small = im.resize(size, Image.LANCZOS)
	px = small.load()
	for y in range(size[1]):
		for x in range(size[0]):
			r, g, b, a = px[x, y]
			px[x, y] = (r, g, b, 255) if a >= 128 else (0, 0, 0, 0)
	small.save(path)
	print("wrote", path)


SPECIES = {
	# Sycamore (Acer pseudoplatanus): big five-lobed leaves, mid green.
	"sycamore": lambda r: broadleaf("sycamore", (64, 64), [(38, 74, 26), (54, 98, 34), (74, 124, 44), (104, 150, 62)], palmate, 46, 6.0, r),
	# English oak (Quercus robur): small wavy-lobed leaves in dense clumps, darker green.
	"oak": lambda r: broadleaf("oak", (64, 64), [(34, 62, 22), (50, 84, 28), (68, 104, 36), (92, 126, 50)], lobed, 80, 4.2, r),
	# Fir (Abies): flat needle sprays, dark blue-green.
	"fir": lambda r: needles("fir", (64, 32), [(20, 46, 34), (28, 62, 44), (40, 80, 56), (58, 100, 70)], r),
	# Weeping willow (Salix babylonica): hanging streamers, light yellow-green.
	"willow": lambda r: streamers("willow", (32, 64), [(72, 104, 34), (96, 128, 44), (124, 154, 60), (150, 176, 82)], r),
}

if __name__ == "__main__":
	os.makedirs(OUT, exist_ok=True)
	for name, make in SPECIES.items():
		rnd = random.Random(name)
		im = make(rnd)
		finish(im, (im.width // SS, im.height // SS), os.path.join(OUT, "leaves_%s.png" % name))
