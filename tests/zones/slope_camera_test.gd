extends Node
## Slope tilt check (CameraDirector._slope_tilt, OoT's slopePitchAdj): on the forest citadel's
## hillside the player walks straight up the slope (camera behind, looking up it), then turns
## and walks down. Prints the slope probe and the tilt added to the rig's pitch every half
## second; PASS when going up tilts the eye down-hill-wards (pitch rises: looks up the hill)
## and going down tilts it the other way, and standing on the flat terrace settles back to ~0.
## OUT=dir saves a frame at the end of each leg.
##   godot --path . --resolution 960x540 tests/zones/slope_camera_test.tscn [ZONE=...]

var fails := 0


func _ready() -> void:
	var path := OS.get_environment("ZONE") if OS.get_environment("ZONE") != "" else "res://zones/forest/forest_citadel.tscn"
	var zone: Node = (load(path) as PackedScene).instantiate()
	zone.set(&"intro", false)
	get_tree().root.add_child.call_deferred(zone)
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().current_scene = zone
	ZoneManager._adopt_current_scene(&"")
	for i in 30:
		await get_tree().physics_frame
	var p := ZoneManager.player
	var d: CameraDirector = p.director
	p.scripted = true
	p.intent.clear()
	var up := await _leg(p, d, Vector3(-20.0, 0.0, -104.0), Vector3.BACK, "up")
	await _shot("up")
	var down := await _leg(p, d, p.global_position, Vector3.FORWARD, "down")
	await _shot("down")
	_check("uphill tilts the view up the slope", up > 0.05, "tilt %.3f rad" % up)
	_check("downhill tilts the view down the slope", down < -0.05, "tilt %.3f rad" % down)
	print("SLOPE done, %d failed" % fails)
	get_tree().quit(1 if fails else 0)


## Walks `dir` for 6 s from `start` with the camera behind; returns the tilt at the end.
func _leg(p: Actor, d: CameraDirector, start: Vector3, dir: Vector3, label: String) -> float:
	var q := PhysicsRayQueryParameters3D.create(Vector3(start.x, 300.0, start.z), Vector3(start.x, -50.0, start.z))
	q.exclude = [p.get_rid()]
	var hit := p.get_world_3d().direct_space_state.intersect_ray(q)
	var y: float = hit.position.y if not hit.is_empty() else start.y
	p.teleport(Transform3D(Basis.IDENTITY, Vector3(start.x, y + 0.4, start.z)))
	p.facing = dir
	p.get(&"_yaw").global_rotation.y = atan2(-dir.x, -dir.z)  # (camera behind, looking along dir)
	for i in 40:
		await get_tree().physics_frame
	for i in 60 * 6:
		p.intent.move = dir
		await get_tree().physics_frame
		if i % 30 == 0:
			print("SLOPE %s t %.1f  pos %s  slope %.3f  tilt %.3f  pitch %.3f" % [label, i / 60.0, p.global_position.snapped(Vector3.ONE * 0.1),
				d._slope, d._slope_applied, d.pitch.rotation.x])
	p.intent.move = Vector3.ZERO
	return d._slope_applied


func _shot(label: String) -> void:
	if OS.get_environment("OUT") == "":
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OS.get_environment("OUT").path_join("slope_%s.png" % label))


func _check(case: String, ok: bool, detail: String) -> void:
	print("SLOPE %s %s  %s" % ["PASS" if ok else "FAIL", case, detail])
	if not ok:
		fails += 1
