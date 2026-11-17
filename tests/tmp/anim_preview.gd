extends Node3D
## Filmstrips of sword clips built from specs in memory (nothing saved): for each spec in
## SPECS (comma list of .json paths), frames every STEP, rendered from a 3/4 view -> OUT/<name>.png
var _p: Node
var _m: ActorModel
var _cam: Camera3D

func _ready() -> void:
	var floor := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(20, 20)
	floor.mesh = pm
	add_child(floor)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.6, 0.7)
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.6)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	add_child(env)
	_p = (load("res://player/player.tscn") as PackedScene).instantiate()
	add_child(_p)
	_p.process_mode = Node.PROCESS_MODE_DISABLED
	_m = _p.find_children("*", "ActorModel", true, false)[0]
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.fov = 40
	var view := OS.get_environment("VIEW")
	_cam.position = Vector3(2.6, 1.5, -2.6) if view == "" else Vector3(0, 1.4, -3.6)
	_cam.look_at(Vector3(0, 0.8, 0))
	_cam.make_current()
	_run.call_deferred()

func _run() -> void:
	await get_tree().process_frame
	if _p.has_method(&"_sheathe"):
		_p.call(&"_sheathe", false)  # (sword in hand)
	var step := float(OS.get_environment("STEP")) if OS.get_environment("STEP") != "" else 2.0
	for path in OS.get_environment("SPECS").split(","):
		var spec := ActorAnimSpec.load_spec(path)
		var a := ActorAnimSpec.build(_m, spec)
		_m.data.animations.append(a)
		_m.anim_index = _m.data.animations.size() - 1
		var shots: Array[Image] = []
		var f := 0.0
		while f <= a.length + 0.01:
			_m.show_frame(f)
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var cw := img.get_width() * 6 / 10
			img = img.get_region(Rect2i((img.get_width() - cw) / 2, img.get_height() / 10, cw, img.get_height() * 8 / 10))
			if OS.get_environment("FRAMES") != "":
				# FRAMES=dir: every frame saved full size as <name><TAG>_NNN.png (video)
				img.save_png("%s/%s%s_%03d.png" % [OS.get_environment("FRAMES"), path.get_file().get_basename(), OS.get_environment("TAG"), shots.size()])
			img.resize(220, 220 * img.get_height() / img.get_width(), Image.INTERPOLATE_BILINEAR)
			shots.append(img)
			f += step
		var w := shots[0].get_width()
		var h := shots[0].get_height()
		var sheet := Image.create(w * shots.size(), h, false, shots[0].get_format())
		for i in shots.size():
			sheet.blit_rect(shots[i], Rect2i(0, 0, w, h), Vector2i(i * w, 0))
		sheet.save_png(OS.get_environment("OUT") + "/" + path.get_file().get_basename() + OS.get_environment("TAG") + ".png")
	get_tree().quit()
