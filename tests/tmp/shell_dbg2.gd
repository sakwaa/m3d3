extends Node3D
func _ready() -> void:
	var sp: TreeSpecies = load("res://addons/n64_level_tools/trees/species/sycamore.tres")
	var m := TreeBuilder.build(sp, 7, 1)
	var only := ArrayMesh.new()
	only.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, m.surface_get_arrays(2))
	only.surface_set_material(0, m.surface_get_material(2))
	var mi := MeshInstance3D.new()
	mi.mesh = only
	add_child(mi)
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 9, 22)
	cam.look_at(Vector3(0, 9, 0))
	cam.make_current()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	cam.environment = env
	for mode in [Viewport.DEBUG_DRAW_DISABLED, Viewport.DEBUG_DRAW_OVERDRAW]:
		get_viewport().debug_draw = mode
		for i in 6:
			await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		img.resize(480, 270)
		img.save_png(OS.get_environment("OUT") + "/dbg_%d.png" % mode)
		print("[dbg] mode ", mode, " centre ", img.get_pixel(240, 135))
	get_tree().quit()
