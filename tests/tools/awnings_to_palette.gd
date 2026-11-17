extends Node
## Rebuilds the generated awning textures (textures/fabric/generated/awning_<cloth>_<colour>_<stripe>.res)
## as palette swaps of one shared CI8 texture per cloth (HouseBuilder.awning_texture), keeping
## their paths so the levels' brushes still point at them.
##   Godot --headless --path . res://tests/tools/awnings_to_palette.tscn


func _ready() -> void:
	var dir := HouseBuilder.CLOTH_DIR
	for f in DirAccess.get_files_at(dir):
		if not f.begins_with("awning_") or not f.ends_with(".res") or f.ends_with("_ci.res"):
			continue
		var parts := f.trim_suffix(".res").split("_")
		var stripe := Color.html(parts[-1])
		var cloth_col := Color.html(parts[-2])
		var cloth_name := "_".join(parts.slice(1, parts.size() - 2))
		var cloth: Texture2D = null
		for d in ["res://textures/fabric", "res://textures"]:
			if ResourceLoader.exists("%s/%s.res" % [d, cloth_name]):
				cloth = load("%s/%s.res" % [d, cloth_name])
				break
		var before: Texture2D = load(dir + "/" + f)
		var tex := HouseBuilder.awning_texture(cloth, cloth_col, stripe, null, true)
		print("%s: cloth %s, row %d of %d, %dx%d (was %s %dx%d)" % [f, cloth_name, tex.palette_row,
			tex.palette_texture.palettes.size(), tex.get_width(), tex.get_height(), before.get_class(), before.get_width(), before.get_height()])
	get_tree().quit()
