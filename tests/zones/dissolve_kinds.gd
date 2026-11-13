extends Node
## Blender's limited dissolve (BlenderDissolve) on a copy of a level's data, triangles before
## and after by brush kind (windows, houses, the rest). Never saves.
##   LEVEL=res://...res godot --headless --path . tests/zones/dissolve_kinds.tscn


func _ready() -> void:
	var data: LevelData = (load(OS.get_environment("LEVEL")) as LevelData).duplicate(true)
	var before := _count(data)
	var r := BlenderDissolve.dissolve(data)
	if r.has("error"):
		print(r.error)
	var after := _count(data)
	for k in before:
		print("%-8s %6d -> %6d tris" % [k, before[k], after.get(k, 0)])
	get_tree().quit()


func _count(data: LevelData) -> Dictionary:
	var out := {window = 0, house = 0, door = 0, other = 0}
	for b: LevelBrush in data.brushes:
		if b == null or b.is_prop() or b.is_fence() or b.is_rope():
			continue
		var k := "window" if b.is_window() else ("house" if b.is_house() else ("door" if b.is_door() else "other"))
		for f in b.get_faces():
			out[k] += f.size() - 2
	return out
