extends Node3D
## The real player running straight (scripted intent, 60 Hz ticks) with the real follow
## camera, rendered at --fixed-fps N, physics interpolation on (INTERP=1) or off: per drawn
## frame, how evenly the drawn player and the camera move (step length spread: 0 = perfectly
## even) and how much the player jitters on screen. FRAMES=dir also saves frames.
##   ZONE=res://... INTERP=1 tools/godot_run.sh --path . --resolution 960x540 --fixed-fps 144 tests/trees/pacing_player.tscn

var _player: Actor
var _t := 0.0
var _rows := []
var _saved := 0


func _ready() -> void:
	get_tree().physics_interpolation = OS.get_environment("INTERP") == "1"
	process_physics_priority = -10  # (before the player: its intent is set for this tick)
	process_priority = 500  # (after the camera director placed the view)
	var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	add_child(zone)
	GameState.set_time(15.0)
	_player = (load("res://player/player.tscn") as PackedScene).instantiate()
	_player.set(&"scripted", true)
	add_child(_player)
	_player.global_position = Vector3(0, 0.2, 29)
	_player.call(&"face", Vector3.FORWARD)
	_player.reset_physics_interpolation()


func _physics_process(_d: float) -> void:
	_player.intent.move = Vector3.FORWARD if _t > 0.3 else Vector3.ZERO


func _process(d: float) -> void:
	_t += d
	if _t < 1.2:
		return
	for c in get_tree().root.find_children("*", "CanvasLayer", true, false):
		c.visible = false
	var cam := get_viewport().get_camera_3d()
	var drawn := _player.get_global_transform_interpolated().origin
	_rows.append([drawn, cam.global_position, cam.unproject_position(drawn + Vector3.UP)])
	if OS.get_environment("FRAMES") != "":
		var img := get_viewport().get_texture().get_image()
		img.resize(480, 270, Image.INTERPOLATE_BILINEAR)
		img.save_png(OS.get_environment("FRAMES") + "/f%04d.png" % _saved)
		_saved += 1
	if _t >= 2.7:
		_report()
		get_tree().quit()


func _spread(vals: Array) -> Array:
	var m := 0.0
	for v in vals:
		m += v
	m /= maxf(vals.size(), 1)
	var s := 0.0
	for v in vals:
		s += (v - m) * (v - m)
	s = sqrt(s / maxf(vals.size(), 1))
	return [m, s]


func _report() -> void:
	var ps := []
	var cs := []
	var sx := []
	var sy := []
	for i in range(1, _rows.size()):
		ps.append((_rows[i][0] as Vector3).distance_to(_rows[i - 1][0]))
		cs.append((_rows[i][1] as Vector3).distance_to(_rows[i - 1][1]))
		var dsc: Vector2 = _rows[i][2] - _rows[i - 1][2]
		sx.append(dsc.x)
		sy.append(dsc.y)
	var p := _spread(ps)
	var c := _spread(cs)
	var x := _spread(sx)
	var y := _spread(sy)
	print("[pp] interp %s, %d frames: player step %.4f m +- %.4f (spread %.0f%%), camera step %.4f m +- %.4f (spread %.0f%%), player on screen jitter x %.2f px, y %.2f px" % [
		get_tree().physics_interpolation, _rows.size(), p[0], p[1], 100.0 * p[1] / maxf(p[0], 1e-6), c[0], c[1], 100.0 * c[1] / maxf(c[0], 1e-6), x[1], y[1]])
