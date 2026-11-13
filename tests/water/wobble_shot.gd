extends Node3D
## Water wobble check: a striped floor under water, a post standing in it (in front of the
## water behind it), rendered with the wobble off and on and a moment later. The stripes
## under water sway; the post must not smear into the water. Saves PNGs to OUT.
##   OUT=dir godot --path . --resolution 960x540 tests/water/wobble_shot.tscn
func _ready() -> void:
	RenderingServer.global_shader_parameter_set(&"n64_ambient_light", Color.WHITE)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 2.2, 5.0)
	add_child(cam)
	cam.look_at(Vector3(0, -0.4, 0))
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 30, 0)
	add_child(sun)
	# Floor: black and white stripes, 0.6 m below the surface.
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	for y in 16:
		for x in 16:
			img.set_pixel(x, y, Color.WHITE if (x / 2) % 2 == 0 else Color(0.1, 0.1, 0.1))
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.albedo_texture = ImageTexture.create_from_image(img)
	fm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	fm.uv1_scale = Vector3(4, 4, 1)
	var floor := MeshInstance3D.new()
	var fq := PlaneMesh.new()
	fq.size = Vector2(12, 12)
	floor.mesh = fq
	floor.material_override = fm
	floor.position.y = -0.6
	add_child(floor)
	# A red post standing in the water, near the camera.
	var post := MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(0.3, 2.0, 0.3)
	post.mesh = pm
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.albedo_color = Color(0.9, 0.1, 0.1)
	post.material_override = rm
	post.position = Vector3(0.6, 0.0, 2.0)
	add_child(post)
	var water := N64Water.new()
	var wp := PlaneMesh.new()
	wp.size = Vector2(12, 12)
	wp.subdivide_width = 24
	wp.subdivide_depth = 24
	water.mesh = wp
	water.reflections = false
	var mat := (load("res://game/materials/water.tres") as ShaderMaterial).duplicate()
	water.material_override = mat
	add_child(water)
	var out := OS.get_environment("OUT")
	DirAccess.make_dir_recursive_absolute(out)
	for shot in [["off", false, 0], ["on_a", true, 0], ["on_b", true, 20]]:
		mat.set_shader_parameter(&"wobble_on", shot[1])
		for f in 10 + int(shot[2]):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out.path_join("water_%s.png" % shot[0]))
	get_tree().quit()
