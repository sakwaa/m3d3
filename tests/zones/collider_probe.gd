extends Node
## Brushes of a level (LEVEL) that collide but aren't drawn, or are props, within RADIUS of
## the middle (x, z): tag, kind, bake mode, centre and size.


func _ready() -> void:
	var d: LevelData = ResourceLoader.load(OS.get_environment("LEVEL"), "", ResourceLoader.CACHE_MODE_IGNORE)
	var r := float(OS.get_environment("RADIUS")) if OS.get_environment("RADIUS") != "" else 25.0
	for b: LevelBrush in d.brushes:
		if b == null:
			continue
		var aabb := b.transform * b.local_aabb()
		var c := aabb.get_center()
		if Vector2(c.x, c.z).length() > r:
			continue
		var kind := "prop:%s" % PropSpec.Kind.keys()[b.prop.kind] if b.is_prop() else ("house" if b.is_house() else ("fence" if b.is_fence() else ("opening" if b.opening_spec() else "brush shape %d" % b.shape)))
		if b.is_house():
			continue
		var bake_faces := {}
		for f in b.get_face_count():
			var k := b.face_bake[f] if f < b.face_bake.size() else 0
			bake_faces[k] = bake_faces.get(k, 0) + 1
		print("%-22s %-22s bake_mode %d faces by bake %s centre %s size %s" % [b.tag, kind, b.bake_mode, bake_faces, c.snapped(Vector3.ONE * 0.1), aabb.size.snapped(Vector3.ONE * 0.1)])
	get_tree().quit()
