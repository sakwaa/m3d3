extends Node
## Ground piling at structures (GroundPile) and grass / dirt edge blending (GroundEdgeBlend)
## on a level file (LEVEL), baked and saved to OUT (default: over LEVEL; editor closed then).
##   LEVEL=res://..._level.res [OUT=/abs/copy.res] [GRASS=res://...] [DIRT=res://...] tools/godot_run.sh --headless --path . tests/zones/pile_and_blend.tscn

const GRASS := "res://textures/grass/157_green_grass.res"
const DIRT := "res://textures/ground/mud.res"
# (Preloaded: run before the editor has registered their class names.)
const Pile := preload("res://addons/n64_level_tools/ground_pile.gd")
const Blend := preload("res://addons/n64_level_tools/ground_edge_blend.gd")


func _ready() -> void:
	var path := OS.get_environment("LEVEL")
	var out := OS.get_environment("OUT") if OS.get_environment("OUT") != "" else path
	var uid := ResourceLoader.get_resource_uid(path)
	var data: LevelData = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var t := Time.get_ticks_msec()
	print("piled: %d vertices" % Pile.apply(data))
	var grass: Texture2D = load(OS.get_environment("GRASS") if OS.get_environment("GRASS") != "" else GRASS)
	var dirt: Texture2D = load(OS.get_environment("DIRT") if OS.get_environment("DIRT") != "" else DIRT)
	print("blended: %d faces (%d ms)" % [Blend.apply(data, grass, dirt), Time.get_ticks_msec() - t])
	var res := LevelBaker.bake(data, true)
	data.baked_mesh = res.mesh
	data.baked_chunks = res.chunks
	data.set_baked_collision(res)
	var err := ResourceSaver.save(data, out, ResourceSaver.FLAG_COMPRESS)
	if out == path and uid != ResourceUID.INVALID_ID:
		ResourceSaver.set_uid(path, uid)
	print("saved %s: %s" % [out, error_string(err)])
	get_tree().quit()
