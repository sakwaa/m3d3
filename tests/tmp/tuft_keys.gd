extends Node
## Prints a few tufts' packed light keys (INSTANCE_CUSTOM) from a zone's grass, unpacked.
func _ready() -> void:
	var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	add_child(zone)
	for i in 240:
		await get_tree().process_frame
	var n := 0
	for mmi in zone.find_children("*", "MultiMeshInstance3D", true, false):
		var mm: MultiMesh = mmi.multimesh
		if mm == null or not mm.use_custom_data or mm.instance_count == 0:
			continue
		for k in [0, mm.instance_count / 2]:
			var c := mm.get_instance_custom_data(k)
			var out := []
			for v in [c.r, c.g, c.b, c.a]:
				var x := int(v + 0.5)
				out.append("%d,%d,%d" % [x / 65536, (x / 256) % 256, x % 256])
			print("TUFT ", mmi.name, " ", mm.instance_count, " raw ", c, " -> ", out)
		n += 1
		if n > 6:
			break
	print("TUFT done ", n)
	get_tree().quit()
