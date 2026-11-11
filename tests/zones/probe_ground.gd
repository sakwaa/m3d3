extends Node
## Prints a level's ground: brushes with upward faces, their textures (by face count and
## area), paint layers and scatter sets.  LEVEL=res://..._level.res godot --headless --path . tests/zones/probe_ground.tscn


func _ready() -> void:
	var d: LevelData = load(OS.get_environment("LEVEL"))
	print("palette:")
	for i in d.textures.size():
		var t = d.textures[i]
		var info := ""
		if t and t.resource_path.contains("::"):
			info = t.get_class() + " " + str(t.get_script().resource_path if t.get_script() else "")
			for pr in t.get_property_list():
				if pr.usage & PROPERTY_USAGE_STORAGE and t.get(pr.name) is Resource and t.get(pr.name).resource_path != "":
					info += " %s=%s" % [pr.name, t.get(pr.name).resource_path]
		print("  %d %s %s" % [i, t.resource_path if t else "null", info])
	var area := {}
	var grounds := 0
	for b in d.brushes:
		if b == null or b.is_prop() or b.house or b.is_fence() or b.is_rope():
			continue
		var faces := b.get_faces()
		var up := 0.0
		for f in faces.size():
			var ids: PackedInt32Array = faces[f]
			var p := []
			for i in ids:
				p.append(b.transform * b.vertices[i])
			var n: Vector3 = (p[1] - p[0]).cross(p[2] - p[0])
			if n.normalized().y < 0.7:
				continue
			var a := 0.0
			for k in range(1, p.size() - 1):
				a += (p[k] - p[0]).cross(p[k + 1] - p[0]).length() * 0.5
			var t := b.get_face_texture(f)
			area[t] = area.get(t, 0.0) + a
			up += a
		if up > 50.0:
			grounds += 1
			print("ground brush %s shape %d at %s size %s up-area %.0f faces %d" % [b.tag, b.shape, b.transform.origin, b.size, up, faces.size()])
	print("up-facing area by texture: ", area)
	# GROUND_JSON=path: every up-facing ground face as [texture, [x, z, ...]] (level space).
	if OS.get_environment("GROUND_JSON") != "":
		var out := []
		for b in d.brushes:
			if b == null or b.is_prop() or b.house or b.is_fence() or b.is_rope():
				continue
			var faces := b.get_faces()
			for f in faces.size():
				var ids: PackedInt32Array = faces[f]
				var p := []
				for i in ids:
					p.append(b.transform * b.vertices[i])
				if ((p[1] - p[0]).cross(p[2] - p[0])).normalized().y < 0.7:
					continue
				var xz := []
				for v in p:
					xz.append_array([snappedf(v.x, 0.01), snappedf(v.z, 0.01)])
				out.append([b.get_face_texture(f), xz, snappedf(p[0].y, 0.01)])
		var fh := FileAccess.open(OS.get_environment("GROUND_JSON"), FileAccess.WRITE)
		fh.store_string(JSON.stringify(out))
		fh.close()
	print("paint layers: ", d.get(&"layers") if d.get(&"layers") != null else "?")
	for prop in ["layers", "paint_layers", "layer_set"]:
		if d.get(prop) != null:
			print(prop, " = ", d.get(prop))
	for l in d.layers:
		if l:
			var props := []
			for pr in l.get_property_list():
				if pr.usage & PROPERTY_USAGE_STORAGE and pr.name not in ["script", "resource_local_to_scene", "resource_path", "resource_name"]:
					var v = l.get(pr.name)
					props.append("%s=%s" % [pr.name, (v.resource_path if v is Resource else str(v).left(60))])
			print("  layer: ", ", ".join(props))
	var masked := {}
	for b in d.brushes:
		if b and not b.face_masks.is_empty():
			masked[b.tag] = b.face_masks.size()
	print("brushes with face masks: ", masked)
	print("scatter sets: ", d.scatter.size())
	for s in d.scatter:
		if s:
			print("  ", s.texture.resource_path if s.texture else "-", " style ", s.style, " size ", s.size)
	get_tree().quit()
