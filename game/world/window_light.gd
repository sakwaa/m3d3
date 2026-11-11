@tool
class_name WindowLight
extends Node3D
## A window lit from inside: warm glass over a window's pane, shown in the evening while
## someone is home. Each window turns on at its own time between `on_hour` and
## `on_hour + spread` and off between `off_hour` and `off_hour + spread`, picked again each
## day (from `light_seed` and the day), so a street's lights come on one by one. On a rainy
## day (weather rain at least RAIN_LIGHTS) about RAIN_SHARE of the homes have theirs on from
## morning, like a gloomy evening (each house picked again each day). Made by the level
## from window brushes (LevelRoot); +Z is out of the wall, the origin the pane's bottom centre.

## Opening outline (OpeningShape): the glow covers it.
@export var width := 0.9:
	set(v):
		width = v
		_rebuild()
@export var height := 1.0:
	set(v):
		height = v
		_rebuild()
@export var top := OpeningShape.Top.FLAT:
	set(v):
		top = v
		_rebuild()
@export var arch_rise := 0.0:
	set(v):
		arch_rise = v
		_rebuild()
## How far apart the two lit faces sit (the pane's two sides).
@export var gap := 0.04:
	set(v):
		gap = v
		_rebuild()
## Windows in a house: how far out the far glow sits (just outside the wall's far
## stand-in, which hides the pane past the LOD distance). 0 = no far glow.
@export var far_offset := 0.0:
	set(v):
		far_offset = v
		_rebuild()
## Lamplight colour (the top of the window is a little darker).
@export var color := Color(1.0, 0.8, 0.45):
	set(v):
		color = v
		_rebuild()
## Someone's home: always (no flag), or while this GameState flag is set.
@export var home := true
@export var home_flag := ""
@export_range(0.0, 24.0, 0.25) var on_hour := 17.5
@export_range(0.0, 24.0, 0.25) var off_hour := 22.5
## Hours after on_hour / off_hour the actual times may fall.
@export_range(0.0, 6.0, 0.25) var spread := 2.0
@export var light_seed := 0

const LOD_SETTING := "n64/build/lod_distance"
## Rain (weather `rain`) from which some homes light up in the daytime, and how many of them.
const RAIN_LIGHTS := 0.3
const RAIN_SHARE := 0.5
## Daytime hours a rainy-day light may be on (it then runs into the evening's own schedule).
const RAIN_FROM := 7.0

var _material: StandardMaterial3D
var _mesh: MeshInstance3D
var _far_mesh: MeshInstance3D


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	if not is_inside_tree():
		return
	if _mesh:
		_mesh.queue_free()
	# Lamplight: warm, brightest low down (a lamp on a table), no glass texture (its blue
	# would turn the warm colour olive).
	if _far_mesh:
		_far_mesh.queue_free()
		_far_mesh = null
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var outline := OpeningShape.outline(width, height, top, arch_rise)
	for side in [1.0, -1.0]:
		var z: float = side * gap * 0.5
		# Fan from the first point; clockwise seen from the side it faces (Godot fronts).
		for i in range(1, outline.size() - 1):
			var tri := [outline[0], outline[i], outline[i + 1]] if side < 0.0 else [outline[0], outline[i + 1], outline[i]]
			for q: Vector2 in tri:
				st.set_color(color.lerp(color.darkened(0.35), clampf(q.y / height, 0.0, 1.0)))
				st.set_uv(Vector2(0.5 + side * q.x / width, 1.0 - q.y / height))
				st.add_vertex(Vector3(q.x, q.y, z))
	_mesh = MeshInstance3D.new()
	_mesh.mesh = st.commit()
	_mesh.material_override = _material
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh, false, INTERNAL_MODE_BACK)
	if far_offset > 0.0:
		var lod_at: float = ProjectSettings.get_setting(LOD_SETTING, 40.0)
		_mesh.visibility_range_end = lod_at
		_far_mesh = MeshInstance3D.new()
		_far_mesh.mesh = _mesh.mesh
		_far_mesh.material_override = _material
		_far_mesh.position.z = far_offset
		_far_mesh.visibility_range_begin = lod_at
		add_child(_far_mesh, false, INTERNAL_MODE_BACK)
	_update()


func _process(_delta: float) -> void:
	_update()


func _update() -> void:
	if _mesh == null:
		return
	var lit := false
	if not Engine.is_editor_hint():
		var gs := get_node_or_null(^"/root/GameState")
		lit = gs != null and (is_lit(gs.day, gs.time_of_day, _is_home(gs))
			or is_lit_in_rain(gs.day, gs.time_of_day, _is_home(gs), float(gs.weather_now.get("rain", 0.0))))
	_mesh.visible = lit
	if _far_mesh:
		_far_mesh.visible = lit


func _is_home(gs: Node) -> bool:
	return gs.get_flag(home_flag) if home_flag != "" else home


## Whether the window is lit on absolute day `day` at `hour` (the evening that starts on
## `day`; past midnight belongs to the day before).
func is_lit(day: int, hour: float, someone_home: bool) -> bool:
	if not someone_home:
		return false
	var evening := day if hour >= 12.0 else day - 1
	var t := hour if hour >= 12.0 else hour + 24.0
	var on := on_hour + spread * _rand(evening, 0)
	var off := off_hour + spread * _rand(evening, 1)
	if off < on:
		off += 24.0
	return t >= on and t < off


## Whether the window is lit for the rain: someone home, rain at least RAIN_LIGHTS, this
## house among the day's RAIN_SHARE, and daytime from RAIN_FROM up to its evening on time.
func is_lit_in_rain(day: int, hour: float, someone_home: bool, rain: float) -> bool:
	if not someone_home or rain < RAIN_LIGHTS or hour < RAIN_FROM:
		return false
	return _rand(day, 2) < RAIN_SHARE and hour < on_hour + spread * _rand(day, 0) + 0.01


func _rand(day: int, which: int) -> float:
	return float(hash([light_seed, day, which]) & 0xffff) / 65535.0
