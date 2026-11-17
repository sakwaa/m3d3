extends Node3D
## Wind check: a zone in a strong gusty wind, frames for a GIF. OLD=1: tufts / carpet / trees
## on the shaders in tests/tmp/old_wind (before the shared gust field).
##   ZONE=res://... OUT=dir CAM=x,y,z LOOK=x,y,z [FRAMES=40] [EVERY=2] [OLD=1]
##   [START=frame to begin saving] [ORBIT=degrees a second round LOOK] (with --fixed-fps,
##   time is exact: renders at different rates line up)
##   tools/godot_run.sh --path . --resolution 960x540 --fixed-fps 20 tests/trees/wind_gif.tscn

var _cam: Camera3D
var _frame := 0
var _wind := Vector4.ZERO
var _t := 0.0
var _cam0 := Vector3.ZERO
var _look := Vector3.ZERO


func _ready() -> void:
	process_priority = 1000  # (after DynamicSky: our wind wins)
	var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	add_child(zone)
	GameState.set_time(15.0)
	var a := deg_to_rad(float(zone.get(&"wind_direction")) if zone.get(&"wind_direction") != null else 30.0)
	_wind = Vector4(cos(a), -sin(a), 0.85, 0.9)
	_cam = Camera3D.new()
	_cam.fov = 60.0
	add_child(_cam)
	_cam0 = _vec(OS.get_environment("CAM"))
	_look = _vec(OS.get_environment("LOOK"))
	_cam.position = _cam0
	_cam.look_at(_look)


func _vec(s: String) -> Vector3:
	var p := s.split(",")
	return Vector3(float(p[0]), float(p[1]), float(p[2]))


func _process(d: float) -> void:
	RenderingServer.global_shader_parameter_set(&"n64_wind", _wind)
	_frame += 1
	_t += d
	if OS.get_environment("ORBIT") != "":
		var off := (_cam0 - _look).rotated(Vector3.UP, deg_to_rad(float(OS.get_environment("ORBIT")) * _t))
		_cam.position = _look + off
		_cam.look_at(_look)
	if _frame == 3:
		for c in get_tree().root.find_children("*", "CanvasLayer", true, false):
			c.visible = false
		for c in get_tree().root.find_children("*", "Camera3D", true, false):
			if c != _cam:
				c.current = false
		_cam.make_current()
		var kinds := {}
		for g in get_tree().root.find_children("*", "GeometryInstance3D", true, false):
			var gi := g as GeometryInstance3D
			var mats := []
			if gi.material_override:
				mats.append(gi.material_override)
			elif gi is MeshInstance3D and (gi as MeshInstance3D).mesh:
				for si in (gi as MeshInstance3D).mesh.get_surface_count():
					mats.append((gi as MeshInstance3D).get_active_material(si))
			for m in mats:
				if m is ShaderMaterial and m.shader:
					var f: String = m.shader.resource_path.get_file()
					kinds[f] = kinds.get(f, 0) + 1
					if OS.get_environment("OLD") != "" and f.get_basename() in ["n64_grass_tuft", "n64_tree", "n64_grass_mat"]:
						m.shader = load("res://tests/tmp/old_wind/" + f)
		print("[wind] shaders: ", kinds)
	var every := int(OS.get_environment("EVERY")) if OS.get_environment("EVERY") != "" else 2
	var frames := int(OS.get_environment("FRAMES")) if OS.get_environment("FRAMES") != "" else 40
	var start := int(OS.get_environment("START")) if OS.get_environment("START") != "" else 20
	if _frame >= start and (_frame - start) % every == 0:
		var k := (_frame - start) / every
		if k >= frames:
			get_tree().quit()
			return
		var img := get_viewport().get_texture().get_image()
		img.resize(640, int(640.0 * img.get_height() / img.get_width()), Image.INTERPOLATE_BILINEAR)
		img.save_png(OS.get_environment("OUT") + "/f%03d.png" % k)
