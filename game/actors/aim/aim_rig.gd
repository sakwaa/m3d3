class_name AimRig
extends SkeletonModifier3D
## The aiming pose over whatever the legs are doing (AimState; TOTK reference in
## references/aiming/totk_aim_reference.md): the spine and chest twist side-on (bow
## shoulder forward) and lean with the aim's pitch, the bow arm reaches out along the aim
## (two-bone IK) and the string hand draws back along the same line to the face. Blends in
## with AimState.raise, out over OUT_TIME. Also draws the bow (limbs bending with the draw,
## the string to the drawing hand) and the nocked arrow, in world space; `nock_point()` is
## where a shot leaves from. A child of the actor's Skeleton3D (Actor.aim_rig).
##
## Handedness (`left_handed`): our player is right-handed (sword in the right hand), so the
## bow is in the LEFT hand and drawn with the right - the mirror of TOTK's left-handed Link
## in the reference footage. Every sideways sign below goes through `_hand`.

const RIGHT_ARM := [&"upper_arm_R", &"forearm_R", &"hand_R"]
const LEFT_ARM := [&"upper_arm_L", &"forearm_L", &"hand_L"]
## Side-on twist (radians, bow shoulder forward), split spine / chest: nearly side-on, so
## both shoulders sit on the arrow's line and the drawing elbow goes back past the far
## shoulder (not across the chest). The head turns back (HEAD_BACK of it) to look down the
## arrow.
const TWIST := 1.15
const HEAD_BACK := 0.9
const SPINE_SHARE := 0.4
## Ready (nocked, not drawn): the bow turned this far (degrees) to the bow side of where the
## archer looks, the body only READY_TWIST of the way side-on, the string hand forward at
## the nock. Drawing twists the body from the hips (spine first) and swings the bow onto the
## aim line, aligned by ALIGN_BY of the draw (so even the earliest shot is about on line).
const READY_YAW := 45.0
const READY_TWIST := 0.35
const ALIGN_BY := 0.6
## Ready: the bow hand this far out from its shoulder (m) and down.
const READY_REACH := 0.5
const READY_DROP := 0.08
## Share of the aim's pitch the chest leans (the arms do the rest).
const PITCH_SHARE := 0.45
## The arrow's line runs through the anchor: the string hand under the chin, this far
## below the head bone and towards the bow side (m).
const ANCHOR_DOWN := 0.1
const ANCHOR_SIDE := 0.0
## How far in front of the chest the arrow's line runs (m).
const CHEST_CLEAR := 0.16
## String to grip at rest (brace height) and the extra pull at a full draw (m).
const BRACE := 0.14
const DRAW_LEN := 0.46
const OUT_TIME := 0.25
## Bow: half its length, how far the tips sit back towards the archer (more when drawn).
const BOW_HALF := 0.55
const TIP_BACK := 0.1
const TIP_BEND := 0.1

var actor: Actor
## Left-handed archer (bow in the right hand, like Link); off: right-handed (bow in the left).
var left_handed := false
var BOW_ARM: Array
var DRAW_ARM: Array
var _hand := 1.0  # +1 left-handed (bow side = the skeleton's +X), -1 right-handed
var _w := 0.0
var _draw := 0.0
var _aim := Vector3.FORWARD  # skeleton space, unit
var _bow_dir := Vector3.FORWARD  # where the bow points (skeleton space): off to the side when ready
var _bones := {}
var _string_local := Vector3.ZERO  # skeleton space
var _grip_local := Vector3.ZERO
var _bow: MeshInstance3D
var _bow_mesh: ImmediateMesh
var _arrow: MeshInstance3D
## Debug: per chain, how far its end ended from the IK target, and the elbow (skeleton space).
var ik_report := {}


func _init(p_actor: Actor = null, p_left_handed := false) -> void:
	actor = p_actor
	name = "AimRig"
	left_handed = p_left_handed
	BOW_ARM = RIGHT_ARM if left_handed else LEFT_ARM
	DRAW_ARM = LEFT_ARM if left_handed else RIGHT_ARM
	_hand = 1.0 if left_handed else -1.0


func _ready() -> void:
	_bow_mesh = ImmediateMesh.new()
	_bow = MeshInstance3D.new()
	_bow.name = "Bow"
	_bow.mesh = _bow_mesh
	_bow.top_level = true
	_bow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_bow.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF  # (rebuilt every frame)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_bow.material_override = mat
	_bow.visible = false
	add_child(_bow, false, Node.INTERNAL_MODE_BACK)
	_arrow = MeshInstance3D.new()
	_arrow.name = "NockedArrow"
	_arrow.mesh = Arrow.build_mesh()
	_arrow.top_level = true
	_arrow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_arrow.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_arrow.visible = false
	add_child(_arrow, false, Node.INTERNAL_MODE_BACK)


## Where a shot leaves from (world): the string at the nock.
func nock_point() -> Vector3:
	var sk := get_skeleton()
	if sk == null:
		return actor.global_position + Vector3.UP * 1.3
	return sk.global_transform * _string_local


func _process_modification_with_delta(delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or actor == null:
		return
	if _bones.is_empty():
		for b in [&"spine", &"chest", &"head"] + BOW_ARM + DRAW_ARM:
			_bones[b] = sk.find_bone(b)
		if _bones.values().has(-1):
			active = false
			return
	var aim := actor.state_of(Actor.ACTION) as AimState
	var inv := sk.global_transform.basis.inverse()
	if aim:
		_w = smoothstep(0.0, 1.0, aim.raise)
		_draw = aim.draw
		_aim = (inv * aim.aim_dir).normalized()
	else:
		_w = maxf(_w - delta / OUT_TIME, 0.0)
		_draw = maxf(_draw - delta * 6.0, 0.0)
	if _w <= 0.0:
		_bow.visible = false
		_arrow.visible = false
		return
	# How far the draw has brought the bow onto the aim line (0 ready .. 1 aligned).
	var k := smoothstep(0.0, ALIGN_BY, _draw)
	# `side`: towards the bow's side of the body (sideways from the aim).
	var side := (_aim.cross(Vector3.UP).normalized() if absf(_aim.y) < 0.98 else Vector3.RIGHT) * _hand
	# Body: side-on by the draw, led from the hips (the spine takes the twist first), lean
	# with the pitch.
	var pitch := asin(clampf(_aim.y, -1.0, 1.0))
	var twist_amt := TWIST * lerpf(READY_TWIST, 1.0, k) * _w * _hand  # (+: the right shoulder forward)
	var spine_part := twist_amt * lerpf(0.75, SPINE_SHARE, k)
	_turn(sk, _bones[&"spine"], Basis(Vector3.UP, spine_part))
	_turn(sk, _bones[&"chest"], Basis(Vector3.UP, twist_amt - spine_part))
	var right := Basis(Vector3.UP, twist_amt) * Vector3.RIGHT
	_turn(sk, _bones[&"chest"], Basis(right, pitch * PITCH_SHARE * _w))
	# The head turned back to look down the aim (and up / down with it).
	_turn(sk, _bones[&"head"], Basis(Vector3.UP, -twist_amt * HEAD_BACK))
	_turn(sk, _bones[&"head"], Basis(side, pitch * (1.0 - PITCH_SHARE) * 0.6 * _w))
	# The bow: off to the bow side when ready, swung onto the aim as it's drawn.
	_bow_dir = _aim.rotated(Vector3.UP, -deg_to_rad(READY_YAW) * (1.0 - k) * _hand).normalized()
	# Drawn: the arrow's line runs from the anchor under the chin out along the aim, the
	# bow hand a full draw out along it. Ready: the bow hand out from its shoulder along the
	# bow, a little low. The string hand on the string (at the nock when ready, back to the
	# anchor at full draw).
	var head := sk.get_bone_global_pose(_bones[&"head"]).origin
	# (Out in front of the chest - the way it faces, side-on - so the string comes back
	# outside the bow-side pectoral to the corner of the chin, never into the torso.)
	var chest_fwd := sk.get_bone_global_pose(_bones[&"chest"]).basis * Vector3(0, 0, -1)
	chest_fwd = (chest_fwd - _aim * chest_fwd.dot(_aim)).normalized()
	var anchor := head + Vector3.DOWN * ANCHOR_DOWN + side * ANCHOR_SIDE + chest_fwd * CHEST_CLEAR
	var bow_shoulder := sk.get_bone_global_pose(_bones[BOW_ARM[0]]).origin
	var grip_ready := bow_shoulder + _bow_dir * READY_REACH + Vector3.DOWN * READY_DROP
	# Drawn (real archery, references/aiming): the bow arm straight out - the grip where the
	# arrow's line meets the bow arm's full reach - so the draw is anchor to grip less brace.
	var reach := _arm_len(sk, BOW_ARM) * 0.97
	var grip_drawn := _on_line_at(anchor, _aim, bow_shoulder, reach)
	var draw_len := maxf(grip_drawn.distance_to(anchor) - BRACE, 0.2)
	var grip := grip_ready.lerp(grip_drawn, k)
	var string := grip - _bow_dir * (BRACE + draw_len * _draw)
	_ik(sk, BOW_ARM, grip, Vector3.DOWN * 0.6 + side * 0.4, _w)
	# (The wrist a hand's length behind the string: the fingers hold it.) The drawing elbow
	# out on the drawing arm's own side (away from the bow), a little back, level with the
	# shoulder: never in across the chest, never up by the head or hanging down.
	var wrist := string - _bow_dir * 0.07
	# Drawn, the elbow goes back behind the hand along the arrow's line, raised about to
	# shoulder height and out on its own side (an archer's "elbow in line").
	_ik(sk, DRAW_ARM, wrist, -_bow_dir * (0.3 + 0.7 * k) + Vector3.UP * 0.3 * k - side * lerpf(1.0, 0.35, k), _w)
	_grip_local = sk.get_bone_global_pose(_bones[BOW_ARM[2]]).origin
	_string_local = sk.get_bone_global_pose(_bones[DRAW_ARM[2]]).origin.lerp(string, 0.5) if _draw > 0.02 else \
		_grip_local - _bow_dir * BRACE
	_draw_bow(sk)


## Upper arm + forearm length of a chain.
func _arm_len(sk: Skeleton3D, chain: Array) -> float:
	var a := sk.get_bone_global_pose(_bones[chain[0]]).origin
	var b := sk.get_bone_global_pose(_bones[chain[1]]).origin
	var c := sk.get_bone_global_pose(_bones[chain[2]]).origin
	return a.distance_to(b) + b.distance_to(c)


## The point along `from` + `dir` * t (t > 0) at distance `r` from `centre` (the far
## crossing; the nearest point on the line if it never gets that far).
static func _on_line_at(from: Vector3, dir: Vector3, centre: Vector3, r: float) -> Vector3:
	var m := from - centre
	var b := m.dot(dir)
	var c := m.dot(m) - r * r
	var disc := b * b - c
	var t := -b + sqrt(disc) if disc >= 0.0 else -b
	return from + dir * maxf(t, 0.3)


## Turns bone `b` by `r` (skeleton space) about its own origin.
func _turn(sk: Skeleton3D, b: int, r: Basis) -> void:
	var g := sk.get_bone_global_pose(b)
	sk.set_bone_global_pose(b, Transform3D(r * g.basis, g.origin))


## Two-bone IK: the chain's end to `target` (skeleton space), the middle joint bending
## towards `pole`; `w` blends from the animation's pose.
func _ik(sk: Skeleton3D, chain: Array, target: Vector3, pole: Vector3, w: float) -> void:
	var ua: int = _bones[chain[0]]
	var lo: int = _bones[chain[1]]
	var en: int = _bones[chain[2]]
	var a := sk.get_bone_global_pose(ua).origin
	var b := sk.get_bone_global_pose(lo).origin
	var c := sk.get_bone_global_pose(en).origin
	var la := a.distance_to(b)
	var lb := b.distance_to(c)
	var t := c.lerp(target, w)
	var to_t := t - a
	var d := clampf(to_t.length(), 0.01, (la + lb) * 0.999)
	var dir := to_t.normalized()
	var cos_a := clampf((la * la + d * d - lb * lb) / (2.0 * la * d), -1.0, 1.0)
	var bend := (pole - dir * pole.dot(dir))
	bend = bend.normalized() if bend.length() > 0.001 else dir.cross(Vector3.RIGHT).normalized()
	var elbow := a + dir * la * cos_a + bend * la * sqrt(1.0 - cos_a * cos_a)
	# The upper arm by two directions, not one: along it to the elbow, and its elbow hinge
	# where this bend needs it (the rest pose's hinge, mapped). A shortest-arc turn alone can
	# leave the arm rolled half round: the elbow in place but bending backwards.
	var hinge := (elbow - a).cross(a + dir * d - elbow)
	if hinge.length() > 0.0001:
		_orient(sk, ua, _hinge_local(sk, ua, lo, en), (elbow - a).normalized(), hinge.normalized())
	else:
		_aim_bone(sk, ua, b - a, elbow - a)
	var b2 := sk.get_bone_global_pose(lo).origin
	var c2 := sk.get_bone_global_pose(en).origin
	_aim_bone(sk, lo, c2 - b2, a + dir * d - b2)
	ik_report[chain[2]] = {miss = sk.get_bone_global_pose(en).origin.distance_to(t), elbow = sk.get_bone_global_pose(lo).origin,
		elbow_want = elbow, shoulder = a, hand = sk.get_bone_global_pose(en).origin, target = t}


## The upper arm's elbow hinge in its own frame: [along the bone, hinge] (local), from the
## rest pose - an arm hanging with the forearm bent forward (towards -Z, the model's front)
## hinges about +X (skeleton space), whichever arm.
func _hinge_local(sk: Skeleton3D, ua: int, lo: int, _en: int) -> Array:
	var key := "hinge_%d" % ua
	if _bones.has(key):
		return _bones[key]
	var rest := sk.get_bone_global_rest(ua)
	var along := (sk.get_bone_global_rest(lo).origin - rest.origin).normalized()
	var fwd_bent := Vector3(0, 0, -1)
	var h := along.cross(fwd_bent)
	if h.length() < 0.001:
		h = Vector3.RIGHT
	var inv := rest.basis.inverse()
	var out := [(inv * along).normalized(), (inv * h.normalized()).normalized()]
	_bones[key] = out
	return out


## Turns bone `i` (about its origin) so its local [along, hinge] (`local`) point along
## `along` and `hinge` (skeleton space).
func _orient(sk: Skeleton3D, i: int, local: Array, along: Vector3, hinge: Vector3) -> void:
	var la: Vector3 = local[0]
	var lh: Vector3 = (local[1] - la * (local[1] as Vector3).dot(la)).normalized()
	var th := (hinge - along * hinge.dot(along)).normalized()
	var from := Basis(la, lh, la.cross(lh))
	var to := Basis(along, th, along.cross(th))
	var g := sk.get_bone_global_pose(i)
	sk.set_bone_global_pose(i, Transform3D((to * from.inverse()).orthonormalized(), g.origin))


## Rotates bone `i` (about its origin) so its `from` direction points along `to`.
func _aim_bone(sk: Skeleton3D, i: int, from: Vector3, to: Vector3) -> void:
	if from.length() < 0.0001 or to.length() < 0.0001:
		return
	var q := Quaternion(from.normalized(), to.normalized())
	var g := sk.get_bone_global_pose(i)
	sk.set_bone_global_pose(i, Transform3D(Basis(q) * g.basis, g.origin))


## The bow (limbs and string) and the nocked arrow, in world space where the skeleton is
## drawn this frame.
func _draw_bow(sk: Skeleton3D) -> void:
	var xf := sk.get_global_transform_interpolated()
	var grip := xf * _grip_local
	var string := xf * _string_local
	var f := (xf.basis * _bow_dir).normalized()
	var up := (Vector3.UP - f * Vector3.UP.dot(f)).normalized()
	up = up.rotated(f, deg_to_rad(-4.0) * _hand)  # (all but upright, as in the reference)
	var side := f.cross(up).normalized()
	var back := TIP_BACK + TIP_BEND * _draw
	var half := BOW_HALF * (1.0 - 0.06 * _draw)
	var top := grip + up * half - f * back
	var bottom := grip - up * half - f * back
	var wood := Color(0.42, 0.27, 0.15)
	var cord := Color(0.88, 0.86, 0.8)
	_bow_mesh.clear_surfaces()
	_bow_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	# Limbs: a curve grip -> tip each way (a few segments), crossed quads for thickness.
	for tip_dir in [1.0, -1.0]:
		var prev := grip
		for k in range(1, 6):
			var s := float(k) / 5.0
			var p: Vector3 = grip + up * half * s * tip_dir - f * back * s * s
			_strip(prev, p, side, up, 0.022 * (1.0 - 0.5 * s), wood)
			prev = p
	# String: tip -> nock -> tip (at rest, straight between the tips).
	var nock := string if _draw > 0.02 else (top + bottom) * 0.5
	_strip(top, nock, side, f, 0.004, cord)
	_strip(nock, bottom, side, f, 0.004, cord)
	_bow_mesh.surface_end()
	_bow.global_transform = Transform3D.IDENTITY
	_bow.visible = true
	# The arrow on the string, pointing along the aim (from the nock), once nocked.
	var aim := actor.state_of(Actor.ACTION) as AimState
	var nocked := aim != null and aim.raise >= 0.6 and aim.since_shot >= aim.item.reload_time * 0.6
	_arrow.visible = nocked
	if nocked:
		var tail := nock if _draw > 0.02 else grip - f * BRACE
		_arrow.global_transform = Transform3D(Basis.looking_at(f, up), tail + f * Arrow.LENGTH * 0.5)


## A thin bar a -> b as two crossed quads (`u`, `v` the cross directions).
func _strip(a: Vector3, b: Vector3, u: Vector3, v: Vector3, w: float, col: Color) -> void:
	for side in [u * w, v * w]:
		for p in [a - side, b - side, b + side, a - side, b + side, a + side]:
			_bow_mesh.surface_set_color(col)
			_bow_mesh.surface_add_vertex(p)
