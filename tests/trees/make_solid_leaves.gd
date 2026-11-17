extends Node
## Writes every species' solid leaf texture (<leaf>_solid.res, TreeBuilder.solid_texture)
## and prints each species' triangles with its foliage style. Rerun after changing
## SOLID_CONTRAST / the solid texture's recipe (bump SOLID_VERSION).
func _ready() -> void:
	var dir := "res://addons/n64_level_tools/trees/species/"
	var made := {}
	for f in DirAccess.get_files_at(dir):
		if not f.ends_with(".tres"):
			continue
		var sp: TreeSpecies = load(dir + f)
		var style := sp.foliage if sp.cards == TreeSpecies.Cards.CLUMPS else TreeSpecies.Foliage.CARDS
		if style != TreeSpecies.Foliage.CARDS and sp.leaf_texture:
			var t := TreeBuilder.solid_texture(sp.leaf_texture)
			made[t.resource_path] = true
		var m := TreeBuilder.build(sp, 7)
		var cards := TreeBuilder.build(sp, 7, TreeSpecies.Foliage.CARDS)
		print("[solid] %-22s %-6s %4d tris (cards %4d)" % [f.get_basename(), ["cards", "shell", "blobs"][style], TreeBuilder.triangles(m), TreeBuilder.triangles(cards)])
	print("[solid] textures: ", made.keys())
	get_tree().quit()
