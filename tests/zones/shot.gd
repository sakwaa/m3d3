extends Node3D
## Renders a zone from a set camera (to compare with its reference photo) and quits.
##   ZONE=res://... CAM=x,y,z LOOK=x,y,z [FOV=50] [HOUR=15] [NOFOG=1] [PLAYER=x,y,z[,yaw]]
##   [WEATHER=rainy] [RAIN_OLD=1] [GRADE=1: tests/zones/grade.gd] OUT=dir godot --path . --resolution 1280x960 tests/zones/shot.tscn

var _frames := 0


func _ready() -> void:
	if OS.get_environment("GRADE") != "":
		preload("res://tests/zones/grade.gd").apply_globals()
	if OS.get_environment("TEXWS") != "":
		preload("res://tests/zones/grade.gd").apply_textures()
	var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	if OS.get_environment("NOFOG") != "":
		# Overhead / far shots: no fog, no clipping at the fog's end.
		zone.set(&"fog", null)
		zone.set(&"clip_at_fog_end", false)
	if OS.get_environment("LEVEL_OVERRIDE") != "":
		# LEVEL_OVERRIDE=path.res: the zone's level data swapped for another (a test bake).
		var lr: Node = zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
		lr.set(&"data", ResourceLoader.load(OS.get_environment("LEVEL_OVERRIDE"), "", ResourceLoader.CACHE_MODE_IGNORE))
	add_child(zone)
	if OS.get_environment("PLAYER") != "":
		# PLAYER=x,y,z[,yaw]: the player standing there (scripted, idle).
		var pp := OS.get_environment("PLAYER").split(",")
		var player: Node3D = (load("res://player/player.tscn") as PackedScene).instantiate()
		player.set(&"scripted", true)
		add_child(player)
		player.global_position = Vector3(float(pp[0]), float(pp[1]), float(pp[2]))
		if pp.size() > 3:
			player.call(&"face", Vector3.FORWARD.rotated(Vector3.UP, deg_to_rad(float(pp[3]))))
	var cam := Camera3D.new()
	cam.name = "ShotCam"
	cam.fov = float(OS.get_environment("FOV")) if OS.get_environment("FOV") != "" else 50.0
	add_child(cam)
	cam.position = _vec(OS.get_environment("CAM"))
	cam.look_at(_vec(OS.get_environment("LOOK")))
	cam.make_current()
	GameState.set_time(float(OS.get_environment("HOUR")) if OS.get_environment("HOUR") != "" else 15.0)
	if OS.get_environment("WEATHER") != "":
		GameState.set_weather(StringName(OS.get_environment("WEATHER")), 0.0)
	if OS.get_environment("RAIN_OLD") != "":
		# The rain as it was (2400 streaks in the shader's default box, no far sheet).
		for r in zone.find_children("*", "Rain", true, false) + _all(zone).filter(func(n): return n is Rain):
			r.mesh = Rain.make_mesh(2400)
			(r.material_override as ShaderMaterial).set_shader_parameter(&"box", Vector3(56, 20, 56))
			for c in r.get_children(true):
				if c.name == "Sheet":
					c.visible = false
	Actor.show_debug = false


func _vec(s: String) -> Vector3:
	var p := s.split(",")
	return Vector3(float(p[0]), float(p[1]), float(p[2]))


func _process(_delta: float) -> void:
	_frames += 1
	if _frames == 3:
		for c in find_children("*", "Camera3D", true, false):
			if c.name != "ShotCam":
				c.current = false
		(get_node("ShotCam") as Camera3D).make_current()
	if _frames == 40:
		get_viewport().get_texture().get_image().save_png(OS.get_environment("OUT") + "/shot.png")
		get_tree().quit()


func _all(n: Node) -> Array:
	var out := []
	for c in n.get_children(true):
		out.append(c)
		out.append_array(_all(c))
	return out
