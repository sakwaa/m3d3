"""Tree importer, step 1 (analysis): turns cut-out photos of real trees (one tree on a
plain light background, e.g. the ImageCELs Trees CD) into what the tree generator needs:
  - measurements: height:width, bare trunk (crown base), trunk width, the crown's outline
    (half width at 16 heights), widest point, bark and foliage colours;
  - leaves_<name>.png: a leaf-cluster cut-out taken from the photo's own foliage (an edge
    patch, its rim thinned by brightness so it frays like leaves, not a square);
  - card_<name>.png: the whole tree, small, for the far stand-in;
  - <name>_mask.png: what was taken as the tree (check it).
Step 2 (Godot: addons/n64_level_tools/trees/tree_import.gd) imports the textures and
writes TreeSpecies presets from analysis.json.

usage: tools/anim_ref/.venv-pose/bin/python -I tools/tree_import/tree_import.py OUT_DIR IMAGE...
Species names come from species.json (photo code -> name, archetype, real height); photos
not listed there use their file name and archetype "broadleaf".
"""
import json
import os
import sys

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SPECIES = json.load(open(os.path.join(HERE, "species.json")))
BANDS = 16
LEAF_SIZE = 64


def load(path):
	im = cv2.imread(path, cv2.IMREAD_COLOR)
	if im is None:
		raise SystemExit("can't read " + path)
	return im


def mask_of(im):
	"""The tree: everything but the light, colourless background (inside the crown too: sky
	seen through gaps), less a pixel of the pale fringe, keeping the main blob."""
	lab = cv2.cvtColor(im, cv2.COLOR_BGR2LAB).astype(np.int32)
	light = (lab[:, :, 0] > 215) & (np.abs(lab[:, :, 1] - 128) < 12) & (np.abs(lab[:, :, 2] - 128) < 12)
	tree = (~light).astype(np.uint8)
	tree = cv2.erode(tree, np.ones((3, 3), np.uint8))
	n, lbl, stats, _ = cv2.connectedComponentsWithStats(tree, 8)
	if n > 1:
		big = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
		keep = stats[:, cv2.CC_STAT_AREA] > max(30, stats[big, cv2.CC_STAT_AREA] * 0.0005)
		keep[0] = False
		return keep[lbl]
	return tree.astype(bool)


def measure(im, tree):
	ys, xs = np.nonzero(tree)
	top, bottom = ys.min(), ys.max()
	left, right = xs.min(), xs.max()
	height = bottom - top + 1
	widths = tree.sum(axis=1)
	# Trunk: the narrow run just above the bottom (5-12% of the height).
	rows = [r for r in range(bottom - int(height * 0.15), bottom - int(height * 0.01)) if widths[r] > 0]
	trunk_w = float(np.percentile([widths[r] for r in rows], 20)) if rows else 1.0
	narrow = [r for r in rows if widths[r] <= trunk_w * 1.3] or rows
	trunk_x = float(np.median([np.nonzero(tree[r])[0].mean() for r in narrow]))
	# Crown base: going up from the ground, the first row clearly wider than the trunk (a
	# crown down to the ground, conifers: right at the bottom).
	base = bottom
	for r in range(bottom, top, -1):
		if widths[r] > max(trunk_w * 3.0, height * 0.06):
			base = r
			break
	rows = narrow
	clear = (bottom - base) / height
	# Outline: half width (about the trunk's line) at BANDS heights through the crown, as
	# fractions of the tree's height.
	profile = []
	for i in range(BANDS):
		y0 = int(base - (base - top) * i / BANDS)
		y1 = int(base - (base - top) * (i + 1) / BANDS)
		band = tree[max(y1, top):max(y0, top + 1)]
		cols = np.nonzero(band.any(axis=0))[0]
		half = ((cols.max() - cols.min() + 1) / 2.0) if cols.size else 0.0
		profile.append(round(half / height, 4))
	widest = int(np.argmax(profile))
	# Colours: trunk (bottom run, middle of the trunk) and foliage (the crown).
	tr = [(r, int(trunk_x)) for r in rows if tree[r, int(trunk_x)]]
	bark = np.mean([im[r, c] for r, c in tr], axis=0)[::-1] / 255.0 if tr else np.array([0.4, 0.33, 0.28])
	crown = tree.copy()
	crown[base:, :] = False
	leaf = np.mean(im[crown], axis=0)[::-1] / 255.0
	return {
		"height_px": int(height), "width_px": int(right - left + 1),
		"aspect": round((right - left + 1) / height, 3),
		"clear": round(float(clear), 3),
		"trunk_width": round(trunk_w / height, 4),
		"profile": profile, "widest": round((widest + 0.5) / BANDS, 3),
		"crown_width": round(max(profile) * 2, 3),
		"bark_rgb": [round(float(c), 3) for c in bark],
		"leaf_rgb": [round(float(c), 3) for c in leaf],
		"box": [int(left), int(top), int(right), int(bottom)], "base_y": int(base),
	}


def leaf_patch(im, tree, m, weeping):
	"""A leaf-cluster cut-out from the foliage: a window on the crown's upper edge (or for
	weeping trees, a tall one on the hanging curtain's lower edge) about half covered, its
	rim thinned by brightness (darker gaps go first) so it frays like leaves."""
	left, top, right, bottom = m["box"]
	H = bottom - top
	side = max(16, int(H * (0.16 if not weeping else 0.12)))
	tall = side * 2 if weeping else side
	best, best_score = None, -1.0
	gray = cv2.cvtColor(im, cv2.COLOR_BGR2GRAY).astype(np.float32)
	step = max(4, side // 6)
	y_lo, y_hi = top, m["base_y"] - tall
	if weeping:
		y_lo, y_hi = top + int(H * 0.25), bottom - tall - int(H * 0.05)
	for y in range(y_lo, max(y_lo + 1, y_hi), step):
		for x in range(left, right - side, step):
			win = tree[y:y + tall, x:x + side]
			cov = win.mean()
			if not (0.5 <= cov <= 0.85):
				continue
			if np.abs(x + side / 2 - (left + right) / 2) < side * 0.6 and not weeping:
				continue  # not the top centre (often the leader / sky gap)
			detail = gray[y:y + tall, x:x + side][win].std()
			score = detail * (1.0 - abs(cov - 0.68))
			if score > best_score:
				best, best_score = (x, y), score
	if best is None:
		x, y = (left + right) // 2 - side // 2, top + int(H * 0.2)
	else:
		x, y = best
	rgb = im[y:y + tall, x:x + side].copy()
	a = tree[y:y + tall, x:x + side].astype(np.float32)
	g = gray[y:y + tall, x:x + side]
	gn = (g - g.min()) / max(1e-3, g.max() - g.min())
	yy, xx = np.mgrid[0:tall, 0:side]
	if weeping:
		d = np.abs((xx + 0.5) / side - 0.5) * 2.0  # fray left / right only
		d = np.maximum(d, np.clip(((yy + 0.5) / tall - 0.85) / 0.15, 0, 1))
	else:
		d = np.hypot((xx + 0.5) / side - 0.5, (yy + 0.5) / tall - 0.5) * 2.0
	keep = (d < 0.55) | ((d < 1.0) & (gn > (d - 0.55) / 0.45 * 0.9 + 0.1))
	a = a * keep
	out_w, out_h = LEAF_SIZE // (2 if weeping else 1), LEAF_SIZE
	rgb = cv2.resize(rgb, (out_w, out_h), interpolation=cv2.INTER_AREA)
	a = cv2.resize(a, (out_w, out_h), interpolation=cv2.INTER_AREA)
	rgba = np.dstack([rgb, np.where(a >= 0.5, 255, 0).astype(np.uint8)])
	rgba[a < 0.5, :3] = 0
	return rgba, [int(x), int(y), int(side), int(tall)]


def card(im, tree, m, width=256):
	left, top, right, bottom = m["box"]
	pad = 2
	crop = im[top:bottom + 1, left:right + 1]
	a = tree[top:bottom + 1, left:right + 1].astype(np.float32)
	h = int(round(width * crop.shape[0] / crop.shape[1]))
	if h > width * 2:
		h = width * 2
		width = int(round(h * crop.shape[1] / crop.shape[0]))
	rgb = cv2.resize(crop, (width - pad * 2, h - pad), interpolation=cv2.INTER_AREA)
	al = cv2.resize(a, (width - pad * 2, h - pad), interpolation=cv2.INTER_AREA)
	out = np.zeros((h, width, 4), np.uint8)
	out[:h - pad, pad:width - pad, :3] = rgb
	out[:h - pad, pad:width - pad, 3] = np.where(al >= 0.5, 255, 0)
	return out


def main():
	out = sys.argv[1]
	os.makedirs(out, exist_ok=True)
	results = []
	for path in sys.argv[2:]:
		code = os.path.splitext(os.path.basename(path))[0].upper()
		info = SPECIES.get(code, {"name": code.lower(), "archetype": "broadleaf", "height": 12})
		name = info["name"]
		im = load(path)
		tree = mask_of(im)
		m = measure(im, tree)
		weeping = info["archetype"] == "weeping"
		leaves, window = leaf_patch(im, tree, m, weeping)
		cv2.imwrite(os.path.join(out, "leaves_%s.png" % name), leaves)
		cv2.imwrite(os.path.join(out, "card_%s.png" % name), card(im, tree, m))
		ov = im.copy()
		ov[~tree] = (ov[~tree] * 0.3 + np.array([255, 0, 255]) * 0.7).astype(np.uint8)
		x, y, s, t = window
		cv2.rectangle(ov, (x, y), (x + s, y + t), (0, 255, 255), 3)
		cv2.line(ov, (m["box"][0], m["base_y"]), (m["box"][2], m["base_y"]), (0, 0, 255), 2)
		cv2.imwrite(os.path.join(out, "%s_mask.png" % name), cv2.resize(ov, None, fx=0.4, fy=0.4))
		results.append(dict(info, code=code, source=os.path.basename(path), leaf_window=window, **m))
		print("%-22s %-10s aspect %.2f clear %.2f crown %.2f widest %.2f" % (name, info["archetype"], m["aspect"], m["clear"], m["crown_width"], m["widest"]))
	json.dump(results, open(os.path.join(out, "analysis.json"), "w"), indent=1)


if __name__ == "__main__":
	main()
