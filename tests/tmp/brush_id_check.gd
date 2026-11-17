extends Node
## Lists, per zone, how many level-mesh vertices carry a brush ID (light key 0 alpha 1..7) vs none.
##   ZONES="res://a.tscn;res://b.tscn" godot --headless --path . tests/tmp/brush_id_check.tscn

func _ready() -> void:
	for path in OS.get_environment("ZONES").split(";"):
		var zone: Node = (load(path) as PackedScene).instantiate()
		if OS.get_environment("LEVEL_OVERRIDE") != "":
			var lr: Node = zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
			lr.set(&"data", ResourceLoader.load(OS.get_environment("LEVEL_OVERRIDE"), "", ResourceLoader.CACHE_MODE_IGNORE))
		add_child(zone)
		await get_tree().process_frame
		await get_tree().process_frame
		var hist := {}
		var meshes := 0
		for mi in zone.find_children("*", "MeshInstance3D", true, false):
			var m: Mesh = (mi as MeshInstance3D).mesh
			if not (m is ArrayMesh):
				continue
			for s in m.get_surface_count():
				var fmt := (m as ArrayMesh).surface_get_format(s)
				if not (fmt & Mesh.ARRAY_FORMAT_CUSTOM0):
					continue
				var arr := m.surface_get_arrays(s)
				var c0 = arr[Mesh.ARRAY_CUSTOM0]
				if not (c0 is PackedByteArray):
					continue
				meshes += 1
				var b: PackedByteArray = c0
				var mat: Material = (mi as MeshInstance3D).get_active_material(s)
				var sh := "?"
				if mat is ShaderMaterial and (mat as ShaderMaterial).shader:
					sh = (mat as ShaderMaterial).shader.resource_path.get_file().get_basename()
				for i in range(3, b.size(), 4):
					var a := b[i]
					var k := sh + (":none" if a == 0 or a > 7 else ":id")
					if (a == 0 or a > 7) and sh == "paint_hybrid":
						k += " mesh=" + m.resource_path + "|" + m.resource_name + " node=" + String(mi.name) + " parent=" + String(mi.get_parent().name) + " decal_depth=" + str(mat.get_shader_parameter(&"decal_depth")) + " script=" + (String(mi.get_script().resource_path.get_file()) if mi.get_script() else "-")
					hist[k] = hist.get(k, 0) + 1
		print(path.get_file(), ": surfaces with keys ", meshes, " ", hist)
		zone.queue_free()
	get_tree().quit()
