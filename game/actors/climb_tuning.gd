@tool
class_name ClimbTuning
extends Resource
## The climbing animation's numbers, grouped by climb state (Climb, Hang, Ceiling, Leap,
## ClimbUp) plus the limbs' shared ones. Saved in climb_tuning.tres: open it in the
## inspector, change values and save (the inspector's save button, or Ctrl+S); a game
## running from the editor reloads it within half a second. Distances are metres, times
## seconds, angles radians. Timing windows are fractions of a stride (x = start, y = end).
## Gait timing is for the hanging style (SotC, the default); ClimbState.GAITS_PLANTED keeps
## the planted style's.

const PATH := "res://game/actors/climb_tuning.tres"

## How a hand or foot moves between holds (position over the move's time):
##   LINEAR: constant speed (robotic).
##   SMOOTHSTEP: eases in and out (3t² − 2t³).
##   MIN_JERK: eases in and out more softly, no jolt at either end (10t³ − 15t⁴ + 6t⁵, the
##     minimum-jerk model of human reaching).
##   EASE_OUT: starts at full speed, slows onto the target (1 − (1 − t)³).
##   SKEWED: minimum-jerk with its fastest point at `ease_peak` (real reaches peak early,
##     then settle onto the hold).
enum Ease { LINEAR, SMOOTHSTEP, MIN_JERK, EASE_OUT, SKEWED }

@export_group("Climb (wall)")
## Average climbing speed and metres per stride.
@export var climb_speed := 0.5
@export var stride := 0.38
## Body's centre off the wall, how far it tilts back off it, how far below the capsule.
@export var wall_hip := 0.3
@export var lean_back := 0.18
@export var body_drop := 0.05
## Weight shift over the leading side each stride: hips across, torso roll.
@export var shift := 0.07
@export var roll := 0.08
## Stride fraction the hips trail the move.
@export var hip_lag := 0.07
@export_subgroup("Hands")
## Above the body's centre at rest, out to the sides; sideways strides the leading /
## trailing hand.
@export var hand_up := 0.3
@export var hand_out := 0.18
@export var hand_out_side_lead := 0.24
@export var hand_out_side_trail := 0.12
@export_subgroup("Feet")
## Below the hip, out to the sides (TotK: legs bent, feet tucked up under the hips); how
## high the leading knee kicks up on a stride (the other foot lifts `Limbs/lift`); how far
## the knees splay out to the sides (0 = straight at the wall).
@export var foot_down := 0.48
@export var foot_out := 0.12
@export var knee_kick := 0.3
@export var knee_out := 0.6
@export_subgroup("Timing up")
@export var up_hand_lead := Vector2(0.0, 0.22)
@export var up_hand_trail := Vector2(0.24, 0.42)
@export var up_foot_lead := Vector2(0.42, 0.72)
@export var up_foot_trail := Vector2(0.62, 0.88)
@export var up_body := Vector2(0.32, 0.85)
@export_subgroup("Timing down")
@export var down_hand_lead := Vector2(0.55, 0.78)
@export var down_hand_trail := Vector2(0.66, 0.9)
@export var down_foot_lead := Vector2(0.0, 0.25)
@export var down_foot_trail := Vector2(0.08, 0.33)
@export var down_body := Vector2(0.18, 0.6)
@export_subgroup("Timing side")
@export var side_hand_lead := Vector2(0.0, 0.25)
@export var side_hand_trail := Vector2(0.58, 0.85)
@export var side_foot_lead := Vector2(0.28, 0.5)
@export var side_foot_trail := Vector2(0.5, 0.72)
@export var side_body := Vector2(0.22, 0.62)

@export_group("Hang (ledge)")
@export var shimmy_speed := 0.55
## Hands apart from the middle; the body's distance in from the capsule.
@export var hang_hand_out := 0.22
@export var hang_hip_in := 0.2
## Braced feet: the hip they hang from (above the origin), how far below it, apart.
@export var hang_hip_height := 0.85
@export var hang_foot_down := 0.36
@export var hang_foot_out := 0.12
## Sideways swing per shimmy: feet braced on a wall / legs hanging free.
@export var hang_swing_braced := 0.08
@export var hang_swing_free := 0.2
## Caught a ledge: seconds hanging before pushing up pulls up (the catch reads; "jump" pulls
## up at once).
@export var hang_settle := 0.2
@export_subgroup("Timing")
@export var hang_hand_lead := Vector2(0.0, 0.3)
@export var hang_hand_trail := Vector2(0.6, 0.9)
@export var hang_foot_lead := Vector2(0.25, 0.45)
@export var hang_foot_trail := Vector2(0.5, 0.7)
@export var hang_body := Vector2(0.2, 0.65)

@export_group("Ceiling")
@export var ceiling_speed := 0.6
## Hands apart, and how high the hands reach above the origin.
@export var ceiling_hand_out := 0.22
@export var ceiling_hand_height := 1.5

@export_group("Leap")
## Wind-up before leaving the wall: a full-length leap (or a free jump) / the shortest hop;
## in between by how far the hold aimed at is.
@export var windup := 0.3
@export var windup_short := 0.12
## The shortest hop's crouch, as a share of the full one below.
@export var crouch_short := 0.35
## Wind-up (TotK): the feet draw up under the body, the body sinks onto them and in to
## the wall, knees high.
@export var crouch_feet := 0.22
@export var crouch_sink := 0.12
@export var crouch_in := 0.08
## Flight: seconds (base + per metre), how far it arcs out from the wall and up.
@export var flight_time := 0.22
@export var flight_per_metre := 0.1
@export var arc_out := 0.3
@export var arc_up := 0.2
## Flight: hands reach this far up and ahead; the legs kick straight off the wall, then
## tuck up (0 straight .. 1 drawn up) and reach for the catch.
@export var leap_hand_height := 1.35
@export var leap_hand_ahead := 0.55
@export var leap_tuck := 0.5

@export_group("ClimbUp (mantle)")
## Seconds for a short pull, plus per metre risen.
@export var pull_up_time := 0.9
@export var pull_up_per_metre := 0.25
## Where the beats end: pull (chest to the edge), press (hips over), knee (onto the top).
@export var beat_pull := 0.35
@export var beat_press := 0.62
@export var beat_knee := 0.85
## Forward pitch over the edge; the feet's depth below the hip while pushing.
@export var pull_up_pitch := 0.6
@export var pull_up_foot_down := 0.45
## Standing up on top: the feet apart, and the ankle's height over the ground.
@export var stand_foot_out := 0.12
@export var ankle_height := 0.07
## How high a foot swings over the edge on its way up onto the top.
@export var over_edge := 0.3

@export_group("Limbs")
## How hands and feet move between holds (see Ease), and where a SKEWED move is fastest
## (share of the way).
@export var hand_ease := Ease.SKEWED
@export var foot_ease := Ease.MIN_JERK
@export_range(0.2, 0.8, 0.05) var ease_peak := 0.4
## Blend in / out of climbing; a hand or foot's step time and lift off the surface.
@export var blend := 0.12
@export var step_time := 0.13
## Changing state (leap to a catch, hang to a mantle...): seconds the limbs take to go from
## one state's pose to the next.
@export var mode_blend := 0.2
@export var lift := 0.08
## Standing still: how far a limb lags its spot before it steps.
@export var step_after := 0.3
## Reach ahead into the move; ankle off the wall with the toes on it.
@export var lead := 0.1
@export var toe := 0.11
## A stepping foot stays at least this far below the hip.
@export var foot_under_hip := 0.15
@export_subgroup("Head")
@export var look_weight := 0.7
@export var look_max := 0.8
@export var look_speed := 4.5


static var _shared: ClimbTuning
static var _stamp := 0
static var _checked := 0


## The tuning in use. Running from the editor, re-read when the file is saved.
static func shared() -> ClimbTuning:
	if _shared == null:
		_shared = load(PATH) as ClimbTuning
		if _shared == null:
			_shared = ClimbTuning.new()
		_stamp = FileAccess.get_modified_time(PATH)
	elif OS.is_debug_build() and Time.get_ticks_msec() - _checked > 500:
		_checked = Time.get_ticks_msec()
		var m := FileAccess.get_modified_time(PATH)
		if m != _stamp:
			_stamp = m
			var fresh := ResourceLoader.load(PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as ClimbTuning
			if fresh:
				_shared = fresh
	return _shared


var _table := {}


## All four hanging-style gaits (see gait()), built once per load.
func gait_table() -> Dictionary:
	if _table.is_empty():
		for k in [&"up", &"down", &"side", &"hang"]:
			_table[k] = gait(k)
	return _table


## Eased progress 0..1 of a limb's move at `t` (0..1), shaped by `kind` (Ease).
func eased(t: float, kind: int) -> float:
	t = clampf(t, 0.0, 1.0)
	match kind:
		Ease.LINEAR:
			return t
		Ease.SMOOTHSTEP:
			return t * t * (3.0 - 2.0 * t)
		Ease.EASE_OUT:
			return 1.0 - pow(1.0 - t, 3.0)
		Ease.SKEWED:
			# Time warped so the minimum-jerk curve's middle lands at ease_peak.
			t = pow(t, log(0.5) / log(clampf(ease_peak, 0.05, 0.95)))
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


## Gait windows ({hands = [lead, trail], feet = [lead, trail], body = [[from, to, 1.0]]})
## for a hanging-style stride `kind`.
func gait(kind: StringName) -> Dictionary:
	var p := ""
	match kind:
		&"up": p = "up_"
		&"down": p = "down_"
		&"side": p = "side_"
		&"hang": p = "hang_"
		_: return {}
	var w := func(n: String) -> Array:
		var v: Vector2 = get(p + n)
		return [v.x, v.y]
	var body: Vector2 = get(p + "body")
	return {hands = [w.call("hand_lead"), w.call("hand_trail")], feet = [w.call("foot_lead"), w.call("foot_trail")],
		body = [[body.x, body.y, 1.0]]}
