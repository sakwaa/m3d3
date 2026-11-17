extends Node3D
## Frame pacing: a marker moved in _physics_process (60 Hz ticks, like the player), the
## camera still, rendered at --fixed-fps N (the render rate) with physics interpolation on
## or off. Saves every rendered frame; tools lay them out on a display's refresh timeline.
##   ZONE=res://... OUT=dir DURATION=1.5 [INTERP=1] tools/godot_run.sh --path . --resolution 960x540 --fixed-fps 144 tests/trees/pacing.tscn

var _marker: Node3D
var _cam: Camera3D
var _frame := 0
var _t := 0.0
var _saving := false
var _saved := 0
var _clock := 0.0
const SPEED := 7.0


func _ready() -> void:
	get_tree().physics_interpolation = OS.get_environment("INTERP") == "1"
	var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	add_child(zone)
	GameState.set_time(15.0)
	_cam = Camera3D.new()
	_cam.fov = 60.0
	add_child(_cam)
	_cam.position = Vector3(0, 2.2, 30)
	_cam.look_at(Vector3(0, 1.6, 24))
	_marker = MeshInstance3D.new()
	var m := CapsuleMesh.new()
	m.radius = 0.35
	m.height = 1.6
	(_marker as MeshInstance3D).mesh = m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.35, 0.1)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	(_marker as MeshInstance3D).material_override = mat
	add_child(_marker)
	_marker.position = Vector3(-8, 2.4, 22)


var _ticks := 0


func _physics_process(d: float) -> void:
	# The game's movement: whole 60 Hz ticks (the 30th tick = 0.5 s restarts it, so every
	# render rate sees the same ticks).
	_ticks += 1
	if _ticks == 30:
		_marker.position.x = -8.0
		_marker.reset_physics_interpolation()
		return
	_marker.position.x += SPEED * d
	if _marker.position.x > 8.0:
		_marker.position.x -= 16.0
		_marker.reset_physics_interpolation()


func _process(d: float) -> void:
	_frame += 1
	if _frame == 3:
		for c in get_tree().root.find_children("*", "CanvasLayer", true, false):
			c.visible = false
		for c in get_tree().root.find_children("*", "Camera3D", true, false):
			if c != _cam:
				c.current = false
		_cam.make_current()
	_clock += d
	if not _saving and _clock >= 0.5:
		# Same game time in every run (the marker restarts at its left edge on a physics
		# tick, so each render rate sees the same motion).
		_saving = true
		_t = 0.0
	if _saving:
		var img := get_viewport().get_texture().get_image()
		img.resize(480, 270, Image.INTERPOLATE_BILINEAR)
		img.save_png(OS.get_environment("OUT") + "/f%04d.png" % _saved)
		_saved += 1
		_t += d
		if _t >= float(OS.get_environment("DURATION")):
			print("[pace] frames %d  t %.3f  time_scale %.2f  physics frames %d  delta %.5f" % [_saved, _t, Engine.time_scale, Engine.get_physics_frames(), d])
			get_tree().quit()
