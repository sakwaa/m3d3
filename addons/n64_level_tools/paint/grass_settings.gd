@tool
class_name GrassSettings
extends Resource
## A level's grass (LevelData.grass; GrassBuilder makes it): a lumpy grass mat a few cm
## over every upward face painted with a grass texture (Majora's Mask style: a carpet with
## a leafy top and a darker edge where it stops at paths and walls), plus tufts scattered
## over it. Anything sitting on the ground (walls, houses, paths, the track) cuts it.
## Turn `enabled` off to drop it; every setting rebuilds it.

@export var enabled := true:
	set(v):
		enabled = v
		emit_changed()
## Carpet over every grass-textured face by itself (painting adds more and erases it where
## you don't want it). Off: carpet only where painted.
@export var auto_fill := true:
	set(v):
		auto_fill = v
		emit_changed()

## Painted carpet (the paint tools' Grass mode): one cell per PAINT_CELL metres from
## paint_origin (level x, z): 0 untouched (auto_fill decides), 1 erased, 2..255 carpet of
## height (value - 2) / 253 * paint_max metres.
@export_storage var paint_map: Image:
	set(v):
		paint_map = v
		emit_changed()
@export_storage var paint_origin := Vector2.ZERO
## Painted edge style, cell for cell with paint_map (same origin and size): 0 the level's
## edge_style, else 1 + an EdgeStyle. null until a stroke paints a style.
@export_storage var style_map: Image:
	set(v):
		style_map = v
		emit_changed()

const PAINT_CELL := 0.25
const MAX_PAINT_HEIGHT := 4.0
## The painted heights' range (metres at value 255): maps painted before ledges were 1 m;
## LevelGrassTool rescales one to MAX_PAINT_HEIGHT when something taller is painted.
@export_storage var paint_max := 1.0
const ERASED := 1


## The painted value at (x, z) (level space): 0 untouched, 1 erased, else carpet.
func paint_at(x: float, z: float) -> int:
	if paint_map == null:
		return 0
	var px := floori((x - paint_origin.x) / PAINT_CELL)
	var pz := floori((z - paint_origin.y) / PAINT_CELL)
	if px < 0 or pz < 0 or px >= paint_map.get_width() or pz >= paint_map.get_height():
		return 0
	return roundi(paint_map.get_pixel(px, pz).r * 255.0)


## The edge style at (x, z) (level space): a painted one, else the level's edge_style.
func style_at(x: float, z: float) -> int:
	if style_map == null:
		return edge_style
	var px := floori((x - paint_origin.x) / PAINT_CELL)
	var pz := floori((z - paint_origin.y) / PAINT_CELL)
	if px < 0 or pz < 0 or px >= style_map.get_width() or pz >= style_map.get_height():
		return edge_style
	var v := roundi(style_map.get_pixel(px, pz).r * 255.0)
	return v - 1 if v > 0 else edge_style


## Whether any of the carpet can be solid (the level's style, or a painted one).
func any_solid() -> bool:
	if is_solid():
		return true
	if style_map == null:
		return false
	for st in [EdgeStyle.LEDGE, EdgeStyle.RIM]:
		if _map_has(style_map, st + 1):
			return true
	return false


static func _map_has(img: Image, v: int) -> bool:
	var data := img.get_data()  # (L8: one byte a cell)
	for b in data:
		if b == v:
			return true
	return false


func height_of(value: int) -> float:
	return float(value - 2) / 253.0 * paint_max


func value_of(height: float) -> int:
	return clampi(2 + roundi(clampf(height / paint_max, 0.0, 1.0) * 253.0), 2, 255)


## Re-encodes the painted heights for a `new_max` range (same heights, coarser steps).
func rescale_paint(new_max: float) -> void:
	if paint_map != null:
		var img := paint_map.duplicate() as Image
		for z in img.get_height():
			for x in img.get_width():
				var v := roundi(img.get_pixel(x, z).r * 255.0)
				if v >= 2:
					var h := height_of(v)
					img.set_pixel(x, z, Color(clampi(2 + roundi(clampf(h / new_max, 0.0, 1.0) * 253.0), 2, 255) / 255.0, 0, 0))
		paint_map = img
	paint_max = new_max


## The carpet's painted height near (x, z): the painted cells around it averaged (smooth
## steps between strokes of different heights), or -1 if none are painted there.
func painted_height(x: float, z: float, reach := 0.75) -> float:
	if paint_map == null:
		return -1.0
	var r := ceili(reach / PAINT_CELL)
	var cx := floori((x - paint_origin.x) / PAINT_CELL)
	var cz := floori((z - paint_origin.y) / PAINT_CELL)
	var sum := 0.0
	var wsum := 0.0
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var px := cx + dx
			var pz := cz + dz
			if px < 0 or pz < 0 or px >= paint_map.get_width() or pz >= paint_map.get_height():
				continue
			var v := roundi(paint_map.get_pixel(px, pz).r * 255.0)
			if v < 2:
				continue
			var w := 1.0 / (1.0 + dx * dx + dz * dz)
			sum += height_of(v) * w
			wsum += w
	return sum / wsum if wsum > 0.0 else -1.0
## Only inside this area of the level (x, z; zero size = everywhere): keeps the grass to
## where it's seen.
@export var area := Rect2():
	set(v):
		area = v
		emit_changed()
## Faces get grass when their texture is one of these (empty: any texture from
## res://textures/grass/), or their surface sound is Grass.
@export var grass_textures: Array[Texture2D] = []:
	set(v):
		grass_textures = v
		emit_changed()

@export_group("Mat")
## Mat only within this distance of buildings and walls (a band of carpet along their
## feet; the rest of the grass ground is bare, with tufts). 0 = mat everywhere.
@export_range(0.0, 20.0, 0.25, "suffix:m") var mat_band := 0.0:
	set(v):
		mat_band = v
		emit_changed()
## Mat grid (metres per cell; smaller follows edges closer, costs more triangles).
@export_range(0.5, 4.0, 0.25, "suffix:m") var cell := 1.5:
	set(v):
		cell = v
		emit_changed()
## Height over the ground, and random variation (lumps, `lump_size` metres across).
## Majora's Mask carpets stand about a quarter to a third of the player's height (0.4 -
## 0.55 m for our 1.6 m player): the player wades through them.
@export_range(0.0, 4.0, 0.01, "suffix:m") var height := 0.45:
	set(v):
		height = v
		emit_changed()
@export_range(0.0, 0.3, 0.01, "suffix:m") var height_var := 0.06:
	set(v):
		height_var = v
		emit_changed()
@export_range(0.5, 20.0, 0.5, "suffix:m") var lump_size := 4.0:
	set(v):
		lump_size = v
		emit_changed()
## Outline: how round (metres: corners round off and inside corners fill in over about
## this distance; 0 = square cells), how frayed (noise along the edges, breaking off small
## patches), and how finely edge cells are cut (pieces per cell side).
@export_range(0.0, 4.0, 0.05, "suffix:m") var round := 1.0:
	set(v):
		round = v
		emit_changed()
@export_range(0.0, 0.45, 0.01) var fray := 0.18:
	set(v):
		fray = v
		emit_changed()
@export_range(1, 8) var detail := 2:
	set(v):
		detail = v
		emit_changed()
## How far simplifying the carpet's outline may move it (metres): bigger = fewer triangles,
## coarser edges (undergrowth in a forest can take 0.3).
@export_range(0.02, 0.5, 0.01, "suffix:m") var outline_tolerance := 0.06:
	set(v):
		outline_tolerance = v
		emit_changed()
## Top texture (metres per repeat) and its colour; the edge skirt is the same, darker.
@export var top_texture: Texture2D = preload("res://textures/grass/ground_cover_3.res"):
	set(v):
		top_texture = v
		emit_changed()
@export_range(0.25, 8.0, 0.25, "suffix:m") var tile := 1.5:
	set(v):
		tile = v
		emit_changed()
@export var color := Color(0.95, 1.0, 0.9):
	set(v):
		color = v
		emit_changed()
## Patchy colour across the field (0 even .. 1 strong), and how dark the edge gets.
@export_range(0.0, 1.0, 0.05) var patchiness := 0.35:
	set(v):
		patchiness = v
		emit_changed()
@export_range(0.0, 1.0, 0.05) var edge_dark := 0.45:
	set(v):
		edge_dark = v
		emit_changed()
## How far the carpet's top rounds over at its edge (metres): a quarter round out and down
## before the side drops to the ground (0: a sharp edge).
@export_range(0.0, 0.3, 0.01, "suffix:m") var edge_round := 0.1:
	set(v):
		edge_round = v
		emit_changed()

## How the carpet stands up from the ground:
##  - Carpet: a low mat you wade through (Majora's Mask), a darker skirt round its edge.
##  - Ledge: a raised lawn (`height` up to a few metres) on a block of earth: the side in
##    `side_texture`, the grass hanging over its top edge in a jagged fringe. Solid.
##  - Mound: the edge swells into a soft bank running `mound_width` out and down to the
##    ground, no skirt. Waded through like the carpet (no collision).
##  - Rim: a raised bed whose side wall stands `rim_height` above its top, a border of
##    leaves (`rim_texture`) with a jagged leafy upper edge (teeth `fringe` tall). Solid.
## Solid styles get collision (Grass sound) and aren't waded through.
enum EdgeStyle { CARPET, LEDGE, MOUND, RIM }
@export var edge_style := EdgeStyle.CARPET:
	set(v):
		edge_style = v
		emit_changed()
@export var side_texture: Texture2D = preload("res://textures/ground/brown_earth_1.res"):
	set(v):
		side_texture = v
		emit_changed()
@export var side_color := Color(0.9, 0.85, 0.78):
	set(v):
		side_color = v
		emit_changed()
## Metres one repeat of the side texture covers.
@export_range(0.25, 8.0, 0.25, "suffix:m") var side_tile := 2.0:
	set(v):
		side_tile = v
		emit_changed()
## How far the grass fringe hangs down the ledge's side (metres; 0 = a clean edge).
@export_range(0.0, 0.6, 0.01, "suffix:m") var fringe := 0.2:
	set(v):
		fringe = v
		emit_changed()
## How far a mound's bank runs out from its top to the ground (metres).
@export_range(0.25, 8.0, 0.25, "suffix:m") var mound_width := 2.0:
	set(v):
		mound_width = v
		emit_changed()


## Rim: how far its border stands above the top (metres), and the border's texture (leaves
## and flowers by default; empty = the top texture). Its colour is side_color; side_tile its repeat.
@export_range(0.0, 2.0, 0.05, "suffix:m") var rim_height := 0.35:
	set(v):
		rim_height = v
		emit_changed()
@export var rim_texture: Texture2D = preload("res://textures/plants/rim_leaves_flowers.res"):
	set(v):
		rim_texture = v
		emit_changed()


## Whether the carpet is solid ground (a ledge or a rim bed) rather than waded through (a
## carpet, a mound).
func is_solid() -> bool:
	return style_solid(edge_style)


static func style_solid(style: int) -> bool:
	return style == EdgeStyle.LEDGE or style == EdgeStyle.RIM

@export_group("Tufts")
@export var tuft_texture: Texture2D = preload("res://textures/plants/grass_tuft.res"):
	set(v):
		tuft_texture = v
		emit_changed()
## Where tufts grow (GrassBuilder), as clumps grow in an unmown, trodden lawn: thickest in
## the strips feet and blades never reach (the feet of walls and houses) and along the
## carpet's fringe (where the long grass spreads out onto the bare ground), fading out over
## `tuft_reach`; a few seed heads poking up through the carpet; hardly any out on open
## ground; none on paths. Always rooted on the ground, in clumps of a few.
## Clumps per square metre at the busiest spots (wall feet, carpet fringe) is
## tufts x edge_tufts; out in the open, tufts x open_tufts.
@export_range(0.0, 4.0, 0.01) var tufts := 0.12:
	set(v):
		tufts = v
		emit_changed()
@export_range(1.0, 8.0, 0.5) var edge_tufts := 3.0:
	set(v):
		edge_tufts = v
		emit_changed()
## How far from a wall's foot or the carpet's edge tufts thin out to none.
@export_range(0.25, 6.0, 0.25, "suffix:m") var tuft_reach := 1.5:
	set(v):
		tuft_reach = v
		emit_changed()
## Out on open ground, away from walls and carpet (share of `tufts`).
@export_range(0.0, 1.0, 0.01) var open_tufts := 0.08:
	set(v):
		open_tufts = v
		emit_changed()
## Through the carpet (share of `tufts`): taller tufts rooted on the ground poking out.
@export_range(0.0, 2.0, 0.05) var carpet_tufts := 0.4:
	set(v):
		carpet_tufts = v
		emit_changed()
## Most tufts in one clump (1-4 round a bigger middle one, a hand's breadth apart).
@export_range(1, 6) var tuft_clump := 4:
	set(v):
		tuft_clump = v
		emit_changed()
## Tuft colour (over the texture; a little darker than the mat's sits them into it).
@export var tuft_color := Color(0.72, 0.76, 0.66):
	set(v):
		tuft_color = v
		emit_changed()
## Tuft height (metres) and random variation (fraction).
@export_range(0.1, 2.0, 0.05, "suffix:m") var tuft_size := 0.45:
	set(v):
		tuft_size = v
		emit_changed()
@export_range(0.0, 0.8, 0.05) var tuft_size_var := 0.35:
	set(v):
		tuft_size_var = v
		emit_changed()
## Level of detail: crossed tufts out to near_distance, 2-triangle cards out to
## far_distance, swapping over within `fade` metres.
@export_range(2.0, 60.0, 1.0, "suffix:m") var near_distance := 14.0:
	set(v):
		near_distance = v
		emit_changed()
@export_range(5.0, 200.0, 1.0, "suffix:m") var far_distance := 40.0:
	set(v):
		far_distance = v
		emit_changed()
@export_range(0.0, 10.0, 0.5, "suffix:m") var fade := 3.0:
	set(v):
		fade = v
		emit_changed()

## Random layout (another seed, other lumps and tufts).
@export var seed := 1:
	set(v):
		seed = v
		emit_changed()
