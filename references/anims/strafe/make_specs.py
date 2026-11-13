"""Writes the Z-targeting stance and strafe specs (build with the actor tools' From spec..., or
tests/tools/import_specs.gd). Angles: see ActorAnimSpec. Run: python3 make_specs.py

Reference: "Zelda Ocarina of Time Combat: Remake vs Original" (YouTube short 6qNOIcnL8P8),
Forest Temple Wolfos / Stalfos fights, remake (top) frames ~644-700 and the N64 original
(bottom) ~616-684, 24 fps, read by eye (480p, from behind: shapes, not frame counts):
- stance: crouched, knees bent, left foot ahead; shield raised in front of the chest on the
  left arm; sword low in the right hand, blade forward and down across the body; chest
  turned a little to the right (shield shoulder forward), squared to the target;
- moving while locked on: a side-shuffle round the target with the upper body held in the
  stance (the remake bobs more than the N64), short back-steps away from it.
Step timing is our choice (not measured): 16 frames at 30 fps a shuffle cycle (two steps).
"""
import json
import os

os.chdir(os.path.dirname(os.path.abspath(__file__)))

SRC = "OoT remake vs original short 6qNOIcnL8P8 (24 fps, read by eye; timing ours)"
UPPER = {"lean": 12, "twist": 15, "head": -8,
	"upper_arm_L": [55, 25], "forearm_L": [100, 25],  # shield up across the chest
	"upper_arm_R": [25, 22], "forearm_R": [55, 10], "blade_R": [65, -15]}  # sword low, forward and in
LEGS = {"thigh_L": [22, 8], "shin_L": -18, "thigh_R": [-4, 8], "shin_R": -28}  # crouched, left foot ahead


def key(frame, legs, lift=0.0, ease="smooth", **kw):
	k = dict(UPPER)
	k.update(legs)
	k.update(kw)
	k["frame"] = frame
	k["ease"] = ease
	k["lift"] = lift
	return k


def spec(name, length, keys, loop=True):
	json.dump({"name": name, "fps": 30, "length": length, "loop": loop, "root": "auto", "source": SRC,
		"measured": False, "keys": keys}, open(name.lower() + ".json", "w"), indent=1)


def swap(legs):
	"""Left and right legs swapped (out stays 'away from the body')."""
	out = {}
	for k, v in legs.items():
		out[k.replace("_L", "_X").replace("_R", "_L").replace("_X", "_R")] = v
	return out


spec("BattleIdle", 40, [key(0, LEGS), key(20, LEGS, lift=-0.025), key(40, LEGS)])

# Side-shuffle to the right: the right foot reaches out, plants wide, the left follows in.
TOGETHER = {"thigh_L": [14, 4], "shin_L": -20, "thigh_R": [14, 4], "shin_R": -20}
R_REACH = {"thigh_L": [14, 2], "shin_L": -22, "thigh_R": [30, 26], "shin_R": -10}
WIDE = {"thigh_L": [12, 14], "shin_L": -16, "thigh_R": [12, 16], "shin_R": -16}
L_FOLLOW = {"thigh_L": [32, 4], "shin_L": -8, "thigh_R": [12, 10], "shin_R": -20}
right = [key(0, TOGETHER), key(4, R_REACH, lift=0.03), key(8, WIDE, lift=-0.02), key(12, L_FOLLOW, lift=0.03), key(16, TOGETHER)]
spec("StrafeR", 16, right)
spec("StrafeL", 16, [key(k["frame"], swap({b: k[b] for b in ("thigh_L", "shin_L", "thigh_R", "shin_R")}), k["lift"]) for k in right])

# Back-steps: one foot back, then the other, the stance held.
B1 = {"thigh_L": [24, 8], "shin_L": -16, "thigh_R": [-24, 8], "shin_R": -40}
B2 = {"thigh_L": [-18, 8], "shin_L": -36, "thigh_R": [10, 8], "shin_R": -26}
spec("StrafeB", 20, [key(0, LEGS), key(5, B1, lift=0.02), key(10, LEGS, lift=-0.01), key(15, B2, lift=0.02), key(20, LEGS)])
print("wrote BattleIdle, StrafeR, StrafeL, StrafeB")
