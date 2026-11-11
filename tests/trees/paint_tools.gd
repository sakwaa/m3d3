extends Node3D
## Grass and Trees paint modes, headless on a copy of a zone: paints a carpet strip (on the
## lane's dirt track too), erases a patch, plants a row of trees, and prints the grass / tree
## counts before and after; renders the result to OUT/paint.png.
##   ZONE=res://...tscn OUT=dir godot --path . tests/trees/paint_tools.tscn


func _ready() -> void:
	var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	var lr: LevelRoot = zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
	lr.data = lr.data.duplicate(false)  # (never saved)
	add_child(zone)
	for i in 30:
		await get_tree().process_frame
	print("before: ", _count(lr))
	var g := LevelGrassTool.new()
	g.height = 0.3
	g.begin(lr, Vector3(0, 0, 18), 1.2, false)
	g.stroke_to(Vector3(0, 0, 8))
	g.end()
	g.begin(lr, Vector3(-5, 0, 26), 1.5, true)
	g.end()
	var t := LevelTreeTool.new()
	t.spacing = 4.0
	t.begin(lr, Vector3(-9, 0, -18), 3.0, false)
	t.stroke_to(Vector3(9, 0, -18))
	t.end()
	for i in 90:
		await get_tree().process_frame
	print("after: ", _count(lr))
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(3, 6, 24)
	cam.look_at(Vector3(0, 0, 8))
	cam.make_current()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OS.get_environment("OUT") + "/paint.png")
	get_tree().quit()


func _count(lr: LevelRoot) -> String:
	var tufts := 0
	var mat := 0
	for n in lr._grass_nodes:
		if n is MeshInstance3D:
			mat += (n.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		elif n is MultiMeshInstance3D and String(n.name).begins_with("Tufts"):
			tufts += n.multimesh.instance_count
	var trees := lr.data.brushes.filter(func(b): return b and b.is_prop() and b.prop.kind == PropSpec.Kind.TREE).size()
	return "carpet %d tris, %d tufts, %d trees" % [mat, tufts, trees]
