extends SceneTree
## Puts each species preset's far cards on it (TreeSpecies.card_textures / card_aspects):
## hand-made species the variants tests/trees/make_cards.tscn rendered
## (textures/plants/tree_card_<name>_<n>.res, aspects in species/cards.json), photo species
## their one photo card (tree_card_<name>.res, its aspect from the import).
##   Godot --headless --path . -s res://addons/n64_level_tools/trees/assign_cards.gd

const DIR := "res://addons/n64_level_tools/trees/species/"
const TEX := "res://textures/plants/tree_card_%s"


func _init() -> void:
	var aspects := {}
	if FileAccess.file_exists(DIR + "cards.json"):
		aspects = JSON.parse_string(FileAccess.get_file_as_string(DIR + "cards.json"))
	for f in DirAccess.get_files_at(DIR):
		if not f.ends_with(".tres"):
			continue
		var name := f.get_basename()
		var sp: TreeSpecies = load(DIR + f)
		var tex: Array[Texture2D] = []
		var asp := PackedFloat32Array()
		var tiles := Vector2i.ONE
		var bases := []  # [texture name without .res, aspect]
		var k := 1
		var list: Array = aspects.get(name, [])
		while _exists((TEX % name) + "_%d" % k):
			bases.append([(TEX % name) + "_%d" % k, float(list[k - 1]) if k - 1 < list.size() else 1.0])
			k += 1
		if bases.is_empty() and _exists(TEX % name):
			bases.append([TEX % name, sp.card_aspect])
		for b in bases:
			# Tiled (cards.sh splits big cards into a 2 x 2 grid of N64 loads) or one piece.
			if ResourceLoader.exists(b[0] + "_t0.res"):
				tiles = Vector2i(2, 2)
				for t in 4:
					tex.append(load(b[0] + "_t%d.res" % t))
			else:
				tex.append(load(b[0] + ".res"))
			asp.append(b[1])
		sp.card_textures = tex
		sp.card_aspects = asp
		sp.card_tiles = tiles
		sp.card_texture = null
		ResourceSaver.save(sp)
		print("%s: %d card(s), tiles %s" % [name, bases.size(), tiles])
	quit()


func _exists(base: String) -> bool:
	return ResourceLoader.exists(base + ".res") or ResourceLoader.exists(base + "_t0.res")
