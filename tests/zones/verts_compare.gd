extends Node
## Compares every brush's vertices between two level files (A, B): how many brushes differ.


func _ready() -> void:
	var a: LevelData = ResourceLoader.load(OS.get_environment("A"), "", ResourceLoader.CACHE_MODE_IGNORE)
	var b: LevelData = ResourceLoader.load(OS.get_environment("B"), "", ResourceLoader.CACHE_MODE_IGNORE)
	var diff := 0
	for i in mini(a.brushes.size(), b.brushes.size()):
		if a.brushes[i] and b.brushes[i] and a.brushes[i].vertices != b.brushes[i].vertices:
			diff += 1
	print("%s: %d brushes with different vertices (of %d)" % [OS.get_environment("A").get_file(), diff, a.brushes.size()])
	get_tree().quit()
