@tool
extends EditorExportPlugin
## Keeps level tooling and authoring data out of exported builds:
##  - every LevelRoot in an exported scene becomes plain built-in nodes made from its bake
##    (Node3D + MeshInstance3D + StaticBody3D): no script, no brushes, painted masks,
##    vertex edits or lighting keys;
##  - N64Textures become plain ImageTextures (no hi-res source path or import settings);
##  - LevelData files and everything in this addon are left out;
##  - nodes in the `editor_only` group (reference images, ...) are removed.
##  - first, every level gets a final bake with its current settings (export_bake.gd;
##    Project Settings > n64/export/bake_on_export), into the export only.
## Shipped code that needs to run in the game lives in addons/n64_runtime/ and game/.

const TOOLS_DIR := "res://addons/n64_level_tools/"
## Bump when the customisation output changes, so Godot's export cache is invalidated.
const VERSION := 3
const ExportBake := preload("res://addons/n64_level_tools/export/export_bake.gd")
const ZoneLinks := preload("res://addons/n64_level_tools/zone_links.gd")
const BuildReport := preload("res://addons/n64_level_tools/export/build_report.gd")

## Hosts each scene while it's baked (own 3D world, never drawn).
var _holder: SubViewport
var _baked := 0
var _failed: Array[String] = []
var _report_levels := []  # BuildReport.level() of every baked level (the full build report)


func _get_name() -> String:
	return "N64LevelToolsStrip"


func _begin_customize_scenes(_platform: EditorExportPlatform, _features: PackedStringArray) -> bool:
	return true


func _begin_customize_resources(_platform: EditorExportPlatform, _features: PackedStringArray) -> bool:
	return true


func _get_customization_configuration_hash() -> int:
	# A final bake depends on everything (lights, level data, settings): never reuse a
	# cached export of a scene then.
	if ExportBake.enabled():
		return hash([VERSION, Time.get_unix_time_from_system()])
	return VERSION


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	_baked = 0
	_failed.clear()
	_report_levels.clear()
	# Pre-build: zone links (exits, zone doors, passages) must all lead somewhere.
	if ZoneLinks.enabled():
		var errors := ZoneLinks.report()
		if errors > 0:
			var msg := "%d zone link(s) lead nowhere (no target zone / missing scene) — see the Output panel. " % errors \
				+ "Fix them, or turn off Project Settings > %s." % ZoneLinks.SETTING
			push_error("N64 export: " + msg)
			var platform = get_export_platform() if has_method(&"get_export_platform") else null
			if platform and platform.has_method(&"add_message"):
				platform.add_message(EditorExportPlatform.EXPORT_MESSAGE_ERROR, "Zone links", msg)
	if ExportBake.enabled():
		_holder = SubViewport.new()
		_holder.own_world_3d = true
		_holder.render_target_update_mode = SubViewport.UPDATE_DISABLED
		EditorInterface.get_base_control().add_child(_holder)


func _export_end() -> void:
	if _holder:
		_holder.queue_free()
		_holder = null
	if ExportBake.enabled():
		print("[N64 export] Final bake: %d level(s) re-baked." % _baked)
	for f in _failed:
		push_warning("N64 export: couldn't re-bake %s; shipping its last editor bake." % f)
	if not _report_levels.is_empty():
		var dir := BuildReport.write(_report_levels, "export", "export")
		print("[N64 export] Build report: %s" % ProjectSettings.globalize_path(dir))
		_report_levels.clear()


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if path.begins_with(TOOLS_DIR):
		skip()
		return
	var ext := path.get_extension()
	if ext == "tres" or ext == "res":
		# Level data, and the rope tools' own resources (banner text is typed in plain words).
		var r := ResourceLoader.load(path)
		if r is LevelData or r is RopeHang or r is RopeStyle or r is GlyphAlphabet or r is StrokeAlphabet or r is SyllabaryAlphabet:
			skip()


func _customize_scene(scene: Node, path: String) -> Node:
	var stripped := _strip_editor_only(scene)
	var roots: Array[LevelRoot] = []
	_find_level_roots(scene, roots)
	if roots.is_empty():
		return scene if stripped else null
	if _holder:
		var t := Time.get_ticks_msec()
		var result := ExportBake.bake_scene(scene, _holder, path,
			bool(ProjectSettings.get_setting(BuildReport.REPORT_ON_EXPORT, true)))
		_report_levels.append_array(result.levels)
		_baked += result.baked
		_failed.append_array(result.failed)
		print("[N64 export] Baked %d level(s) in %s (%d ms)." % [result.baked, path, Time.get_ticks_msec() - t])
	for root in roots:
		var out := _replace_level_root(root, scene, path)
		if root == scene:
			scene = out
	return scene


func _customize_resource(resource: Resource, _path: String) -> Resource:
	if resource is N64Texture:
		var image: Image = resource.get_image()
		if image:
			return ImageTexture.create_from_image(image)
	return null


## Removes `editor_only` nodes (and what's under them). True when there were any.
func _strip_editor_only(scene: Node) -> bool:
	var doomed: Array[Node] = []
	for n in scene.find_children("*", "", true, false):
		if n.is_in_group(&"editor_only") and not doomed.any(func(d): return d.is_ancestor_of(n)):
			doomed.append(n)
	for n in doomed:
		n.get_parent().remove_child(n)
		n.free()
	return not doomed.is_empty()


func _find_level_roots(node: Node, out: Array[LevelRoot]) -> void:
	if node is LevelRoot:
		out.append(node)
	for child in node.get_children():
		_find_level_roots(child, out)


func _replace_level_root(root: LevelRoot, scene: Node, scene_path: String) -> Node3D:
	var data := root.data
	if data == null or not data.has_bake():
		push_error("N64 export: level '%s' in %s has no bake; it ships without geometry. Bake it first." % [root.name, scene_path])
	elif root.is_bake_stale() and _holder == null:
		push_warning("N64 export: level '%s' in %s changed since its last bake; shipping the old bake." % [root.name, scene_path])

	var out := Node3D.new()
	out.name = root.name
	out.transform = root.transform
	out.visible = root.visible
	for group in root.get_groups():
		if not str(group).begins_with("_"):
			out.add_to_group(group, true)
	if data:
		var meshes := data.baked_meshes()
		for i in meshes.size():
			var mi := MeshInstance3D.new()
			mi.name = "Mesh" if meshes.size() == 1 else "Mesh%d" % i
			mi.mesh = meshes[i].duplicate()
			mi.layers = root.level_layers()
			LevelRoot.apply_lod_range(mi, LevelRoot.lod_distance())
			out.add_child(mi)
	if data:
		var c := data.baked_collision_set()
		for body in Surface.build_bodies(c[0].map(func(shape): return shape.duplicate()), c[1]):
			out.add_child(body)
		var occ := LevelRoot.house_occluder(data)
		if occ:
			var oi := OccluderInstance3D.new()
			oi.name = "Occluder"
			oi.occluder = occ
			out.add_child(oi)
		var rain := RainCover.from_build(data.rain_cover_built(), data.rain_light_built())
		if rain:
			out.add_child(rain)
		for n in Backdrop.build_nodes(data.backdrop_mesh, data.backdrop_ring, data.backdrop_ring_info):
			out.add_child(n)
	if data:
		for i in data.scatter.size():
			var nodes := data.scatter[i].build_nodes(root.level_layers()) if data.scatter[i] else ([] as Array[MultiMeshInstance3D])
			for k in nodes.size():
				nodes[k].name = "Scatter%d" % i if nodes.size() == 1 else "Scatter%d_%d" % [i, k]
				out.add_child(nodes[k])
		# Grass (mat tiles and tufts) as plain nodes.
		for g in root.build_grass_for_export():
			out.add_child(g)

	# Passage brushes' gameplay nodes (exit, fade, spawn) ship as children of the bake.
	root.make_passage_nodes_for_export(scene)
	# Door brushes' Door nodes ship too (under the zone, outside any Room).
	root.make_door_nodes_for_export(scene)
	# Prop brushes' nodes (signs, stalls, drips, birds, NPC spots) ship as real nodes.
	root.make_prop_nodes_for_export(scene)
	# Scenes hung along ropes (lanterns) ship as children of the bake too.
	root.make_rope_nodes_for_export(scene)
	# Swap in place, keeping the level's own children (actors, markers) and their owners.
	var owners := {}
	_collect_owners(root, owners)
	var parent := root.get_parent()
	var index := root.get_index()
	for child in root.get_children():
		root.remove_child(child)
		out.add_child(child)
	if parent:
		parent.remove_child(root)
		parent.add_child(out)
		parent.move_child(out, index)
	_retarget_references(out if root == scene else scene, root, out)
	var new_scene := out if root == scene else scene
	if out != new_scene:
		out.owner = new_scene
	for n in out.get_children():
		_set_owners(n, new_scene, owners)
	root.free()
	return out


## Node-typed exports pointing at the level (e.g. Passage.level) follow the replacement.
func _retarget_references(node: Node, from: Node, to: Node) -> void:
	for prop in node.get_property_list():
		if prop.type == TYPE_OBJECT and prop.usage & PROPERTY_USAGE_STORAGE and node.get(prop.name) == from:
			node.set(prop.name, to)
	for child in node.get_children():
		_retarget_references(child, from, to)


func _collect_owners(node: Node, owners: Dictionary) -> void:
	for child in node.get_children():
		owners[child] = child.owner
		_collect_owners(child, owners)


## Generated nodes get the scene as owner; moved nodes keep theirs.
func _set_owners(node: Node, scene: Node, owners: Dictionary) -> void:
	var previous: Node = owners.get(node)
	node.owner = scene if previous == null or not is_instance_valid(previous) or previous is LevelRoot else previous
	for child in node.get_children():
		_set_owners(child, scene, owners)
