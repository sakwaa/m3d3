extends Node
## Compares two builds of a level (A, B: .res from tests/zones/build_bake.tscn): per house
## brush (matched by tag), the area covered by each texture and each corner colour, and
## lists brushes where they differ (a face that came out of the Blender pass with another
## texture or colour).  A=... B=... godot --headless --path . tests/zones/face_diff.tscn


func _ready() -> void:
	var a: LevelData = ResourceLoader.load(OS.get_environment("A"), "", ResourceLoader.CACHE_MODE_IGNORE)
	var b: LevelData = ResourceLoader.load(OS.get_environment("B"), "", ResourceLoader.CACHE_MODE_IGNORE)
	var sa := _summary(a)
	var sb := _summary(b)
	var diffs := 0
	for tag in sa:
		if not sb.has(tag):
			continue
		var ta: Dictionary = sa[tag]
		var tb: Dictionary = sb[tag]
		for k in ta.keys() + tb.keys():
			var x: float = ta.get(k, 0.0)
			var y: float = tb.get(k, 0.0)
			if absf(x - y) > 0.05 * maxf(x, y) + 0.05:
				diffs += 1
				print("%s  %-60s A %.2f m2  B %.2f m2" % [tag, k, x, y])
	print("differences: ", diffs)
	get_tree().quit()


func _summary(d: LevelData) -> Dictionary:
	var out := {}
	for br in d.brushes:
		if br == null or br.is_prop():
			continue
		var m := {}
		var faces := br.get_faces()
		var corner := 0
		for f in faces.size():
			var ids: PackedInt32Array = faces[f]
			var pts := PackedVector3Array()
			for v in ids:
				pts.append(br.vertices[v])
			var nv := Vector3.ZERO  # (Newell's vector: its length is twice the polygon's area)
			for k in pts.size():
				var p0 := pts[k]
				var p1 := pts[(k + 1) % pts.size()]
				nv += Vector3((p0.y - p1.y) * (p0.z + p1.z), (p0.z - p1.z) * (p0.x + p1.x), (p0.x - p1.x) * (p0.y + p1.y))
			var area := nv.length() * 0.5
			var ti := br.get_face_texture(f)
			var tex: String = d.textures[ti].resource_path.get_file() if ti >= 0 and ti < d.textures.size() and d.textures[ti] else "none"
			var key := tex  # (colour isn't compared: a merged face's corners come from several)
			m[key] = m.get(key, 0.0) + area
			corner += ids.size()
		out[br.tag] = m
	return out
