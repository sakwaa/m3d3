"""2D pose (RTMPose, Halpe-26 keypoints) for every frame in a folder.

usage: pose.py FRAMES_DIR OUT_JSON [--detect]
  default: each frame is a crop of one person (the whole frame is the box).
  --detect: run the person detector first (full frames); keeps the most confident person.
Writes {frame: {kp: [[x, y, score] * 26], box: [...]}} and overlay images (ov_*.png).
"""
import json
import sys
from pathlib import Path

import cv2
import numpy as np
from rtmlib import RTMPose, YOLOX

POSE = "https://download.openmmlab.com/mmpose/v1/projects/rtmposev1/onnx_sdk/rtmpose-m_simcc-body7_pt-body7-halpe26_700e-256x192-4d3e73dd_20230605.zip"
DET = "https://download.openmmlab.com/mmpose/v1/projects/rtmposev1/onnx_sdk/yolox_m_8xb8-300e_humanart-c2c7a14a.zip"
# Halpe-26: 0 nose, 5/6 shoulders, 7/8 elbows, 9/10 wrists, 11/12 hips, 13/14 knees, 15/16 ankles,
# 17 head top, 18 neck, 19 hip centre, 20-25 toes / heels (L big, R big, L small, R small, L heel, R heel).
BONES = [(5, 7), (7, 9), (6, 8), (8, 10), (11, 13), (13, 15), (12, 14), (14, 16), (5, 6), (11, 12),
         (5, 11), (6, 12), (17, 18), (18, 19), (15, 24), (16, 25), (15, 20), (16, 21)]

frames_dir, out = Path(sys.argv[1]), Path(sys.argv[2])
detect = "--detect" in sys.argv
pose = RTMPose(onnx_model=POSE, model_input_size=(192, 256), backend="onnxruntime", device="cpu")
det = YOLOX(onnx_model=DET, model_input_size=(640, 640), backend="onnxruntime", device="cpu") if detect else None
result = {}
ov_dir = out.parent / (out.stem + "_ov")
ov_dir.mkdir(exist_ok=True)
for f in sorted(frames_dir.glob("f_*.png")):
    img = cv2.imread(str(f))
    h, w = img.shape[:2]
    box = [0, 0, w, h]
    if det is not None:
        boxes = det(img)
        if len(boxes) == 0:
            continue
        areas = [(b[2] - b[0]) * (b[3] - b[1]) for b in boxes]
        box = list(map(float, boxes[int(np.argmax(areas))]))
    kps, scores = pose(img, bboxes=[box])
    kp = [[float(kps[0][i][0]), float(kps[0][i][1]), float(scores[0][i])] for i in range(len(kps[0]))]
    result[f.stem] = {"kp": kp, "box": box}
    for a, b in BONES:
        if kp[a][2] > 0.3 and kp[b][2] > 0.3:
            col = (0, 200, 255) if a % 2 == 1 or b % 2 == 1 else (255, 120, 0)  # left yellow, right blue
            cv2.line(img, (int(kp[a][0]), int(kp[a][1])), (int(kp[b][0]), int(kp[b][1])), col, max(1, w // 160))
    cv2.imwrite(str(ov_dir / f.name), img)
out.write_text(json.dumps(result))
print("posed", len(result))
