extends Actor
## Third-person player (capsule placeholder). Left stick / WASD / arrows move (hold Shift
## to walk), right stick / mouse orbit the camera, Space jump, left mouse / J attack, right
## mouse / K guard, hold Q / L1 to Z-target (enemies, NPCs, points of interest), Esc frees
## the mouse. Walking or jumping into a Climbable wall climbs it (A / E lets go).
## Movement runs through state machines (Locomotion, Action) like every Actor; this only
## turns input into `intent`. Lives under the ZoneManager autoload so it persists across
## zones.

## Body size and camera pivot; the editor's reference character reads these too.
const BODY_RADIUS := 0.35
const BODY_HEIGHT := 1.6
const CAMERA_HEIGHT := 1.4
## Z-targeting: side-shuffle and back-step speeds (m/s).
const STRAFE_SPEED := 2.4
const BACKSTEP_SPEED := 1.9
## Z-targeting control: Switch (press to latch) instead of Hold.
const Z_SWITCH_SETTING := "game/controls/z_target_switch"
const WALK_SPEED := 2.5
const RUN_SPEED := 6.0
## Jump (OoT remake, measured at 60 fps: ~0.25 s up to ~1 m, ~0.33 s down, ~0.57 s in the air):
## strong gravity going up, less coming down.
const JUMP_VELOCITY := 8.0
const JUMP_GRAVITY := 3.25
const FALL_GRAVITY := 1.9
const MOUSE_SENSITIVITY := 0.004
## Right stick camera turn, radians per second at full tilt.
const STICK_TURN_SPEED := 3.0
const STICK_DEADZONE := 0.2
const MODEL := preload("res://characters/player_model.tscn")
const SWORD := preload("res://characters/props/practice_sword.tscn")  # generated stand-in (0.64 m)

## Z-targeting.
var lock: TargetLock
## Sword on the back (OoT): drawn to fight, put away a while after, always while climbing.
const SHEATHE_DELAY := 3.0
## The sheathed sword, in the chest bone's space: grip over the right shoulder, blade
## down across the back to the left hip.
const SWORD_BACK := Transform3D(Basis(Vector3.BACK, deg_to_rad(150.0)), Vector3(0.1, 0.22, 0.14))
var _model: Node3D
var _sword: Node3D
var _sheathed := false
var _combat_left := 0.0
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
	_model = model
	_sword = ActorSockets.attach(model, &"prop_R", SWORD.instantiate())
	add_child(SwordTrail.new(_sword, _swing_trail, self))
	_sheathe(true)
	var skeleton := model.find_children("*", "Skeleton3D", true, false)
	if not skeleton.is_empty():
		skeleton[0].add_child(ClimbRig.new(self))  # hands and feet on what's climbed
		skeleton[0].add_child(StrikeRig.new(self))  # swings bent onto the strike point aimed at
		skeleton[0].add_child(LandDip.new(self))  # the knees give on soft landings
	add_child(GrassWake.new(self))  # wading through grass carpets
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
	lock.switch_mode = ProjectSettings.get_setting(Z_SWITCH_SETTING, false)
	add_child(lock)

	var grip := Grip.new()
	grip.name = "Grip"
	add_child(grip)
	var hud := CanvasLayer.new()
	hud.name = "Hud"
	add_child(hud)
	hud.add_child(GripMeter.new(grip))
	var marks := TargetMarks.new(lock)
	marks.letterboxed = func() -> bool: return director.z_targeting()
	hud.add_child(marks)

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	footsteps = true
	fall_damage_height = 8.0  # about three storeys
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
	# Z-targeting (OoT remake / N64: references/anims/strafe): standing, the battle-ready
	# stance (shield up, sword low); moving round the target, a side-shuffle; backing off,
	# back-steps; forward, the usual walk / run at it.
	var stance := LocoGround.new()
	stance.name = "BattleIdle"
	stance.speed = 0.0
	var strafes: Array[LocoGround] = [stance]
	for spec in [["StrafeL", STRAFE_SPEED], ["StrafeR", STRAFE_SPEED], ["StrafeB", BACKSTEP_SPEED]]:
		var st := LocoGround.new()
		st.name = spec[0]
		st.speed = spec[1]
		strafes.append(st)
	for st in strafes:
		st.z_only = true
	for st: LocoGround in [idle, walk, run] + strafes:
		st.z_stance = &"BattleIdle"
		st.z_left = &"StrafeL"
		st.z_right = &"StrafeR"
		st.z_back = &"StrafeB"
		st.z_forward = &"Walk"
	var jump := LocoAir.new()
	jump.name = "Jump"
	jump.launch_velocity = JUMP_VELOCITY
	jump.gravity_scale = JUMP_GRAVITY
	jump.tags = PackedStringArray(["airborne"])
	var fall := LocoAir.new()
	fall.name = "Fall"
	fall.tags = PackedStringArray(["airborne"])
	fall.gravity_scale = FALL_GRAVITY
	for air in [jump, fall]:
		# Only falls that hurt land hard (Land: a stop); others run straight on.
		air.idle_state = &"Idle"
		air.walk_state = &"Walk"
		air.run_state = &"Run"
	var land := ActorState.new()
	land.name = "Land"
	land.length = 0.15
	land.exit_mode = ActorState.Exit.FINISH
	land.next_state = &"Idle"
	land.speed = 0.0
	# Climbing: walking or jumping into a Climbable wall grabs it; in the air also ledges
	# and Climbable ceilings. All of it uses grip (see Grip).
	var climb := LocoClimb.new()
	climb.name = "Climb"
	climb.grip_still = 0.4
	climb.grip_moving = 0.4
	var hang := LocoHang.new()
	hang.name = "Hang"
	hang.grip_still = 0.6
	hang.grip_moving = 0.35
	var ceiling := LocoCeiling.new()
	ceiling.name = "Ceiling"
	ceiling.grip_still = 0.7
	ceiling.grip_moving = 0.5
	var leap := LocoLeap.new()
	leap.name = "Leap"
	leap.grip_still = 0.5
	var pull_up := LocoPullUp.new()
	pull_up.name = "ClimbUp"
	pull_up.exit_mode = ActorState.Exit.FINISH
	pull_up.next_state = &"Idle"
	# Ladders: hand over hand on the rungs, free of grip.
	var ladder := LocoLadder.new()
	ladder.name = "Ladder"
	var climbing: Array[ClimbState] = [climb, hang, ceiling, leap, pull_up, ladder]
	# Limbs come from the ClimbRig; the body holds a neutral pose under them.
	for s in [climb, hang, ceiling, leap, ladder]:
		s.animation = &"Idle"
	for s in climbing:
		s.tags = PackedStringArray(["climbing"])
		s.restrict = {&"Action": PackedStringArray(["Ready"])}
	for s in [idle, walk, run, jump, fall] + strafes:
		s.climb_state = &"Climb"
	for s in [idle, walk, run, jump, fall, land] + strafes:
		loco.add_child(s)
	for s in climbing:
		loco.add_child(s)
	add_machine(loco)

	var action := StateMachine.new()
	action.name = "Action"
	# Sword attacks picked like MM's (references/combat/mm_sword_attacks_decomp.md): from the
	# stick at the press. Free: neutral / left / back the horizontal cut (right to left,
	# SlashH), right the other way (SlashH2), forward a vertical chop stepping in. Z-targeting:
	# neutral the vertical chop, forward a stab stepping in, sides as free. Air / jump while
	# locked: the jump slash. Pressing into the same cut again repeats it; the third in a row
	# is its finisher ("<name>Fin", once measured). SlashD (the OoT remake's diagonal) isn't
	# picked.
	var attacks: Dictionary[StringName, StringName] = {&"neutral": &"SlashH", &"forward": &"SlashV", &"left": &"SlashH",
		&"back": &"SlashH", &"right": &"SlashH2", &"lock": &"SlashV", &"lock_forward": &"Stab", &"lock_left": &"SlashH",
		&"lock_back": &"SlashH", &"lock_right": &"SlashH2", &"air": &"JumpSlash"}
	var ready_state := ActionState.new()
	ready_state.name = "Ready"
	ready_state.inputs = {&"attack": ActionState.PICK, &"jump_attack": &"JumpSlash"}
	ready_state.attacks = attacks
	ready_state.holds = {&"guard": &"Guard"}
	var swings: Array[AttackState] = [_attack("SlashH", 1, 2.0), _attack("SlashH2", 1, 2.0), _attack("SlashD", 1, 1.5),
		_attack("SlashV", 2, 0.0), _attack("Stab", 1, 0.0), _attack("JumpSlash", 2, 1.5)]
	swings[0].slash_axis = Vector3.RIGHT
	swings[1].slash_axis = Vector3.RIGHT
	swings[2].slash_axis = Vector3(1, 1, 0).normalized()
	swings[4].slash_axis = Vector3.BACK  # (the attacker's forward)
	# Finishers (the third press of a cut in a row): a bigger swing, the blade's reach 1.5x at
	# first (MM). Only the vertical one is measured so far.
	var fin_v := _attack("SlashVFin", 2, 3.0)
	fin_v.trigger_boost = 1.5
	swings.append(fin_v)
	for a in swings:
		a.attacks = attacks
		a.inputs = {&"attack": ActionState.PICK}
	# Jump slash (OoT): the leap holds the sword up for as long as it's airborne; the chop
	# and landing (JumpSlashLand, the hit) start as the ground comes up, whatever the height.
	var jump_slash: AttackState = swings[5]
	jump_slash.launch = Vector2(4.4, 5.8)  # a leap at the target (~0.6 s on flat ground)
	jump_slash.land_state = &"JumpSlashLand"
	jump_slash.exit_mode = ActorState.Exit.FINISH
	jump_slash.next_state = &""  # (leaves only by landing, or a hit reaction)
	jump_slash.windows = {}
	jump_slash.blocked_by_tags = PackedStringArray()  # also from the air
	jump_slash.restrict = {&"Locomotion": PackedStringArray(["Fall", "Land"])}  # (not Idle: its speed 0 would stop the leap)
	jump_slash.inputs = {}
	jump_slash.priority = 1  # takes over from the jump it may start in
	var jump_land := _attack("JumpSlashLand", 2, 1.5)
	jump_land.reach = 1.8
	jump_land.arc = 90.0
	jump_land.blocked_by_tags = PackedStringArray()
	jump_land.restrict = {&"Locomotion": PackedStringArray(["Fall", "Land"])}
	jump_land.inputs = {}
	jump_land.priority = 1
	swings.append(jump_land)
	# Shield: walk slowly behind it, slash out of it.
	var guard := GuardState.new()
	guard.name = "Guard"
	guard.restrict = {&"Locomotion": PackedStringArray(["Idle", "Walk", "BattleIdle", "StrafeL", "StrafeR", "StrafeB"])}  # (strafing behind the shield)
	guard.move_scale = 0.6
	guard.inputs = {&"attack": ActionState.PICK}
	guard.attacks = attacks
	guard.tags = PackedStringArray(["guarding"])
	guard.blocked_by_tags = PackedStringArray(["airborne"])
	action.add_child(ready_state)
	for a in swings:
		action.add_child(a)
	action.add_child(guard)
	Actor.add_reaction_states(action, &"Ready")
	add_machine(action)


## A sword swing (timings and windows come from its animation, these are fallbacks):
## roots the player, hits during "active", chains from "cancel", leaves an "opening".
func _attack(state_name: String, damage: int, knockback: float, lunge := 0.0) -> AttackState:
	var a := AttackState.new()
	a.name = state_name
	a.length = 0.6
	a.exit_mode = ActorState.Exit.WINDOW
	a.next_state = &"Ready"
	a.windows = {&"active": Vector2(0.3, 0.5), &"cancel": Vector2(0.6, 1.0), &"opening": Vector2(0.75, 1.0)}
	a.restrict = {&"Locomotion": PackedStringArray(["Idle"])}
	a.can_turn = false
	a.damage = damage
	a.knockback = 4.0 + knockback
	a.lunge = lunge
	a.tags = PackedStringArray(["attacking"])
	a.blocked_by_tags = PackedStringArray(["airborne"])
	return a


## The sword's BladeTrigger (made for a sword scene that has none: the top of the blade).
var _trigger: BladeTrigger


func _sword_trigger() -> BladeTrigger:
	if _trigger == null and _sword:
		_trigger = BladeTrigger.of(_sword)
		if _trigger == null:
			_trigger = BladeTrigger.new()
			_trigger.name = "Trigger"
			_trigger.position = Vector3(0, 0.48, 0)
			_sword.add_child(_trigger)
	return _trigger


func blade() -> Array:
	if _sword == null or _sheathed:
		return []
	var a := state_of(ACTION) as AttackState
	return _sword_trigger().segment(a.trigger_scale() if a else 1.0)


func blade_power() -> int:
	return _sword_trigger().power if _sword else 1


func blade_trigger_local() -> Vector3:
	return _sword.transform * _sword_trigger().position if _sword else super.blade_trigger_local()


## The sword leaves a smear from just before a swing's active window to just after it.
func _swing_trail() -> bool:
	var a := state_of(ACTION) as AttackState
	if a == null or not Combat.juice.trail or not a.windows.has(&"active"):
		return false
	var w: Vector2 = a.windows[&"active"]
	var p := a.progress()
	return p >= w.x - 0.08 and p <= w.y + 0.03


## Draws the sword while fighting (attacking, guarding, locked onto an enemy), sheathes it a moment
## after, and whenever climbing.
func _update_sword(delta: float) -> void:
	if has_tag(&"attacking") or has_tag(&"guarding") or lock.hostile():
		_combat_left = SHEATHE_DELAY
	else:
		_combat_left = maxf(_combat_left - delta, 0.0)
	_sheathe(_combat_left <= 0.0 or has_tag(&"climbing"))


func _sheathe(on_back: bool) -> void:
	if _sword == null or (on_back == _sheathed and _sword.is_inside_tree()):
		return
	_sheathed = on_back
	if on_back:
		ActorSockets.move(_model, _sword, &"chest", SWORD_BACK)
	else:
		ActorSockets.move(_model, _sword, &"prop_R")


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
	_add_action(&"target", [KEY_Q], [JOY_BUTTON_LEFT_SHOULDER])  # (not Shift: it clashes with screenshot keys)
	_add_action(&"walk", [[KEY_ALT, KEY_LOCATION_LEFT]], [])
	# Left stick moves (with WASD / arrows), right stick turns the camera.
	_add_axis_action(&"move_left", [KEY_A, KEY_LEFT], JOY_AXIS_LEFT_X, -1.0)
	_add_axis_action(&"move_right", [KEY_D, KEY_RIGHT], JOY_AXIS_LEFT_X, 1.0)
	_add_axis_action(&"move_forward", [KEY_W, KEY_UP], JOY_AXIS_LEFT_Y, -1.0)
	_add_axis_action(&"move_back", [KEY_S, KEY_DOWN], JOY_AXIS_LEFT_Y, 1.0)
	_add_axis_action(&"camera_left", [], JOY_AXIS_RIGHT_X, -1.0)
	_add_axis_action(&"camera_right", [], JOY_AXIS_RIGHT_X, 1.0)
	_add_axis_action(&"camera_up", [], JOY_AXIS_RIGHT_Y, -1.0)
	_add_axis_action(&"camera_down", [], JOY_AXIS_RIGHT_Y, 1.0)


static func _add_axis_action(action: StringName, keys: Array, axis: JoyAxis, sign: float) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action, STICK_DEADZONE)
	for k in keys:
		var e := InputEventKey.new()
		e.physical_keycode = k
		InputMap.action_add_event(action, e)
	var j := InputEventJoypadMotion.new()
	j.axis = axis
	j.axis_value = sign
	InputMap.action_add_event(action, j)


## `keys`: physical key codes, or [key, KEY_LOCATION_LEFT / RIGHT] for one side's key only.
static func _add_action(action: StringName, keys: Array, pads: Array, mouse := []) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	for k in keys:
		var e := InputEventKey.new()
		if k is Array:
			e.physical_keycode = k[0]
			e.location = k[1]
		else:
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
		if not _z_camera() and director.allows_turn():  # Z-targeting, the camera frames the target / holds behind
			_yaw.rotation.y -= event.relative.x * MOUSE_SENSITIVITY
		if director.allows_pitch():
			_pitch.rotation.x = clampf(_pitch.rotation.x - event.relative.y * MOUSE_SENSITIVITY, -1.2, 0.4)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()  # the click that grabs the mouse isn't an attack


## Input -> intent: camera-relative move (Left Alt = walk strength), button presses.
## Grass parts round the player (n64_bender0: position, radius).
func _process(delta: float) -> void:
	super(delta)
	var p := global_position
	RenderingServer.global_shader_parameter_set(&"n64_bender0", Vector4(p.x, p.y, p.z, 0.9))


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
	_update_sword(delta)
	_turn_camera(delta)
	# Left stick (analog strength) or WASD / arrow keys.
	var input := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back")
	var basis := director.input_basis(input != Vector2.ZERO)
	var dir := basis * Vector3(input.x, 0.0, input.y)
	dir.y = 0.0
	dir = dir.normalized() * minf(input.length(), 1.0)
	if Input.is_action_pressed(&"walk"):
		dir *= 0.5
	intent.move = dir
	intent.stick = Vector2(input.x, -input.y).limit_length(1.0)
	intent.view_right = Vector3(basis.x.x, 0.0, basis.x.z).normalized()
	_update_lock(delta, dir)
	# Climbing, the hands are busy: no attacks or shield (they'd queue up and go off the
	# moment the climb ends).
	var climbing := has_tag(&"climbing")
	if Input.is_action_just_pressed(&"jump"):
		# Locked on, on the ground: a jump slash at the target (OoT), not a plain jump.
		intent.press(&"jump_attack" if lock.active() and is_on_floor() and not climbing else &"jump")
	if Input.is_action_just_pressed(&"attack") and not climbing:
		intent.press(&"attack")
	intent.hold(&"guard", Input.is_action_pressed(&"guard") and not climbing)

	if global_position.y < -20.0:
		ZoneManager.respawn_player()


## Right stick orbits the camera like the mouse.
func _turn_camera(delta: float) -> void:
	var look := Input.get_vector(&"camera_left", &"camera_right", &"camera_up", &"camera_down")
	if look == Vector2.ZERO:
		return
	if not _z_camera() and director.allows_turn():
		_yaw.rotation.y -= look.x * STICK_TURN_SPEED * delta
	if director.allows_pitch():
		_pitch.rotation.x = clampf(_pitch.rotation.x - look.y * STICK_TURN_SPEED * 0.6 * delta, -1.2, 0.4)


## Z-targeting (TargetLock: MM's rules, Hold or Switch mode). Locked on, the player faces
## the target (left / right circle it); in Parallel (Z with nothing to lock) the facing
## holds. The CameraDirector frames it. No targeting while climbing.
func _update_lock(delta: float, move: Vector3) -> void:
	# Stick held back (most of the way, within 45° of straight back): no next target.
	var back := move.length() > 0.9 and move.normalized().dot(-facing) > cos(deg_to_rad(45.0))
	lock.update(delta, Input.is_action_just_pressed(&"target"), Input.is_action_pressed(&"target"), back,
		has_tag(&"climbing"))
	face_target = lock.target
	face_dir = lock.parallel_facing if lock.parallel else Vector3.ZERO
	# (The camera's Z framing is the CameraDirector's.)


## The camera is Z-targeting (locked, Parallel or a lock just lost with Z held): the stick
## and mouse don't turn it.
func _z_camera() -> bool:
	return lock.target != null or lock.parallel or lock.forced
