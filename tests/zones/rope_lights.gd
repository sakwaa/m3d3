extends Node
## Rope brushes of a level (LEVEL): their hangs. SET=1: every TASSEL hang becomes string
## lights (RopeHang LIGHTS, preset values), ropes rebuilt, the level baked and saved to OUT
## (a copy; OUT = the level's own path writes the level, editor closed).
##   SCENE=res://zones/....tscn [SET=1 OUT=...] tools/godot_run.sh --headless --path . tests/zones/rope_lights.tscn

const RopeHangScript := preload("res://addons/n64_level_tools/rope_hang.gd")


func _ready() -> void:
	var scene_path := OS.get_environment("SCENE")
	var zone: Node = (load(scene_path) as PackedScene).instantiate()
	add_child(zone)
	await get_tree().process_frame
	var root: LevelRoot = zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
	var data := root.data
	var changed := 0
	for b: LevelBrush in data.brushes:
		if b == null or not b.is_rope():
			continue
		var kinds := root._hang_list(b).map(func(h): return RopeHangScript.Kind.keys()[h.kind])
		print("%s: %d points, sag %.2f, hangs %s" % [b.tag, b.rope_points.size(), b.rope_sag, kinds])
		if OS.get_environment("SET") == "":
			continue
		var hangs: Array[RopeHang] = []
		for h in root._hang_list(b):
			if h.kind == RopeHangScript.Kind.TASSEL:
				hangs.append(RopeHangScript.preset(RopeHangScript.Kind.LIGHTS))
				changed += 1
			else:
				hangs.append(h)
		b.rope_hangs = hangs
		root._generate_rope(b)
	if OS.get_environment("SET") != "":
		var res := LevelBaker.bake(data, root.merge_coplanar)
		data.baked_mesh = res.mesh
		data.baked_chunks = res.chunks
		data.set_baked_collision(res)
		var out := OS.get_environment("OUT")
		var uid := ResourceLoader.get_resource_uid(data.resource_path)
		var err := ResourceSaver.save(data, out, ResourceSaver.FLAG_COMPRESS)
		if out == data.resource_path and uid != ResourceUID.INVALID_ID:
			ResourceSaver.set_uid(out, uid)
		print("%d tassel hangs to lights; saved %s: %s" % [changed, out, error_string(err)])
	get_tree().quit()
