extends Node
## Which paint-shader settings differ between a baked level's surface materials (what a merged
## surface would have to carry per vertex), and the base texture sizes. Never saves.
##   LEVEL=res://...res godot --headless --path . tests/zones/material_diff.tscn


func _ready() -> void:
	var d: LevelData = load(OS.get_environment("LEVEL"))
	var mats := {}
	var per_mesh := []
	for m in d.baked_meshes():
		per_mesh.append(m.get_surface_count())
		for i in m.get_surface_count():
			var mat := m.surface_get_material(i) as ShaderMaterial
			if mat:
				mats[mat] = true
	var values := {}  # param -> {value repr -> count}
	var sizes := {}
	for mat: ShaderMaterial in mats:
		for u in mat.shader.get_shader_uniform_list():
			var v = mat.get_shader_parameter(u.name)
			var r := str(v.resource_path.get_file() if v is Resource and v.resource_path != "" else ("<tex %s>" % str(v.get_size()) if v is Texture2D else v))
			if not values.has(u.name):
				values[u.name] = {}
			values[u.name][r] = values[u.name].get(r, 0) + 1
		var bt = mat.get_shader_parameter(&"base_tex")
		if bt is Texture2D:
			var k := str(bt.get_size())
			sizes[k] = sizes.get(k, 0) + 1
	print("materials ", mats.size(), "  surfaces per mesh ", per_mesh)
	print("base texture sizes ", sizes)
	for k in values:
		if values[k].size() > 1:
			print("  %-22s %d different: %s" % [k, values[k].size(), str(values[k].keys().slice(0, 5)).left(160)])
	get_tree().quit()
