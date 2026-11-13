extends Node
## Where a level's house triangles come from: per house, the faces HouseBuilder makes, what
## the level stores (after relights / cuts), how many of those carry overlay paint (the trim:
## the Blender dissolve leaves painted faces alone), and what the dissolve leaves. Never saves.
##   LEVEL=res://...res [N=5] godot --headless --path . tests/zones/house_density.tscn


func _ready() -> void:
	var data: LevelData = (load(OS.get_environment("LEVEL")) as LevelData).duplicate(true)
	var houses := data.brushes.filter(func(b): return b != null and b.is_house())
	var n := int(OS.get_environment("N")) if OS.get_environment("N") != "" else 5
	var stored := {}
	var totals := {built = 0, stored = 0, painted_faces = 0, faces = 0}
	for h: LevelBrush in houses:
		var built := 0
		for f in HouseBuilder.build(h.house):
			if f.get("bake", 0) != 2:
				built += f.pts.size() - 2
		var tris := _tris(h)
		var painted := _painted(h)
		stored[h] = tris
		totals.built += built
		totals.stored += tris
		totals.painted_faces += painted
		totals.faces += h.get_face_count()
		if houses.find(h) < n:
			print("%s %.0fx%.0f s%d shop %s: built %d tris, stored %d tris in %d faces (%d painted)" % [h.tag, h.house.width, h.house.depth,
				h.house.storeys, h.house.shopfront, built, tris, h.get_face_count(), painted])
	print("ALL %d houses: built %d, stored %d tris, faces %d (%d painted)" % [houses.size(), totals.built, totals.stored, totals.faces, totals.painted_faces])
	var r := BlenderDissolve.dissolve(data)
	var after := 0
	for h in houses:
		after += _tris(h)
	print("after dissolve: %d tris (%s)" % [after, r.get("error", "ok")])
	for h in houses.slice(0, n):
		print("  %s: %d -> %d" % [h.tag, stored[h], _tris(h)])
	get_tree().quit()


func _tris(b: LevelBrush) -> int:
	var t := 0
	for f in b.get_faces():
		t += f.size() - 2
	return t


func _painted(b: LevelBrush) -> int:
	var faces := {}
	for k: Vector2i in b.face_masks:
		faces[k.x] = true
	return faces.size()
