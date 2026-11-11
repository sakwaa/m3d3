"""Find usable stretches in a long video: timestamped contact sheets (1 frame every STEP s),
and with --score, a 2D pose pass that ranks moments where the character is large and seen
side-on (best for measuring swing angles).

usage: scan.py VIDEO OUT_DIR [--step 10] [--score]
-> OUT_DIR/sheet_N.png (60 frames each), OUT_DIR/best.txt with --score
"""
import json
import math
import subprocess
import sys
from pathlib import Path

import cv2

args = sys.argv[1:]
video, out = args[0], Path(args[1])
step = float(args[args.index("--step") + 1]) if "--step" in args else 10.0
score = "--score" in args
frames = out / "scan"
frames.mkdir(parents=True, exist_ok=True)
subprocess.run(["/opt/homebrew/bin/ffmpeg", "-v", "error", "-y", "-i", video, "-vf", "fps=1/%g" % step,
	str(frames / "f_%04d.png")], check=True)
files = sorted(frames.glob("f_*.png"))
thumbs = []
for i, f in enumerate(files):
	img = cv2.imread(str(f))
	t = i * step
	img_s = cv2.resize(img, (200, int(img.shape[0] * 200 / img.shape[1])))
	cv2.putText(img_s, "%d:%04.1f" % (t // 60, t % 60), (3, 15), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 255, 255), 1)
	thumbs.append(img_s)
for s in range(0, len(thumbs), 60):
	chunk = thumbs[s:s + 60]
	rows = [cv2.hconcat(chunk[r:r + 10] + [chunk[0] * 0] * (10 - len(chunk[r:r + 10]))) for r in range(0, len(chunk), 10)]
	cv2.imwrite(str(out / ("sheet_%d.png" % (s // 60))), cv2.vconcat(rows))
print("sheets:", len(range(0, len(thumbs), 60)), "in", out)
if not score:
	sys.exit()

# Pose every scan frame (detector + RTMPose) and rank side-on, large, mid-stride moments.
here = Path(__file__).resolve().parent
subprocess.run([str(here / ".venv-pose/bin/python"), "-I", str(here / "pose.py"), str(frames), str(out / "scan.json"), "--detect"], check=True)
d = json.load(open(out / "scan.json"))
rows = []
for k, v in d.items():
	kp = v["kp"]
	if min(kp[i][2] for i in [5, 6, 11, 12, 13, 14, 15, 16]) < 0.35:
		continue
	sh = ((kp[5][0] + kp[6][0]) / 2, (kp[5][1] + kp[6][1]) / 2)
	hp = ((kp[11][0] + kp[12][0]) / 2, (kp[11][1] + kp[12][1]) / 2)
	torso = math.dist(sh, hp)
	if torso < 30:
		continue
	side = math.dist(kp[5][:2], kp[6][:2]) / torso  # small = side-on
	spread = abs(kp[15][0] - kp[16][0]) / torso      # big = legs apart, side-on
	t = (int(k.split("_")[1]) - 1) * step
	rows.append((t, side, spread, torso))
rows = [r for r in rows if r[1] < 0.4]
rows.sort(key=lambda r: -(r[3] * (0.5 + r[2])))
with open(out / "best.txt", "w") as fh:
	for t, side, spread, torso in rows[:40]:
		line = "%d:%04.1f  side %.2f  spread %.2f  torso %.0fpx" % (t // 60, t % 60, side, spread, torso)
		fh.write(line + "\n")
		print(line)
print("check these with the overlays in", out / "scan_ov")
