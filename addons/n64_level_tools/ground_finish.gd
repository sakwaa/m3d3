@tool
class_name GroundFinish
extends Resource
## A level's ground finish (LevelData.ground_finish): soft, ragged edges where grass ground
## meets dirt (GroundEdgeBlend: the dirt's overlay painted onto the grass along the border)
## and the ground piled up a little at the foot of buildings and blocks (GroundPile). Both
## are kept apart from the ground as built (LevelBrush.pile_offsets / blend_base), so Apply
## can be pressed again after changing the settings or the level, and Clear takes them off.
## Lighting is baked from the ground as it stands: Bake Lighting again after applying.

@export_tool_button("Apply", "Play") var apply_button := apply
@export_tool_button("Clear", "Clear") var clear_button := clear
@export_tool_button("Fill Textures From Level", "Search") var fill_button := fill_textures

@export_group("Edge Blend")
@export var blend := true
## Grass textures (the ground the dirt bleeds onto) and dirt textures (each needs an overlay
## slot in the level's default layer set; one is added when there's room).
@export var grass_textures: Array[Texture2D] = []
@export var dirt_textures: Array[Texture2D] = []
## How far the dirt reaches onto the grass (metres) and how ragged its edge is (share of
## that width the noise moves it).
@export_range(0.1, 3.0, 0.05, "suffix:m") var blend_width := 0.7
@export_range(0.0, 1.0, 0.05) var blend_noise := 0.45

@export_group("Pile")
@export var pile := true
## Rise at a building's / block's foot and how far out it eases off.
@export_range(0.0, 0.5, 0.01, "suffix:m") var pile_height := 0.15
@export_range(0.25, 4.0, 0.05, "suffix:m") var pile_width := 1.2
## All the ground slopes up (paving too), not only the grass and dirt.
@export var pile_any_ground := false

## The level this belongs to (set by LevelData).
var level: WeakRef


func _data() -> LevelData:
	return level.get_ref() as LevelData if level else null


## Takes the finish off, then puts it on with the current settings. Returns a summary.
func apply() -> String:
	var data := _data()
	if data == null:
		push_warning("Ground finish: not on a level.")
		return ""
	clear()
	var out := []
	if pile:
		out.append("piled %d vertices" % GroundPile.apply(data, pile_height, pile_width, [] if pile_any_ground else grass_textures + dirt_textures))
	if blend and not grass_textures.is_empty() and not dirt_textures.is_empty():
		for dirt in dirt_textures:
			var n := GroundEdgeBlend.apply(data, grass_textures, dirt, blend_width, blend_noise)
			out.append("blended %d faces with %s" % [n, dirt.resource_path.get_file()] if n >= 0
				else "no overlay slot free for %s" % dirt.resource_path.get_file())
	var summary := ", ".join(out)
	print("Ground finish: %s. Bake Lighting to light it." % summary)
	return summary


## Takes the finish off: the ground as built, the paint as it was.
func clear() -> void:
	var data := _data()
	if data == null:
		return
	GroundPile.clear(data)
	GroundEdgeBlend.clear(data)


## Grass / dirt texture lists from what the level's ground wears: textures from the grass
## folder are grass, from the ground folder dirt (recoloured palette entries count as theirs).
func fill_textures() -> void:
	var data := _data()
	if data == null:
		return
	var g: Array[Texture2D] = []
	var d: Array[Texture2D] = []
	for t in data.textures:
		if t == null:
			continue
		var inner = t.get(&"texture")
		var base: Texture2D = inner if inner is Texture2D else t
		if base.resource_path.contains("/grass/") and not base in g:
			g.append(base)
		elif base.resource_path.contains("/ground/") and not base in d:
			d.append(base)
	grass_textures = g
	dirt_textures = d
	emit_changed()
