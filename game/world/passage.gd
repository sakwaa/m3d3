@tool
class_name Passage
extends Node3D
## Ocarina of Time style passageway out of the zone: an open corridor that fades to
## black and loads another zone. Local -Z points out of the zone (the arrow):
##  - a floor brush in `level` runs from the threshold outward, kept in sync with
##    width / depth / this node's transform;
##  - a DarknessVolume fades everything in the corridor to black;
##  - a ZoneExit deep in the corridor travels to `target_zone` / `target_spawn`;
##  - other zones arrive here via `spawn_id`, just inside the threshold, facing in.
## Walls and ceiling around the corridor are up to you; the fade covers them within
## `fade_margin` of the opening.

@export_group("Waypoint")
@export_file("*.tscn") var target_zone := "":
	set(value):
		target_zone = value
		notify_property_list_changed()  # (target_spawn's choices)
		_queue_rebuild()
@export var target_spawn: StringName = &"default":
	set(value):
		target_spawn = value
		_queue_rebuild()
## Id other zones use (ZoneExit/Passage target_spawn) to arrive through this passage.
@export var spawn_id: StringName = &"passage"
## Room the arrival spawn is in; defaults to the Room this node is under.
@export var room: Room
## How far inside the threshold the player appears.
@export var arrival_offset := 1.5
## Seconds the player walks in on arriving (while the screen fades in).
const ARRIVAL_WALK := 0.45

@export_group("Shape")
@export var width := 1.2:
	set(value):
		width = maxf(value, 0.1)
		_queue_rebuild()
@export var height := 2.4:
	set(value):
		height = maxf(value, 0.1)
		_queue_rebuild()
@export var depth := 5.0:
	set(value):
		depth = maxf(value, 0.1)
		_queue_rebuild()
## Top of the opening (the fade around it follows): flat, round arch or pointed arch.
@export var top := OpeningShape.Top.FLAT:
	set(value):
		top = value
		_queue_rebuild()
@export_range(0.0, 5.0, 0.05, "or_greater", "suffix:m") var arch_rise := 0.0:
	set(value):
		arch_rise = maxf(value, 0.0)
		_queue_rebuild()
## Depth fraction after which entering the corridor triggers travel.
@export_range(0.0, 0.95) var trigger_start := 0.6:
	set(value):
		trigger_start = value
		_queue_rebuild()

@export_group("Fade")
@export var fade_enabled := true:
	set(value):
		fade_enabled = value
		_queue_rebuild()
## Metres in front of the opening where the darkening begins (eases in very gently).
@export var fade_lead := 1.5:
	set(value):
		fade_lead = maxf(value, 0.0)
		_queue_rebuild()
## Fade start / end as fractions of the corridor depth (0 = the opening).
@export_range(0.0, 1.0) var fade_start := 0.0:
	set(value):
		fade_start = value
		_queue_rebuild()
@export_range(0.0, 1.0) var fade_end := 0.9:
	set(value):
		fade_end = value
		_queue_rebuild()
## Extra size around the corridor (past the threshold) so walls and ceilings you add are
## darkened too; the room's wall around the doorway stays lit.
@export var fade_margin := 0.6:
	set(value):
		fade_margin = maxf(value, 0.0)
		_queue_rebuild()

@export_group("Dressing")
## Casing / trim around the opening on the room side (an OpeningDressing, shareable with
## doors). Empty = none.
@export var dressing: OpeningDressing:
	set(value):
		if dressing and dressing.changed.is_connected(_queue_rebuild):
			dressing.changed.disconnect(_queue_rebuild)
		dressing = value
		if dressing:
			dressing.changed.connect(_queue_rebuild)
		_queue_rebuild()

@export_group("Floor")
## LevelRoot holding the floor brush. Typed as Node3D: level tooling isn't shipped, and in
## exported builds this is the plain node the level was baked into.
@export var level: Node3D
## Tag of the floor brush in `level` (set by the Passage tool).
@export var floor_tag: StringName

var _exit: ZoneExit
var _fade: DarknessVolume
var _arrow: MeshInstance3D
var _dressing: MeshInstance3D
var _dressing_shape: CollisionShape3D
## Baked AO per dressing vertex (editor Bake AO) and the trim shape it was baked for.
@export_storage var dressing_ao := PackedFloat32Array()
@export_storage var dressing_ao_key := 0
var _rebuild_queued := false


func _ready() -> void:
	set_notify_transform(true)
	_rebuild()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		_sync_floor()


## Arriving through this passage (ZoneManager, as the screen fades in): a few steps in
## from the corridor, Majora's Mask style, before control comes back.
func play_arrival(player: Node3D) -> void:
	if not player is Actor:
		return
	var a := player as Actor
	a.scripted = true
	a.intent.clear()
	a.intent.move = -get_spawn_transform().basis.z * 0.5
	await get_tree().create_timer(ARRIVAL_WALK).timeout
	if is_instance_valid(a):
		a.intent.clear()
		a.scripted = false


func get_spawn_transform() -> Transform3D:
	return global_transform * Transform3D(Basis(Vector3.UP, PI), Vector3(0, 0, arrival_offset))


func get_room() -> Room:
	if room:
		return room
	var n := get_parent()
	while n and not n is Room:
		n = n.get_parent()
	return n as Room


func _queue_rebuild() -> void:
	if is_inside_tree() and not _rebuild_queued:
		_rebuild_queued = true
		_rebuild.call_deferred()


func _rebuild() -> void:
	_rebuild_queued = false
	if _exit == null:
		_exit = ZoneExit.new()
		add_child(_exit, false, INTERNAL_MODE_BACK)
	var exit_depth := depth * (1.0 - trigger_start)
	_exit.target_zone = target_zone
	_exit.target_spawn = target_spawn
	_exit.size = Vector3(width, height, exit_depth)
	_exit.position = Vector3(0, 0, -depth + exit_depth * 0.5)

	if _fade == null:
		_fade = DarknessVolume.new()
		add_child(_fade, false, INTERNAL_MODE_BACK)
	_fade.visible = fade_enabled
	_fade.box_min = Vector3(-width * 0.5 - fade_margin, -fade_margin, -depth)
	_fade.box_max = Vector3(width * 0.5 + fade_margin, height + fade_margin, fade_lead)
	_fade.opening = Vector4(-width * 0.5, width * 0.5, -fade_margin, height)
	_fade.opening_arch = arch_params(width, height, top, arch_rise)
	# The box includes the lead-in; the gradient starts at its front edge when fade_start is 0.
	var span := fade_lead + depth
	_fade.fade_start = 0.0 if fade_start <= 0.0 else (fade_lead + fade_start * depth) / span
	_fade.fade_end = (fade_lead + fade_end * depth) / span

	if _dressing == null:
		_dressing = MeshInstance3D.new()
		add_child(_dressing, false, INTERNAL_MODE_BACK)
		var body := StaticBody3D.new()
		_dressing_shape = CollisionShape3D.new()
		body.add_child(_dressing_shape)
		_dressing.add_child(body)
	if dressing:
		# The passage origin is on the wall face; +Z is the room side.
		var ao := dressing_ao if dressing_ao_key == dressing_shape_key() else PackedFloat32Array()
		OpeningDressing.apply(dressing, _dressing, _dressing_shape, width, height, [[0.0, 1.0]], ao)
	else:
		_dressing.mesh = null
		_dressing_shape.shape = null

	if Engine.is_editor_hint() and _arrow == null:
		_arrow = WorldPreview.arrow(Color(0.35, 1.0, 0.45), -1, Vector3(0, 0.05, 0))
		add_child(_arrow, false, INTERNAL_MODE_BACK)
	_sync_floor()


## Keeps the floor brush matching this passage (editor only; LevelRoot does the work).
func _sync_floor() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree() or level == null or not level.is_inside_tree():
		return
	if level.has_method(&"sync_floor_brush"):
		var xf := global_transform * Transform3D(Basis(), Vector3(0, 0, -depth * 0.5))
		level.call(&"sync_floor_brush", floor_tag, xf, Vector3(width, 0, depth))


## Shape fingerprint of the current dressing (for keeping baked AO in sync).
func dressing_shape_key() -> int:
	return dressing.shape_key(width, height, [[0.0, 1.0]]) if dressing else 0


func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if target_zone.is_empty():
		out.append("Set target_zone (Waypoint).")
	if level and floor_tag != &"" and level.has_method(&"has_tagged_brush") \
			and not level.call(&"has_tagged_brush", floor_tag):
		out.append("Floor brush '%s' not found in %s." % [floor_tag, level.name])
	return out


## DarknessVolume.opening_arch for an opening's shape.
static func arch_params(w: float, h: float, top_kind: int, rise_setting: float) -> Vector4:
	if top_kind == OpeningShape.Top.FLAT:
		return Vector4.ZERO
	var rise := OpeningShape.rise_of(w, h, top_kind, rise_setting)
	var spring := h - rise
	if top_kind == OpeningShape.Top.ROUND:
		return Vector4(1, spring, w * 0.5, rise)
	var c := (rise * rise - w * w * 0.25) / w
	return Vector4(2, spring, c, c + w * 0.5)


func _validate_property(property: Dictionary) -> void:
	ZoneArrivals.hint(property, target_zone)
