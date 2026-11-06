@tool
class_name Cutscene
extends Resource
## A scripted scene: cues on a timeline (camera shots, actor moves / animations, dialogue,
## events), played by the Cutscenes autoload. Authored in the Story workspace's Cutscenes
## tab against the zone it happens in; positions are in that zone's space.
## Facing angles are degrees of yaw, 0 = looking along -Z (like the actors).

enum Skip { NEVER, SEEN, ALWAYS }

## Names the "seen" flag (cutscene/<id>), set when it finishes or is skipped.
@export var id := &""
## Seconds; the cutscene ends here (dialogue held open stretches it).
@export_range(0.5, 600.0, 0.5, "or_greater") var length := 8.0
## Holding a button skips it: never, once it's been seen before (OoT), or always. A skip
## still applies every Story event, and puts actors where the cutscene leaves them.
@export var skip := Skip.SEEN
## Black bars top and bottom while it plays.
@export var letterbox := true
## The zone scene it's authored in (the editor preview opens it).
@export_file("*.tscn") var zone := ""
@export var cues: Array[CutsceneCue] = []

## Matching the player's walk / run speeds (preview and walking time limits).
const WALK_SPEED := 2.5
const RUN_SPEED := 6.0


func seen_flag() -> String:
	return "cutscene/%s" % (id if id != &"" else StringName(resource_path.get_file().get_basename()))


## The cues in time order.
func sorted() -> Array[CutsceneCue]:
	var out: Array[CutsceneCue] = []
	for c in cues:
		if c:
			out.append(c)
	out.sort_custom(func(a, b): return a.time < b.time)
	return out


## Timeline rows: camera, dialogue, events, then each actor (player first).
func track_ids() -> Array[StringName]:
	var out: Array[StringName] = [&"camera", &"dialogue", &"events"]
	var actors: Array[StringName] = []
	for c in sorted():
		if c.kind == CutsceneCue.Kind.ACTOR and not actors.has(c.actor):
			actors.append(c.actor)
	actors.sort_custom(func(a, b): return a == CutsceneCue.PLAYER and b != CutsceneCue.PLAYER)
	out.append_array(actors)
	return out


static func facing_vector(degrees: float) -> Vector3:
	var a := deg_to_rad(degrees)
	return Vector3(-sin(a), 0.0, -cos(a))


static func facing_degrees(v: Vector3) -> float:
	return rad_to_deg(atan2(-v.x, -v.z))


## Camera at `t`: {xf, fov}, or {} before the first shot. `actor_pos(id) -> Vector3` finds
## actors (for look_at), `zone_view(id) -> Camera3D` CameraZone views (may return null).
func camera_at(t: float, actor_pos: Callable, zone_view: Callable) -> Dictionary:
	var shots := sorted().filter(func(c): return c.kind == CutsceneCue.Kind.SHOT)
	var k := -1
	for i in shots.size():
		if shots[i].time <= t + 0.0001:
			k = i
	if k < 0:
		return {}
	var cur: CutsceneCue = shots[k]
	var target := _shot(cur, actor_pos, zone_view)
	if k > 0 and cur.move != CutsceneCue.Move.CUT and cur.duration > 0.0 and t < cur.time + cur.duration:
		var prev := _shot(shots[k - 1], actor_pos, zone_view)
		var f := clampf((t - cur.time) / cur.duration, 0.0, 1.0)
		if cur.move == CutsceneCue.Move.SMOOTH:
			f = smoothstep(0.0, 1.0, f)
		return {xf = prev.xf.interpolate_with(target.xf, f), fov = lerpf(prev.fov, target.fov, f)}
	return target


func _shot(c: CutsceneCue, actor_pos: Callable, zone_view: Callable) -> Dictionary:
	var xf := c.transform
	var fov := c.fov
	if c.camera_id > 0 and zone_view.is_valid():
		var v: Camera3D = zone_view.call(c.camera_id)
		if v:
			xf = v.global_transform
			fov = v.fov
	if c.look_at != &"" and actor_pos.is_valid():
		var p: Variant = actor_pos.call(c.look_at)
		if p is Vector3 and xf.origin.distance_to(p + Vector3.UP * 1.2) > 0.01:
			var dir: Vector3 = p + Vector3.UP * 1.2 - xf.origin
			xf.basis = Basis.looking_at(dir, Vector3.UP if absf(dir.normalized().y) < 0.999 else Vector3.FORWARD)
	return {xf = xf, fov = fov}


## Where an actor is at `t` (editor preview; the game moves them for real): {position,
## facing (degrees), visible, animation}, starting from `start` (same keys).
func actor_at(actor: StringName, t: float, start: Dictionary) -> Dictionary:
	var s := start.duplicate()
	for c in sorted():
		if c.time > t:
			break
		if c.kind != CutsceneCue.Kind.ACTOR or c.actor != actor:
			continue
		match c.action:
			CutsceneCue.Action.WALK, CutsceneCue.Action.RUN:
				var speed := RUN_SPEED if c.action == CutsceneCue.Action.RUN else WALK_SPEED
				var from: Vector3 = s.position
				var to := c.position
				var flat := Vector3(to.x - from.x, 0.0, to.z - from.z)
				var go := minf(flat.length(), speed * (t - c.time))
				if flat.length() > 0.001:
					s.position = from + flat.normalized() * go + Vector3.UP * (to.y - from.y) * (go / flat.length())
					s.facing = facing_degrees(flat)
				if go >= flat.length() - 0.001:
					s.position = to
					s.facing = c.facing
			CutsceneCue.Action.TELEPORT:
				s.position = c.position
				s.facing = c.facing
			CutsceneCue.Action.FACE:
				s.facing = c.facing
			CutsceneCue.Action.ANIMATE:
				s.animation = c.animation
			CutsceneCue.Action.SHOW:
				s.visible = true
			CutsceneCue.Action.HIDE:
				s.visible = false
	return s
