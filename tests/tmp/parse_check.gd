extends Node
func _ready() -> void:
	for p in ["res://addons/n64_level_tools/plugin.gd", "res://addons/n64_level_tools/game_preview.gd", "res://addons/n64_runtime/world/mountain_range.gd"]:
		var s: GDScript = load(p)
		print("[pc] ", p.get_file(), " ", s != null and s.can_instantiate())
	get_tree().quit()
