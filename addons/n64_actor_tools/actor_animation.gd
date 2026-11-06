@tool
class_name ActorAnimation
extends Resource
## One animation of a character: whole-body pose keys on a frame grid, each easing into
## the next one; named windows (frame ranges the state machine reads: windup, active,
## cancel, opening...) and events (footsteps, sounds). Named like the state that plays it.
## Built into a Godot Animation (baked per frame) for the game.

enum Ease {
	SMOOTH,    ## Ease in and out (default, natural).
	LINEAR,    ## Constant speed.
	EASE_IN,   ## Slow start, fast arrival (falls, wind-up releases).
	EASE_OUT,  ## Fast start, settling (strikes, landings).
	SNAP,      ## Very fast out, long settle: snappy N64 attacks.
	POP,       ## Overshoots then settles back: punchy accents.
	STEP,      ## Holds, then jumps to the next key.
}
const EASE_NAMES := ["Smooth", "Linear", "Ease in", "Ease out", "Snap", "Pop", "Step"]
const EASE_COLORS := [Color(0.9, 0.9, 0.9), Color(0.6, 0.8, 1.0), Color(0.5, 1.0, 0.6), Color(1.0, 0.8, 0.4),
	Color(1.0, 0.45, 0.35), Color(1.0, 0.5, 1.0), Color(0.55, 0.55, 0.55)]
## Window names with a meaning in the state machines (others are fine too).
const WINDOW_PRESETS := ["windup", "active", "cancel", "opening"]
const WINDOW_COLORS := {"windup": Color(1.0, 0.85, 0.3), "active": Color(1.0, 0.35, 0.3),
	"cancel": Color(0.4, 0.75, 1.0), "opening": Color(0.45, 1.0, 0.5)}

@export var name := "Animation"
## Frames per second of the key grid (OoT animated at 20; the game interpolates).
@export var fps := 20
## Frames (the last frame of a loop wraps to frame 0).
@export var length := 20
@export var loop := false
## [{frame: int, pose: {bone: Quaternion}, root: Vector3, ease: Ease}], sorted by frame.
@export var keys: Array = []
## Window name -> Vector2i(first frame, last frame).
@export var windows := {}
## [{frame: int, name: String}].
@export var events: Array = []


func sort_keys() -> void:
	keys.sort_custom(func(a, b): return a.frame < b.frame)


func key_index(frame: int) -> int:
	for i in keys.size():
		if keys[i].frame == frame:
			return i
	return -1


## Adds or replaces the key at `frame` (keeps an existing key's ease).
func set_key(frame: int, pose: Dictionary, root: Vector3, ease := -1) -> void:
	var i := key_index(frame)
	if i >= 0:
		keys[i].pose = pose.duplicate()
		keys[i].root = root
		if ease >= 0:
			keys[i].ease = ease
	else:
		keys.append({frame = frame, pose = pose.duplicate(), root = root, ease = Ease.SMOOTH if ease < 0 else ease})
		sort_keys()


func remove_key(frame: int) -> void:
	var i := key_index(frame)
	if i >= 0:
		keys.remove_at(i)


## Pose at a (fractional) frame: {pose, root}. Loops wrap from the last key to the first.
func evaluate(frame: float) -> Dictionary:
	if keys.is_empty():
		return {pose = {}, root = Vector3.ZERO}
	if loop and length > 0:
		frame = fposmod(frame, length)
	var prev: Dictionary = keys[0]
	var next: Dictionary = keys[0]
	var span := 1.0
	if frame <= keys[0].frame and not loop:
		return {pose = keys[0].pose, root = keys[0].root}
	var found := false
	for i in keys.size():
		if keys[i].frame > frame:
			next = keys[i]
			prev = keys[i - 1] if i > 0 else keys[-1]
			span = next.frame - prev.frame if i > 0 else next.frame + length - prev.frame
			found = true
			break
	if not found:
		prev = keys[-1]
		if not loop:
			return {pose = prev.pose, root = prev.root}
		next = keys[0]
		span = next.frame + length - prev.frame
	var since: float = frame - prev.frame
	if since < 0.0:
		since += length
	var t := clampf(since / maxf(span, 1e-4), 0.0, 1.0)
	return blend(prev, next, eased(t, prev.ease))


## Pose between two keys at weight `t` (beyond 0..1 overshoots).
static func blend(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var pose := {}
	var bones := {}
	for k in a.pose:
		bones[k] = true
	for k in b.pose:
		bones[k] = true
	for bone in bones:
		var qa: Quaternion = a.pose.get(bone, Quaternion.IDENTITY)
		var qb: Quaternion = b.pose.get(bone, Quaternion.IDENTITY)
		pose[bone] = _slerp_any(qa, qb, t)
	return {pose = pose, root = (a.root as Vector3).lerp(b.root, t)}


static func _slerp_any(a: Quaternion, b: Quaternion, t: float) -> Quaternion:
	if t >= 0.0 and t <= 1.0:
		return a.slerp(b, t)
	# Overshoot: extrapolate along the same arc.
	var d := (a.inverse() * b).normalized()
	var axis := d.get_axis()
	var angle := d.get_angle()
	if axis.length() < 1e-5:
		return a
	return (a * Quaternion(axis.normalized(), angle * t)).normalized()


static func eased(t: float, mode: int) -> float:
	match mode:
		Ease.LINEAR:
			return t
		Ease.EASE_IN:
			return t * t * t
		Ease.EASE_OUT:
			return 1.0 - pow(1.0 - t, 3.0)
		Ease.SNAP:
			return 1.0 - pow(1.0 - t, 6.0)
		Ease.POP:
			# Back-out: passes the target by ~10% and settles.
			var c := 1.70158
			var u := t - 1.0
			return 1.0 + (c + 1.0) * u * u * u + c * u * u
		Ease.STEP:
			return 0.0 if t < 1.0 else 1.0
	return t * t * (3.0 - 2.0 * t)


## Windows as fractions of the length (what the state machines use).
func window_fractions() -> Dictionary:
	var out := {}
	var n := float(maxi(length, 1))
	for w in windows:
		var r: Vector2i = windows[w]
		out[StringName(w)] = Vector2(r.x / n, (r.y + 1) / n)
	return out


# --- Mirroring (bone names _L <-> _R, rotations reflected across the body's centre) ----

static func mirror_pose(pose: Dictionary) -> Dictionary:
	var out := {}
	for bone in pose:
		var q: Quaternion = pose[bone]
		out[BodyPlan.mirror_name(bone)] = Quaternion(q.x, -q.y, -q.z, q.w)
	return out


static func mirror_root(root: Vector3) -> Vector3:
	return Vector3(-root.x, root.y, root.z)


## A copy of this animation with every pose mirrored (attacks for the other hand...).
func mirrored(new_name: String) -> ActorAnimation:
	var a := duplicate(true) as ActorAnimation
	a.name = new_name
	for k in a.keys:
		k.pose = mirror_pose(k.pose)
		k.root = mirror_root(k.root)
	return a
