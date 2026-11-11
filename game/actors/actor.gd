class_name Actor
extends CharacterBody3D
## Character driven by StateMachines (its children): the player, NPCs, enemies. A driver
## (player input or AI) fills `intent` every physics frame; the machines' states react to
## it and decide movement (speed, rooting, turning); the actor then moves.
##
## Combat: health, team, hit reactions (the Action machine's Hurt / Stagger / Recoil /
## Death states, see add_reaction_states()) and the counter window after a block; hits
## themselves are worked out by Combat while an AttackState's "active" window is open.
##
## Ground: the Surface under the actor (floor_surface) sets footstep sounds and reacts to
## slippery, damage and void-out floors (respawn at the last safe spot).
##
## Debug: a label over each actor lists its machines' states, timers and open windows
## (F8 toggles); `debug_log` prints every state change.

signal damaged(amount: int, by: Actor)
signal died
## Sent back to the last safe ground after touching a void-out surface.
signal voided

## Machine that holds attacks, guarding and hit reactions.
const ACTION := &"Action"

## Labels over actors (debug builds; F8 in the DebugHud toggles).
static var show_debug := OS.is_debug_build()

@export var turn_speed := 12.0
## Print state changes to the console.
@export var debug_log := false
## Visual pivot turned to face the movement (the collision capsule doesn't turn).
@export var body: Node3D
## Actors on the same team don't hit each other (0 = player side).
@export var team := 0
@export var max_health := 8
## Body radius for attack reach.
@export var radius := 0.35
## Footstep sounds from the ground's Surface (Sfx "step_<sound>"), a stride apart.
@export var footsteps := false
## Metres between footsteps at walking speed (grows a little with speed).
@export var stride := 0.7
## Falls ending this far (m) below the highest point hurt (a heart, more every 4 m
## further); 0 = never.
@export var fall_damage_height := 0.0

var health := 8
## While set (and the states allow turning), face this instead of the movement (lock-on,
## enemies squaring off).
var face_target: Node3D
## Extra horizontal velocity that fades out (knockback, lunges).
var impulse := Vector3.ZERO
## Seconds left to punish a blocked attacker (set when this actor blocks).
var counter_left := 0.0

var intent := Intent.new()
var machines: Array[StateMachine] = []
## Horizontal facing (world, unit).
var facing := Vector3.FORWARD

## Surface (sound | flags) of the floor stood on, 0 in the air.
var floor_surface := 0
## A cutscene drives this actor: `intent` is set from outside (the actor's own driver
## leaves it alone).
var scripted := false
## A cutscene's animation clip playing instead of the states' ("" = none).
var cue_animation := &""
## Climbing stamina (a Grip child); null = unlimited.
var grip: Grip
## When the actor last let go of a wall or ledge (ClimbState: no grabbing straight back).
var let_go_time := -1000.0
## That let-go was the player's own (let go, drop, jump off): no catching anything they
## don't push towards on the way down.
var let_go_deliberate := false
## How far the last landing fell (m): states tell a hard landing from a soft one.
var last_drop := 0.0
var _dip_depth := 0.0
var _dip_t := 1.0  # seconds into the landing dip (LAND_DIP_TIME = done)

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _safe_position := Vector3.ZERO
var _has_safe := false
var _hazard_wait := 0.0
var _step_left := 0.0
var _was_on_floor := true
var _air_top := 0.0  # highest point since leaving the ground (fall damage)
var _lean := 0.0  # body lean (radians) and where it pivots, eased (_pose_body)
var _lean_pivot := 0.8
var _lean_shift := Vector3.ZERO
var _lean_roll := 0.0
var _anim: AnimationPlayer
var _label: Label3D


## What the driver wants this frame: a move direction (world, length 0..1 = analog
## strength) and button presses, which stay available briefly until a state takes them.
class Intent:
	var move := Vector3.ZERO
	## The raw stick (x right, y up), for screen-relative controls like climbing; zero
	## when the driver has no stick (AI): states fall back to `move`.
	var stick := Vector2.ZERO
	## The view's right (world, flat), which way the stick's x points on screen.
	var view_right := Vector3.RIGHT
	var _presses := {}  # action -> seconds left
	var _held := {}

	## Buttons held down (guard).
	func hold(action: StringName, down: bool) -> void:
		if down:
			_held[action] = true
		else:
			_held.erase(action)

	func held(action: StringName) -> bool:
		return _held.has(action)

	func clear() -> void:
		move = Vector3.ZERO
		stick = Vector2.ZERO
		_presses.clear()
		_held.clear()

	func press(action: StringName, keep := 0.15) -> void:
		_presses[action] = keep

	## True once per press (consumes it).
	func take(action: StringName) -> bool:
		return _presses.erase(action)

	func pressed(action: StringName) -> bool:
		return _presses.has(action)

	func tick(delta: float) -> void:
		for a in _presses.keys():
			_presses[a] -= delta
			if _presses[a] <= 0.0:
				_presses.erase(a)


func _ready() -> void:
	add_to_group(&"actors")
	health = max_health
	# Stand on no-camera level faces too (the camera arm skips that layer).
	collision_mask |= Surface.NO_CAMERA_LAYER
	_safe_position = global_position
	for child in get_children():
		if child is StateMachine and not machines.has(child):
			machines.append(child)
	var players := find_children("*", "AnimationPlayer", true, false)
	_anim = players[0] if not players.is_empty() else null
	for m in machines:
		m.state_changed.connect(func(_from, _to): play_state_animation())
		if m.current:
			_bind_animation(m.current)
	play_state_animation()
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.fixed_size = true
	_label.pixel_size = 0.0012
	_label.font_size = 22
	_label.outline_size = 6
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_label.position.y = 2.2
	add_child(_label, false, INTERNAL_MODE_BACK)


## Adds a machine built in code (scenes can just have StateMachine children).
func add_machine(machine: StateMachine) -> StateMachine:
	add_child(machine)
	machines.append(machine)
	return machine


func machine(machine_name: StringName) -> StateMachine:
	for m in machines:
		if m.name == machine_name:
			return m
	return null


## Current state of a machine, or null.
func state_of(machine_name: StringName) -> ActorState:
	var m := machine(machine_name)
	return m.current if m else null


## Any machine's current state carries `tag` ("guarding", "airborne"...).
func has_tag(tag: StringName) -> bool:
	return machines.any(func(m): return m.current and m.current.has_tag(tag))


## Any machine's current state has `window` open ("active", "opening"...).
func in_window(window: StringName) -> bool:
	return machines.any(func(m): return m.current and m.current.in_window(window))


## Override: fill `intent` (player input, AI).
func drive(_delta: float) -> void:
	pass


func _physics_process(delta: float) -> void:
	# During a cutscene, actors not in it hold still (no AI, no attacks), like OoT.
	# (Brains are machines too: frozen actors don't tick theirs at all.)
	var frozen := not scripted and Cutscenes.is_playing()
	if frozen:
		intent.clear()
	else:
		drive(delta)
		for m in machines:
			m.tick(delta)
		Combat.update_attacks(self)
	_move(delta)
	intent.tick(delta)
	_dip_t += delta
	counter_left = maxf(counter_left - delta, 0.0)
	_update_label()


# --- Combat -------------------------------------------------------------------------------

func is_dead() -> bool:
	return health <= 0


## The attack of this actor that is mid-swing (active window open), or null.
func active_attack() -> AttackState:
	var a := state_of(ACTION) as AttackState
	return a if a and a.in_window(&"active") else null


## Switches the Action machine to a reaction state (Hurt, Stagger, Recoil, Death) if it
## has one; reactions have high priority, so they cut anything.
func react(state: StringName) -> void:
	var m := machine(ACTION)
	if m and m.states.has(state):
		m.request(state)


func take_hit(damage: int, by: Actor, knockback: float) -> void:
	if is_dead():
		return
	health = maxi(health - damage, 0)
	var away := global_position - by.global_position
	away.y = 0.0
	impulse = away.normalized() * knockback if away.length() > 0.01 else Vector3.ZERO
	damaged.emit(damage, by)
	if is_dead():
		react(&"Death")
		died.emit()
	else:
		react(&"Hurt")


func heal_full() -> void:
	health = max_health
	var m := machine(ACTION)
	if m:
		m.request(m.initial_state if m.initial_state != &"" else m.get_child(0).name, true)


## Standard reaction states for an Action machine (placeholder timings). All leave an
## "opening" (free hits); Death holds until the actor is removed / respawned.
static func add_reaction_states(action: StateMachine, ready_state: StringName) -> void:
	for spec in [[&"Hurt", 0.4, 50], [&"Stagger", 0.8, 40], [&"Recoil", 0.5, 40], [&"Death", 0.0, 100]]:
		var r := ActorState.new()
		r.name = spec[0]
		r.length = spec[1]
		r.priority = spec[2]
		r.exit_mode = ActorState.Exit.FINISH
		r.can_turn = false
		r.restrict = {&"Locomotion": PackedStringArray(["Idle"])}
		r.windows = {&"opening": Vector2(0.0, 1.0)}
		if spec[0] == &"Death":
			r.exit_mode = ActorState.Exit.FINISH
			r.length = 0.0
			r.tags = PackedStringArray(["dead"])
			r.restrict = {&"Locomotion": PackedStringArray()}
			r.windows = {}
		else:
			r.next_state = ready_state
			r.tags = PackedStringArray(["reeling"])
		action.add_child(r)


func _move(delta: float) -> void:
	for m in machines:
		if m.current and m.current.move_actor(delta):
			_pose_body(delta, m.current.body_lean() if m.current.has_method(&"body_lean") else [0.0, _lean_pivot, Vector3.ZERO])
			floor_surface = 0
			_was_on_floor = false
			_air_top = global_position.y  # holding on: falls count from here
			return
	var speed := -1.0
	var scale := 1.0
	var turn := true
	var grav := 1.0
	for m in machines:
		var s := m.current
		if s == null:
			continue
		speed = maxf(speed, s.speed)
		scale *= s.move_scale
		turn = turn and s.can_turn
		grav *= s.gravity_scale
	if not is_on_floor():
		velocity.y -= _gravity * grav * delta
	# Direction from the input; the state sets the speed (analog strength only picks the
	# state), so movement always matches the state's animation.
	var dir := Vector3(intent.move.x, 0.0, intent.move.z).limit_length(1.0)
	if dir.length() > 0.1:
		dir = dir.normalized()
	if speed >= 0.0:
		var h := dir * speed * scale
		if floor_surface & Surface.SLIPPERY:
			# Ice: speed builds up and dies away slowly instead of following the stick.
			var v := Vector2(velocity.x, velocity.z).move_toward(Vector2(h.x, h.z), SLIP_ACCEL * delta)
			h = Vector3(v.x, 0.0, v.y)
		velocity.x = h.x
		velocity.z = h.z
	# speed < 0 everywhere (e.g. in the air): keep momentum.
	var look := dir
	if is_instance_valid(face_target):
		look = face_target.global_position - global_position
		look.y = 0.0
	if turn and look.length() > 0.1:
		var target := look.normalized()
		# Turned by heading angle (Vector3.slerp trips over near-opposite directions).
		if facing.dot(target) > -0.99:
			var yaw := lerp_angle(atan2(facing.x, facing.z), atan2(target.x, target.z), clampf(turn_speed * delta, 0.0, 1.0))
			facing = Vector3(sin(yaw), 0.0, cos(yaw))
		else:
			facing = target
	_pose_body(delta, [0.0, _lean_pivot, Vector3.ZERO])
	velocity.x += impulse.x
	velocity.z += impulse.z
	move_and_slide()
	velocity.x -= impulse.x
	velocity.z -= impulse.z
	impulse = impulse.move_toward(Vector3.ZERO, 14.0 * delta)
	_update_ground(delta)


## Turns the body to `facing` and eases it into a lean ([tilt, pivot height, shift, roll],
## see ClimbState.body_lean): climbing slanted walls lies the body along them, and the
## weight shifts side to side (roll: + lifts the right shoulder).
func _pose_body(delta: float, lean: Array) -> void:
	if body == null:
		return
	var k := clampf(10.0 * delta, 0.0, 1.0)
	_lean = lerpf(_lean, lean[0], k)
	_lean_shift = _lean_shift.lerp(lean[2], k)
	_lean_roll = lerpf(_lean_roll, lean[3] if lean.size() > 3 else 0.0, k)
	if absf(lean[0]) > 0.001:
		_lean_pivot = lean[1]
	var r := Basis.from_euler(Vector3(_lean, atan2(-facing.x, -facing.z), _lean_roll))
	body.basis = r
	var pivot := Vector3.UP * _lean_pivot
	body.position = pivot - r * pivot + _lean_shift


## How far the hips are dipping from a soft landing right now (m; LandDip applies it):
## quickly down, then eased back up.
func land_dip() -> float:
	if _dip_t >= LAND_DIP_TIME:
		return 0.0
	var down := 0.06
	if _dip_t < down:
		return _dip_depth * sin(_dip_t / down * PI * 0.5)
	return _dip_depth * (1.0 - smoothstep(down, LAND_DIP_TIME, _dip_t))


# --- Ground -------------------------------------------------------------------------------

const DUST_EFFECT := preload("res://game/effects/dust_puff.tres")
const SPLASH_EFFECT := preload("res://game/effects/water_splash.tres")
const RIPPLE_EFFECT := preload("res://game/effects/splash_ring.tres")

## Seconds a soft landing's dip lasts.
const LAND_DIP_TIME := 0.26
## m/s² of speed change on slippery floors.
const SLIP_ACCEL := 5.0
## Seconds between damage-floor hits (the hop carries the actor off meanwhile).
const HAZARD_INTERVAL := 1.0
const HAZARD_HOP := 5.0


func _update_ground(delta: float) -> void:
	_hazard_wait = maxf(_hazard_wait - delta, 0.0)
	var on_floor := is_on_floor()
	var found := false
	if on_floor:
		var up := get_floor_normal()
		var best := -1.0
		for i in get_slide_collision_count():
			var c := get_slide_collision(i)
			var d := c.get_normal().dot(up)
			if d > best:
				best = d
				floor_surface = Surface.of_collision(c)
				found = true
	if not on_floor:
		floor_surface = 0
		_air_top = maxf(_air_top, global_position.y)
	elif not _was_on_floor:
		_land_from(_air_top - global_position.y)
	if on_floor:
		_air_top = global_position.y
	# On the floor without a contact this frame (snapped): keep the last floor's surface.
	if on_floor and floor_surface & Surface.VOID:
		_void_out()
		return
	if on_floor and floor_surface & Surface.DAMAGE and _hazard_wait <= 0.0 and not is_dead():
		_hazard_wait = HAZARD_INTERVAL
		velocity.y = HAZARD_HOP
		hurt(1)
	elif found and floor_surface & Surface.HAZARDS == 0 and get_floor_normal().y > 0.85:
		_safe_position = global_position
		_has_safe = true
	if footsteps:
		_update_footsteps(on_floor, delta)
	_was_on_floor = on_floor


func _land_from(drop: float) -> void:
	last_drop = drop
	if drop > 0.15 and not (fall_damage_height > 0.0 and drop >= fall_damage_height):
		# A soft landing: the knees give a little (LandDip), more the further it fell.
		_dip_depth = clampf(0.025 + drop * 0.012, 0.025, 0.07)
		_dip_t = 0.0
	if fall_damage_height > 0.0 and drop > fall_damage_height:
		hurt(1 + int((drop - fall_damage_height) / 4.0))


## Dust kicked up on soft ground, ripples (a splash on landing) in water.
func _step_effect(landing: bool) -> void:
	match Surface.sound(floor_surface):
		Surface.Sound.DIRT, Surface.Sound.SAND, Surface.Sound.SNOW:
			Effects.spawn(DUST_EFFECT, global_position + Vector3.UP * 0.15)  # puffs centre on it
		Surface.Sound.WATER:
			Effects.spawn(SPLASH_EFFECT if landing else RIPPLE_EFFECT, global_position + Vector3.UP * 0.03)


## Where a void-out sends the actor until it next stands on safe ground (spawns, warps).
func set_safe_position(at: Vector3) -> void:
	_safe_position = at
	_has_safe = true


## Damage not from an attack (hazard floors, falls): reacts like a hit.
func hurt(amount: int) -> void:
	if is_dead():
		return
	health = maxi(health - amount, 0)
	damaged.emit(amount, null)
	if is_dead():
		react(&"Death")
		died.emit()
	else:
		react(&"Hurt")


## Back to the last safe ground (OoT fall-out), a heart of damage.
func _void_out() -> void:
	if Surface.sound(floor_surface) == Surface.Sound.WATER:
		Effects.spawn(SPLASH_EFFECT, global_position)
	if _has_safe:
		global_position = _safe_position
	velocity = Vector3.ZERO
	impulse = Vector3.ZERO
	voided.emit()
	hurt(1)


func _update_footsteps(on_floor: bool, delta: float) -> void:
	if not on_floor:
		_step_left = 0.0
		return
	if not _was_on_floor:
		Sfx.footstep(floor_surface, global_position, 1.3)  # landing
		_step_effect(true)
		_step_left = stride
		return
	var moved := Vector2(velocity.x, velocity.z).length() * delta
	if moved < 0.0005:
		_step_left = minf(_step_left, stride * 0.5)  # the first step comes soon after starting
		return
	_step_left -= moved
	if _step_left <= 0.0:
		Sfx.footstep(floor_surface, global_position)
		_step_effect(false)
		_step_left += stride * (1.0 + 0.08 * Vector2(velocity.x, velocity.z).length())


# --- Animation (optional AnimationPlayer anywhere under the actor) ----------------------

## The animation a state plays: its `animation`, or one named like the state.
func state_animation(state: ActorState) -> StringName:
	if state.animation != &"":
		return state.animation
	return StringName(state.name) if _anim and _anim.has_animation(StringName(state.name)) else &""


## Full-body layering: the last machine (Action after Locomotion) whose current state has
## an animation wins; when it has none (Ready), the earlier machine's shows again.
## Plays a model clip for a cutscene (over the states' animations); "" goes back to them.
## Returns false if the model has no such clip.
func play_cue_animation(anim: StringName) -> bool:
	cue_animation = anim
	if anim == &"" or _anim == null or not _anim.has_animation(anim):
		cue_animation = &""
		play_state_animation()
		return anim == &""
	_anim.play(anim, 0.15)
	return true


func cue_animation_playing() -> bool:
	return _anim != null and cue_animation != &"" and _anim.is_playing() and _anim.current_animation == cue_animation


func play_state_animation(_state: ActorState = null) -> void:
	if _anim == null or cue_animation != &"":
		return
	for i in range(machines.size() - 1, -1, -1):
		var s := machines[i].current
		if s == null:
			continue
		var anim := state_animation(s)
		if anim != &"" and _anim.has_animation(anim):
			if _anim.current_animation != anim or (not _anim.is_playing() and s.time < 0.05):
				_anim.play(anim, s.blend_time)
			return


func animation_length(anim: StringName) -> float:
	if _anim and anim != &"" and _anim.has_animation(anim):
		return _anim.get_animation(anim).length
	return 0.0


## Gives a state its animation's length and windows (states made before the
## AnimationPlayer existed).
func _bind_animation(s: ActorState) -> void:
	var anim := state_animation(s)
	var l := animation_length(anim)
	if l > 0.0:
		s.length = l
	var w := animation_windows(anim)
	if not w.is_empty():
		var typed: Dictionary[StringName, Vector2] = {}
		for k in w:
			typed[StringName(k)] = w[k]
		s.windows = typed


## Windows an animation carries (fractions of its length), e.g. from the actor tools.
func animation_windows(anim: StringName) -> Dictionary:
	if _anim and anim != &"" and _anim.has_animation(anim):
		return _anim.get_animation(anim).get_meta(&"n64_windows", {})
	return {}


func animation_loops(anim: StringName) -> bool:
	if _anim and anim != &"" and _anim.has_animation(anim):
		return _anim.get_animation(anim).loop_mode != Animation.LOOP_NONE
	return false


# --- Debug ------------------------------------------------------------------------------

func _update_label() -> void:
	_label.visible = show_debug
	if not show_debug:
		return
	var lines := PackedStringArray()
	lines.append("HP %d/%d%s" % [health, max_health, "  counter!" if counter_left > 0.0 else ""])
	for m in machines:
		var s := m.current
		if s == null:
			continue
		var t := "%s: %s" % [m.name, s.name]
		if s.length > 0.0 and not s.is_loop():
			t += " %.2f/%.2f" % [minf(s.time, s.length), s.length]
		else:
			t += " %.1fs" % s.time
		var open := PackedStringArray()
		for w in s.windows:
			if s.in_window(w):
				open.append(w)
		if not open.is_empty():
			t += " [%s]" % ", ".join(open)
		if not s.can_leave():
			t += " (locked)"
		if m.pending() != &"":
			t += " -> %s?" % m.pending()
		lines.append(t)
	_label.text = "\n".join(lines)
