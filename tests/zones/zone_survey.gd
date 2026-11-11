extends Node
## For each level (LEVELS, comma separated): lighting mode, light settings, ground (GRID)
## brushes, houses / solid boxes, and the grass / dirt textures it uses.


func _ready() -> void:
	for path in OS.get_environment("LEVELS").split(","):
		var d: LevelData = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		var grids := 0
		var houses := 0
		var boxes := 0
		for b in d.brushes:
			if b == null:
				continue
			if b.shape == BrushShapes.Shape.GRID and not b.is_prop():
				grids += 1
			if b.is_house():
				houses += 1
			elif BuildCull._is_solid_box(b):
				boxes += 1
		var tex := []
		for t in d.textures:
			if t:
				var inner = t.get(&"texture")
				var p: String = (inner as Texture2D).resource_path if inner is Texture2D else t.resource_path
				if p.contains("/grass/") or p.contains("/ground/"):
					tex.append(p.get_file())
		print("%s: mode %d floor %.2f contrast %.2f intensity %.2f | grids %d houses %d boxes %d | ground tex %s | grass %s" % [path.get_file(), d.lighting_mode,
			d.light_floor, d.light_contrast, d.light_intensity, grids, houses, boxes, tex, d.grass != null])
	get_tree().quit()
