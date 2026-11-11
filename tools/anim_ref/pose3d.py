"""3D pose (MediaPipe Pose Landmarker, heavy) for a folder of frames, in video mode.

usage: pose3d.py FRAMES_DIR OUT_JSON FPS [BOXES_JSON]
BOXES_JSON (optional, pose.py output): crops each frame to the person box (padded) first,
which helps small figures. Writes {frame: {world: [[x,y,z,vis]*33], img: [[x,y]*33]}}:
world = metres, hip-centred (x right, y down, z towards the camera, MediaPipe's frame).
Also writes overlay images (<out>_ov/).
"""
import json
import sys
from pathlib import Path

import cv2
import mediapipe as mp
from mediapipe.tasks.python import vision
from mediapipe.tasks.python.core.base_options import BaseOptions

src, out, fps = Path(sys.argv[1]), Path(sys.argv[2]), float(sys.argv[3])
boxes = json.load(open(sys.argv[4])) if len(sys.argv) > 4 else {}
MODEL = str(Path(__file__).resolve().parent / "models" / "pose_heavy.task")  # setup.sh fetches it
opts = vision.PoseLandmarkerOptions(base_options=BaseOptions(model_asset_path=MODEL),
	running_mode=vision.RunningMode.VIDEO, num_poses=1,
	min_pose_detection_confidence=0.3, min_tracking_confidence=0.3)
lm = vision.PoseLandmarker.create_from_options(opts)
ov = out.parent / (out.stem + "_ov")
ov.mkdir(exist_ok=True)
EDGES = [(11, 13), (13, 15), (12, 14), (14, 16), (11, 12), (11, 23), (12, 24), (23, 24),
	(23, 25), (25, 27), (24, 26), (26, 28), (27, 31), (28, 32)]
res = {}
last_box = None
for n, f in enumerate(sorted(src.glob("f_*.png"))):
	img = cv2.imread(str(f))
	h, w = img.shape[:2]
	x0, y0 = 0, 0
	b = boxes.get(f.stem, {}).get("box") if boxes else None
	if b is None:
		b = last_box
	if b is not None:
		last_box = b
		bw, bh = b[2] - b[0], b[3] - b[1]
		side = max(bw, bh) * 1.5
		cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
		x0, y0 = int(max(cx - side / 2, 0)), int(max(cy - side / 2, 0))
		x1, y1 = int(min(cx + side / 2, w)), int(min(cy + side / 2, h))
		img = img[y0:y1, x0:x1]
		if img.shape[0] < 256:
			s = 256 / img.shape[0]
			img = cv2.resize(img, None, fx=s, fy=s, interpolation=cv2.INTER_CUBIC)
	rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
	r = lm.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb), int(n * 1000 / fps))
	if not r.pose_world_landmarks:
		continue
	wl = r.pose_world_landmarks[0]
	il = r.pose_landmarks[0]
	res[f.stem] = {"world": [[p.x, p.y, p.z, p.visibility] for p in wl],
		"img": [[p.x, p.y] for p in il]}
	ih, iw = img.shape[:2]
	for a, c in EDGES:
		cv2.line(img, (int(il[a].x * iw), int(il[a].y * ih)), (int(il[c].x * iw), int(il[c].y * ih)),
			(0, 200, 255) if a % 2 else (255, 120, 0), 2)
	cv2.imwrite(str(ov / f.name), img)
out.write_text(json.dumps(res))
print("posed", len(res), "of", n + 1)
