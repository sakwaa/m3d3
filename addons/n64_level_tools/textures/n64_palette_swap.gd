@tool
class_name N64PaletteSwap
extends N64Texture
## A colour variant of a shared palette texture (N64PaletteTexture): one row of its palettes.
## Used anywhere a texture goes (brushes, the picker); levels draw it the N64 way - the
## shared indices looked up in this row (PaintAtlas.set_base), so every variant shares one
## texture and recolouring is a palette edit. Its own image is the row drawn out, for
## previews and paths that want plain colours.

@export var palette_texture: N64PaletteTexture
@export var palette_row := 0


## Re-draws the image from the palette (after the palette or row changed).
func refresh_image() -> void:
	if palette_texture:
		set_image(palette_texture.render_row(palette_row))
