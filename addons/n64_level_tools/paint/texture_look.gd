@tool
class_name TextureLook
extends Texture2D
## A base texture painted with its own colouring: an entry in a level's texture palette
## (LevelData.textures) standing for `texture` plus a palette, a colour, variation and a
## tile size. Painting with settings tuned in the Paint panel makes one (or reuses one with
## the same settings), so faces painted earlier keep the look they were painted with.
## Materials render `texture` with these values (PaintAtlas.set_base); this resource is
## never drawn by a shader itself. Editor data only (LevelData doesn't ship).

## The texture underneath.
@export var texture: Texture2D
## [dark, light] gradient palette; empty = the level's / texture's own.
@export var palette := PackedColorArray()
## Multiplied over the result (brightness / warmth).
@export var color := Color.WHITE
## Variation (strength, metres per noise repeat, mode 0 light & dark / 1 darken).
@export var variation := Vector3(0.0, 8.0, 0.0)
## Metres per repeat (0 = the level's / texture's own).
@export var tile := 0.0
## The faces' vertex colour recolours the texture (the texture gives brightness detail,
## the vertex colour the colour) instead of multiplying it.
@export var recolour := false


## The plain texture behind `t` (itself when it isn't a look).
static func source_of(t: Texture2D) -> Texture2D:
	return t.texture if t is TextureLook else t


func same_as(src: Texture2D, p_palette: PackedColorArray, p_color: Color, p_variation: Vector3, p_tile: float,
		p_recolour := false) -> bool:
	if texture != src or recolour != p_recolour or palette.size() != p_palette.size() or not color.is_equal_approx(p_color):
		return false
	for i in palette.size():
		if not palette[i].is_equal_approx(p_palette[i]):
			return false
	return variation.is_equal_approx(p_variation) and is_equal_approx(tile, p_tile)


func _get_width() -> int:
	return texture.get_width() if texture else 1


func _get_height() -> int:
	return texture.get_height() if texture else 1


func _has_alpha() -> bool:
	return texture.has_alpha() if texture else false


func _draw(to_canvas_item: RID, pos: Vector2, modulate: Color, transpose: bool) -> void:
	if texture:
		texture.draw(to_canvas_item, pos, modulate * color, transpose)


func _draw_rect(to_canvas_item: RID, rect: Rect2, tile_texture: bool, modulate: Color, transpose: bool) -> void:
	if texture:
		texture.draw_rect(to_canvas_item, rect, tile_texture, modulate * color, transpose)


func _draw_rect_region(to_canvas_item: RID, rect: Rect2, src_rect: Rect2, modulate: Color, transpose: bool, clip_uv: bool) -> void:
	if texture:
		texture.draw_rect_region(to_canvas_item, rect, src_rect, modulate * color, transpose, clip_uv)
