extends Node
## Sets a texture's metres per repeat (TEX=res://...res, SIZE=metres) and saves it.


func _ready() -> void:
	var t: Resource = load(OS.get_environment("TEX"))
	t.set(&"world_size", float(OS.get_environment("SIZE")))
	print("%s world_size %s: %s" % [t.resource_path, t.get(&"world_size"), error_string(ResourceSaver.save(t, t.resource_path))])
	get_tree().quit()
