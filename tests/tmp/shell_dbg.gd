extends Node3D
func _ready() -> void:
	var sp: TreeSpecies = load("res://addons/n64_level_tools/trees/species/sycamore.tres")
	var m := TreeBuilder.build(sp, 7, 1)
	for i in m.get_surface_count():
		var a := m.surface_get_arrays(i)
		var mat := m.surface_get_material(i) as ShaderMaterial
		print("[dbg] surface ", i, " verts ", (a[0] as PackedVector3Array).size(), " idx ", (a[Mesh.ARRAY_INDEX] as PackedInt32Array).size(), " cutout ", mat.get_shader_parameter(&"cutout"), " aabb ", m.get_aabb())
	var a := m.surface_get_arrays(2)
	var v: PackedVector3Array = a[0]
	var lo := v[0]
	var hi := v[0]
	for p in v:
		lo = lo.min(p)
		hi = hi.max(p)
	print("[dbg] solid bounds ", lo, " ", hi)
	get_tree().quit()
