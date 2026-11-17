extends Node3D
## Runs the player through a zone along waypoints with the game's own camera following, and
## records it: every frame (half size, JPEG) to OUT/frames/, full-size PNG stills every
## STILL_EVERY frames to OUT/stills/. Run with --fixed-fps 30 so no frame is dropped.
##   ZONE=res://... [LEVEL_OVERRIDE=bake.res] HOUR=13 ROUTE="x,z;x,z;..." START=x,y,z OUT=dir
##   [SECONDS=14] [WEATHER=sunny] godot --path . --resolution 1920x1080 --fixed-fps 30 tests/render/town_run.tscn
const STILL_EVERY := 60

var _p: Actor
var _route: Array[Vector3] = []
var _i := 0
var _frame := 0
var _stuck := 0.0
var _last := Vector3.ZERO
var _out := ""
var _seconds := 14.0


func _ready() -> void:
	_out = OS.get_environment("OUT")
	DirAccess.make_dir_recursive_absolute(_out + "/frames")
	DirAccess.make_dir_recursive_absolute(_out + "/stills")
	if OS.get_environment("SECONDS") != "":
		_seconds = float(OS.get_environment("SECONDS"))
	var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	if OS.get_environment("LEVEL_OVERRIDE") != "":
		var lr: Node = zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
		lr.set(&"data", ResourceLoader.load(OS.get_environment("LEVEL_OVERRIDE"), "", ResourceLoader.CACHE_MODE_IGNORE))
	add_child(zone)
	for wp in OS.get_environment("ROUTE").split(";"):
		var v := wp.split(",")
		_route.append(Vector3(float(v[0]), 0.0, float(v[1])))
	var s := OS.get_environment("START").split(",")
	_p = (load("res://player/player.tscn") as PackedScene).instantiate()
	_p.scripted = true
	add_child(_p)
	_p.global_position = Vector3(float(s[0]), float(s[1]), float(s[2]))
	var d := (_route[0] - _p.global_position) * Vector3(1, 0, 1)
	_p.call(&"face", d.normalized())
	(_p.get(&"_yaw") as Node3D).rotation.y = atan2(-d.x, -d.z)
	_last = _p.global_position
	GameState.set_time(float(OS.get_environment("HOUR")) if OS.get_environment("HOUR") != "" else 13.0)
	if OS.get_environment("WEATHER") != "":
		GameState.set_weather(StringName(OS.get_environment("WEATHER")), 0.0)
	for h in get_tree().root.find_children("*", "DebugHud", true, false):
		h.queue_free()


func _physics_process(delta: float) -> void:
	if _i >= _route.size():
		_p.intent.move = Vector3.ZERO
		return
	var to := (_route[_i] - _p.global_position) * Vector3(1, 0, 1)
	if to.length() < 1.2:
		_i += 1
		_stuck = 0.0
		return
	var dir := to.normalized()
	_p.intent.move = dir
	_p.intent.stick = Vector2(0, 1)
	# A player keeping the camera behind the run (the stick's job, roughly).
	var yaw := _p.get(&"_yaw") as Node3D
	yaw.rotation.y = lerp_angle(yaw.rotation.y, atan2(-dir.x, -dir.z), clampf(1.6 * delta, 0.0, 1.0))
	_stuck = _stuck + delta if _p.global_position.distance_to(_last) < 0.02 else 0.0
	_last = _p.global_position
	if _stuck > 0.8:
		print("[town_run] stuck before waypoint %d: skipped" % _i)
		_i += 1
		_stuck = 0.0


func _process(_delta: float) -> void:
	for l in _p.find_children("*", "Label3D", true, false):
		l.visible = false  # (the actor debug label)
	_frame += 1
	if _frame < 20:
		return  # (settling: streaming, sky)
	var n := _frame - 20
	if n > int(_seconds * 30.0):
		get_tree().quit()
		return
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if n % STILL_EVERY == 0:
		img.save_png("%s/stills/%04d.png" % [_out, n])
	img.resize(img.get_width() / 2, img.get_height() / 2, Image.INTERPOLATE_BILINEAR)
	img.save_jpg("%s/frames/%04d.jpg" % [_out, n], 0.9)
