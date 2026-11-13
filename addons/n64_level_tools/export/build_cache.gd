@tool
extends RefCounted
## What lets Build & Play skip work: a level's build key (everything its build depends on:
## the build code, the zone scene - lights, doors, dressing -, the brushes and paint, the
## level's and the project's build settings, the lighting schedule) stored with its bake, so
## an unchanged zone isn't rebuilt; and per-step result files (the Blender dissolve per brush,
## the never-seen cull per level) under .godot/, so a small edit redoes only what it touched.
## Exports don't read the caches (they always build from scratch).

const DIR := "res://.godot/n64_build_cache"
## On while Build & Play builds (the plugin sets it): steps read and write their result files.
static var active := false
## The files the build runs: any change to them rebuilds everything.
const PIPELINE := [
	"res://addons/n64_level_tools/export/export_bake.gd",
	"res://addons/n64_level_tools/level_baker.gd",
	"res://addons/n64_level_tools/level_lighting.gd",
	"res://addons/n64_level_tools/build_cull.gd",
	"res://addons/n64_level_tools/build_simplify.gd",
	"res://addons/n64_level_tools/blender_dissolve.gd",
	"res://tools/blender_dissolve/dissolve.py",
	"res://addons/n64_level_tools/ground_lod.gd",
	"res://addons/n64_level_tools/chunk_split.gd",
	"res://addons/n64_level_tools/crack_close.gd",
	"res://addons/n64_level_tools/material_merge.gd",
	"res://addons/n64_level_tools/unseen_cull.gd",
	"res://addons/n64_level_tools/room_vis.gd",
	"res://addons/n64_level_tools/level_brush.gd",
	"res://addons/n64_level_tools/level_data.gd",
	"res://addons/n64_grade/grade_bake.gd",
	"res://addons/n64_level_tools/paint/grass_builder.gd",
	"res://addons/n64_grade/grade_processor.gd",
	"res://addons/n64_grade/grade_vertex.gd",
]
## LevelData properties that are the bake's output, not its input.
const OUTPUTS := [&"brushes", &"bake_hash", &"bake_summary", &"build_key", &"rain_cover_image", &"rain_cover_area",
	&"rain_light_image", &"rain_light_keys", &"backdrop_mesh", &"backdrop_ring", &"backdrop_ring_info"]


## A 64-bit key for `value` (two independent 32-bit hashes).
static func key(value: Variant) -> int:
	return (hash(value) & 0xFFFFFFFF) | (hash([value, 0x5bd1e995]) << 32)


## A result file's path for `step` and `key` (its folder made).
static func path(step: String, key: int) -> String:
	var d := DIR.path_join(step)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(d))
	return d.path_join("%016x.bin" % key)


static func read(step: String, key: int) -> Variant:
	var p := path(step, key)
	if not FileAccess.file_exists(p):
		return null
	return bytes_to_var(FileAccess.get_file_as_bytes(p))


static func write(step: String, key: int, value: Variant) -> void:
	var f := FileAccess.open(path(step, key), FileAccess.WRITE)
	if f:
		f.store_buffer(var_to_bytes(value))


## The build code's checksum.
static func pipeline_hash() -> int:
	var parts := []
	for f in PIPELINE:
		parts.append(FileAccess.get_md5(f))
	return hash(parts)


## Everything `root`'s build depends on (`scene_path`: its zone scene, saved).
static func level_key(root: LevelRoot, scene_path: String) -> int:
	var settings := {}
	for p in ProjectSettings.get_property_list():
		var n: String = p.name
		if n.begins_with("n64/") or n.begins_with("rendering/"):
			settings[n] = ProjectSettings.get_setting(n)
	var schedule = ProjectSettings.get_setting(LightingSchedule.SETTING, "")
	if not schedule is String or schedule == "":
		schedule = LightingSchedule.DEFAULT_PATH
	# (the Grade's filters sit deeper than _settings_hash looks; its own signature covers them)
	var grade: String = root.data.grade.call(&"signature") if root.data.grade and root.data.grade.has_method(&"signature") else ""
	var filters := ""
	for f in DirAccess.get_files_at("res://addons/n64_grade/filters"):
		if f.ends_with(".gd"):
			filters += FileAccess.get_md5("res://addons/n64_grade/filters".path_join(f))
	return key([pipeline_hash(), FileAccess.get_md5(scene_path), root.compute_hash(), root.merge_coplanar,
		_settings_hash(root.data), hash(settings), FileAccess.get_md5(schedule), grade, filters if grade != "" else ""])


## The level's own settings (lighting mode, strengths, textures, grass, scatter...).
static func _settings_hash(data: LevelData, depth := 0) -> int:
	var parts := []
	for p in data.get_property_list():
		if not p.usage & PROPERTY_USAGE_STORAGE or p.name in OUTPUTS or String(p.name).begins_with("baked"):
			continue
		parts.append([p.name, _value(data.get(p.name), depth)])
	return hash(parts)


static func _value(v: Variant, depth: int) -> Variant:
	if v is Resource:
		if (v as Resource).resource_path != "" and not (v as Resource).resource_path.contains("::"):
			return (v as Resource).resource_path
		if depth > 2:
			return "embedded"
		var parts := []
		for p in (v as Resource).get_property_list():
			if p.usage & PROPERTY_USAGE_STORAGE:
				parts.append([p.name, _value((v as Resource).get(p.name), depth + 1)])
		return hash(parts)
	if v is Array:
		return hash((v as Array).map(func(x): return _value(x, depth + 1)))
	if v is Dictionary:
		var parts := []
		for k in v:
			parts.append([k, _value(v[k], depth + 1)])
		return hash(parts)
	return v


## Whether every level of the zone at `scene_path` holds a build made from what's there now.
static func zone_up_to_date(scene_path: String) -> bool:
	var packed := load(scene_path) as PackedScene
	if packed == null:
		return false
	var scene := packed.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED)
	var ok := true
	var any := false
	for root in [scene] + scene.find_children("*", "Node3D", true, false):
		if not root is LevelRoot or root.data == null or root.data.brushes.is_empty():
			continue
		any = true
		if not root.data.has_bake() or root.data.build_key == 0 or root.data.build_key != level_key(root, scene_path) \
				or not _arrays_ok(root.data):
			ok = false
			break
	scene.free()
	return ok and any


## Whether the build's merged texture arrays (MaterialMerge) all have their layers. One
## saved by an editor without a renderer (headless) comes back empty: built again.
static func _arrays_ok(data: LevelData) -> bool:
	var meshes: Array = data.baked_chunks.duplicate()
	if data.baked_mesh:
		meshes.append(data.baked_mesh)
	for m in meshes:
		if not m is ArrayMesh:
			continue
		for si in m.get_surface_count():
			var mat := m.surface_get_material(si) as ShaderMaterial
			var array = mat.get_shader_parameter(&"base_array") if mat else null
			if array is Texture2DArray and array.get_layers() == 0:
				return false
	return true


## Whether the scene at `scene_path` has a level with brushes (a zone the build bakes).
static func has_levels(scene_path: String) -> bool:
	var packed := load(scene_path) as PackedScene
	if packed == null:
		return false
	var state := packed.get_state()
	for i in state.get_node_count():
		for k in state.get_node_property_count(i):
			if state.get_node_property_name(i, k) == &"data" and state.get_node_property_value(i, k) is LevelData:
				return not (state.get_node_property_value(i, k) as LevelData).brushes.is_empty()
	return false
