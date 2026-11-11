"""Track Wander (bright, low-saturation figure) through a video and write crops.

usage: track.py VIDEO OUT_DIR START END X0 Y0 [CROP_W CROP_H]
X0/Y0: his rough position (1280x720 pixels) at START.
"""
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

video, out, start, end, x0, y0 = sys.argv[1], Path(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5]), float(sys.argv[6])
cw = int(sys.argv[7]) if len(sys.argv) > 7 else 140
ch = int(sys.argv[8]) if len(sys.argv) > 8 else 170
W, H = 1280, 720
out.mkdir(parents=True, exist_ok=True)
cmd = ["/opt/homebrew/bin/ffmpeg", "-v", "error", "-ss", str(start), "-t", str(end - start), "-i", video,
       "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
pos = np.array([x0, y0])
track = []
i = 0
while True:
    buf = proc.stdout.read(W * H * 3)
    if len(buf) < W * H * 3:
        break
    f = np.frombuffer(buf, np.uint8).reshape(H, W, 3).astype(np.float32)
    # Search window round the last position.
    r = 90
    xa, xb = int(max(pos[0] - r, 0)), int(min(pos[0] + r, W))
    ya, yb = int(max(pos[1] - r, 0)), int(min(pos[1] + r, H))
    win = f[ya:yb, xa:xb]
    v = win.max(axis=2)
    s = (v - win.min(axis=2)) / (v + 1.0)
    # Bright relative to the window, not green-saturated (his tunic / skin / hair highlights).
    thr = max(np.percentile(v, 97), 60)
    mask = (v >= thr) & (s < 0.45)
    ys, xs = np.nonzero(mask)
    if len(xs) > 6:
        c = np.array([xs.mean() + xa, ys.mean() + ya])
        pos = pos * 0.4 + c * 0.6
    track.append((i, pos[0], pos[1], len(xs)))
    # Crop round him, brightened.
    cx, cy = int(pos[0]), int(pos[1])
    x1 = min(max(cx - cw // 2, 0), W - cw)
    y1 = min(max(cy - ch // 2, 0), H - ch)
    crop = f[y1:y1 + ch, x1:x1 + cw]
    crop = np.clip((crop - crop.min()) * (255.0 / max(crop.max() - crop.min(), 1.0)), 0, 255).astype(np.uint8)
    Image.fromarray(crop).resize((cw * 2, ch * 2), Image.LANCZOS).save(out / f"f_{i:04d}.png")
    i += 1
proc.wait()
with open(out / "track.csv", "w") as fh:
    for t in track:
        fh.write("%d,%.1f,%.1f,%d\n" % t)
print("frames", i)
