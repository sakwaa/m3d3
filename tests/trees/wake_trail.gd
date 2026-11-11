extends Node3D
## Grass wading trail: walks the player across a zone's carpet (scripted), then renders the
## trail of rings behind them.  ZONE=res://... FROM=x,z TO=x,z CAM=x,y,z OUT=dir [AT=0.6]
##   godot --path . --resolution 1280x720 tests/trees/wake_trail.tscn
## AT: when to shoot, as a share of the walk (1 = just arrived).

var _player: Node3D
var _cam: Camera3D
var _from := Vector3.ZERO
var _to := Vector3.ZERO
var _t := 0.0
var _walk := 1.6
var _shot_at := 1.0
var _shot := false


func _ready() -> void:
	var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	add_child(zone)
	var f := OS.get_environment("FROM").split(",")
	var t := OS.get_environment("TO").split(",")
	_from = Vector3(float(f[0]), 0.0, float(f[1]))
	_to = Vector3(float(t[0]), 0.0, float(t[1]))
	_shot_at = float(OS.get_environment("AT")) if OS.get_environment("AT") != "" else 1.0
	_player = (load("res://player/player.tscn") as PackedScene).instantiate()
	_player.set(&"scripted", true)
	add_child(_player)
	_player.global_position = _from
	_player.call(&"face", (_to - _from).normalized())
	_cam = Camera3D.new()
	_cam.name = "ShotCam"
	_cam.fov = 55
	add_child(_cam)
	var c := OS.get_environment("CAM").split(",")
	_cam.position = Vector3(float(c[0]), float(c[1]), float(c[2]))
	GameState.set_time(15.0)
	Actor.show_debug = false


func _process(delta: float) -> void:
	_t += delta
	for cam in find_children("*", "Camera3D", true, false):
		if cam != _cam:
			cam.current = false
	_cam.make_current()
	var s := clampf((_t - 0.5) / _walk, 0.0, 1.0)  # half a second to settle, then walk
	var p := _from.lerp(_to, s)
	_player.global_position = Vector3(p.x, _player.global_position.y, p.z)
	_player.set(&"velocity", (_to - _from) / _walk if s < 1.0 else Vector3.ZERO)
	if OS.get_environment("TOPDOWN") != "":
		_cam.global_position = Vector3(p.x + 0.5, 3.0, p.z + 0.6)
	_cam.look_at(Vector3(p.x, 0.3, p.z))
	if not _shot and s >= _shot_at:
		_shot = true
		var wake := _player.get_node_or_null("GrassWake")
		if wake:
			var opens := []
			for r in wake.get(&"_rings"):
				opens.append(snappedf(r.open, 0.01))
			print("rings %d, open: %s" % [opens.size(), opens])
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(OS.get_environment("OUT") + "/trail.png")
		get_tree().quit()
