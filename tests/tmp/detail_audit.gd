extends SceneTree
## Which textures the market's brush faces use, and whether each has a detail texture
## (N64Texture lod_mode 2 + detail_texture). Read only.
##   godot --headless --path . -s res://tests/tmp/detail_audit.gd [-- ZONE=res://...]

func _init() -> void:
	var zone_path := "res://zones/town1/town_1_market_square.tscn"
	var zone: Node = (load(zone_path) as PackedScene).instantiate()
	var roots := zone.find_children("*", "LevelRoot", true, false)
	if roots.is_empty():
		for c in zone.find_children("*", "", true, false):
			if c.get(&"data") != null and c.get(&"data").get(&"brushes") != null:
				roots.append(c)
	for lr in roots:
		var data: Resource = lr.get(&"data")
		var texs: Array = data.get(&"textures")
		var faces := {}  # tex index -> face count
		var brushes := {}  # tex index -> brush count
		var nb := 0
		for b in data.get(&"brushes"):
			nb += 1
			var seen := {}
			var ft: PackedInt32Array = b.get(&"face_textures")
			var nf: int = (b.get(&"face_counts") as PackedInt32Array).size() if b.get(&"face_counts") != null else ft.size()
			for f in maxi(nf, ft.size()):
				var t: int = ft[f] if f < ft.size() else -1
				faces[t] = int(faces.get(t, 0)) + 1
				seen[t] = true
			for t in seen:
				brushes[t] = int(brushes.get(t, 0)) + 1
		print("LevelRoot %s: %d brushes, %d textures" % [lr.name, nb, texs.size()])
		var keys := faces.keys()
		keys.sort_custom(func(a, b): return faces[a] > faces[b])
		for t in keys:
			var name := "(none: brush material / neutral)"
			var det := "-"
			if t >= 0 and t < texs.size() and texs[t]:
				var tx: Texture2D = texs[t]
				name = tx.resource_path.get_file() if tx.resource_path != "" else str(tx)
				var lod = tx.get(&"lod_mode")
				var dt = tx.get(&"detail_texture")
				det = ("DETAIL " + (dt as Resource).resource_path.get_file()) if lod == 2 and dt else ("lod_mode %s" % lod if lod != null else "not N64Texture")
			print("  %5d faces %4d brushes  %-40s %s" % [faces[t], brushes[t], name, det])
	quit()
