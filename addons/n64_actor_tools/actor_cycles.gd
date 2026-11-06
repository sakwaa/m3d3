@tool
class_name ActorCycles
extends RefCounted
## Starter cycles generated from a few settings with the character's own IK: feet / paws
## on a stride path, hips bouncing, arms swinging against the legs. A consistent base to
## tweak by hand, not a finished animation. Keys every few frames, smooth eases, looping.

const KINDS := {
	&"humanoid": ["walk", "run", "idle", "attack", "attack2", "guard", "hurt", "stagger", "recoil", "death", "jump", "fall", "land"],
	&"quadruped": ["walk", "run", "idle", "claw", "guard", "hurt", "stagger", "recoil", "death"],
}


static func kinds(plan: StringName) -> Array:
	return KINDS.get(plan, [])


## New looping animation `kind` for `model` (pose / root are restored afterwards).
static func generate(model: ActorModel, kind: String) -> ActorAnimation:
	var saved_pose: Dictionary = model.data.pose.duplicate()
	var saved_root := model.data.root_offset
	var saved_step := model.data.angle_step
	var saved_mode := model.mode
	model.data.angle_step = 0.0  # exact curves; keys snap only when edited by hand
	model.mode = ActorModel.Mode.POSE
	var a := ActorAnimation.new()
	a.name = kind.capitalize()
	a.loop = true
	match [model.data.plan, kind]:
		[&"humanoid", "walk"]:
			_biped(model, a, 24, 3, 0.55, 0.04, 0.09, 28.0, 15.0, 0.0)
		[&"humanoid", "run"]:
			_biped(model, a, 16, 2, 0.9, 0.08, 0.2, 45.0, 85.0, 12.0)
		[&"humanoid", "idle"]:
			_idle(model, a, 40, 0.012)
		[&"humanoid", _]:
			a.loop = false
			_biped_action(model, a, kind)
		[&"quadruped", "walk"]:
			_quadruped(model, a, 24, 3, 0.35, 0.07)
		[&"quadruped", "run"]:
			_quadruped(model, a, 12, 2, 0.6, 0.12, [0.0, 0.5, 0.1, 0.6])
		[&"quadruped", "idle"]:
			_idle(model, a, 40, 0.01)
		[&"quadruped", _]:
			a.loop = false
			_quadruped_action(model, a, kind)
	model.data.pose = saved_pose
	model.data.root_offset = saved_root
	model.data.angle_step = saved_step
	model.mode = saved_mode
	model.apply_pose()
	return a


static func _reset(model: ActorModel, root: Vector3) -> void:
	model.data.pose = {}
	model.data.root_offset = root
	model.apply_pose()


## Rest position of a chain's end (model space).
static func _rest_end(model: ActorModel, chain_name: StringName) -> Vector3:
	var c := model.find_chain(chain_name)
	return model.rest_global(model.bone_index(c.end)).origin


## Two-legged cycle: feet slide back on the ground then swing forward lifted; hips dip at
## each contact; arms swing opposite to the legs; `bend` = forearm bend (degrees), `lean`
## = forward lean of the spine.
static func _biped(model: ActorModel, a: ActorAnimation, length: int, step: int, stride: float, bounce: float,
		lift: float, swing: float, bend: float, lean: float) -> void:
	a.length = length
	var foot_l := _rest_end(model, &"leg_L")
	var foot_r := _rest_end(model, &"leg_R")
	for f in range(0, length, step):
		var p := float(f) / length
		var hips := Vector3(0, -bounce * (0.5 + 0.5 * cos(p * TAU * 2.0)), 0)
		_reset(model, hips)
		if lean != 0.0:
			_rotate(model, &"spine", Vector3.RIGHT, -lean)
		for side in [[&"leg_L", foot_l, 0.0], [&"leg_R", foot_r, 0.5]]:
			var q := fposmod(p + side[2], 1.0)
			var target: Vector3 = side[1]
			if q < 0.5:
				# Stance: from front (-Z) to back, on the ground.
				target.z += lerpf(-stride * 0.5, stride * 0.5, q / 0.5)
			else:
				var s := (q - 0.5) / 0.5
				target.z += lerpf(stride * 0.5, -stride * 0.5, s)
				target.y += sin(s * PI) * lift
			model.solve_chain(model.find_chain(side[0]), target)
		# Arms: left arm forward when the right leg is forward (left foot back).
		var arm := sin(p * TAU) * swing
		_rotate(model, &"upper_arm_L", Vector3.RIGHT, arm)
		_rotate(model, &"upper_arm_R", Vector3.RIGHT, -arm)
		for fa in [&"forearm_L", &"forearm_R"]:
			_rotate(model, fa, Vector3.RIGHT, bend)
		a.set_key(f, model.data.pose, model.data.root_offset)


## Breathing: chest rises and falls, a slight sway.
static func _idle(model: ActorModel, a: ActorAnimation, length: int, breath: float) -> void:
	a.length = length
	var chest := &"chest"
	for f in [0, length / 2]:
		var up: bool = f == length / 2
		_reset(model, Vector3(0, -breath if up else 0.0, 0))
		_rotate(model, chest, Vector3.RIGHT, -3.0 if up else 0.0)
		for c in model.chains:
			if String(c.name).begins_with("leg") or String(c.name).ends_with("leg_L") or String(c.name).ends_with("leg_R"):
				model.solve_chain(c, model.rest_global(model.bone_index(c.end)).origin)
		a.set_key(f, model.data.pose, model.data.root_offset)


## Four-legged walk: back left, front left, back right, front right, a quarter cycle apart.
static func _quadruped(model: ActorModel, a: ActorAnimation, length: int, step: int, stride: float, lift: float,
		phases := [0.0, 0.25, 0.5, 0.75]) -> void:
	a.length = length
	var legs := [[&"back_leg_L", phases[0]], [&"front_leg_L", phases[1]], [&"back_leg_R", phases[2]], [&"front_leg_R", phases[3]]]
	var rest := {}
	for l in legs:
		rest[l[0]] = _rest_end(model, l[0])
	for f in range(0, length, step):
		var p := float(f) / length
		_reset(model, Vector3(0, -0.015 * (0.5 + 0.5 * cos(p * TAU * 2.0)), 0))
		for l in legs:
			var q := fposmod(p + l[1], 1.0)
			var target: Vector3 = rest[l[0]]
			if q < 0.75:
				target.z += lerpf(-stride * 0.5, stride * 0.5, q / 0.75)
			else:
				var s := (q - 0.75) / 0.25
				target.z += lerpf(stride * 0.5, -stride * 0.5, s)
				target.y += sin(s * PI) * lift
			model.solve_chain(model.find_chain(l[0]), target)
		a.set_key(f, model.data.pose, model.data.root_offset)


## Rotates a bone by `degrees` about a model-space axis (on top of its current pose).
static func _rotate(model: ActorModel, bone: StringName, axis: Vector3, degrees: float) -> void:
	var i := model.bone_index(bone)
	if i < 0:
		return
	var cur := model.pose_global(i).basis.orthonormalized()
	model.set_global_rotation_of(i, Basis(axis, deg_to_rad(degrees)) * cur)


# --- Starter actions (one-shots: strikes, guards, reactions) ---------------------------------
# Each is a few keyed poses: extremes with Snap / Pop eases where it should hit hard, and
# windows on the frames the state machines care about. Right arm swings the weapon; the
# left holds the shield.

## Keys a pose: resets to rest + `root`, plants the feet / paws unless `free_legs`, then
## runs `pose_fn(model)` for the rest.
static func _key(model: ActorModel, a: ActorAnimation, frame: int, ease: int, root: Vector3, pose_fn: Callable, free_legs := false) -> void:
	_reset(model, root)
	if not free_legs:
		for c in model.chains:
			if String(c.name).contains("leg"):
				model.solve_chain(c, model.rest_global(model.bone_index(c.end)).origin)
	pose_fn.call(model)
	a.set_key(frame, model.data.pose, model.data.root_offset, ease)


## Points a bone along a model-space direction.
static func _aim(model: ActorModel, bone: StringName, dir: Vector3) -> void:
	var i := model.bone_index(bone)
	if i >= 0:
		model._point(i, dir.normalized())


static func _ready_arms(m: ActorModel) -> void:
	_aim(m, &"upper_arm_R", Vector3(0.35, -0.85, -0.3))
	_aim(m, &"forearm_R", Vector3(0.1, -0.4, -0.9))
	_aim(m, &"upper_arm_L", Vector3(-0.35, -0.85, -0.2))
	_aim(m, &"forearm_L", Vector3(0.0, -0.3, -0.95))


static func _biped_action(model: ActorModel, a: ActorAnimation, kind: String) -> void:
	var E := ActorAnimation.Ease
	match kind:
		"attack":  # horizontal slash, right to left (12 frames = 0.6 s)
			a.length = 12
			_key(model, a, 0, E.EASE_IN, Vector3.ZERO, _ready_arms)
			_key(model, a, 3, E.SNAP, Vector3(0, -0.02, 0), func(m):
				_rotate(m, &"spine", Vector3.UP, 25.0)
				_aim(m, &"upper_arm_R", Vector3(0.8, 0.45, 0.4))
				_aim(m, &"forearm_R", Vector3(0.5, 0.6, 0.6))
				_aim(m, &"upper_arm_L", Vector3(-0.4, -0.8, -0.3)))
			_key(model, a, 5, E.EASE_OUT, Vector3(0, -0.04, -0.05), func(m):
				_rotate(m, &"spine", Vector3.UP, -25.0)
				_aim(m, &"upper_arm_R", Vector3(-0.1, -0.05, -1.0))
				_aim(m, &"forearm_R", Vector3(-0.7, -0.1, -0.7))
				_aim(m, &"upper_arm_L", Vector3(-0.4, -0.8, 0.3)))
			_key(model, a, 8, E.SMOOTH, Vector3(0, -0.04, -0.05), func(m):
				_rotate(m, &"spine", Vector3.UP, -32.0)
				_aim(m, &"upper_arm_R", Vector3(-0.6, -0.5, -0.6))
				_aim(m, &"forearm_R", Vector3(-0.7, -0.6, -0.2)))
			_key(model, a, 11, E.SMOOTH, Vector3.ZERO, _ready_arms)
			a.windows = {"windup": Vector2i(0, 3), "active": Vector2i(4, 6), "cancel": Vector2i(7, 11), "opening": Vector2i(9, 11)}
		"attack2":  # overhead chop
			a.length = 12
			_key(model, a, 0, E.EASE_IN, Vector3.ZERO, _ready_arms)
			_key(model, a, 3, E.SNAP, Vector3(0, 0.0, 0.03), func(m):
				_rotate(m, &"spine", Vector3.RIGHT, 12.0)
				_aim(m, &"upper_arm_R", Vector3(0.25, 1.0, 0.15))
				_aim(m, &"forearm_R", Vector3(0.1, 0.6, 0.8)))
			_key(model, a, 5, E.EASE_OUT, Vector3(0, -0.06, -0.06), func(m):
				_rotate(m, &"spine", Vector3.RIGHT, -18.0)
				_aim(m, &"upper_arm_R", Vector3(0.1, -0.2, -1.0))
				_aim(m, &"forearm_R", Vector3(0.0, -0.75, -0.65)))
			_key(model, a, 8, E.SMOOTH, Vector3(0, -0.06, -0.06), func(m):
				_rotate(m, &"spine", Vector3.RIGHT, -20.0)
				_aim(m, &"upper_arm_R", Vector3(0.1, -0.6, -0.8))
				_aim(m, &"forearm_R", Vector3(0.0, -0.95, -0.3)))
			_key(model, a, 11, E.SMOOTH, Vector3.ZERO, _ready_arms)
			a.windows = {"windup": Vector2i(0, 3), "active": Vector2i(4, 6), "cancel": Vector2i(7, 11), "opening": Vector2i(9, 11)}
		"guard":  # shield up in front, crouched a little
			a.length = 6
			_key(model, a, 0, E.EASE_OUT, Vector3.ZERO, _ready_arms)
			_key(model, a, 3, E.SMOOTH, Vector3(0, -0.06, 0), func(m):
				_rotate(m, &"spine", Vector3.RIGHT, -8.0)
				_aim(m, &"upper_arm_L", Vector3(-0.2, -0.1, -1.0))
				_aim(m, &"forearm_L", Vector3(0.75, 0.45, -0.3))
				_aim(m, &"upper_arm_R", Vector3(0.45, -0.7, 0.2))
				_aim(m, &"forearm_R", Vector3(0.1, -0.3, -0.95)))
		"hurt":  # knocked back (8 frames)
			a.length = 8
			_key(model, a, 0, E.SNAP, Vector3.ZERO, _ready_arms)
			_key(model, a, 2, E.SMOOTH, Vector3(0, -0.03, 0.06), func(m):
				_rotate(m, &"spine", Vector3.RIGHT, 22.0)
				_rotate(m, &"head", Vector3.RIGHT, 15.0)
				_aim(m, &"upper_arm_R", Vector3(0.8, -0.3, 0.5))
				_aim(m, &"upper_arm_L", Vector3(-0.8, -0.3, 0.5)))
			_key(model, a, 7, E.SMOOTH, Vector3.ZERO, _ready_arms)
		"stagger":  # reeling, arms flung, a step back (16 frames)
			a.length = 16
			_key(model, a, 0, E.POP, Vector3.ZERO, _ready_arms)
			_key(model, a, 3, E.SMOOTH, Vector3(0, -0.05, 0.12), func(m):
				_rotate(m, &"spine", Vector3.RIGHT, 28.0)
				_rotate(m, &"spine", Vector3.FORWARD, 10.0)
				_aim(m, &"upper_arm_R", Vector3(0.9, 0.3, 0.3))
				_aim(m, &"upper_arm_L", Vector3(-0.9, 0.1, 0.4)))
			_key(model, a, 9, E.SMOOTH, Vector3(0, -0.08, 0.1), func(m):
				_rotate(m, &"spine", Vector3.RIGHT, 12.0)
				_rotate(m, &"spine", Vector3.FORWARD, -8.0)
				_aim(m, &"upper_arm_R", Vector3(0.7, -0.6, 0.2))
				_aim(m, &"upper_arm_L", Vector3(-0.7, -0.5, 0.3)))
			_key(model, a, 15, E.SMOOTH, Vector3.ZERO, _ready_arms)
		"recoil":  # weapon bounced off a shield / blade (10 frames)
			a.length = 10
			_key(model, a, 0, E.SNAP, Vector3.ZERO, _ready_arms)
			_key(model, a, 2, E.SMOOTH, Vector3(0, -0.02, 0.05), func(m):
				_rotate(m, &"spine", Vector3.RIGHT, 14.0)
				_aim(m, &"upper_arm_R", Vector3(0.6, 0.75, 0.3))
				_aim(m, &"forearm_R", Vector3(0.3, 0.9, 0.4)))
			_key(model, a, 9, E.SMOOTH, Vector3.ZERO, _ready_arms)
		"death":  # knees buckle, falls forward (16 frames, holds)
			a.length = 16
			_key(model, a, 0, E.EASE_OUT, Vector3.ZERO, _ready_arms)
			_key(model, a, 5, E.EASE_IN, Vector3(0, -0.35, 0), func(m):
				_rotate(m, &"spine", Vector3.RIGHT, -20.0)
				_aim(m, &"upper_arm_R", Vector3(0.3, -0.9, -0.2))
				_aim(m, &"upper_arm_L", Vector3(-0.3, -0.9, -0.2)))
			_key(model, a, 12, E.POP, Vector3(0, -0.72, -0.45), func(m):
				_rotate(m, &"hips", Vector3.RIGHT, -80.0)
				_aim(m, &"upper_arm_R", Vector3(0.4, -0.2, -0.9))
				_aim(m, &"upper_arm_L", Vector3(-0.4, -0.2, -0.9)), true)
			_key(model, a, 15, E.SMOOTH, Vector3(0, -0.74, -0.45), func(m):
				_rotate(m, &"hips", Vector3.RIGHT, -84.0)
				_aim(m, &"upper_arm_R", Vector3(0.5, -0.3, -0.8))
				_aim(m, &"upper_arm_L", Vector3(-0.5, -0.3, -0.8)), true)
		"jump":  # tucked
			a.length = 6
			_key(model, a, 0, E.EASE_OUT, Vector3.ZERO, _ready_arms, true)
			_key(model, a, 4, E.SMOOTH, Vector3.ZERO, func(m):
				_rotate(m, &"thigh_L", Vector3.RIGHT, -50.0)
				_rotate(m, &"shin_L", Vector3.RIGHT, 70.0)
				_rotate(m, &"thigh_R", Vector3.RIGHT, -25.0)
				_rotate(m, &"shin_R", Vector3.RIGHT, 45.0)
				_aim(m, &"upper_arm_R", Vector3(0.7, 0.6, -0.2))
				_aim(m, &"upper_arm_L", Vector3(-0.7, 0.6, -0.2)), true)
		"fall":  # arms up, legs reaching down
			a.length = 6
			_key(model, a, 0, E.SMOOTH, Vector3.ZERO, func(m):
				_rotate(m, &"thigh_L", Vector3.RIGHT, -15.0)
				_rotate(m, &"shin_L", Vector3.RIGHT, 25.0)
				_aim(m, &"upper_arm_R", Vector3(0.8, 0.55, 0.1))
				_aim(m, &"upper_arm_L", Vector3(-0.8, 0.55, 0.1)), true)
		"land":  # crouch on impact (3 frames)
			a.length = 3
			_key(model, a, 0, E.EASE_OUT, Vector3(0, -0.16, 0), func(m):
				_rotate(m, &"spine", Vector3.RIGHT, -15.0)
				_aim(m, &"upper_arm_R", Vector3(0.5, -0.6, -0.5))
				_aim(m, &"upper_arm_L", Vector3(-0.5, -0.6, -0.5)))
			_key(model, a, 2, E.SMOOTH, Vector3(0, -0.06, 0), _ready_arms)


static func _quadruped_action(model: ActorModel, a: ActorAnimation, kind: String) -> void:
	var E := ActorAnimation.Ease
	match kind:
		"claw":  # crouch, lunge with a snapping bite (18 frames = 0.9 s)
			a.length = 18
			_key(model, a, 0, E.EASE_IN, Vector3.ZERO, func(_m): pass)
			_key(model, a, 6, E.SNAP, Vector3(0, -0.08, 0.1), func(m):
				_rotate(m, &"neck", Vector3.RIGHT, 22.0)
				_rotate(m, &"jaw", Vector3.RIGHT, -30.0)
				_rotate(m, &"tail_1", Vector3.RIGHT, 25.0))
			_key(model, a, 8, E.EASE_OUT, Vector3(0, 0.02, -0.25), func(m):
				_rotate(m, &"neck", Vector3.RIGHT, -25.0)
				_rotate(m, &"jaw", Vector3.RIGHT, -35.0)
				for side in [&"front_leg_L", &"front_leg_R"]:
					var c: BodyPlan.Chain = m.find_chain(side)
					m.solve_chain(c, m.rest_global(m.bone_index(c.end)).origin + Vector3(0, 0.12, -0.2)), true)
			_key(model, a, 10, E.SMOOTH, Vector3(0, -0.03, -0.25), func(m):
				_rotate(m, &"neck", Vector3.RIGHT, -20.0))
			_key(model, a, 17, E.SMOOTH, Vector3.ZERO, func(_m): pass)
			a.windows = {"windup": Vector2i(0, 7), "active": Vector2i(8, 9), "opening": Vector2i(11, 17)}
		"guard":  # low, head down, braced
			a.length = 6
			_key(model, a, 0, E.EASE_OUT, Vector3.ZERO, func(_m): pass)
			_key(model, a, 3, E.SMOOTH, Vector3(0, -0.1, 0.05), func(m):
				_rotate(m, &"neck", Vector3.RIGHT, -25.0)
				_rotate(m, &"tail_1", Vector3.RIGHT, -20.0))
		"hurt":
			a.length = 8
			_key(model, a, 0, E.SNAP, Vector3.ZERO, func(_m): pass)
			_key(model, a, 2, E.SMOOTH, Vector3(0, 0.02, 0.1), func(m):
				_rotate(m, &"neck", Vector3.RIGHT, 30.0)
				_rotate(m, &"jaw", Vector3.RIGHT, -20.0))
			_key(model, a, 7, E.SMOOTH, Vector3.ZERO, func(_m): pass)
		"stagger":
			a.length = 16
			_key(model, a, 0, E.POP, Vector3.ZERO, func(_m): pass)
			_key(model, a, 3, E.SMOOTH, Vector3(0.05, 0.0, 0.15), func(m):
				_rotate(m, &"neck", Vector3.RIGHT, 35.0)
				_rotate(m, &"pelvis", Vector3.FORWARD, 8.0))
			_key(model, a, 9, E.SMOOTH, Vector3(-0.03, -0.05, 0.1), func(m):
				_rotate(m, &"neck", Vector3.UP, 25.0)
				_rotate(m, &"pelvis", Vector3.FORWARD, -6.0))
			_key(model, a, 15, E.SMOOTH, Vector3.ZERO, func(_m): pass)
		"recoil":
			a.length = 10
			_key(model, a, 0, E.SNAP, Vector3.ZERO, func(_m): pass)
			_key(model, a, 2, E.SMOOTH, Vector3(0, 0.0, 0.08), func(m):
				_rotate(m, &"neck", Vector3.RIGHT, 25.0)
				_rotate(m, &"head", Vector3.UP, 20.0))
			_key(model, a, 9, E.SMOOTH, Vector3.ZERO, func(_m): pass)
		"death":  # legs give way, rolls onto its side (16 frames, holds)
			a.length = 16
			_key(model, a, 0, E.EASE_IN, Vector3.ZERO, func(_m): pass)
			_key(model, a, 7, E.EASE_IN, Vector3(0, -0.3, 0), func(m):
				_rotate(m, &"neck", Vector3.RIGHT, -30.0))
			_key(model, a, 14, E.POP, Vector3(0.1, -0.42, 0), func(m):
				_rotate(m, &"pelvis", Vector3.FORWARD, 75.0)
				_rotate(m, &"neck", Vector3.RIGHT, -20.0), true)
			_key(model, a, 15, E.SMOOTH, Vector3(0.1, -0.43, 0), func(m):
				_rotate(m, &"pelvis", Vector3.FORWARD, 78.0)
				_rotate(m, &"neck", Vector3.RIGHT, -22.0), true)
