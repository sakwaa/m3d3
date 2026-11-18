extends SceneTree
func _init() -> void:
	var d: LevelData = load("res://tests/tmp/citadel_tuck/forest_citadel_level.res")
	var seen := {}
	var meshes := []
	if d.baked_mesh: meshes.append(d.baked_mesh)
	for c in d.baked_chunks:
		var v: Variant = c
		if v is Mesh: meshes.append(v)
	print("CHUNKS ", d.baked_chunks.size(), " ", meshes.size())
	for m in meshes:
		for i in m.get_surface_count():
			var mat = m.surface_get_material(i)
			if mat is ShaderMaterial and not seen.has(mat):
				seen[mat] = true
				var bt = mat.get_shader_parameter(&"base_tex")
				print("MAT ", bt.resource_path.get_file() if bt else null, " mode ", mat.get_shader_parameter(&"base_tint_mode"), " dark ", mat.get_shader_parameter(&"base_tint_dark"), " light ", mat.get_shader_parameter(&"base_tint_light"))
	quit()
