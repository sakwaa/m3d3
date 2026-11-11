@tool
class_name Door
extends Node3D
## Ocarina of Time style door. Stand near it and press `interact` (E / gamepad A): the
## player stops, the door opens, the player walks through and it closes behind them.
##  - ROOM: joins two Rooms of this zone (room_a on local -Z, room_b on +Z, the arrow).
##    The room behind stays unloaded until the door opens; the one left behind
##    unloads once it closes.
##  - ZONE: leads to another zone (house doors). It is also an arrival spawn: players
##    arriving with `spawn_id` step out of it and it closes behind them.
## Keep Doors outside Rooms (directly under the Zone) so they never unload.

signal opened
signal closed

enum Mode { ROOM, ZONE }
enum Style { SWING, SLIDE }
enum Lock { NONE, FLAG, SMALL_KEY }

const OPEN_TIME := 0.35
const WALK_TIME := 0.8
const SWING_ANGLE := 1.75  # ~100°

@export var mode := Mode.ROOM:
	set(value):
		mode = value
		notify_property_list_changed()
		_queue_rebuild()
@export var style := Style.SWING:
	set(value):
		style = value
		_queue_rebuild()

@export_group("Rooms")
## Room on the local -Z side (behind the arrow).
@export var room_a: Room
## Room on the local +Z side (the arrow points into it).
@export var room_b: Room

@export_group("Zone")
@export_file("*.tscn") var target_zone := "":
	set(v):
		target_zone = v
		notify_property_list_changed()  # (target_spawn's choices)
@export var target_spawn: StringName = &"default"
## Id other zones use to arrive through this door.
@export var spawn_id: StringName = &"door"
## Room arrivals start in (defaults to the Room this node is under).
@export var arrival_room: Room
## Darken what's behind the door while it is open (OoT's black doorway).
@export var dark_behind := true

@export_group("Lock")
@export var lock := Lock.NONE
## Lock.FLAG: GameState flag that must be truthy for the door to open.
@export var lock_flag := ""
## Identifies the door in save data (small-key unlocks). Defaults to the node name.
@export var door_id: StringName

@export_group("Shape")
@export var width := 1.2:
	set(value):
		width = maxf(value, 0.2)
		_queue_rebuild()
@export var height := 2.4:
	set(value):
		height = maxf(value, 0.2)
		_queue_rebuild()
## Top of the doorway (and panel): flat, round arch or pointed arch.
@export var top := OpeningShape.Top.FLAT:
	set(value):
		top = value
		_queue_rebuild()
## How much of the height the arch takes (0 = half the width round, equilateral pointed).
@export_range(0.0, 5.0, 0.05, "or_greater", "suffix:m") var arch_rise := 0.0:
	set(value):
		arch_rise = maxf(value, 0.0)
		_queue_rebuild()
@export var thickness := 0.15:
	set(value):
		thickness = maxf(value, 0.02)
		_queue_rebuild()
## Distance from the door at which the player can use it (both sides).
@export var interact_range := 1.5:
	set(value):
		interact_range = maxf(value, 0.3)
		_queue_rebuild()
## How far past the door the player ends up.
@export var arrival_offset := 1.2
## Panel surface: an N64 texture tiled over both faces at the project texel density (like
## level walls). Empty: panel_material, else a wood (swing) or iron (slide) colour.
@export var panel_surface: Texture2D:
	set(value):
		panel_surface = value
		_queue_rebuild()
## Older doors' panel material (shown in the inspector only while one is set).
@export var panel_material: Material:
	set(value):
		panel_material = value
		notify_property_list_changed()
		_queue_rebuild()
## Picture of the whole door, stretched over the panel (wins over panel_material). Its
## left edge goes on the hinge side, on both faces; import door photos with the N64
## texture importer's Door object mode to crop and turn them that way.
@export var panel_texture: Texture2D:
	set(value):
		panel_texture = value
		_queue_rebuild()
## Wall thickness and its centre along local Z (set by the Door tool), so the dressing
## sits on the wall faces: front face at centre + depth / 2 (+Z side), back at - depth / 2.
@export var wall_depth := 0.25:
	set(value):
		wall_depth = maxf(value, 0.0)
		_queue_rebuild()
@export var wall_center_z := 0.0:
	set(value):
		wall_center_z = value
		_queue_rebuild()

@export_group("Dressing")
## Casing / trim around the opening (an OpeningDressing: texture, butt or mitre joints,
## sizes, depths). Shareable between doors and passages; empty = none.
@export var dressing: OpeningDressing:
	set(value):
		if dressing and dressing.changed.is_connected(_queue_rebuild):
			dressing.changed.disconnect(_queue_rebuild)
		dressing = value
		if dressing:
			dressing.changed.connect(_queue_rebuild)
		_queue_rebuild()

var _pivot: Node3D
var _panel: MeshInstance3D
var _collider: CollisionShape3D
var _area: Area3D
var _area_shape: CollisionShape3D
var _label: Label3D
var _dark: DarknessVolume
var _arrow: MeshInstance3D
var _dressing: MeshInstance3D
var _dressing_shape: CollisionShape3D
## Baked AO per dressing vertex (editor Bake AO) and the trim shape it was baked for.
@export_storage var dressing_ao := PackedFloat32Array()
@export_storage var dressing_ao_key := 0
## Level brushes built with this door by the editor's recess tool (tag prefix) and the
## shape of the ones you may grow into a room ({tag: vertices hash}), so removing the door
## only deletes those while still untouched.
@export_storage var recess_tag: StringName
@export_storage var recess_hashes := {}
## Size of the opening cut for it (the level tools cut it again when width / height change).
@export_storage var cut_size := Vector2.ZERO
var _player: Node3D
var _busy := false
var _rebuild_queued := false


func _validate_property(property: Dictionary) -> void:
	var room_only := [&"room_a", &"room_b"]
	var zone_only := [&"target_zone", &"target_spawn", &"spawn_id", &"arrival_room", &"dark_behind"]
	if (mode == Mode.ZONE and property.name in room_only) or (mode == Mode.ROOM and property.name in zone_only):
		property.usage = PROPERTY_USAGE_STORAGE
	elif property.name == &"panel_material" and panel_material == null:
		property.usage = PROPERTY_USAGE_STORAGE
	ZoneArrivals.hint(property, target_zone)


func _ready() -> void:
	if door_id == &"":
		door_id = StringName(name.to_snake_case())
	_rebuild()


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or _player == null or _busy:
		return
	if event.is_action_pressed(&"interact"):
		get_viewport().set_input_as_handled()
		interact()


# --- Spawn interface (ZONE mode) ----------------------------------------------------

func get_spawn_transform() -> Transform3D:
	return global_transform * Transform3D(Basis(Vector3.UP, PI), Vector3(0, 0, arrival_offset))


func get_room() -> Room:
	if arrival_room:
		return arrival_room
	if room_b:
		return room_b
	var n := get_parent()
	while n and not n is Room:
		n = n.get_parent()
	return n as Room


## Called by ZoneManager after placing a player who arrived through this door.
func play_arrival(player: Node3D) -> void:
	_busy = true
	_update_label()
	player.set_controlled(false)
	player.global_position = to_global(Vector3(0, 0, -0.3))
	player.face(global_basis.z)
	_dark.visible = dark_behind
	_set_open(-1.0)
	await _tween_player(player, to_global(Vector3(0, 0, arrival_offset)), WALK_TIME)
	await _animate_door(0.0)
	_dark.visible = false
	player.set_controlled(true)
	_busy = false
	_update_label()


# --- Use ----------------------------------------------------------------------------

func interact() -> void:
	if _busy or _player == null:
		return
	if not _try_unlock():
		_flash("Locked")
		return
	var player := _player
	var side := 1.0 if to_local(player.global_position).z >= 0.0 else -1.0
	_busy = true
	_update_label()
	player.set_controlled(false)

	var zone := _zone()
	var from_room: Room = room_b if side > 0.0 else room_a
	var to_room: Room = room_a if side > 0.0 else room_b
	# A zone door with no target set works as a plain walk-through door. One whose target
	# doesn't exist yet (a house's interior still to build) travels anyway: ZoneManager
	# sends the player to the nowhere room.
	var travels := mode == Mode.ZONE and not target_zone.is_empty()
	if mode == Mode.ZONE and not travels:
		push_warning("Door '%s': no target zone set (%s); walking through instead." % [name, target_zone if target_zone else "empty"])
	if mode == Mode.ROOM and zone:
		if from_room:
			zone.hold_room(from_room)
		if to_room:
			zone.hold_room(to_room)

	if travels:
		# Load the other side while the door opens and the player walks through.
		get_node(^"/root/ZoneManager").preload_zone(target_zone)
	player.face(global_basis * Vector3(0, 0, -side))
	await _tween_player(player, to_global(Vector3(0, 0, side * 0.9)), 0.2)
	if travels:
		_dark.visible = dark_behind
	await _animate_door(side)
	opened.emit()

	if travels:
		await _tween_player(player, to_global(Vector3(0, 0, -side * 0.6)), WALK_TIME * 0.6)
		get_node(^"/root/ZoneManager").travel(target_zone, target_spawn)
		return

	await _tween_player(player, to_global(Vector3(0, 0, -side * arrival_offset)), WALK_TIME)
	await _animate_door(0.0)
	closed.emit()
	if zone and mode == Mode.ROOM:
		if to_room:
			zone.set_current_room(to_room)
		if from_room:
			zone.release_room(from_room)
		if to_room:
			zone.release_room(to_room)
	player.set_controlled(true)
	_busy = false
	_update_label()


func is_locked() -> bool:
	match lock:
		Lock.FLAG:
			return not _game_state().get_flag(lock_flag)
		Lock.SMALL_KEY:
			return not _game_state().get_flag(_unlock_flag())
	return false


## Opens the lock if possible (consuming a small key). False when it stays locked.
func _try_unlock() -> bool:
	if not is_locked():
		return true
	if lock != Lock.SMALL_KEY:
		return false
	var gs := _game_state()
	var keys_flag := _keys_flag()
	var keys := int(gs.get_flag(keys_flag, 0))
	if keys <= 0:
		return false
	gs.set_flag(keys_flag, keys - 1)
	gs.set_flag(_unlock_flag(), true)
	return true


func _keys_flag() -> String:
	var zone := _zone()
	return zone.flag("small_keys") if zone else "small_keys"


func _unlock_flag() -> String:
	var zone := _zone()
	var id := "door_%s_unlocked" % door_id
	return zone.flag(id) if zone else id


func _zone() -> Zone:
	var n := get_parent()
	while n and not n is Zone:
		n = n.get_parent()
	return n as Zone


func _game_state() -> Node:
	return get_node(^"/root/GameState")


# --- Animation ----------------------------------------------------------------------

## side: +1 opens away from a player on +Z, -1 away from one on -Z, 0 closes.
func _animate_door(side: float) -> void:
	_collider.disabled = side != 0.0
	var tween := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if style == Style.SWING:
		tween.tween_property(_pivot, ^"rotation:y", SWING_ANGLE * side, OPEN_TIME)
	else:
		tween.tween_property(_pivot, ^"scale:y", 1.0 - 0.97 * absf(side), OPEN_TIME)
	await tween.finished
	_collider.disabled = false if side == 0.0 else true


func _set_open(side: float) -> void:
	_collider.disabled = side != 0.0
	if style == Style.SWING:
		_pivot.rotation.y = SWING_ANGLE * side
	else:
		_pivot.scale.y = 1.0 - 0.97 * absf(side)


func _tween_player(player: Node3D, target: Vector3, duration: float) -> void:
	var tween := create_tween()
	tween.tween_property(player, ^"global_position", target, duration)
	await tween.finished


# --- Prompt -------------------------------------------------------------------------

func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group(&"player"):
		_player = body
		_update_label()


func _on_body_exited(body: Node3D) -> void:
	if body == _player:
		_player = null
		_update_label()


func _update_label() -> void:
	if _label == null or Engine.is_editor_hint():
		return
	_label.visible = _player != null and not _busy
	if is_locked():
		var can_unlock := lock == Lock.SMALL_KEY and int(_game_state().get_flag(_keys_flag(), 0)) > 0
		_label.text = "Unlock (key)" if can_unlock else "Locked"
	else:
		_label.text = "Open"


func _flash(text: String) -> void:
	_label.text = text
	_label.modulate = Color(1, 0.5, 0.4)
	await get_tree().create_timer(0.6).timeout
	if is_instance_valid(_label):
		_label.modulate = Color.WHITE
		_update_label()


# --- Build --------------------------------------------------------------------------

func _queue_rebuild() -> void:
	if is_inside_tree() and not _rebuild_queued:
		_rebuild_queued = true
		_rebuild.call_deferred()


func _rebuild() -> void:
	_rebuild_queued = false
	# The level tools keep a cut wall opening matching the door's size.
	if Engine.is_editor_hint() and recess_tag != &"" and Engine.has_meta(&"n64_door_changed"):
		(Engine.get_meta(&"n64_door_changed") as Callable).call(self)
	if _pivot == null:
		_pivot = Node3D.new()
		add_child(_pivot, false, INTERNAL_MODE_BACK)
		_panel = MeshInstance3D.new()
		_pivot.add_child(_panel)
		var body := StaticBody3D.new()
		_collider = CollisionShape3D.new()
		body.add_child(_collider)
		_pivot.add_child(body)
		_area = Area3D.new()
		_area.monitorable = false
		_area_shape = CollisionShape3D.new()
		_area.add_child(_area_shape)
		add_child(_area, false, INTERNAL_MODE_BACK)
		if not Engine.is_editor_hint():
			_area.body_entered.connect(_on_body_entered)
			_area.body_exited.connect(_on_body_exited)
			_label = Label3D.new()
			_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			_label.no_depth_test = true
			_label.font_size = 48
			_label.outline_size = 12
			_label.pixel_size = 0.004
			_label.visible = false
			add_child(_label, false, INTERNAL_MODE_BACK)
		_dressing = MeshInstance3D.new()
		add_child(_dressing, false, INTERNAL_MODE_BACK)
		var dressing_body := StaticBody3D.new()
		_dressing_shape = CollisionShape3D.new()
		dressing_body.add_child(_dressing_shape)
		_dressing.add_child(dressing_body)
		_dark = DarknessVolume.new()
		_dark.fade_start = 0.0
		_dark.fade_end = 0.02
		_dark.visible = false
		add_child(_dark, false, INTERNAL_MODE_BACK)
		if Engine.is_editor_hint():
			_arrow = WorldPreview.arrow(Color(0.35, 1.0, 0.45), 1, Vector3(0, 0.05, 0.1))
			add_child(_arrow, false, INTERNAL_MODE_BACK)

	# Swing doors hinge on the local -X edge; slide shutters retract up into the lintel
	# (pivot at the top, scaled down) so they never poke out above the wall.
	var swing := style == Style.SWING
	_pivot.position = Vector3(-width * 0.5, 0, 0) if swing else Vector3(0, height, 0)
	_pivot.rotation = Vector3.ZERO
	_pivot.scale = Vector3.ONE
	var center := Vector3(width * 0.5, height * 0.5, 0) if swing else Vector3(0, -height * 0.5, 0)
	_panel.mesh = _panel_mesh(Vector3(width, height, thickness)) if top == OpeningShape.Top.FLAT \
		else _arched_panel_mesh(width, height, thickness, top, arch_rise)
	_panel.position = center
	if panel_texture:
		var m := N64Materials.textured(Color.WHITE, panel_texture)
		# Gates / screen doors: see-through where the picture is transparent.
		var img := panel_texture.get_image()
		if img and img.detect_alpha() != Image.ALPHA_NONE:
			m.set_shader_parameter(&"cutout", true)
		_panel.material_override = m
	elif panel_surface:
		var m := N64Materials.textured(Color.WHITE, panel_surface)
		var density := maxf(float(ProjectSettings.get_setting("n64/textures/texels_per_metre", 32)), 1.0)
		m.set_shader_parameter(&"uv_scale", Vector2(width, height) * density / Vector2(panel_surface.get_size()))
		_panel.material_override = m
	elif panel_material:
		_panel.material_override = N64Materials.from_material(panel_material)
	else:
		_panel.material_override = _default_material()
	if top == OpeningShape.Top.FLAT:
		var shape := BoxShape3D.new()
		shape.size = Vector3(width, height, thickness)
		_collider.shape = shape
	else:
		var hull := ConvexPolygonShape3D.new()
		var pts := PackedVector3Array()
		for p in OpeningShape.outline(width, height, top, arch_rise):
			for z in [-thickness * 0.5, thickness * 0.5]:
				pts.append(Vector3(p.x, p.y - height * 0.5, z))
		hull.points = pts
		_collider.shape = hull
	_collider.position = center
	_collider.disabled = false

	var area_box := BoxShape3D.new()
	area_box.size = Vector3(width + 1.0, height, interact_range * 2.0)
	_area_shape.shape = area_box
	_area_shape.position.y = height * 0.5
	if _label:
		_label.position = Vector3(0, height + 0.35, 0)
	_build_dressing()
	# Exactly the opening, so the black never spills past the wall around the door.
	_dark.box_min = Vector3(-width * 0.5, -0.05, -1.0)
	_dark.box_max = Vector3(width * 0.5, height, 0.0)


## Panel box with the door picture on both big faces, u = 0 on the hinge (-X) edge (so
## the back reads mirrored, like the back of a real door); the edges take thin strips of
## the picture's matching border.
## Arched panel centred like _panel_mesh's box: the opening's outline as front and back
## (u from the -X edge, v from the top) and its edges as thin strips.
static func _arched_panel_mesh(width: float, height: float, thickness: float, top_kind: int, rise: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var outline := OpeningShape.outline(width, height, top_kind, rise)
	var hz := thickness * 0.5
	var uv_of := func(p: Vector2) -> Vector2:
		return Vector2(p.x / width + 0.5, 1.0 - p.y / height)
	var at := func(p: Vector2, z: float) -> Vector3:
		return Vector3(p.x, p.y - height * 0.5, z)
	# Front (+Z) and back: fans over the convex outline (counter-clockwise from the front).
	for i in range(1, outline.size() - 1):
		for k in [0, i + 1, i]:  # Godot front faces wind clockwise
			st.set_normal(Vector3.BACK)
			st.set_uv(uv_of.call(outline[k]))
			st.add_vertex(at.call(outline[k], hz))
		for k in [0, i, i + 1]:
			st.set_normal(Vector3.FORWARD)
			st.set_uv(uv_of.call(outline[k]))
			st.add_vertex(at.call(outline[k], -hz))
	# Edges.
	for i in outline.size():
		var a := outline[i]
		var b := outline[(i + 1) % outline.size()]
		var n := Vector3(b.y - a.y, -(b.x - a.x), 0.0).normalized()
		var ua: Vector2 = uv_of.call(a)
		var ub: Vector2 = uv_of.call(b)
		# Counter-clockwise seen from outside (like _panel_mesh's edges).
		var quad := [[at.call(a, -hz), ua + Vector2(0.03, 0)], [at.call(b, -hz), ub + Vector2(0.03, 0)], [at.call(b, hz), ub], [at.call(a, hz), ua]]
		for k in [0, 2, 1, 0, 3, 2]:
			st.set_normal(n)
			st.set_uv(quad[k][1])
			st.add_vertex(quad[k][0])
	return st.commit()


static func _panel_mesh(size: Vector3) -> ArrayMesh:
	var h := size * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var strip := 0.03
	# Corners (as seen from outside, counter-clockwise from bottom-left) and their UVs.
	var quad := func(n: Vector3, p: Array, uv: Array) -> void:
		for i: int in [0, 2, 1, 0, 3, 2]:  # Godot front faces wind clockwise
			st.set_normal(n)
			st.set_uv(uv[i])
			st.add_vertex(p[i])
	# Front (+Z) and back (-Z): u from the -X edge, v from the top.
	quad.call(Vector3.BACK, [Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z)],
		[Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
	quad.call(Vector3.FORWARD, [Vector3(h.x, -h.y, -h.z), Vector3(-h.x, -h.y, -h.z), Vector3(-h.x, h.y, -h.z), Vector3(h.x, h.y, -h.z)],
		[Vector2(1, 1), Vector2(0, 1), Vector2(0, 0), Vector2(1, 0)])
	# Hinge (-X) and latch (+X) edges.
	quad.call(Vector3.LEFT, [Vector3(-h.x, -h.y, -h.z), Vector3(-h.x, -h.y, h.z), Vector3(-h.x, h.y, h.z), Vector3(-h.x, h.y, -h.z)],
		[Vector2(0, 1), Vector2(strip, 1), Vector2(strip, 0), Vector2(0, 0)])
	quad.call(Vector3.RIGHT, [Vector3(h.x, -h.y, h.z), Vector3(h.x, -h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(h.x, h.y, h.z)],
		[Vector2(1 - strip, 1), Vector2(1, 1), Vector2(1, 0), Vector2(1 - strip, 0)])
	# Top and bottom.
	quad.call(Vector3.UP, [Vector3(-h.x, h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z)],
		[Vector2(0, strip), Vector2(1, strip), Vector2(1, 0), Vector2(0, 0)])
	quad.call(Vector3.DOWN, [Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z), Vector3(h.x, -h.y, h.z), Vector3(-h.x, -h.y, h.z)],
		[Vector2(0, 1), Vector2(1, 1), Vector2(1, 1 - strip), Vector2(0, 1 - strip)])
	return st.commit()


## Shape fingerprint of the current dressing (for keeping baked AO in sync).
func dressing_shape_key() -> int:
	return dressing.shape_key(width, height, _dressing_faces(), Vector2(top, arch_rise)) if dressing else 0


func _dressing_faces() -> Array:
	var faces := []
	if dressing.sides != OpeningDressing.Sides.BACK:
		faces.append([wall_center_z + wall_depth * 0.5, 1.0])
	if dressing.sides != OpeningDressing.Sides.FRONT:
		faces.append([wall_center_z - wall_depth * 0.5, -1.0])
	return faces


func _build_dressing() -> void:
	if dressing == null:
		_dressing.mesh = null
		_dressing_shape.shape = null
		return
	# Wall faces: front (+Z) at centre + depth / 2, back (-Z) at centre - depth / 2.
	var faces := _dressing_faces()
	var ao := dressing_ao if dressing_ao_key == dressing.shape_key(width, height, faces) else PackedFloat32Array()
	OpeningDressing.apply(dressing, _dressing, _dressing_shape, width, height, faces, ao, Vector2(top, arch_rise))


## N64 material (fog, no Godot specular): wood for swing doors, iron with a metal sheen
## and a glint for sliding ones.
func _default_material() -> ShaderMaterial:
	if style == Style.SWING:
		return N64Materials.textured(Color(0.45, 0.28, 0.15))
	return N64Materials.textured(Color(0.35, 0.36, 0.4), null, N64Materials.Shine.METAL, 0.35, 0.5)


func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if mode == Mode.ROOM and (room_a == null or room_b == null):
		out.append("ROOM doors need room_a (-Z side) and room_b (+Z side, the arrow).")
	if mode == Mode.ZONE and target_zone.is_empty():
		out.append("ZONE doors need a target_zone.")
	var n := get_parent()
	while n:
		if n is Room and mode == Mode.ROOM:
			out.append("Room doors should sit outside Rooms (directly under the Zone) so they never unload.")
			break
		n = n.get_parent()
	return out
