extends Node
## Sandbox archery range check: the player on the mat aims at the 10 m dummy and shoots.
var sb: Node
var t := 0.0
func _ready() -> void:
	sb = (load("res://tests/targeting/sandbox.tscn") as PackedScene).instantiate()
	add_child(sb)
	await get_tree().physics_frame
	var p: Actor = sb.player
	p.global_position = sb.RANGE + Vector3(0, 0.1, 0)
	p.reset_physics_interpolation()
	p.facing = Vector3(-1, 0, 0)
	p.director.yaw.global_rotation.y = atan2(1.0, 0.0)
func _physics_process(d: float) -> void:
	t += d
	var p: Actor = sb.player if sb else null
	if p == null:
		return
	if t > 0.3 and t < 2.4:
		Input.action_press(&"aim")
		var tgt: Node3D = sb.get_node("Range 10 m")
		var to: Vector3 = tgt.global_position + Vector3.UP * 1.0 - (p.global_position + Vector3.UP * 1.45)
		p.director.yaw.global_rotation.y = atan2(-to.x, -to.z)
		p.director.pitch.rotation.x = atan2(to.y, Vector2(to.x, to.z).length())
	if absf(t - 1.4) < d * 0.5:
		Input.action_press(&"attack")
	if absf(t - 1.5) < d * 0.5:
		Input.action_release(&"attack")
	if t > 2.4:
		Input.action_release(&"aim")
		var tgt: Actor = sb.get_node("Range 10 m")
		print("[range] 10 m dummy health %d/%d, sliding dummy at %s" % [tgt.health, tgt.profile.max_health if tgt.profile else -1, sb.get_node("Sliding dummy").global_position])
		if OS.get_environment("OUT") != "":
			get_viewport().get_texture().get_image().save_png(OS.get_environment("OUT"))
		get_tree().quit()
