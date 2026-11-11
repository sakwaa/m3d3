"""Climb pose metrics from 2D side-view joints: the reel (RTMPose JSON, climber facing the
wall on the image's left) and ours (logged side-plane joints, wall at x = WALL, facing -x).

usage: analyze.py REEL_JSON REEL_FPS REEL_FIRST REEL_LAST OURS_TXT OURS_FROM OURS_TO OUT_PNG
Prints a table and draws the curves (reel solid, ours dashed).
"""
import json
import sys

import cv2
import numpy as np

reel_json, reel_fps, r0, r1 = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
ours_txt, o0, o1, out_png = sys.argv[5], float(sys.argv[6]), float(sys.argv[7]), sys.argv[8]
WALL = 0.5  # our test wall's face (z)


def angle(a, b, c):
    """Interior angle at b (degrees)."""
    u, v = a - b, c - b
    cos = np.dot(u, v) / max(np.linalg.norm(u) * np.linalg.norm(v), 1e-6)
    return np.degrees(np.arccos(np.clip(cos, -1, 1)))


def metrics(j):
    """j: dict of joint -> np.array([x_off_wall, y_up]) (x grows away from the wall)."""
    sh = (j["shoulder_L"] + j["shoulder_R"]) / 2
    hip = (j["hip_L"] + j["hip_R"]) / 2
    torso = max(np.linalg.norm(sh - hip), 1e-6)
    lean = np.degrees(np.arctan2(sh[0] - hip[0], sh[1] - hip[1]))  # + = top away from the wall
    hands_x = min(j["wrist_L"][0], j["wrist_R"][0])
    feet_x = min(j["ankle_L"][0], j["ankle_R"][0])
    return {
        "elbow_L": angle(j["shoulder_L"], j["elbow_L"], j["wrist_L"]),
        "elbow_R": angle(j["shoulder_R"], j["elbow_R"], j["wrist_R"]),
        "knee_L": angle(j["hip_L"], j["knee_L"], j["ankle_L"]),
        "knee_R": angle(j["hip_R"], j["knee_R"], j["ankle_R"]),
        "lean": lean,
        "chest_off": (sh[0] - hands_x) / torso,
        "hips_off": (hip[0] - feet_x) / torso,
        "hand_L_up": (j["wrist_L"][1] - sh[1]) / torso,
        "hand_R_up": (j["wrist_R"][1] - sh[1]) / torso,
        "foot_L_down": (hip[1] - j["ankle_L"][1]) / torso,
        "foot_R_down": (hip[1] - j["ankle_R"][1]) / torso,
        "hip_y": hip[1] / torso,
    }


# The reel (Halpe-26 indices); image y grows down, the wall is on the image's left.
H26 = {"shoulder_L": 5, "shoulder_R": 6, "elbow_L": 7, "elbow_R": 8, "wrist_L": 9, "wrist_R": 10,
       "hip_L": 11, "hip_R": 12, "knee_L": 13, "knee_R": 14, "ankle_L": 15, "ankle_R": 16}
data = json.load(open(reel_json))
reel = []
for k in sorted(data):
    i = int(k.split("_")[1])
    if not r0 <= i <= r1:
        continue
    kp = data[k]["kp"]
    if min(kp[v][2] for v in H26.values()) < 0.25:
        continue
    j = {n: np.array([kp[v][0], -kp[v][1]], dtype=float) for n, v in H26.items()}
    reel.append(((i - r0) / reel_fps, metrics(j)))

# Ours: t;head;ua_L;fa_L;hand_L;ua_R;fa_R;hand_R;th_L;sh_L;ft_L;th_R;sh_R;ft_R (z,y).
names = ["head", "shoulder_L", "elbow_L", "wrist_L", "shoulder_R", "elbow_R", "wrist_R",
         "hip_L", "knee_L", "ankle_L", "hip_R", "knee_R", "ankle_R"]
ours = []
seen = set()
for line in open(ours_txt):
    parts = line.strip().split(";")
    t = float(parts[0])
    if not o0 <= t <= o1 or t in seen:
        continue
    seen.add(t)
    j = {n: np.array([float(p.split(",")[0]) - WALL, float(p.split(",")[1])]) for n, p in zip(names, parts[1:])}
    ours.append((t - o0, metrics(j)))

keys = list(reel[0][1].keys()) if reel else list(ours[0][1].keys())
print("%-12s %22s %22s" % ("metric", "reel  min / mean / max", "ours  min / mean / max"))
for k in keys:
    def stats(rows):
        v = np.array([m[k] for _, m in rows])
        return "%6.2f %6.2f %6.2f" % (v.min(), v.mean(), v.max()) if len(v) else "      -"
    print("%-12s %22s %22s" % (k, stats(reel), stats(ours)))

# Curves.
plot_keys = ["elbow_L", "elbow_R", "knee_L", "knee_R", "lean", "chest_off", "hand_L_up", "hand_R_up", "foot_L_down", "foot_R_down"]
W, Hp = 1400, 110
img = np.full((Hp * len(plot_keys), W, 3), 255, np.uint8)
span = max(max((t for t, _ in reel), default=1), max((t for t, _ in ours), default=1))
for r, k in enumerate(plot_keys):
    y0 = r * Hp
    vals = [m[k] for _, m in reel] + [m[k] for _, m in ours]
    lo, hi = min(vals), max(vals)
    cv2.putText(img, "%s  [%.2f .. %.2f]" % (k, lo, hi), (4, y0 + 14), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (60, 60, 60), 1)
    cv2.line(img, (0, y0 + Hp - 1), (W, y0 + Hp - 1), (210, 210, 210), 1)
    for rows, col, dash in [(reel, (40, 40, 200), False), (ours, (30, 150, 30), True)]:
        prev = None
        for n, (t, m) in enumerate(rows):
            p = (int(t / span * (W - 10)) + 5, int(y0 + Hp - 8 - (m[k] - lo) / max(hi - lo, 1e-6) * (Hp - 26)))
            if prev and (not dash or n % 2 == 0):
                cv2.line(img, prev, p, col, 2)
            prev = p
for s in range(int(span) + 1):
    x = int(s / span * (W - 10)) + 5
    cv2.line(img, (x, 0), (x, img.shape[0]), (235, 235, 235), 1)
cv2.imwrite(out_png, img)
print("reel frames", len(reel), "ours frames", len(ours))
