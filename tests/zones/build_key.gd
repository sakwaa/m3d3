extends Node
## Build cache checks for a zone: its build key twice (must match), after a brush moves
## (must change), whether it counts as a zone with levels, the zones its exits lead to, and
## whether its stored bake is a current build.
##   ZONE=res://... godot --headless --path . tests/zones/build_key.tscn
const BuildCache := preload("res://addons/n64_level_tools/export/build_cache.gd")
const ZoneLinks := preload("res://addons/n64_level_tools/zone_links.gd")


func _ready() -> void:
	var path := OS.get_environment("ZONE")
	var scene: Node = (load(path) as PackedScene).instantiate()
	var root: LevelRoot = scene.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
	var t := Time.get_ticks_msec()
	var a := BuildCache.level_key(root, path)
	var ms := Time.get_ticks_msec() - t
	var b := BuildCache.level_key(root, path)
	root.data = root.data.duplicate(true)
	var brush: LevelBrush = root.data.brushes.filter(func(x): return x != null and not x.is_prop())[0]
	brush.transform.origin += Vector3(0.5, 0, 0)
	var c := BuildCache.level_key(root, path)
	print("key %x (%d ms) | again same: %s | after a brush moves differs: %s" % [a, ms, a == b, a != c])
	print("has levels: %s | links to: %s | stored build current: %s" % [BuildCache.has_levels(path), ZoneLinks.targets(path),
		BuildCache.zone_up_to_date(path)])
	scene.free()
	get_tree().quit()
