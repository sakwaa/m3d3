"""Locomotion / climbing cycle from MediaPipe 3D world landmarks, in the body's own frame
(so any camera angle works).

usage: cycle3d.py POSE3D_JSON FPS FIRST LAST OUT_JSON OUT_PNG [--period N] [--spec SPEC_JSON --keys 8 --name Run]
Body frame per frame: up = hips -> shoulders, right = left hip -> right hip (made square to
up), forward = up x right... (the way the chest faces). Angles in degrees:
  thigh/shin/uarm/farm: swing in the sagittal plane from straight down, + = forward;
  *_out: out to the side (abduction), + = away from the body.
  lean: torso forward from the camera's vertical (rough: assumes a level camera).
  bob: pelvis height (m) relative to the ankles' mean, minus its average.
Cycle phase 0 = left thigh furthest forward; the right side is folded in half a cycle on.
"""
import json
import math
import sys

import cv2
import numpy as np


def write_spec(path, name, cycle, nb, period, fps, nkeys, keys_map, lean_key, bob_key, bob_scale):
	"""An animation spec (see the actor tools' ActorAnimSpec): NKEYS evenly spaced keys over
	one cycle at 30 fps; left limbs from bin b, right from half a cycle on."""
	def v(arr, i):
		for d in range(len(arr)):
			for j in (i + d, i - d):
				x = arr[j % len(arr)]
				if x is not None:
					return round(float(x), 1)
		return 0.0
	length = max(int(round(period / fps * 30)), nkeys)
	out = {"name": name, "fps": 30, "length": length, "loop": True, "root": "auto", "keys": []}
	for k in range(nkeys):
		b = int(round(k / nkeys * nb)) % nb
		bh = (b + nb // 2) % nb
		key = {"frame": int(round(k / nkeys * length)), "lean": v(cycle[lean_key], b) if lean_key else 0.0}
		if bob_key:
			key["lift"] = round(v(cycle[bob_key], b) * bob_scale, 3)
		for bone, (swing, out_k) in keys_map.items():
			for side, bin_ in (("L", b), ("R", bh)):
				val = v(cycle[swing], bin_)
				key[bone + "_" + side] = [val, v(cycle[out_k], bin_)] if out_k else val
		out["keys"].append(key)
	json.dump(out, open(path, "w"), indent=1)
	print("spec ->", path, nkeys, "keys over", length, "frames")

src, fps, first, last, out_json, out_png = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], sys.argv[6]
force_period = int(sys.argv[sys.argv.index("--period") + 1]) if "--period" in sys.argv else 0
d = json.load(open(src))
# MediaPipe 33: 11/12 shoulders, 13/14 elbows, 15/16 wrists, 23/24 hips, 25/26 knees, 27/28 ankles.
NEED = [11, 12, 13, 14, 15, 16, 23, 24, 25, 26, 27, 28]


def sag(v, up, fwd, right):
	"""Swing of segment v from straight down in the sagittal plane (+ forward), and out."""
	down = -up
	s = math.degrees(math.atan2(np.dot(v, fwd), np.dot(v, down)))
	o = math.degrees(math.atan2(np.dot(v, right), np.dot(v, down)))
	return s, o


frames = []
for k in sorted(d):
	i = int(k.split("_")[1])
	if not first <= i <= last:
		continue
	w = np.array(d[k]["world"])
	if min(w[j][3] for j in NEED) < 0.3:
		continue
	p = {j: np.array([w[j][0], -w[j][1], -w[j][2]]) for j in range(33)}  # y up, z away
	hip = (p[23] + p[24]) / 2
	sh = (p[11] + p[12]) / 2
	up = sh - hip
	up /= np.linalg.norm(up)
	right = p[24] - p[23]  # (MediaPipe: 23 = left hip) left -> right... see sign below
	right = right - up * np.dot(right, up)
	right /= np.linalg.norm(right)
	fwd = np.cross(up, right)
	# Facing check: the nose (0) should be ahead of the shoulders.
	if np.dot(p[0] - sh, fwd) < 0:
		fwd = -fwd
		right = -right
	f = {"frame": i}
	for side, (s, e, wr, h, kn, an) in {"L": (11, 13, 15, 23, 25, 27), "R": (12, 14, 16, 24, 26, 28)}.items():
		sgn = -1.0 if side == "L" else 1.0  # out = away from the body
		f["thigh_" + side], o = sag(p[kn] - p[h], up, fwd, right); f["thigh_out_" + side] = o * sgn
		f["shin_" + side], _ = sag(p[an] - p[kn], up, fwd, right)
		f["uarm_" + side], o = sag(p[e] - p[s], up, fwd, right); f["uarm_out_" + side] = o * sgn
		f["farm_" + side], _ = sag(p[wr] - p[e], up, fwd, right)
	f["lean"] = math.degrees(math.atan2(np.dot(up, np.array([fwd[0], 0, fwd[2]]) / max(np.linalg.norm([fwd[0], fwd[2]]), 1e-6)), up[1]))
	f["bob"] = float(hip[1] - (p[27][1] + p[28][1]) / 2)
	frames.append(f)
print("frames", len(frames))

# Period from the thigh scissor (consecutive runs).
segs, cur = [], []
for f in frames:
	if cur and f["frame"] - cur[-1]["frame"] > 2:
		segs.append(cur); cur = []
	cur.append(f)
segs.append(cur)
segs = [s for s in segs if len(s) >= 12]
acc = {}
for s in segs:
	x = np.array([f["thigh_L"] - f["thigh_R"] for f in s]); x -= x.mean()
	for lag in range(8, min(len(x) - 4, 50)):
		a, b = x[:-lag], x[lag:]
		acc.setdefault(lag, []).append(np.dot(a, b) / max(np.linalg.norm(a) * np.linalg.norm(b), 1e-6))
cands = sorted(acc, key=lambda l: -np.mean(acc[l]))
period = force_period or (cands[0] if cands else 20)
print("segments", len(segs), "period %d frames = %.3f s (corr %.2f)" % (period, period / fps, np.mean(acc.get(period, [0]))))

NB = 16
keys = ["thigh", "shin", "uarm", "farm", "thigh_out", "uarm_out"]
bins = {k: [[] for _ in range(NB)] for k in keys + ["lean", "bob"]}
for s in segs:
	x = np.array([f["thigh_L"] - f["thigh_R"] for f in s])
	ph = np.arange(len(s)) / period
	off = math.atan2(np.sum((x - x.mean()) * np.sin(2 * np.pi * ph)), np.sum((x - x.mean()) * np.cos(2 * np.pi * ph))) / (2 * np.pi)
	bob = np.array([f["bob"] for f in s]); bob -= bob.mean()
	for n, f in enumerate(s):
		phase = (n / period - off) % 1.0
		b, bh = int(phase * NB) % NB, int(((phase + 0.5) % 1.0) * NB) % NB
		for k in keys:
			bins[k][b].append(f[k + "_L"]); bins[k][bh].append(f[k + "_R"])
		bins["lean"][b].append(f["lean"]); bins["bob"][b].append(bob[n])
cycle = {k: [float(np.median(v)) if v else None for v in bins[k]] for k in bins}
json.dump({"period_frames": period, "fps": fps, "bins": NB, "cycle": cycle}, open(out_json, "w"), indent=1)
for k in cycle:
	print("%-9s" % k, " ".join("%6.1f" % v if v is not None else "   -  " for v in cycle[k]))

W, H = 900, 90
img = np.full((H * len(cycle), W, 3), 255, np.uint8)
for r, k in enumerate(cycle):
	vals = [v for v in cycle[k] if v is not None]
	lo, hi = min(vals), max(vals)
	cv2.putText(img, "%s [%.2f .. %.2f]" % (k, lo, hi), (4, r * H + 14), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (60, 60, 60), 1)
	pts = [(int(i / (NB - 1) * (W - 20)) + 10, int(r * H + H - 8 - (v - lo) / max(hi - lo, 1e-6) * (H - 26))) for i, v in enumerate(cycle[k]) if v is not None]
	for a, b in zip(pts, pts[1:]):
		cv2.line(img, a, b, (40, 40, 200), 2)
cv2.imwrite(out_png, img)
if "--spec" in sys.argv:
	write_spec(sys.argv[sys.argv.index("--spec") + 1], sys.argv[sys.argv.index("--name") + 1] if "--name" in sys.argv else "Cycle",
		cycle, NB, period, fps, int(sys.argv[sys.argv.index("--keys") + 1]) if "--keys" in sys.argv else 8,
		{"thigh": ("thigh", "thigh_out"), "shin": ("shin", None), "upper_arm": ("uarm", "uarm_out"), "forearm": ("farm", None)}, "lean", "bob", 1.0)
