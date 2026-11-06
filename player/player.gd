extends Actor
## Third-person player (capsule placeholder). WASD / arrows move (hold Shift to walk),
## Space jump, left mouse / J attack, right mouse / K guard, hold Q / L1 to Z-target
## (enemies, NPCs, points of interest), mouse orbits the camera, Esc frees the mouse.
## Movement runs through state machines (Locomotion, Action) like every Actor; this only
## turns input into `intent`. Lives under the ZoneManager autoload so it persists across
## zones.

## Body size and camera pivot; the editor's reference character reads these too.
const BODY_RADIUS := 0.35
const BODY_HEIGHT := 1.6
const CAMERA_HEIGHT := 1.4
const WALK_SPEED := 2.5
const RUN_SPEED := 6.0
const JUMP_VELOCITY := 5.5
const MOUSE_SENSITIVITY := 0.004
const MODEL := preload("res://characters/player_model.tscn")
const SWORD := preload("res://characters/sword_beta1.tscn")

## Z-targeting.
var lock: TargetLock
## Seconds dead (respawn after RESPAWN_TIME).
var _dead_time := 0.0
const RESPAWN_TIME := 2.5

var _yaw: Node3D
var _pitch: Node3D
## Picks the shot (free orbit, CameraZones) for the real camera.
var director: CameraDirector


func _ready() -> void:
	add_to_group(&"player")
	_ensure_input_actions()
	floor_max_angle = deg_to_rad(50.0)
	floor_snap_length = 0.3

	var capsule := CapsuleShape3D.new()
	capsule.radius = BODY_RADIUS
	capsule.height = BODY_HEIGHT
	var shape := CollisionShape3D.new()
	shape.shape = capsule
	shape.position.y = BODY_HEIGHT * 0.5
	add_child(shape)

	# Model (built with the actor tools: skeleton, mesh, animations named after the
	# states below). Faces -Z like the actor; the body pivot turns it.
	body = Node3D.new()
	body.name = "Body"
	add_child(body)
	var model := MODEL.instantiate()
	body.add_child(model)
	ActorSockets.attach(model, &"prop_R", SWORD.instantiate())
	_build_machines()
	# Fake shadow: silhouette decals from the sun and nearest torch (no shadow maps).
	add_child(ProjectedShadow.new())  # darkness: the zone's shadow_strength

	_yaw = Node3D.new()
	_yaw.position.y = CAMERA_HEIGHT
	add_child(_yaw)
	_pitch = Node3D.new()
	_pitch.rotation.x = -0.35
	_yaw.add_child(_pitch)
	var arm := SpringArm3D.new()
	arm.spring_length = 5.0
	arm.add_excluded_object(get_rid())
	_pitch.add_child(arm)
	# The orbit rig's end; the real camera (top-level) follows it or a CameraZone's shot.
	var orbit := Camera3D.new()
	orbit.fov = 60.0
	arm.add_child(orbit)
	var camera := Camera3D.new()
	camera.name = "View"
	camera.fov = 60.0  # OoT / MM vertical FOV
	camera.top_level = true
	add_child(camera)
	camera.make_current()
	director = CameraDirector.new(self, _yaw, _pitch, arm, orbit, camera)
	add_child(director)

	lock = TargetLock.new()
	add_child(lock)

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	footsteps = true
	super._ready()


## Locomotion (idle / walk / run / jump / fall / land) and Action (ready / attacks).
## Placeholder timings until there are animations; give a state an `animation` and its
## length comes from the clip instead.
func _build_machines() -> void:
	var loco := StateMachine.new()
	loco.name = "Locomotion"
	var idle := LocoGround.new()
	idle.name = "Idle"
	idle.idle_state = &""
	idle.move_state = &"Walk"
	idle.speed = 0.0
	var walk := LocoGround.new()
	walk.name = "Walk"
	walk.faster = &"Run"
	walk.speed = WALK_SPEED
	walk.sync_phase = true
	var run := LocoGround.new()
	run.name = "Run"
	run.slower = &"Walk"
	run.speed = RUN_SPEED
	run.sync_phase = true
	var jump := LocoAir.new()
	jump.name = "Jump"
	jump.launch_velocity = JUMP_VELOCITY
	jump.tags = PackedStringArray(["airborne"])
	var fall := LocoAir.new()
	fall.name = "Fall"
	fall.tags = PackedStringArray(["airborne"])
	var land := ActorState.new()
	land.name = "Land"
	land.length = 0.15
	land.exit_mode = ActorState.Exit.FINISH
	land.next_state = &"Idle"
	land.speed = 0.0
	for s in [idle, walk, run, jump, fall, land]:
		loco.add_child(s)
	add_machine(loco)

	var action := StateMachine.new()
	action.name = "Action"
	var ready_state := ActionState.new()
	ready_state.name = "Ready"
	ready_state.inputs = {&"attack": &"Attack1"}
	ready_state.holds = {&"guard": &"Guard"}
	var a1 := _attack("Attack1", &"Attack2")
	var a2 := _attack("Attack2", &"Attack1")
	# Shield: walk slowly behind it, slash out of it.
	var guard := GuardState.new()
	guard.name = "Guard"
	guard.restrict = {&"Locomotion": PackedStringArray(["Idle", "Walk"])}
	guard.move_scale = 0.6
	guard.inputs = {&"attack": &"Attack1"}
	guard.tags = PackedStringArray(["guarding"])
	guard.blocked_by_tags = PackedStringArray(["airborne"])
	for s in [ready_state, a1, a2, guard]:
		action.add_child(s)
	Actor.add_reaction_states(action, &"Ready")
	add_machine(action)


## Placeholder sword swing: roots the player, hits during "active", can chain into
## `combo` from the "cancel" window, leaves an "opening" at the end.
func _attack(state_name: String, combo: StringName) -> AttackState:
	var a := AttackState.new()
	a.name = state_name
	a.length = 0.6
	a.exit_mode = ActorState.Exit.WINDOW
	a.next_state = &"Ready"
	a.windows = {&"active": Vector2(0.3, 0.5), &"cancel": Vector2(0.6, 1.0), &"opening": Vector2(0.75, 1.0)}
	a.restrict = {&"Locomotion": PackedStringArray(["Idle"])}
	a.can_turn = false
	a.inputs = {&"attack": combo}
	a.tags = PackedStringArray(["attacking"])
	a.blocked_by_tags = PackedStringArray(["airborne"])
	return a


## Enables/disables player control (doors and cutscenes move the player themselves).
func set_controlled(enabled: bool) -> void:
	velocity = Vector3.ZERO
	process_mode = Node.PROCESS_MODE_INHERIT if enabled else Node.PROCESS_MODE_DISABLED


## Turns the camera/heading to look along a world direction.
func face(direction: Vector3) -> void:
	_yaw.rotation.y = atan2(-direction.x, -direction.z)


## Default bindings when the project's input map doesn't define them.
static func _ensure_input_actions() -> void:
	_add_action(&"interact", [KEY_E], [JOY_BUTTON_A])
	_add_action(&"jump", [KEY_SPACE], [JOY_BUTTON_Y])
	_add_action(&"attack", [KEY_J], [JOY_BUTTON_X], [MOUSE_BUTTON_LEFT])
	_add_action(&"guard", [KEY_K], [JOY_BUTTON_RIGHT_SHOULDER], [MOUSE_BUTTON_RIGHT])
	_add_action(&"target", [KEY_Q], [JOY_BUTTON_LEFT_SHOULDER])


static func _add_action(action: StringName, keys: Array, pads: Array, mouse := []) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	for k in keys:
		var e := InputEventKey.new()
		e.physical_keycode = k
		InputMap.action_add_event(action, e)
	for b in pads:
		var e := InputEventJoypadButton.new()
		e.button_index = b
		InputMap.action_add_event(action, e)
	for b in mouse:
		var e := InputEventMouseButton.new()
		e.button_index = b
		InputMap.action_add_event(action, e)


## Moves the player to a spawn transform, facing its -Z.
func teleport(xf: Transform3D) -> void:
	global_position = xf.origin
	velocity = Vector3.ZERO
	set_safe_position(xf.origin)
	_yaw.rotation.y = xf.basis.get_euler().y


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if lock.target == null and director.allows_turn():  # locked on, the camera frames the target
			_yaw.rotation.y -= event.relative.x * MOUSE_SENSITIVITY
		if director.allows_pitch():
			_pitch.rotation.x = clampf(_pitch.rotation.x - event.relative.y * MOUSE_SENSITIVITY, -1.2, 0.4)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()  # the click that grabs the mouse isn't an attack


## Input -> intent: camera-relative move (Shift = walk strength), button presses.
func drive(delta: float) -> void:
	if scripted:
		return  # a cutscene sets intent
	if is_dead():
		_dead_time += delta
		intent.clear()
		if _dead_time > RESPAWN_TIME:
			_dead_time = 0.0
			lock.release()
			heal_full()
			ZoneManager.respawn_player()
		return
	_update_lock(delta)
	# WASD or arrow keys.
	var input := Vector2(
		float(_held(KEY_D, KEY_RIGHT)) - float(_held(KEY_A, KEY_LEFT)),
		float(_held(KEY_S, KEY_DOWN)) - float(_held(KEY_W, KEY_UP)))
	var dir := director.input_basis(input != Vector2.ZERO) * Vector3(input.x, 0.0, input.y)
	dir.y = 0.0
	dir = dir.normalized()
	if Input.is_physical_key_pressed(KEY_SHIFT):
		dir *= 0.5
	intent.move = dir
	for action in [&"jump", &"attack"]:
		if Input.is_action_just_pressed(action):
			intent.press(action)
	intent.hold(&"guard", Input.is_action_pressed(&"guard"))

	if global_position.y < -20.0:
		ZoneManager.respawn_player()


## Hold to lock (OoT hold mode): picks the best target in front of the camera; the
## camera swings behind the player to frame it and the player faces it (so left / right
## circle it). Pressing with nothing to lock just recentres the camera behind the player.
func _update_lock(delta: float) -> void:
	var held := Input.is_action_pressed(&"target")
	if held and Input.is_action_just_pressed(&"target"):
		var view := -_yaw.global_basis.z
		var t := lock.pick(global_position + Vector3.UP * CAMERA_HEIGHT, view)
		if t:
			lock.lock(t)
		else:
			_yaw.rotation.y = atan2(-facing.x, -facing.z)
	elif not held:
		lock.release()
	face_target = lock.target
	if lock.target:
		var to := lock.target.global_position - global_position
		var want := atan2(-to.x, -to.z)
		_yaw.rotation.y = lerp_angle(_yaw.rotation.y, want, clampf(8.0 * delta, 0.0, 1.0))


static func _held(a: Key, b: Key) -> bool:
	return Input.is_physical_key_pressed(a) or Input.is_physical_key_pressed(b)
