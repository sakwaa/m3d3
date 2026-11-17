extends SceneTree
## Rebuilds (from source) every N64Texture the market level uses (new mip chains).
func _init() -> void:
	var zone: Node = (load("res://zones/town1/town_1_market_square.tscn") as PackedScene).instantiate()
	var done := 0
	for lr in zone.find_children("*", "", true, false):
		var data = lr.get(&"data")
		if data == null or data.get(&"textures") == null:
			continue
		for t in data.get(&"textures"):
			if t is N64Texture and t.source_path != "" and t.resource_path != "" and not t.resource_path.contains("::"):
				var t0 := Time.get_ticks_msec()
				var err: int = t.rebuild()
				done += 1
				print("rebuilt %s (%d ms) %s" % [t.resource_path.get_file(), Time.get_ticks_msec() - t0, error_string(err)])
			elif t is N64Texture:
				print("skip ", t.resource_path, " (no source)")
	print("rebuilt ", done)
	quit()
