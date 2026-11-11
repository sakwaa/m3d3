"""Writes the sword attack specs (build them with the actor tools' From spec…, or
ActorAnimSpec). Angles: see ActorAnimSpec. Run: python3 make_specs.py

Reference: OoT remake front view (youtube 64WRm0sZn0E, frames 33-189 at 60 fps) and the
MM3D Swordsman's School short (AXzZe1vsjxk) for the jump slash. Measured there:
- blade: cocked up and back over the right shoulder in the windup, in line with the forearm
  through the strike (flat across the front), out low to the side in the follow-through
  (held ~0.25 s);
- legs: knees bend in the windup (~150 deg), the stance widens on the strike (feet ~0.9 ->
  1.6 torso lengths apart: the left foot steps out), back in during recovery;
- hips: turn with the swing about half as far as the shoulders, pelvis rocks ~10 deg.
SlashD and SlashH2 are the standing combo seen there; SlashH / SlashV / Stab are mirrored or
OoT-convention shapes using the same rules.
"""
import json
import os

os.chdir(os.path.dirname(os.path.abspath(__file__)))

FREE_L = {"upper_arm_L": [5, 25], "forearm_L": [40, 15]}  # shield on the back: left arm loose
STANCE = {"thigh_L": 18, "shin_L": -6, "thigh_R": -14, "shin_R": -22}
CROUCH = {"thigh_L": [26, 6], "shin_L": -16, "thigh_R": [-6, 6], "shin_R": -38}  # windup: knees bend
STEP = {"thigh_L": [36, 14], "shin_L": -4, "thigh_R": [-26, 10], "shin_R": -20}   # strike: wide, left foot out
READY = dict(FREE_L, **STANCE, **{"upper_arm_R": [10, 20], "forearm_R": [70, 10], "lean": 6})
SRC = "OoT remake front view 64WRm0sZn0E (60 fps) + MM3D Swordsman's School AXzZe1vsjxk, read by eye"


def key(frame, ease="smooth", **kw):
	k = dict(READY)
	k.update(kw)
	k["frame"] = frame
	k["ease"] = ease
	return k


def spec(name, length, keys, windows, measured=True):
	json.dump({"name": name, "fps": 30, "length": length, "loop": False, "root": "auto", "source": SRC,
		"measured": measured, "windows": windows, "keys": keys}, open(name.lower() + ".json", "w"), indent=1)


# Diagonal: blade cocked up behind the right shoulder -> flat across the front -> out low left.
spec("SlashD", 20, [
	key(0),
	key(5, "ease_in", twist=40, hip_twist=18, hip_roll=-6, lean=2, lift=-0.03,
		upper_arm_R=[150, 50], forearm_R=[185, 55], blade_R=[195, 35], upper_arm_L=[-15, 30], **CROUCH),
	key(8, "snap", twist=0, hip_twist=0, hip_roll=0, lean=12,
		upper_arm_R=[90, 15], forearm_R=[85, 5], blade_R=[92, -10], upper_arm_L=[15, 25], **STEP),
	key(11, "ease_out", twist=-40, hip_twist=-20, hip_roll=8, lean=16,
		upper_arm_R=[40, -45], forearm_R=[25, -60], blade_R=[60, -75], upper_arm_L=[30, 20], **STEP),
	key(15, twist=-35, hip_twist=-18, hip_roll=6, lean=14,
		upper_arm_R=[42, -45], forearm_R=[28, -58], blade_R=[62, -72], upper_arm_L=[28, 20], **STEP),
	key(20),
], {"windup": [0, 5], "active": [6, 10], "cancel": [12, 20], "opening": [14, 20]})

# Backhand horizontal, left to right at the waist (follows the diagonal): blade from out on
# the left, flat across, out to the right.
spec("SlashH2", 18, [
	key(0, twist=-40, hip_twist=-20, hip_roll=8, lean=14,
		upper_arm_R=[40, -45], forearm_R=[25, -60], blade_R=[62, -72], **STEP),
	key(4, "ease_in", twist=-48, hip_twist=-24, hip_roll=6, lean=10, lift=-0.02,
		upper_arm_R=[55, -70], forearm_R=[45, -95], blade_R=[85, -120], **CROUCH),
	key(7, "snap", twist=0, hip_twist=0, hip_roll=0, lean=10,
		upper_arm_R=[85, 5], forearm_R=[90, 10], blade_R=[90, 15], **STEP),
	key(10, "ease_out", twist=40, hip_twist=20, hip_roll=-8, lean=6,
		upper_arm_R=[15, 80], forearm_R=[25, 85], blade_R=[80, 95], **STEP),
	key(13, twist=36, hip_twist=18, hip_roll=-6, lean=6,
		upper_arm_R=[18, 78], forearm_R=[28, 82], blade_R=[78, 92], **STEP),
	key(18),
], {"windup": [0, 4], "active": [5, 9], "cancel": [11, 18], "opening": [13, 18]})

# Horizontal right to left (locked on, stick sideways): the backhand mirrored.
spec("SlashH", 18, [
	key(0),
	key(4, "ease_in", twist=40, hip_twist=18, hip_roll=-6, lean=4, lift=-0.02,
		upper_arm_R=[-5, 80], forearm_R=[10, 85], blade_R=[85, 115], **CROUCH),
	key(7, "snap", twist=0, hip_twist=0, hip_roll=0, lean=10,
		upper_arm_R=[85, 10], forearm_R=[88, 0], blade_R=[90, -10], **STEP),
	key(10, "ease_out", twist=-40, hip_twist=-20, hip_roll=8, lean=12,
		upper_arm_R=[65, -55], forearm_R=[60, -75], blade_R=[80, -95], **STEP),
	key(18),
], {"windup": [0, 4], "active": [5, 9], "cancel": [11, 18], "opening": [13, 18]}, measured=False)

# Vertical chop (locked on, stick neutral): blade straight up and back -> over the top -> low ahead.
spec("SlashV", 20, [
	key(0),
	key(5, "ease_in", lean=-4, lift=-0.03, hip_roll=0,
		upper_arm_R=[170, 15], forearm_R=[215, 10], blade_R=[205, 5], **CROUCH),
	key(8, "snap", lean=14,
		upper_arm_R=[95, 5], forearm_R=[95, 0], blade_R=[100, 0], **STEP),
	key(11, "ease_out", lean=22,
		upper_arm_R=[45, 5], forearm_R=[30, 0], blade_R=[40, 0], **STEP),
	key(20),
], {"windup": [0, 5], "active": [6, 10], "cancel": [13, 20], "opening": [14, 20]}, measured=False)

# Stab (locked on, stick forward): blade drawn back level at the hip -> thrust straight ahead.
spec("Stab", 16, [
	key(0),
	key(4, "ease_in", twist=25, hip_twist=12, lean=4, lift=-0.02,
		upper_arm_R=[-35, 25], forearm_R=[75, 10], blade_R=[88, 5], **CROUCH),
	key(7, "snap", twist=-10, hip_twist=-6, lean=16,
		upper_arm_R=[88, 5], forearm_R=[90, 0], blade_R=[90, 0], **STEP),
	key(10, "ease_out", twist=-10, hip_twist=-6, lean=14,
		upper_arm_R=[85, 5], forearm_R=[88, 0], blade_R=[89, 0], **STEP),
	key(16),
], {"windup": [0, 4], "active": [5, 9], "cancel": [10, 16], "opening": [11, 16]}, measured=False)

# Jump slash (MM3D frames 550-595 / 140-185): takeoff crouch, airborne knees tucked with the
# blade up behind the shoulder (~0.27 s), chop over the top descending, deep landing crouch
# with the blade low ahead (hit), hold, rise.
TUCK = {"thigh_L": 75, "shin_L": -45, "thigh_R": 60, "shin_R": -60}
LAND = {"thigh_L": [70, 8], "shin_L": -55, "thigh_R": [40, 8], "shin_R": -80}
# The air part holds its last pose (sword up behind the shoulder) for as long as Link is
# airborne; JumpSlashLand (chop -> crouch -> rise) starts as the ground comes up.
spec("JumpSlash", 12, [
	key(0, "ease_in", lean=22, upper_arm_R=[-40, 25], forearm_R=[15, 15], blade_R=[60, 10],
		thigh_L=45, shin_L=-40, thigh_R=30, shin_R=-55),
	key(4, air=True, lean=8, upper_arm_R=[150, 30], forearm_R=[200, 20], blade_R=[200, 15], **TUCK),
	key(11, "ease_in", air=True, lean=0, upper_arm_R=[175, 20], forearm_R=[225, 15], blade_R=[215, 10], **TUCK),
], {})
spec("JumpSlashLand", 20, [
	key(0, "snap", air=True, lean=18, upper_arm_R=[115, 10], forearm_R=[115, 5], blade_R=[120, 5], **TUCK),
	key(4, "ease_out", lean=34, upper_arm_R=[60, 8], forearm_R=[50, 5], blade_R=[45, 0], **LAND),
	key(11, lean=30, upper_arm_R=[62, 8], forearm_R=[55, 5], blade_R=[48, 0], **LAND),
	key(20),
], {"active": [0, 7], "cancel": [12, 20], "opening": [8, 20]})
print("specs written:", sorted(f for f in os.listdir(".") if f.endswith(".json")))
