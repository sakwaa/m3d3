extends Node3D
## Ground mist disturbance: the player walks (2 s), stands (1.5 s), lands a jump (GroundMist.splash),
## stands again; frames saved at SHOTS (seconds) as OUT/t_<s>.png, a high camera following like
## the reference clip.  OUT=dir [ZONE=…] [SHOTS=0.8,1.6,…] godot --path . --resolution 1280x720 tests/render/mist_walk.tscn

var _player: Node3D
var _cam: Camera3D
var _zone: Node
var _t := 0.0
var _shots: Array = []
var _splashed := false
var _pin_y := 0.0
var FROM := Vector3(-3, 0, 7)
var TO := Vector3(3, 0, -1)
const WALK := 2.0


func _ready() -> void:
	_zone = (load(OS.get_environment("ZONE") if OS.get_environment("ZONE") != "" else "res://zones/town1/town_1_hillside.tscn") as PackedScene).instantiate()
	# FROM=x,z TO=x,z: the walk; MIST=0: no ground mist (grass checks); WEATHER=…
	if OS.get_environment("FROM") != "":
		var f := OS.get_environment("FROM").split(",")
		var t := OS.get_environment("TO").split(",")
		FROM = Vector3(float(f[0]), 0, float(f[1]))
		TO = Vector3(float(t[0]), 0, float(t[1]))
	_zone.set(&"ground_mist", float(OS.get_environment("MIST")) if OS.get_environment("MIST") != "" else 1.0)
	if OS.get_environment("LEVEL_OVERRIDE") != "":
		for lr in _zone.find_children("*", "Node3D", true, false):
			if lr is LevelRoot:
				lr.set(&"data", ResourceLoader.load(OS.get_environment("LEVEL_OVERRIDE"), "", ResourceLoader.CACHE_MODE_IGNORE))
				break
	add_child(_zone)
	GameState.set_weather(StringName(OS.get_environment("WEATHER")) if OS.get_environment("WEATHER") != "" else &"misty", 0.0)
	GameState.set_time(10.0)
	# Arriving in rain: soaked at once (DynamicSky starts wet only if it rained on arrival).
	for sky in find_children("*", "WorldEnvironment", true, false):
		if sky.get(&"_wet_started") != null:
			sky.set(&"_wet_started", false)
	_player = (load("res://player/player.tscn") as PackedScene).instantiate()
	_player.set(&"scripted", true)
	add_child(_player)
	_player.global_position = FROM + Vector3.UP
	_player.call(&"face", (TO - FROM).normalized())
	_cam = Camera3D.new()
	_cam.fov = 50
	add_child(_cam)
	Actor.show_debug = false
	var s := OS.get_environment("SHOTS") if OS.get_environment("SHOTS") != "" else "0.8,1.6,2.4,3.0,3.6,3.8,4.1,4.6,5.5,6.5"
	_shots = Array(s.split(",")).map(func(x): return float(x))


func _process(delta: float) -> void:
	_t += delta
	for cam in find_children("*", "Camera3D", true, false):
		if cam != _cam:
			cam.current = false
	_cam.make_current()
	var s := clampf((_t - 0.3) / WALK, 0.0, 1.0)
	var p := FROM.lerp(TO, s)
	# (scripted: nothing holds it up - kept at the height it settled at)
	if _t < 0.3:
		_pin_y = _player.global_position.y
	_player.global_position = Vector3(p.x, _pin_y if _t >= 0.3 else _player.global_position.y, p.z)
	_player.set(&"velocity", (TO - FROM) / WALK if s > 0.0 and s < 1.0 else Vector3.ZERO)
	if OS.get_environment("NOSIM") != "" and _zone.get(&"_mist"):
		_zone.get(&"_mist").set(&"simulate", false)
	if OS.get_environment("BLAST") != "" and not _splashed and _t >= 3.6:
		# BLAST=1: a gust / shockwave beside the player instead of a landing (GroundSim.blast).
		_splashed = true
		GroundSim.blast(get_tree(), _player.global_position + Vector3(1.2, 0, 0), 2.5, 1.0)
	if not _splashed and _t >= 3.6:
		_splashed = true
		var mist = _zone.get(&"_mist")
		if mist:
			mist.call(&"splash", _player, 1.0)
		for sim_name in [&"_grass_sim", &"_ripple_sim"]:
			var sim = _zone.get(sim_name)
			if sim:
				sim.call(&"splash", _player, 1.0)
	# CAM_OFF=x,y,z[,spin deg/s]: the camera's offset from the player (default high behind),
	# turning round them at spin (a pan, for swimming / wobble checks).
	var off := Vector3(0.6, 4.2, 4.6)
	if OS.get_environment("CAM_OFF") != "":
		var o := OS.get_environment("CAM_OFF").split(",")
		off = Vector3(float(o[0]), float(o[1]), float(o[2]))
		if o.size() > 3:
			off = off.rotated(Vector3.UP, deg_to_rad(float(o[3])) * Time.get_ticks_msec() / 1000.0)
	_cam.global_position = _player.global_position + off
	_cam.look_at(_player.global_position + Vector3(0, 0.3, 0))
	if not _shots.is_empty() and _t >= float(_shots[0]):
		var at: float = _shots.pop_front()
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/t_%.1f.png" % [OS.get_environment("OUT"), at])
		if OS.get_environment("DUMP_PRINTS") != "":
			print("print sim ", _zone.get(&"_print_sim"), " mats ", (_zone.get(&"_print_mats") as Dictionary).size())
			var mats: Array[ShaderMaterial] = []
			_zone.call(&"_find_shader_mats", _zone, ["paint_hybrid.gdshader", "paint_merged.gdshader", "paint.gdshader", "paint_unshaded.gdshader"], mats)
			for m in mats:
				var t = m.get_shader_parameter(&"base_tex")
				print("  ", m.shader.resource_path.get_file(), " ", t.resource_path.get_file() if t is Resource else "-", " soft ", m.get_shader_parameter(&"soft_ground"))
			var ps = _zone.get(&"_print_sim")
			if ps:
				var img: Image = ps.texture.get_image()
				var mx := 0.0
				for y in img.get_height():
					for x in img.get_width():
						mx = maxf(mx, img.get_pixel(x, y).b)
				print("  print max b ", mx)
		if OS.get_environment("DUMP_RIPPLE") != "" and _zone.get(&"_ripple_sim"):
			var img: Image = _zone.get(&"_ripple_sim").texture.get_image()
			var mx := 0.0
			for y in img.get_height():
				for x in img.get_width():
					mx = maxf(mx, absf(img.get_pixel(x, y).r))
			print("%.1f ripple max %.3f, player y %.2f" % [at, mx, _player.global_position.y])
		if OS.get_environment("DUMP") != "" and _zone.get(&"_mist"):
			var sim = _zone.get(&"_mist").get(&"sim")
			for k in [["out", sim.texture]] + [["vp0", sim._vp[0].get_texture()], ["vp1", sim._vp[1].get_texture()]]:
				var img: Image = k[1].get_image()
				var mx := 0.0
				for y in range(0, img.get_height(), 4):
					for x in range(0, img.get_width(), 4):
						var c := img.get_pixel(x, y)
						mx = maxf(mx, maxf(absf(c.r), maxf(absf(c.b), absf(c.a))))
				print("%.1f %s %s max %.3f" % [at, k[0], img.get_format(), mx])
		if _shots.is_empty():
			get_tree().quit()
