extends Node
## One-off market square fixes (editor closed):
##  - the stray collision-only box at the middle of town (fence_524eb7a0) goes;
##  - the bright recoloured meadow grass in the south-east corner becomes the town's grass;
##  - the ground's walls round the edge (painted with the grass / mud when the market was
##    greened) and their tops become dry stone (river_rock_1, as outside town).
## Saves without baking: run join_terraces after (it relights and bakes).
##   tools/godot_run.sh --headless --path . tests/zones/market_fixes.tscn

const SCENE := "res://zones/town1/town_1_market_square.tscn"
const STRAY := &"fence_524eb7a0"
const GRASS := "res://textures/grass/157_green_grass.res"
const MEADOW := "res://textures/grass/grass_meadow.res"
const STONE := "res://textures/rock/river_rock_1.res"


func _ready() -> void:
	var zone: Node = (load(SCENE) as PackedScene).instantiate()
	add_child(zone)
	await get_tree().process_frame
	var root: LevelRoot = zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
	var data: LevelData = root.data
	var path := data.resource_path
	var uid := ResourceLoader.get_resource_uid(path)
	for b in data.brushes.duplicate():
		if b and b.tag == STRAY:
			data.remove_brush(b)
			print("removed ", STRAY)
	var grass := root._palette_index(load(GRASS))
	var stone := root._palette_index(load(STONE))
	# Palette entries drawing the meadow texture (recoloured variants of it).
	var meadow := {}
	for i in data.textures.size():
		var t: Texture2D = data.textures[i]
		if t and (t.resource_path == MEADOW or (t.get(&"texture") is Texture2D and (t.get(&"texture") as Texture2D).resource_path == MEADOW)):
			meadow[i] = true
	var ground: LevelBrush
	for b in data.brushes:
		if b and b.shape == BrushShapes.Shape.GRID and (ground == null or b.get_face_count() > ground.get_face_count()):
			ground = b
	var to_grass := 0
	var to_stone := 0
	for b: LevelBrush in data.brushes:
		if b == null or b.is_prop() or b.is_house():
			continue
		var ft := PackedInt32Array()
		for f in b.get_face_count():
			ft.append(b.get_face_texture(f))
		var masks := b.face_masks.duplicate()
		var changed := false
		for f in b.get_face_count():
			var want := -1
			if meadow.has(ft[f]):
				want = grass
			if b == ground:
				var pts := b.get_face_points(f)
				var n := (b.transform.basis * b.get_face_normal(f)).normalized()
				var low := INF
				for p in pts:
					low = minf(low, (b.transform * p).y)
				# Walls (anything not facing up) and the tops of them (up, well off the ground).
				if absf(n.y) < 0.7 or low >= 1.0:
					want = stone
			if want >= 0 and ft[f] != want:
				if want == stone:
					to_stone += 1
					# (Overlays painted on it were for the ground.)
					for k in masks.keys():
						if (k as Vector2i).x == f:
							masks.erase(k)
				else:
					to_grass += 1
				ft[f] = want
				changed = true
		if changed:
			b.face_textures = ft
			b.face_masks = masks
	print("faces to town grass: %d, to stone: %d" % [to_grass, to_stone])
	var err := ResourceSaver.save(data, path, ResourceSaver.FLAG_COMPRESS)
	if uid != ResourceUID.INVALID_ID:
		ResourceSaver.set_uid(path, uid)
	print("saved %s: %s" % [path, error_string(err)])
	get_tree().quit()
