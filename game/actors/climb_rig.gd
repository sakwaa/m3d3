class_name ClimbRig
extends SkeletonModifier3D
## Procedural climbing limbs (a child of the actor's Skeleton3D): while a ClimbState is
## current, hands and feet are planted on what the actor holds (its limb_pose()) and two-
## bone IK bends the arms and legs to them, over whatever animation plays. Planted limbs
## stay put in the world as the body moves. While the climb state strides, each limb moves
## in its window of the stride (ClimbState.GAITS: going up, lead foot, body pushes, trail
## foot, lead hand, trail hand...) to where it belongs when the stride ends; standing
## still, limbs left behind catch up in diagonal pairs.
##   wall: hands and feet on the wall, stepping.
##   ledge: hands on the edge (shuffling along it), feet on the wall below if there is one.
##   ceiling: hands on the ceiling, stepping; legs hang (animation).
##   pull: hands stay on the edge while the body rises, then let go; the feet push on the
##     wall, then step up onto the top where it stands.
##   leap: arms reach the way of the leap, then for the hold it lands on.
## Changing state, the limbs go from the old state's pose to the new one over mode_blend.

## Blend, step timing, lift, reach, head look and every state's limb spots: ClimbTuning
## (climb_tuning.tres, live-reloaded).

enum { HAND_L, HAND_R, FOOT_L, FOOT_R }
const CHAINS := [
	[&"upper_arm_L", &"forearm_L", &"hand_L"], [&"upper_arm_R", &"forearm_R", &"hand_R"],
	[&"thigh_L", &"shin_L", &"foot_L"], [&"thigh_R", &"shin_R", &"foot_R"]]
## Diagonal pairs that step together.
const PAIRS := [[HAND_L, FOOT_R], [HAND_R, FOOT_L]]

var actor: Actor
var tune: ClimbTuning:
	get:
		return ClimbTuning.shared()

var _bones := []  # per limb: [upper, lower, end] bone indices
var _plant: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var _from: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var _to: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var _moving: Array[bool] = [false, false, false, false]  # in its stride window
var _weight: Array[float] = [0.0, 0.0, 0.0, 0.0]
var _planted := false
var _stepping := -1  # pair stepping now (-1 = none)
var _step_t := 0.0
var _next_pair := 0
var _mode := &""
var _pull_hands: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _feet_hold: Array[bool] = [false, false]  # ledge: wall under each foot
var _head := -1
var _face_local := Vector3.FORWARD  # the face's direction in the head bone's space
var _look_at := Vector3.INF
var _rest_lead := 1  # the side that led the last stride (standing still keeps its pose)
var _palm_local := {}  # hand limb -> [palm axis in the bone's space, mirrored basis]
var _shown: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]  # targets solved last
var _trans_from: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var _trans_t := 1.0  # changing state: 0..1, 1 = done


func _init(p_actor: Actor = null) -> void:
	actor = p_actor
	name = "ClimbRig"
	influence = 0.0


func _process_modification_with_delta(delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or actor == null:
		return
	if _bones.is_empty() and not _find_bones(sk):
		active = false
		return
	var pose := _limb_pose()
	influence = move_toward(influence, 1.0 if not pose.is_empty() else 0.0, delta / tune.blend)
	if pose.is_empty():
		_planted = false
		_mode = &""
		_look_at = Vector3.INF
		return
	var mode: StringName = pose.mode
	if mode != _mode:
		if mode == &"pull":
			_pull_hands = [_edge_grip(pose, -1.0), _edge_grip(pose, 1.0)]
		if _mode != &"":
			# From one climbing state to another: ease from where the limbs were.
			_trans_from = _shown.duplicate()
			_trans_t = 0.0
		_mode = mode
	var ideal := _ideals(pose, actor.global_position)
	var want := _wants(pose)
	for i in 4:
		_weight[i] = move_toward(_weight[i], 1.0 if want[i] else 0.0, delta / tune.blend)
	_update_plants(pose, ideal, delta)
	for i in 4:
		_shown[i] = _plant[i]
	if _trans_t < 1.0:
		_trans_t = minf(_trans_t + delta / maxf(tune.mode_blend, 0.01), 1.0)
		var e := tune.eased(_trans_t, ClimbTuning.Ease.MIN_JERK)
		for i in 4:
			_shown[i] = _trans_from[i].lerp(_plant[i], e)
	_solve_all(sk, pose)
	_look(sk, pose, delta)


func _limb_pose() -> Dictionary:
	for m in actor.machines:
		var s := m.current as ClimbState
		if s:
			return s.limb_pose()
	return {}


func _find_bones(sk: Skeleton3D) -> bool:
	for chain in CHAINS:
		var ids := []
		for b in chain:
			var i := sk.find_bone(b)
			if i < 0:
				_bones = []
				return false
			ids.append(i)
		_bones.append(ids)
	return true


## Where each limb would rest now (world), on the surface held.
func _ideals(pose: Dictionary, o: Vector3) -> Array[Vector3]:
	var f := actor.facing
	var r := f.cross(Vector3.UP).normalized()
	var n: Vector3 = pose.get(&"normal", -f)
	var t := tune
	var out: Array[Vector3] = [o, o, o, o]
	match pose.mode:
		&"wall":
			# Spots along the wall's own up (the body lies along a slanted wall), uneven like a
			# climber's: the leading side reaches high with its hand and steps high with its
			# foot while the other hand stays by the head and the other leg long below
			# (sideways: the leading limbs reach out that way). Swaps every stride.
			var lead := _lead(pose, n)
			var up := ClimbState.up_of(n)
			var c := o + Vector3.UP * 0.8
			var hip := c + Vector3.UP * 0.05 - up * float(pose.get(&"drop", 0.0)) + lead
			var lead_side := float(pose.get(&"lead", _rest_lead))
			var kind: StringName = pose.get(&"gait", &"")
			var planted: bool = pose.get(&"planted", false)
			if kind == &"":
				kind = &"up"
			for side in [-1.0, 1.0]:
				var leading: bool = side == lead_side
				var hand_up := 0.8
				var hand_out := 0.22
				var foot_down := 0.55  # (well inside the leg's reach, or planted feet get dragged)
				var foot_out := 0.17
				if not planted:
					# Hanging: hands level at rest (uneven only while one reaches, which the
					# stride's timing does), legs long and close under the body.
					hand_up = t.hand_up  # about shoulder height after a pull (the body hangs back and low): elbows bent
					hand_out = t.hand_out if kind != &"side" else (t.hand_out_side_lead if leading else t.hand_out_side_trail)
					foot_down = t.foot_down  # legs long between moves (inside the leg's reach)
					foot_out = t.foot_out
					kind = &"-"
				match kind:
					&"up":
						hand_up = 1.0 if leading else 0.6
						foot_down = 0.4 if leading else 0.62
					&"down":
						hand_up = 0.6 if leading else 0.95
						foot_down = 0.62 if leading else 0.35
					&"side":
						hand_out = 0.38 if leading else 0.12
						foot_out = 0.3 if leading else 0.08
				var hand := HAND_L if side < 0.0 else HAND_R
				var foot := FOOT_L if side < 0.0 else FOOT_R
				out[hand] = _on_surface(c + up * hand_up + r * side * hand_out + lead, n)
				out[foot] = _on_surface(hip - up * foot_down + r * side * foot_out, n, tune.toe)
			var crouch: float = pose.get(&"crouch", 0.0)
			if crouch > 0.0:  # leap wind-up: feet draw up under the body
				for foot in [FOOT_L, FOOT_R]:
					out[foot] = _on_surface(out[foot] + up * t.crouch_feet * crouch, n, tune.toe)
		&"ledge":
			var edge: float = pose.edge
			var lead := r * signf((pose.moving as Vector2).x) * tune.lead
			for side in [[HAND_L, -1.0], [HAND_R, 1.0]]:
				var p: Vector3 = Vector3(o.x, edge, o.z) + r * t.hang_hand_out * side[1] + lead
				# (The face just under the edge: over it the ray would miss and leave the hands out
				# where the body is.)
				var hit := _ray(p + n * 0.5 - Vector3.UP * 0.05, -n, 1.0)
				out[side[0]] = Vector3(hit.position.x, edge + 0.03, hit.position.z) - n * 0.04 if not hit.is_empty() else p
			# Feet braced against the wall below (knees and toes on it), if it reaches under
			# them (not an overhang).
			for side in [[FOOT_L, -1.0], [FOOT_R, 1.0]]:
				# Tucked: knees drawn up, the feet just touching the wall (SotC's ledge hang).
				var hip: Vector3 = o + Vector3.UP * t.hang_hip_height + r * t.hang_foot_out * side[1]
				var spot := _on_surface(hip - Vector3.UP * t.hang_foot_down, n, tune.toe)
				var hit := _ray(spot + n * 0.4, -n, 0.8)
				_feet_hold[side[0] - FOOT_L] = not hit.is_empty()
				out[side[0]] = spot
		&"ceiling":
			var dir: Vector3 = pose.moving
			for side in [[HAND_L, -1.0], [HAND_R, 1.0]]:
				var p: Vector3 = o + Vector3.UP * t.ceiling_hand_height + r * t.ceiling_hand_out * side[1] + dir * tune.lead
				var hit := _ray(p, Vector3.UP, 0.8)
				out[side[0]] = hit.position - Vector3.UP * 0.04 if not hit.is_empty() else p + Vector3.UP * 0.35
		&"pull":
			# Hands stay on the edge; the feet push on the wall below (kept under the edge),
			# then step up over it: the right knee hooks onto the top by the knee beat and
			# steps to where it stands, the left swings up as the press brings the hips over. Both end on
			# the ground on top, apart, where the actor stands.
			out[HAND_L] = _pull_hands[0]
			out[HAND_R] = _pull_hands[1]
			var p: float = pose.progress
			var edge := float(pose.edge)
			var hip := o + Vector3.UP * 0.85
			var target: Vector3 = pose.get(&"target", o)
			var mid := (_pull_hands[0] + _pull_hands[1]) * 0.5
			var lip := Vector3(mid.x, edge, mid.z) + n * 0.06  # just off the edge's face
			for side in [[FOOT_L, -1.0], [FOOT_R, 1.0]]:
				var s: float = side[1]
				var w := hip - Vector3.UP * t.pull_up_foot_down + r * 0.15 * s
				w.y = minf(w.y, edge - 0.2)
				var wall := _on_surface(w, n, tune.toe)
				var stand := _on_ground(target + r * t.stand_foot_out * s)
				# Over the lip: a curve from the wall up over the edge (clear of it) and onto the top.
				var over := lip + r * 0.15 * s + Vector3.UP * t.over_edge
				var go: float
				if s > 0.0:
					var knee := _on_ground(Vector3(mid.x, edge, mid.z) - n * 0.3 + r * 0.15)
					go = smoothstep(0.45, t.beat_knee - 0.05, p)
					out[FOOT_R] = _curve(wall, over, knee, go).lerp(stand, smoothstep(t.beat_knee, 1.0, p))
				else:
					go = smoothstep(t.beat_press - 0.12, 0.95, p)  # (leaves the wall as the hips come over)
					out[FOOT_L] = _curve(wall, over, stand, go)
		&"leap":
			# Off the wall the legs kick straight, tuck up mid-flight, reach for the catch
			# (blending into the pose of the hold it lands on, below).
			var p: float = pose.get(&"progress", 0.0)
			var tuck := t.leap_tuck * sin(PI * p)
			var dir: Vector3 = pose.dir
			for side in [[FOOT_L, -1.0], [FOOT_R, 1.0]]:
				var hip: Vector3 = o + Vector3.UP * 0.85 + r * 0.1 * side[1]
				out[side[0]] = hip - Vector3.UP * lerpf(0.82, 0.3, tuck) - n * 0.25 * tuck
			out[HAND_L] = o + Vector3.UP * t.leap_hand_height - r * 0.2 + dir * t.leap_hand_ahead - n * 0.2
			out[HAND_R] = o + Vector3.UP * t.leap_hand_height + r * 0.2 + dir * t.leap_hand_ahead - n * 0.2
			var catch: Dictionary = pose.get(&"catch", {})
			if not catch.is_empty():
				var land := _ideals(catch, o)
				var k := smoothstep(0.45, 1.0, p)
				for i in 4:
					out[i] = out[i].lerp(land[i], k)
	return out


## Which limbs IK this frame (the rest follow the animation).
func _wants(pose: Dictionary) -> Array[bool]:
	match pose.mode:
		&"wall":
			return [true, true, true, true]
		&"ledge":
			return [true, true, _feet_hold[0], _feet_hold[1]]
		&"ceiling":
			return [true, true, false, false]
		&"pull":
			var p: float = pose.progress
			return [p < 0.8, p < 0.8, true, true]
		&"leap":
			return [true, true, true, true]
	return [false, false, false, false]


func _lead(pose: Dictionary, n: Vector3) -> Vector3:
	var m: Vector2 = pose.get(&"moving", Vector2.ZERO)
	if m == Vector2.ZERO:
		return Vector3.ZERO
	return (ClimbState.right_of(n) * m.x + ClimbState.up_of(n) * m.y).normalized() * tune.lead


func _update_plants(pose: Dictionary, ideal: Array[Vector3], delta: float) -> void:
	var stepping_modes := [&"wall", &"ledge", &"ceiling"]
	if not stepping_modes.has(pose.mode):
		# No gait: limbs go straight to their spots (pull keeps the hands where they were).
		for i in 4:
			_plant[i] = ideal[i]
		_stepping = -1
		_planted = false
		return
	if pose.get(&"crouch", 0.0) > 0.0:
		# Leap wind-up: the feet slide up with the crouch (the crouch eases them in).
		for i in [FOOT_L, FOOT_R]:
			_plant[i] = ideal[i]
	var far := false
	for i in 4:
		far = far or _plant[i].distance_to(ideal[i]) > 1.0
	if not _planted or far:
		# Just grabbed, or jumped (corner wrap, leap): plant everything where it belongs.
		for i in 4:
			_plant[i] = ideal[i]
			_moving[i] = false
		_planted = true
		_stepping = -1
		return
	var n: Vector3 = pose.get(&"normal", Vector3.ZERO)
	var lift_dir := Vector3.DOWN if pose.mode == &"ceiling" else n
	var gait: StringName = pose.get(&"gait", &"")
	if gait != &"":
		_rest_lead = pose.lead
		# Striding: each limb in its window, to where it belongs when the stride ends.
		var sched: Dictionary = pose.sched
		var planted: bool = pose.get(&"planted", false)
		var phase: float = pose.phase
		var lead: int = pose.lead
		var end_ideal := _ideals(pose, pose.end)
		for i in 4:
			var right := i == HAND_R or i == FOOT_R
			var w: Array = (sched.hands if i <= HAND_R else sched.feet)[0 if right == (lead > 0) else 1]
			if phase >= w[0] and phase < w[1]:
				if not _moving[i]:
					_moving[i] = true
					_from[i] = _plant[i]
					_to[i] = end_ideal[i]
					if i >= FOOT_L and pose.mode == &"wall":
						# The foot steps before the body rises: no higher than just under the hip
						# as it is now (stepping to where the hip will be folds the leg up).
						var up := ClimbState.up_of(n)
						var hip := actor.global_position + Vector3.UP * 0.85
						var over := (_to[i] - hip).dot(up) + tune.foot_under_hip
						if over > 0.0:
							_to[i] = _on_surface(_to[i] - up * over, n, tune.toe)
				var t: float = (phase - w[0]) / (w[1] - w[0])
				# Hands and feet ease along their move (ClimbTuning hand_ease / foot_ease). Hanging, the feet
				# kick up (knees drawn in) on their way to the next hold.
				var e := tune.eased(t, tune.hand_ease if i <= HAND_R else tune.foot_ease)
				var lift := tune.lift
				if not planted and i >= FOOT_L:
					# Hanging: the leading leg kicks its knee up high, the other just follows.
					var leads: bool = (i == FOOT_R) == (lead > 0)
					lift = tune.knee_kick if leads else tune.lift
				_plant[i] = _from[i].lerp(_to[i], e) + lift_dir * sin(PI * t) * lift
			elif _moving[i]:
				_plant[i] = _to[i]
				_moving[i] = false
		_stepping = -1
		return
	for i in 4:  # a stride cut short: land the limbs that were moving
		if _moving[i]:
			_plant[i] = _to[i]
			_moving[i] = false
	if _stepping >= 0:
		_step_t += delta / tune.step_time
		var s := minf(_step_t, 1.0)
		for i in PAIRS[_stepping]:
			var e := tune.eased(s, tune.hand_ease if i <= HAND_R else tune.foot_ease)
			_plant[i] = _from[i].lerp(ideal[i], e) + lift_dir * sin(PI * s) * tune.lift
		if s >= 1.0:
			_stepping = -1
		return
	# Start the next pair's step when one of its limbs has fallen behind.
	for k in 2:
		var pair: int = (_next_pair + k) % 2
		for i in PAIRS[pair]:
			if _plant[i].distance_to(ideal[i]) > tune.step_after:
				_stepping = pair
				_next_pair = (pair + 1) % 2
				_step_t = 0.0
				for j in PAIRS[pair]:
					_from[j] = _plant[j]
				return


func _solve_all(sk: Skeleton3D, pose: Dictionary) -> void:
	var to_sk := sk.global_transform.affine_inverse()
	var f := actor.facing
	var n: Vector3 = pose.get(&"normal", -f)
	var away := ClimbState.flat(n) if ClimbState.flat(n) != Vector3.ZERO else -f
	var r := f.cross(Vector3.UP).normalized()
	for i in 4:
		if _weight[i] <= 0.0:
			continue
		var ids: Array = _bones[i]
		var side := -1.0 if i == HAND_L or i == FOOT_L else 1.0
		var root := sk.get_bone_global_pose(ids[0]).origin
		var end := sk.get_bone_global_pose(ids[2]).origin
		var target: Vector3 = end.lerp(to_sk * _shown[i], _weight[i])
		# Elbows out, down and off the wall; knees towards the wall and a little out.
		var pole_world: Vector3
		if i <= HAND_R:
			pole_world = r * side * 0.8 - Vector3.UP * 0.35 + away * 0.25
		elif pose.mode == &"wall" and pose.get(&"planted", false):
			pole_world = r * side * 0.6 + Vector3.UP * 0.25 - away * 0.1  # knees out to the sides
		elif pose.mode == &"wall":
			pole_world = -away * 0.15 + r * side * tune.knee_out + Vector3.UP * 0.25  # knees splayed out (TotK), a little to the wall
		else:
			pole_world = -away * 0.2 + r * side * tune.knee_out + Vector3.UP * 0.2
		var pole := root + to_sk.basis * pole_world
		two_bone(sk, ids, target, pole)
		if i <= HAND_R:
			_orient_hand(sk, i, ids[2], pose, to_sk.basis, n)


## Turns a hand so its palm lies on what it holds, fingers along it (wall: palm in, fingers
## up; ledge / pull: palm down over the edge; ceiling: palm up). Which side of the hand
## is the palm comes from the rest pose (arms down, palms to the thighs).
func _orient_hand(sk: Skeleton3D, limb: int, bone: int, pose: Dictionary, to_sk: Basis, n: Vector3) -> void:
	var palm: Vector3
	var fingers: Vector3
	match pose.mode:
		&"wall":
			palm = -n
			fingers = ClimbState.up_of(n)
		&"ledge", &"pull":
			palm = Vector3.DOWN
			fingers = ClimbState.flat(-n)
		&"ceiling":
			palm = Vector3.UP
			fingers = actor.facing
		&"leap":
			palm = -n
			fingers = pose.dir
		_:
			return
	if not _palm_local.has(limb):
		var rest := sk.get_bone_global_rest(bone).basis
		var medial := Vector3.RIGHT if limb == HAND_L else Vector3.LEFT  # towards the body
		var p := rest.inverse() * medial
		p.y = 0.0  # across the bone (+Y runs along it)
		_palm_local[limb] = [p.normalized(), rest.determinant() < 0.0]
	var palm_l: Vector3 = _palm_local[limb][0]
	var ps := (to_sk * palm).normalized()
	var fs := to_sk * fingers
	fs = (fs - ps * fs.dot(ps)).normalized()
	if fs == Vector3.ZERO:
		return
	var local := Basis(Vector3.UP, palm_l, Vector3.UP.cross(palm_l))
	var z := fs.cross(ps) * (-1.0 if _palm_local[limb][1] else 1.0)
	var want := Basis(fs, ps, z) * local.inverse()
	var cur := sk.get_bone_global_pose(bone)
	var w := _weight[limb]
	var b := want.orthonormalized() if w >= 1.0 else cur.basis.orthonormalized().slerp(want.orthonormalized(), w)
	sk.set_bone_global_pose(bone, Transform3D(b, cur.origin))


## Bends upper / lower so the end bone's head reaches `target` (skeleton space), the middle
## joint towards `pole`. The end bone keeps its orientation.
static func two_bone(sk: Skeleton3D, ids: Array, target: Vector3, pole: Vector3) -> void:
	var a := sk.get_bone_global_pose(ids[0])
	var b := sk.get_bone_global_pose(ids[1])
	var c := sk.get_bone_global_pose(ids[2])
	var l1 := a.origin.distance_to(b.origin)
	var l2 := b.origin.distance_to(c.origin)
	if l1 < 0.001 or l2 < 0.001:
		return
	var to := target - a.origin
	var d := clampf(to.length(), 0.01, (l1 + l2) * 0.999)
	var dir := to.normalized() if to.length() > 0.0001 else (c.origin - a.origin).normalized()
	var cos_a := clampf((l1 * l1 + d * d - l2 * l2) / (2.0 * l1 * d), -1.0, 1.0)
	var bend := pole - a.origin
	bend -= dir * bend.dot(dir)
	if bend.length() < 0.0001:
		bend = (b.origin - a.origin) - dir * (b.origin - a.origin).dot(dir)
	bend = bend.normalized()
	var knee := a.origin + dir * cos_a * l1 + bend * sqrt(1.0 - cos_a * cos_a) * l1
	var reach := a.origin + dir * d
	var end_basis := c.basis
	var rot_a := _from_to((b.origin - a.origin).normalized(), (knee - a.origin).normalized())
	sk.set_bone_global_pose(ids[0], Transform3D(Basis(rot_a) * a.basis, a.origin))
	var c_now := knee + Basis(rot_a) * (c.origin - b.origin)
	var rot_b := _from_to((c_now - knee).normalized(), (reach - knee).normalized())
	sk.set_bone_global_pose(ids[1], Transform3D(Basis(rot_b * rot_a) * b.basis, knee))
	sk.set_bone_global_pose(ids[2], Transform3D(end_basis, reach))


static func _from_to(u: Vector3, v: Vector3) -> Quaternion:
	if u.dot(v) > 0.99999:
		return Quaternion.IDENTITY
	if u.dot(v) < -0.99999:
		var axis := u.cross(Vector3.RIGHT)
		if axis.length() < 0.001:
			axis = u.cross(Vector3.UP)
		return Quaternion(axis.normalized(), PI)
	return Quaternion(u, v)


## Turns the head to watch the hand that's reaching (else up the wall, at the hands, or
## the way of a leap), within a comfortable turn.
func _look(sk: Skeleton3D, pose: Dictionary, delta: float) -> void:
	if _head < 0:
		_head = sk.find_bone(&"head")
		if _head < 0:
			return
		_face_local = (sk.get_bone_global_rest(_head).basis.inverse() * Vector3.FORWARD).normalized()
	var n: Vector3 = pose.get(&"normal", -actor.facing)
	var o := actor.global_position
	var target := o + Vector3.UP * 2.4 - ClimbState.flat(n) * 0.2
	match pose.mode:
		&"ledge", &"pull":
			target = (_plant[HAND_L] + _plant[HAND_R]) * 0.5 + Vector3.UP * 0.3
		&"ceiling":
			target = (_plant[HAND_L] + _plant[HAND_R]) * 0.5 + actor.facing * 0.6
		&"leap":
			target = o + Vector3.UP * 1.6 + (pose.dir as Vector3) * 2.0
	for i in [HAND_L, HAND_R]:
		if _moving[i]:
			target = _to[i]  # eyes on where the hand is going
	_look_at = target if _look_at == Vector3.INF else _look_at.lerp(target, clampf(tune.look_speed * delta, 0.0, 1.0))
	var g := sk.get_bone_global_pose(_head)
	var cur := (g.basis * _face_local).normalized()
	var want := (sk.global_transform.affine_inverse() * _look_at - g.origin).normalized()
	var ang := cur.angle_to(want)
	if ang < 0.001:
		return
	want = cur.slerp(want, minf(1.0, tune.look_max / ang))
	var q := Quaternion.IDENTITY.slerp(_from_to(cur, want), tune.look_weight)
	sk.set_bone_global_pose(_head, Transform3D(Basis(q) * g.basis, g.origin))


## A hand gripping the top edge for a mantle (side -1 left, +1 right): just over the lip,
## shoulder width apart.
func _edge_grip(pose: Dictionary, side: float) -> Vector3:
	var n: Vector3 = pose.normal
	var o := actor.global_position
	var r := actor.facing.cross(Vector3.UP).normalized()
	var edge := float(pose.edge)
	var p := Vector3(o.x, edge - 0.1, o.z) + r * 0.22 * side
	var hit := _ray(p + n * 0.5, -n, 1.5)
	var face: Vector3 = hit.position if not hit.is_empty() else p - n * 0.35
	return Vector3(face.x, edge + 0.03, face.z) - n * 0.06


## The ground under `p` with an ankle over it (the ankle at `p`'s height without ground).
func _on_ground(p: Vector3) -> Vector3:
	var hit := _ray(p + Vector3.UP * 0.6, Vector3.DOWN, 1.4)
	return (hit.position as Vector3) + Vector3.UP * tune.ankle_height if not hit.is_empty() else p + Vector3.UP * tune.ankle_height


## A point `t` (0..1) along the curve from `a` to `c` bowing through near `b` (quadratic).
static func _curve(a: Vector3, b: Vector3, c: Vector3, t: float) -> Vector3:
	return a.lerp(b, t).lerp(b.lerp(c, t), t)


## The point on the surface behind `p` (along -n), a hand's thickness off it.
func _on_surface(p: Vector3, n: Vector3, off := 0.05) -> Vector3:
	var hit := _ray(p + n * 0.5, -n, 1.1)
	return hit.position + n * off if not hit.is_empty() else p - n * 0.3


func _ray(from: Vector3, dir: Vector3, length: float) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * length, actor.collision_mask, [actor.get_rid()])
	return actor.get_world_3d().direct_space_state.intersect_ray(q)
