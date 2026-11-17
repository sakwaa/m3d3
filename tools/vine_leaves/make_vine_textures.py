"""Draws the creeping-vine textures (WorldVines), N64 style like tools/tree_leaves: a few
flat greens, 1-bit alpha, lit from the top left. Writes PNGs into texture_inbox/ for the
usual texture import (category plants):
  vine_leaf.png       one pointed oval leaf on a short stalk (stalk at the bottom middle)
  vine_leaf_heart.png one heart-shaped leaf, same layout
  vine_stem.png       twisted rope-like stem bark, tiling both ways (u round, v along)
Run: tools/anim_ref/.venv-pose/bin/python -I tools/vine_leaves/make_vine_textures.py [OUT_DIR]
Not shipped (tools/ is export-excluded); the imported textures are.
"""
import math
import os
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "texture_inbox")
SS = 8  # supersampling, then a hard alpha threshold

GREENS = [(30, 58, 22), (44, 82, 28), (62, 106, 36), (86, 132, 48), (112, 156, 64)]


def finish(im, size, path, cutout=True):
	small = im.resize(size, Image.LANCZOS)
	if cutout:
		px = small.load()
		for y in range(size[1]):
			for x in range(size[0]):
				r, g, b, a = px[x, y]
				px[x, y] = (r, g, b, 255) if a >= 128 else (0, 0, 0, 0)
	small.save(path)
	print("wrote", path)


def leaf_outline(w, h, shape):
	"""Outline points (x, y), the leaf pointing up, its stalk end at the bottom middle."""
	pts = []
	base_y, tip_y = h * 0.86, h * 0.04
	cx = w * 0.5
	n = 64
	for i in range(n + 1):
		t = i / n  # 0 = base, up the right edge to the tip at 1 ... then mirrored
		y = base_y + (tip_y - base_y) * t
		if shape == "heart":
			# Heart: round lobes either side of a notch at the stalk, a pointed tip.
			half = math.sin(math.pi * min(t ** 0.5, 1.0)) ** 0.7 * (1.0 - t) ** 0.3 * w * 0.48
			y -= h * 0.08 * (1.0 - smooth(0.0, 0.25, t)) * (1.0 if half < w * 0.12 else 0.0)
		else:
			# Pointed oval: widest a third of the way up, a drawn-out tip.
			half = math.sin(math.pi * t ** 0.8) * (1.0 - t) ** 0.3 * w * 0.48
		pts.append((cx + half, y))
	return pts + [(2 * cx - x, y) for x, y in reversed(pts)]


def smooth(a, b, t):
	k = min(max((t - a) / (b - a), 0.0), 1.0)
	return k * k * (3 - 2 * k)


def leaf(shape, size=(32, 32)):
	w, h = size[0] * SS, size[1] * SS
	im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
	d = ImageDraw.Draw(im)
	# The stalk.
	d.line([(w * 0.5, h), (w * 0.5, h * 0.82)], fill=GREENS[0] + (255,), width=int(SS * 1.6))
	outline = leaf_outline(w, h, shape)
	d.polygon(outline, fill=GREENS[2] + (255,))
	# Light from the top left: the left half a shade lighter, the right darker, a lit rim.
	cx = w * 0.5
	left = [(x, y) for x, y in outline if x <= cx + 1]
	d.polygon(left + [(cx, h * 0.86)], fill=GREENS[3] + (255,))
	d.polygon([(x, y) for x, y in outline if x >= cx - 1] + [(cx, h * 0.86)], fill=GREENS[1] + (255,))
	inner = [(cx + (x - cx) * 0.55, h * 0.45 + (y - h * 0.45) * 0.7) for x, y in left]
	d.polygon(inner + [(cx, h * 0.7)], fill=GREENS[4] + (255,))
	# Midrib and a few veins.
	d.line([(cx, h * 0.86), (cx, h * 0.12)], fill=GREENS[0] + (255,), width=SS)
	for k in range(3):
		y0 = h * (0.72 - k * 0.17)
		for s in (-1, 1):
			d.line([(cx, y0), (cx + s * w * 0.2, y0 - h * 0.1)], fill=GREENS[1] + (255,), width=SS // 2)
	return im


def stem(size=(32, 32)):
	"""Twisted fibres winding round the stem: diagonal strands, wrapped so it tiles."""
	w, h = size[0] * SS, size[1] * SS
	im = Image.new("RGBA", (w, h), (64, 66, 38, 255))
	d = ImageDraw.Draw(im)
	browns = [(42, 40, 24), (58, 58, 32), (78, 80, 42), (98, 104, 54), (120, 126, 68)]
	strands = 3
	period = w / strands
	for s in range(strands):
		x0 = s * period
		for dx in (-w, 0, w):
			# One strand: a band leaning across (one turn over the tile's height).
			poly = [(x0 + dx, h), (x0 + dx + period * 0.86, h), (x0 + dx + period * 0.86 + w, 0), (x0 + dx + w, 0)]
			d.polygon(poly, fill=browns[2] + (255,))
			# Lit edge and shadowed groove.
			d.line([(x0 + dx + period * 0.15, h), (x0 + dx + period * 0.15 + w, 0)], fill=browns[4] + (255,), width=SS * 2)
			d.line([(x0 + dx + period * 0.35, h), (x0 + dx + period * 0.35 + w, 0)], fill=browns[3] + (255,), width=SS * 2)
			d.line([(x0 + dx + period * 0.86, h), (x0 + dx + period * 0.86 + w, 0)], fill=browns[0] + (255,), width=SS * 3)
	# Knots / nodes: a few dark flecks.
	for k, (fx, fy) in enumerate([(0.2, 0.3), (0.65, 0.75), (0.85, 0.2)]):
		x, y = fx * w, fy * h
		d.ellipse([x - SS * 1.5, y - SS, x + SS * 1.5, y + SS], fill=browns[1] + (255,))
	return im


if __name__ == "__main__":
	os.makedirs(OUT, exist_ok=True)
	finish(leaf("oval"), (32, 32), os.path.join(OUT, "vine_leaf.png"))
	finish(leaf("heart"), (32, 32), os.path.join(OUT, "vine_leaf_heart.png"))
	finish(stem(), (32, 32), os.path.join(OUT, "vine_stem.png"), cutout=False)
