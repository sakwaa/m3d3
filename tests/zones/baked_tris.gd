extends Node
## Triangles in a level file's stored bake (its chunks, else its baked mesh), no re-bake.
##   LEVELS=a.res,b.res godot --headless --path . tests/zones/baked_tris.tscn


func _ready() -> void:
	for path in OS.get_environment("LEVELS").split(","):
		var d: LevelData = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		var meshes: Array = []
		if not d.baked_chunks.is_empty():
			meshes.append_array(d.baked_chunks)
		elif d.baked_mesh:
			meshes.append(d.baked_mesh)
		var tris := 0
		for m in meshes:
			if m is Mesh:
				for s in m.get_surface_count():
					var a: Array = m.surface_get_arrays(s)
					var idx = a[Mesh.ARRAY_INDEX]
					tris += (idx.size() if idx != null else (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
		print("%s: %d baked triangles (%d meshes)" % [path.get_file(), tris, meshes.size()])
	get_tree().quit()
