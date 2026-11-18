"""Draws the creeping-vine textures (WorldVines), N64 style like tools/tree_leaves: a few
flat greens, 1-bit alpha, lit from the top left. Writes PNGs into texture_inbox/ for the
usual texture import (category plants):
  vine_leaf.png       one pointed oval leaf on a short stalk (stalk at the bottom middle)
  vine_leaf_heart.png one heart-shaped leaf, same layout
  vine_stem.png       twisted rope-like stem bark, tiling both ways (u round, v along)
  vine_sprig.png      three leaves fanned out on stalks from one point (bottom middle): one
                      triangle (apex at the stalks) carries all three
  vine_card.png       a whole vine seen from above, tiling along its length (v): the stem
                      down the middle, leaves alternating either side (one strip = stem + leaves)
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


def draw_leaf(d, base, length, angle_deg, wrap_h=0, shape="oval"):
	"""A leaf drawn straight onto `d`: stalk end at `base`, `length` px (at SS) long, turned
	`angle_deg` from pointing up (+ = clockwise). Shaded like leaf(): the left half lighter,
	a bright patch, a dark midrib. wrap_h: drawn again a canvas height above and below."""
	unit = leaf_outline(1.0, 1.0, shape)  # (in a unit box: base at (0.5, 0.86), tip at (0.5, 0.04))
	a = math.radians(angle_deg)
	ca, sa = math.cos(a), math.sin(a)
	def tf(x, y):
		# unit box -> leaf space (base at origin, up = -y), scaled, turned, moved
		lx, ly = (x - 0.5) * length / 0.82, (y - 0.86) * length / 0.82
		return (base[0] + lx * ca - ly * sa, base[1] + lx * sa + ly * ca)
	for dy in ([0] if not wrap_h else [-wrap_h, 0, wrap_h]):
		pts = [(x, y + dy) for x, y in (tf(*q) for q in unit)]
		d.polygon(pts, fill=GREENS[1] + (255,))
		left = [tf(x, y) for x, y in unit if x <= 0.501]
		d.polygon([(x, y + dy) for x, y in left] + [(tf(0.5, 0.86)[0], tf(0.5, 0.86)[1] + dy)], fill=GREENS[3] + (255,))
		inner = [tf(0.5 + (x - 0.5) * 0.55, 0.45 + (y - 0.45) * 0.7) for x, y in unit if x <= 0.501]
		d.polygon([(x, y + dy) for x, y in inner] + [(tf(0.5, 0.7)[0], tf(0.5, 0.7)[1] + dy)], fill=GREENS[4] + (255,))
		b0, b1 = tf(0.5, 0.86), tf(0.5, 0.14)
		d.line([(b0[0], b0[1] + dy), (b1[0], b1[1] + dy)], fill=GREENS[0] + (255,), width=max(SS // 2, 2))


def sprig(size=(64, 64)):
	"""Three leaves fanned from a point at the bottom middle, on short stalks."""
	w, h = size[0] * SS, size[1] * SS
	im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
	d = ImageDraw.Draw(im)
	root = (w * 0.5, h * 0.97)
	for ang, ln, st in [(-34, 0.42, 0.16), (34, 0.42, 0.16), (0, 0.52, 0.12)]:
		a = math.radians(ang)
		b = (root[0] + math.sin(a) * h * st, root[1] - math.cos(a) * h * st)
		d.line([root, b], fill=GREENS[0] + (255,), width=int(SS * 1.6))
		draw_leaf(d, b, h * ln, ang)
	return im


def card(size=(64, 64)):
	"""A vine from above, tiling along v: stem down the middle, leaves either side."""
	w, h = size[0] * SS, size[1] * SS
	im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
	d = ImageDraw.Draw(im)
	browns = [(42, 40, 24), (58, 58, 32), (78, 80, 42), (98, 104, 54), (120, 126, 68)]
	sw = w * 0.12  # stem width
	x0, x1 = w * 0.5 - sw / 2, w * 0.5 + sw / 2
	# Leaves first (the stem over their stalks): six a tile, alternating, out and forwards.
	n = 4
	for i in range(n):
		side = -1 if i % 2 == 0 else 1
		y = (i + 0.5) * h / n
		ln = w * (0.44 if i % 2 == 0 else 0.4)
		draw_leaf(d, (w * 0.5 + side * sw * 0.3, y), ln, side * (50 + 12 * ((i * 7) % 3)), wrap_h=h)
	d.rectangle([x0, 0, x1, h], fill=browns[2] + (255,))
	turns = 5
	for k in range(turns + 1):
		y = k * h / turns
		d.line([(x0, y), (x1, y - h / turns * 0.6)], fill=browns[4] + (255,), width=int(SS * 1.2))
		d.line([(x0, y + h / turns * 0.45), (x1, y - h / turns * 0.15)], fill=browns[0] + (255,), width=int(SS * 1.2))
	d.line([(x0, 0), (x0, h)], fill=browns[0] + (255,), width=SS)
	return im


if __name__ == "__main__":
	os.makedirs(OUT, exist_ok=True)
	finish(leaf("oval"), (32, 32), os.path.join(OUT, "vine_leaf.png"))
	finish(leaf("heart"), (32, 32), os.path.join(OUT, "vine_leaf_heart.png"))
	finish(stem(), (32, 32), os.path.join(OUT, "vine_stem.png"), cutout=False)
	finish(sprig(), (64, 64), os.path.join(OUT, "vine_sprig.png"))
	finish(card(), (64, 64), os.path.join(OUT, "vine_card.png"))
