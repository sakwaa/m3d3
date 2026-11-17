class_name SwordSway
extends Node3D
## Follow-through for a held blade: the sword's visible parts hang from the grip on a spring,
## so the tip lags and wobbles as the hand moves (loose while carried or winding up), and
## snaps nearly straight while a swing is in its hit window (stiff), with a small different
## lean each swing so no two cuts look identical. Only the look moves: the sword's
## BladeTrigger stays on the true hand pose (hits, StrikeRig and reach are unchanged).
## Usage: SwordSway.install(sword, actor, swinging, active) - moves the sword's meshes under a
## new SwordSway pivot at the grip; give the pivot to SwordTrail so the trail follows the
## blade as drawn.

## Spring when loose (carried, winding up, recovering) and during the hit window:
## [frequency Hz, damping ratio].
const LOOSE := Vector2(6.0, 0.32)
const STRIKE := Vector2(16.0, 0.9)
## How far the tip may swing off the hand's line (degrees): carried / winding up, and in the
## hit window (a swing turns the blade so fast any spring would trail it far behind: there
## it is held almost rigid). The cap eases between the two (degrees a second).
const MAX_LEAN := 14.0
const STRIKE_LEAN := 2.5
const CAP_RATE := 160.0
## Per-swing variation: a lean (degrees) picked at random when a swing starts, settling out.
const SWING_VARIATION := 4.0
const SUBSTEP := 1.0 / 120.0

var actor: Actor
## True while a swing is under way (windup to recovery) / in its hit window.
var swinging: Callable
var active: Callable
## The tip, metres along the blade (+Y) from the grip.
var length := 0.6
var enabled := true

var _tip := Vector3.ZERO     # simulated tip (world)
var _vel := Vector3.ZERO
var _ready_sim := false
var _was_swinging := false
var _bias := Basis.IDENTITY  # this swing's lean
var _bias_k := 0.0
var _acc := 0.0
var _cap := MAX_LEAN


## Puts the sword's visible children (not its BladeTrigger) under a SwordSway at the grip.
static func install(sword: Node3D, p_actor: Actor, p_swinging := Callable(), p_active := Callable()) -> SwordSway:
	var s := SwordSway.new()
	s.name = "Sway"
	s.actor = p_actor
	s.swinging = p_swinging
	s.active = p_active
	for c in sword.get_children():
		if c is BladeTrigger or not (c is Node3D):
			continue
		sword.remove_child(c)
		s.add_child(c)
	sword.add_child(s)
	var trig := BladeTrigger.of(sword)
	if trig:
		s.length = maxf(trig.position.length(), 0.3)
	return s


func _process(delta: float) -> void:
	var sword := get_parent() as Node3D
	if sword == null:
		return
	var held := enabled and sword.get_parent() is BoneAttachment3D and String(sword.get_parent().name).contains("prop")
	if not held:
		# (sheathed: no sway, start fresh when drawn)
		basis = Basis.IDENTITY
		_ready_sim = false
		return
	if actor and actor.in_hitstop():
		return
	var xf := sword.global_transform
	var grip := xf.origin
	var axis := xf.basis.y.normalized()
	var sw: bool = swinging.call() if swinging.is_valid() else false
	var act: bool = active.call() if active.is_valid() else false
	if sw and not _was_swinging:
		# A new swing: its own small lean.
		_bias = Basis(Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)).normalized(), deg_to_rad(randf_range(0.4, 1.0) * SWING_VARIATION))
		_bias_k = 1.0
	_was_swinging = sw
	_bias_k = move_toward(_bias_k, 0.0, delta * (0.0 if sw else 2.0))
	var target_axis: Vector3 = (xf.basis * _bias.slerp(Basis.IDENTITY, 1.0 - _bias_k) * Vector3.UP).normalized() if _bias_k > 0.0 else axis
	var target := grip + target_axis * length
	if not _ready_sim:
		_tip = target
		_vel = Vector3.ZERO
		_ready_sim = true
	var spring := STRIKE if act else LOOSE
	_cap = move_toward(_cap, STRIKE_LEAN if act else MAX_LEAN, CAP_RATE * delta)
	var w := TAU * spring.x
	_acc += minf(delta, 0.1)
	while _acc >= SUBSTEP:
		_acc -= SUBSTEP
		var a := (target - _tip) * w * w - _vel * 2.0 * spring.y * w
		_vel += a * SUBSTEP
		_tip += _vel * SUBSTEP
		# (the blade doesn't stretch: back onto its length from the grip)
		var d := _tip - grip
		_tip = grip + (d.normalized() if d.length() > 1e-5 else axis) * length
	# Lean = the turn from the hand's line to the simulated blade, capped, in the sword's space.
	var sim := (_tip - grip).normalized()
	var ang := axis.angle_to(sim)
	if ang > deg_to_rad(_cap):
		sim = axis.slerp(sim, deg_to_rad(_cap) / ang).normalized()
		_tip = grip + sim * length
	var local := (xf.basis.inverse() * sim).normalized()
	if local.distance_to(Vector3.UP) < 1e-5:
		basis = Basis.IDENTITY
	else:
		basis = Basis(Quaternion(Vector3.UP, local)).scaled(Vector3.ONE)
