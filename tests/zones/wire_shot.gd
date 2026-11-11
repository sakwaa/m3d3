extends Node3D
## Wireframe overlay check (DebugHud F10's WireframeView): a zone from a set camera with the
## overlay on, in the given mode.  ZONE=res://... CAM=x,y,z LOOK=x,y,z [MODE=0|1] OUT=dir
##   godot --path . --resolution 1280x720 tests/zones/wire_shot.tscn

var _frames := 0


func _ready() -> void:
	var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	if OS.get_environment("LEVEL_OVERRIDE") != "":
		var lr: Node = zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
		lr.set(&"data", ResourceLoader.load(OS.get_environment("LEVEL_OVERRIDE"), "", ResourceLoader.CACHE_MODE_IGNORE))
	add_child(zone)
	var cam := Camera3D.new()
	cam.fov = 60
	add_child(cam)
	var c := OS.get_environment("CAM").split(",")
	var l := OS.get_environment("LOOK").split(",")
	cam.position = Vector3(float(c[0]), float(c[1]), float(c[2]))
	cam.look_at(Vector3(float(l[0]), float(l[1]), float(l[2])))
	cam.make_current()
	GameState.set_time(15.0)
	var w := WireframeView.new()
	add_child(w)
	w.mode = int(OS.get_environment("MODE")) if OS.get_environment("MODE") != "" else 0


func _process(_delta: float) -> void:
	_frames += 1
	if _frames == 30:
		get_viewport().get_texture().get_image().save_png(OS.get_environment("OUT") + "/wire.png")
		get_tree().quit()
