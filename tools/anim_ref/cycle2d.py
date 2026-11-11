"""Run cycle from side-view pose frames: per-frame sagittal angles, the stride period, and a
phase-averaged cycle (left limbs; the right is the same half a cycle later).

usage: cycle2d.py OUT_JSON OUT_PNG FPS WINDOW_JSON[:first:last] ... [--spec SPEC_JSON --keys 8 --name Run]
Angles (degrees) from straight down, + = forward (the way he faces): thigh, shin, upper
arm, forearm; torso: from straight up, + = leaning forward. bob: pelvis height / torso.
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

out_json, out_png, fps = sys.argv[1], sys.argv[2], float(sys.argv[3])
NEED = [5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]


def ang_down(a, b, face):
    """Angle of a->b from straight down (image y grows down), + towards `face` (+1 = image right)."""
    dx, dy = (b[0] - a[0]) * face, b[1] - a[1]
    return math.degrees(math.atan2(dx, dy))


segments = []  # lists of per-frame dicts (consecutive frames)
_pos = []
for x in sys.argv[4:]:
	if x.startswith("--"):
		break
	_pos.append(x)
for spec in _pos:
    path, *rng = spec.split(":")
    lo, hi = (int(rng[0]), int(rng[1])) if rng else (0, 10 ** 9)
    d = json.load(open(path))
    seg = []
    for k in sorted(d):
        i = int(k.split("_")[1])
        if not lo <= i <= hi:
            continue
        kp = d[k]["kp"]
        if min(kp[j][2] for j in NEED) < 0.3:
            if len(seg) > 8:
                segments.append(seg)
            seg = []
            continue
        p = {j: (kp[j][0], kp[j][1]) for j in range(len(kp))}
        # Facing: toes ahead of heels (20/21 big toes, 24/25 heels), else nose ahead of neck.
        fx = (p[20][0] + p[21][0]) - (p[24][0] + p[25][0])
        face = 1.0 if fx > 0 else -1.0
        sh = ((p[5][0] + p[6][0]) / 2, (p[5][1] + p[6][1]) / 2)
        hip = ((p[11][0] + p[12][0]) / 2, (p[11][1] + p[12][1]) / 2)
        torso = math.dist(sh, hip)
        seg.append({
            "frame": i,
            "thigh_L": ang_down(p[11], p[13], face), "shin_L": ang_down(p[13], p[15], face),
            "thigh_R": ang_down(p[12], p[14], face), "shin_R": ang_down(p[14], p[16], face),
            "uarm_L": ang_down(p[5], p[7], face), "farm_L": ang_down(p[7], p[9], face),
            "uarm_R": ang_down(p[6], p[8], face), "farm_R": ang_down(p[8], p[10], face),
            "torso": math.degrees(math.atan2((sh[0] - hip[0]) * face, hip[1] - sh[1])),
            "hip_y": -hip[1] / torso,
        })
    if len(seg) > 8:
        segments.append(seg)

# Stride period: autocorrelation of the thigh scissor (L - R), averaged over segments.
best = {}
for seg in segments:
    x = np.array([f["thigh_L"] - f["thigh_R"] for f in seg])
    x = x - x.mean()
    for lag in range(6, min(len(x) - 4, 40)):
        c = np.dot(x[:-lag], x[lag:]) / max(np.linalg.norm(x[:-lag]) * np.linalg.norm(x[lag:]), 1e-6)
        best.setdefault(lag, []).append(c)
lags = sorted(best, key=lambda l: -np.mean(best[l]))
period = lags[0] if lags else 12
print("segments", len(segments), "frames", sum(len(s) for s in segments), "period", period, "frames =", "%.3f s" % (period / fps))

# Phase: 0 = left thigh furthest forward, per segment (fit by the scissor's peaks).
NB = 16
keys = ["thigh_L", "shin_L", "uarm_L", "farm_L", "torso", "hip_y"]
bins = {k: [[] for _ in range(NB)] for k in keys}
for seg in segments:
    x = np.array([f["thigh_L"] - f["thigh_R"] for f in seg])
    # Phase offset: maximise sum of cos alignment with the scissor.
    ph = np.arange(len(seg)) / period
    off = math.atan2(np.sum(x * np.sin(2 * np.pi * ph)), np.sum(x * np.cos(2 * np.pi * ph))) / (2 * np.pi)
    hy = np.array([f["hip_y"] for f in seg])
    hy = hy - hy.mean()
    for n, f in enumerate(seg):
        phase = (n / period - off) % 1.0
        b = int(phase * NB) % NB
        b_half = int(((phase + 0.5) % 1.0) * NB) % NB  # the right limbs, half a cycle on
        for k in keys:
            if k in ("torso",):
                bins[k][b].append(f[k])
            elif k == "hip_y":
                bins[k][b].append(hy[n])
            else:
                bins[k][b].append(f[k])
                bins[k][b_half].append(f[k.replace("_L", "_R")])
cycle = {k: [float(np.median(v)) if v else None for v in bins[k]] for k in keys}
json.dump({"period_frames": period, "fps": fps, "bins": NB, "cycle": cycle}, open(out_json, "w"), indent=1)
for k in keys:
    print("%-8s" % k, " ".join("%6.1f" % v if v is not None else "   -  " for v in cycle[k]))

W, H = 900, 90
img = np.full((H * len(keys), W, 3), 255, np.uint8)
for r, k in enumerate(keys):
    vals = [v for v in cycle[k] if v is not None]
    if not vals:
        continue
    lo, hi = min(vals), max(vals)
    cv2.putText(img, "%s [%.1f .. %.1f]" % (k, lo, hi), (4, r * H + 14), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (60, 60, 60), 1)
    pts = [(int(i / (NB - 1) * (W - 20)) + 10, int(r * H + H - 8 - (v - lo) / max(hi - lo, 1e-6) * (H - 26))) for i, v in enumerate(cycle[k]) if v is not None]
    for a, b in zip(pts, pts[1:]):
        cv2.line(img, a, b, (40, 40, 200), 2)
cv2.imwrite(out_png, img)
if "--spec" in sys.argv:
	write_spec(sys.argv[sys.argv.index("--spec") + 1], sys.argv[sys.argv.index("--name") + 1] if "--name" in sys.argv else "Cycle",
		cycle, NB, period, fps, int(sys.argv[sys.argv.index("--keys") + 1]) if "--keys" in sys.argv else 8,
		{"thigh": ("thigh_L", None), "shin": ("shin_L", None), "upper_arm": ("uarm_L", None), "forearm": ("farm_L", None)}, "torso", "hip_y", 0.43)
