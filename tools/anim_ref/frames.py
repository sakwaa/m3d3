"""Numbered, zoomed contact sheets of a character over a frame range, for reading poses by
eye (the step that works when automatic pose fails: small, dark or stylised characters).
Crops round the character using a pose JSON's boxes (pose.py --detect) or a track.py CSV.

usage: frames.py FRAMES_DIR FIRST LAST OUT_PNG [--boxes POSE_JSON | --track TRACK_CSV]
                 [--every 1] [--size 300] [--cols 10] [--pad 1.2]
"""
import csv
import json
import sys
from pathlib import Path

import cv2

a = sys.argv[1:]
src, first, last, out = Path(a[0]), int(a[1]), int(a[2]), a[3]
opt = lambda k, d: a[a.index(k) + 1] if k in a else d
every, size, cols, pad = int(opt("--every", 1)), int(opt("--size", 300)), int(opt("--cols", 10)), float(opt("--pad", 1.2))
boxes = json.load(open(opt("--boxes", ""))) if "--boxes" in a else {}
track = {}
if "--track" in a:
	for row in csv.reader(open(opt("--track", ""))):
		track[int(row[0]) + 1] = (float(row[1]), float(row[2]))
tiles, last_box = [], None
for i in range(first, last + 1, every):
	f = src / ("f_%04d.png" % i)
	if not f.exists():
		continue
	img = cv2.imread(str(f))
	h, w = img.shape[:2]
	b = boxes.get("f_%04d" % i, {}).get("box")
	if b is None and i in track:
		cx, cy = track[i]
		b = [cx - 50, cy - 70, cx + 50, cy + 70]
	b = b or last_box
	if b:
		last_box = b
		cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
		s = max(b[2] - b[0], b[3] - b[1]) * pad
		x0, y0 = int(max(cx - s / 2, 0)), int(max(cy - s / 2, 0))
		img = img[y0:int(min(cy + s / 2, h)), x0:int(min(cx + s / 2, w))]
	t = cv2.resize(img, (size, size), interpolation=cv2.INTER_CUBIC)
	cv2.putText(t, str(i), (4, 22), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 255), 2)
	tiles.append(t)
blank = tiles[0] * 0
rows = [cv2.hconcat(tiles[r:r + cols] + [blank] * (cols - len(tiles[r:r + cols]))) for r in range(0, len(tiles), cols)]
cv2.imwrite(out, cv2.vconcat(rows))
print(out, len(tiles), "frames")
