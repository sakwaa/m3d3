class_name TargetLock
extends Node3D
## Z-targeting for the player, after Majora's Mask (references/targeting/z_targeting_spec.md).
##
## Every frame it searches for the best Targetable (`hover`, shown by the arrow before Z is
## pressed: what Z will grab):
##   - in front of the player's body (not the camera): within 60°; while locked, the next
##     target is looked for within 90°, nearer straight ahead counting as closer (x0.6..1
##     on the squared distance);
##   - within its acquire range (3D, feet to feet), roughly on screen and in line of sight;
##   - two tiers: if any enemy / boss qualifies, NPCs and points of interest are not
##     considered; within the tier the nearest wins (ties: the one that appeared first).
## A lock lets go only when its target dies / is disabled, or the player passes its release
## range (not in the first 0.5 s) - not for walls, turning away or time.
##
## Buttons (MM's timer, in its 20 Hz frames): pressing locks the hover target; locked,
## pressing moves to the next one (`hover`). Hold mode: the lock lasts while Z is held and
## lingers 0.25 s after; pressing again within 0.2 s of letting go takes the next target
## (the old one is still left out). Switch mode: a press latches; pressing again with no
## other target lets go. Holding the stick back while locked pauses the search (no next
## target: in Switch mode the press lets go). Pressing with nothing to lock: Parallel - the
## facing holds (squared up to a wall in front) and the camera swings behind, until Z is
## let go.

signal locked(target: Targetable)
signal released(target: Targetable, forced: bool)

## Battle music (MM): the nearest hostile enemy (not a boss) within BATTLE_FAR, wherever it is
## (behind, through walls), sets it; the enemy layer is full within BATTLE_NEAR and fades out
## linearly to BATTLE_FAR. Nodes in BATTLE_GROUP get set_battle_level(0..1) when it changes.
const BATTLE_NEAR := 6.0  # 150 units
const BATTLE_FAR := 20.0  # 500 units
const BATTLE_GROUP := &"battle_music"

## MM frames per second (its timers count these).
const FPS := 20.0
## Unlocked search cone, and the next-target cone while locked (degrees off the facing).
const CONE := 60.0
const NEXT_CONE := 90.0
## Screen leeway (MM pixels on its 320x240 screen).
const LEEWAY := Vector2(20.0, 160.0)

## Switch mode instead of Hold (the player's option).
@export var switch_mode := false
## Targets must be roughly on screen (off for tests without a real view).
@export var check_screen := true

## The locked target (MM's focus actor), or null.
var target: Targetable
## The arrow's target: unlocked, what Z would lock; locked, the next target.
var hover: Targetable
## Parallel: no target, the facing holds (`parallel_facing`).
var parallel := false
var parallel_facing := Vector3.FORWARD
## The lock was lost (target gone / out of range) with Z still held: the camera stays
## behind and Parallel can't start until Z is let go.
var forced := false

## The enemy setting the battle music (null = none), and its level 0..1.
var bgm_enemy: Targetable
var battle_level := 0.0

var _timer := 0.0  # MM's zTargetActiveTimer, in its frames
var _latch := false  # Switch mode holding the lock
var _owner_actor: Actor


func _ready() -> void:
	_owner_actor = get_parent() as Actor


## The lock is on (the reticle shows): MM's timer >= 5. Below that it's on its way out.
func active() -> bool:
	return target != null and _timer >= 5.0


## The first 0.5 s of a lock: the release range doesn't apply yet.
func in_grace() -> bool:
	return _timer >= 6.0


## Locked onto something hostile (battle stance, battle camera).
func hostile() -> bool:
	return active() and target.is_hostile()


## One frame of Z-targeting: `pressed` / `held` the target button, `stick_back` the stick
## held back (see the class notes), `blocked` no targeting at all (cutscene, dead...).
func update(delta: float, pressed: bool, held: bool, stick_back: bool, blocked := false) -> void:
	var f := delta * FPS
	if blocked:
		_timer = 0.0
	elif held or _latch:
		_timer = 5.0 if _timer <= 5.0 else maxf(_timer - f, 5.0)
	elif parallel:
		_timer = 0.0
	elif _timer > 0.0:
		_timer = maxf(_timer - f, 0.0)
	if not held:
		forced = false
	if _timer > 0.0 and pressed and not blocked:
		_press()
	if _timer <= 0.0:
		if target:
			var t := target
			target = null
			released.emit(t, false)
		parallel = false
		_latch = false
	if target and (not valid(target) or (not in_grace() and _outside_leash(target))):
		var t := target
		release()
		forced = held
		released.emit(t, true)
	_search(stick_back and active())


func _press() -> void:
	var c := hover
	if c and not c.lock_disabled:
		lock(c)
	elif active():
		if switch_mode:
			var t := target
			release()
			released.emit(t, false)
	elif target == null and not parallel and not forced:
		_start_parallel()
	# (Hold mode, letting go then pressing with nothing else to take: the old lock stays.)


func lock(t: Targetable) -> void:
	target = t
	_timer = 15.0
	_latch = switch_mode
	parallel = false
	locked.emit(t)


func release() -> void:
	target = null
	_latch = false


func _start_parallel() -> void:
	parallel = true
	parallel_facing = _owner_actor.facing if _owner_actor else -global_basis.z
	# Against a wall, facing within 45° of it: square up to it first.
	if _owner_actor:
		var from := _owner_actor.global_position + Vector3.UP * 0.8
		var hit := _ray(from, from + parallel_facing * 0.7)
		if not hit.is_empty() and absf(hit.normal.y) < 0.5:
			var into := -Vector3(hit.normal.x, 0.0, hit.normal.z).normalized()
			if parallel_facing.dot(into) > cos(deg_to_rad(45.0)):
				parallel_facing = into


# --- Search -------------------------------------------------------------------------------

## Fills `hover`. While locked (active), the next target under the locked weighting; else
## the best target, leaving out a lock on its way out (tap-tap moves on).
func _search(paused: bool) -> void:
	hover = null
	if paused or _owner_actor == null:
		return  # (MM: no battle music search either)
	var weighted := active()
	var from := _owner_actor.global_position
	var eye := from + Vector3.UP * 1.4
	var face := _owner_actor.facing
	var cam := get_viewport().get_camera_3d()
	var best := [null, null, null]  # hostile tier, other tier, non-zero priority
	var best_d := [INF, INF, INF]
	var bgm: Targetable = null
	var bgm_d2 := BATTLE_FAR * BATTLE_FAR
	for node in get_tree().get_nodes_in_group(Targetable.GROUP):
		var t := node as Targetable
		if t == null or not valid(t):
			continue
		var to := t.origin() - from
		var d2 := to.length_squared()
		if t.kind == Targetable.Kind.ENEMY and t.hostile and d2 < bgm_d2:
			bgm = t
			bgm_d2 = d2
		if t == target:
			continue
		var flat := Vector3(to.x, 0.0, to.z)
		var ang := rad_to_deg(face.angle_to(flat)) if flat.length() > 0.01 else 0.0
		if weighted:
			if ang > NEXT_CONE or t.lock_disabled:
				continue
			d2 *= 1.0 - 0.8 * (NEXT_CONE - ang) / 180.0
		elif ang > CONE:
			continue
		var slot := 2 if t.priority != 0 else (0 if t.is_hostile_tier() else 1)
		var key := float(t.priority) if slot == 2 else d2
		if key > best_d[slot] or (key == best_d[slot] and best[slot] and t.order > best[slot].order):
			continue
		var r := t.acquire_range()
		if d2 >= r * r or (check_screen and not on_screen(cam, t.global_position)) or not _sees(eye, t):
			continue
		best[slot] = t
		best_d[slot] = key
	hover = best[0] if best[0] else (best[1] if best[1] else best[2])
	_set_battle(bgm, sqrt(bgm_d2))


func _set_battle(enemy: Targetable, d: float) -> void:
	bgm_enemy = enemy
	var level := 0.0
	if enemy:
		level = 1.0 - clampf(d - BATTLE_NEAR, 0.0, BATTLE_FAR - BATTLE_NEAR) / (BATTLE_FAR - BATTLE_NEAR)
	if absf(level - battle_level) > 0.001:
		battle_level = level
		get_tree().call_group(BATTLE_GROUP, &"set_battle_level", level)


func _outside_leash(t: Targetable) -> bool:
	var r := t.release_range()
	return _owner_actor and t.origin().distance_squared_to(_owner_actor.global_position) >= r * r


func valid(t: Targetable) -> bool:
	if not is_instance_valid(t) or not t.enabled or not t.is_visible_in_tree():
		return false
	var a := t.actor()
	return a == null or (a != _owner_actor and not a.is_dead())


## Within MM's screen leeway (a little past the sides, well past the top and bottom).
static func on_screen(cam: Camera3D, p: Vector3) -> bool:
	if cam == null:
		return true
	if cam.is_position_behind(p):
		return false
	var size := cam.get_viewport().get_visible_rect().size
	var s := cam.unproject_position(p)
	var lx := LEEWAY.x / 320.0 * size.x
	var ly := LEEWAY.y / 240.0 * size.y
	return s.x > -lx and s.x < size.x + lx and s.y > -ly and s.y < size.y + ly


## Nothing of the level between the eye and the target's focus (actors don't block).
func _sees(eye: Vector3, t: Targetable) -> bool:
	return _ray(eye, t.global_position).is_empty()


func _ray(a: Vector3, b: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(a, b)
	var exclude: Array[RID] = []
	for n in get_tree().get_nodes_in_group(&"actors"):
		if n is CollisionObject3D:
			exclude.append((n as CollisionObject3D).get_rid())
	q.exclude = exclude
	return get_world_3d().direct_space_state.intersect_ray(q)


## Whether `who` is what the player has locked on (enemies take turns by it).
static func is_locked_on(who: Node, tree: SceneTree) -> bool:
	var p := tree.get_first_node_in_group(&"player")
	if p == null or not "lock" in p or p.lock == null or not p.lock.active():
		return false
	var t: Targetable = p.lock.target
	return t.actor() == who or t.get_parent() == who
