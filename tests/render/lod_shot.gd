extends Node3D
## N64Lod check: the hero twice, left full, right forced to its reduced model (preview_lod),
## triangle counts printed. OUT=<dir> [WIRE=1] tools/godot_run.sh --path . tests/render/lod_shot.tscn

var _frames := 0


func _ready() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.25, 0.27, 0.33)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.65)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 30, 0)
	add_child(sun)
	var ratio := float(OS.get_environment("RATIO")) if OS.get_environment("RATIO") != "" else 0.35
	for i in 2:
		var hero: Node3D
		if OS.get_environment("MODEL") == "sphere":
			# A dense stand-in (the characters are box mannequins, already minimal).
			hero = Node3D.new()
			var mi := MeshInstance3D.new()
			var sm := SphereMesh.new()
			sm.radius = 0.45
			sm.height = 0.9
			var am := ArrayMesh.new()
			am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sm.get_mesh_arrays())
			mi.mesh = am
			mi.position.y = 0.9
			hero.add_child(mi)
		else:
			hero = (load(OS.get_environment("MODEL") if OS.get_environment("MODEL") != "" else "res://characters/hero.tscn") as PackedScene).instantiate()
		hero.position = Vector3(-0.6 + i * 1.2, 0, 0)
		hero.rotation_degrees.y = 180 + 25
		add_child(hero)
		if i == 1:
			var lod := N64Lod.new()
			lod.ratio = ratio
			lod.preview_lod = true
			hero.add_child(lod)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.1, 3.4)
	cam.fov = 40
	add_child(cam)
	cam.look_at(Vector3(0, 0.9, 0))
	if OS.get_environment("WIRE") != "":
		RenderingServer.set_debug_generate_wireframes(true)
		get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME


func _process(_d: float) -> void:
	_frames += 1
	if _frames == 6:
		for mi: MeshInstance3D in find_children("*", "MeshInstance3D", true, false):
			if mi.mesh and mi.visible:
				print("mesh ", mi.get_path(), " tris ", N64Lod.tris(mi.mesh))
	if _frames == 10:
		get_viewport().get_texture().get_image().save_png(OS.get_environment("OUT") + "/shot.png")
		get_tree().quit()
