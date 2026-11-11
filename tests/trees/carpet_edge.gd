extends Node
## Finds where a zone's carpet ends going from FROM=x,z along WAY=x,z (GrassField.surface_at):
## prints the last point with carpet.  ZONE=res://...tscn


func _ready() -> void:
	var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	add_child(zone)
	for i in 90:
		await get_tree().process_frame
	var f := OS.get_environment("FROM").split(",")
	var w := OS.get_environment("WAY").split(",")
	var p := Vector3(float(f[0]), 0.0, float(f[1]))
	var way := Vector3(float(w[0]), 0.0, float(w[1])).normalized()
	var last := Vector3.INF
	for i in 400:
		var q := p + way * i * 0.05
		var h := GrassField.top_at(q + Vector3.UP * 0.05)
		var field := GrassField.at(q + Vector3.UP * 0.05)
		var s := field.surface_at(q) if field else -INF
		if s == -INF:
			print("carpet ends after %s (%.2f m)" % [last, i * 0.05])
			break
		last = Vector3(q.x, s, q.z)
	get_tree().quit()
