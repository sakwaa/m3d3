@tool
class_name ScreenLook
extends Resource
## A colour mood for the whole 3D picture (N64VideoOut, after the grade, before the HUD).
## Not how OoT / MM set moods (their per-scene light and fog colours did that, like our
## lighting schedule and weather): an extra layer for moods lighting can't reach, such as
## memories, dreams, cursed places. Zones, rooms, weather presets and cutscene Screen cues
## pick one; RenderScale crossfades between them.
##  - Gradient: the picture's brightness mapped through `gradient` (dark -> light), like the
##    N64 combiner's gradient tint over the whole screen.
##  - Palette: every pixel snapped to the nearest of `palette` (or `palette_image`'s colours),
##    an ordered dither mixing neighbours so gradients survive.
##  - LUT: any colour grade from a lookup table (`lut`): a strip (N slices of N x N side by
##    side; game/looks/lut_neutral_16.png is the untouched one to grade in an image editor
##    together with a screenshot), a HaldCLUT image, or an imported .cube file (LutFile).

enum Mode { GRADIENT, PALETTE, LUT }

const MAX_COLOURS := 64

@export var mode := Mode.GRADIENT:
	set(v):
		mode = v
		notify_property_list_changed()
		emit_changed()
## How much of the look shows (1 = all of it).
@export_range(0.0, 1.0, 0.05) var strength := 1.0:
	set(v):
		strength = v
		emit_changed()
## Seconds to blend into this look when it takes over (and out again).
@export_range(0.0, 10.0, 0.1, "suffix:s") var blend_time := 1.0
## Gradient: dark (left) to light (right), in display colours.
@export var gradient: Gradient:
	set(v):
		gradient = v
		emit_changed()
## Palette: the colours (up to 64), or an image whose colours are used (a palette strip).
@export var palette := PackedColorArray():
	set(v):
		palette = v
		emit_changed()
@export var palette_image: Texture2D:
	set(v):
		palette_image = v
		emit_changed()
## Palette: how strongly the ordered dither mixes neighbouring colours (0 = flat bands).
@export_range(0.0, 1.0, 0.05) var palette_dither := 0.5:
	set(v):
		palette_dither = v
		emit_changed()
## LUT: the lookup strip.
@export var lut: Texture2D:
	set(v):
		lut = v
		emit_changed()


func _validate_property(property: Dictionary) -> void:
	var by_mode := {gradient = Mode.GRADIENT, palette = Mode.PALETTE, palette_image = Mode.PALETTE,
		palette_dither = Mode.PALETTE, lut = Mode.LUT}
	if by_mode.has(property.name) and by_mode[property.name] != mode:
		property.usage = PROPERTY_USAGE_NO_EDITOR


## The look as an RGBA8 image for the shader (gradient: 256 x 1; palette: n x 1; LUT: the
## strip) and its size number (palette: colours; LUT: N; gradient: 256).
func bake() -> Array:
	match mode:
		Mode.PALETTE:
			var cols := colours()
			var img := Image.create(maxi(cols.size(), 1), 1, false, Image.FORMAT_RGBA8)
			for i in cols.size():
				img.set_pixel(i, 0, cols[i])
			return [img, cols.size()]
		Mode.LUT:
			var strip := LutFile.strip_from_image(lut.get_image() if lut else null)
			if strip:
				return [strip, strip.get_height()]
			if lut:
				push_warning("ScreenLook: %s isn't a LUT strip, HaldCLUT or .cube." % lut.resource_path)
			return [LutFile.neutral(16), 16]
	var g := gradient
	var ramp := Image.create(256, 1, false, Image.FORMAT_RGBA8)
	for i in 256:
		var t := i / 255.0
		ramp.set_pixel(i, 0, g.sample(t) if g else Color(t, t, t))
	return [ramp, 256]


## The palette's colours: `palette`, else the image's distinct colours in order (up to 64).
func colours() -> PackedColorArray:
	if not palette.is_empty():
		return palette.slice(0, MAX_COLOURS)
	var out := PackedColorArray()
	if palette_image:
		var img := palette_image.get_image()
		if img:
			if img.is_compressed():
				img.decompress()
			var seen := {}
			for y in img.get_height():
				for x in img.get_width():
					var c := img.get_pixel(x, y)
					var key := c.to_rgba32()
					if c.a > 0.5 and not seen.has(key):
						seen[key] = true
						out.append(Color(c.r, c.g, c.b))
						if out.size() >= MAX_COLOURS:
							return out
	if out.is_empty():
		out = PackedColorArray([Color.BLACK, Color.WHITE])
	return out


## Saves the neutral strip as a PNG to grade in an image editor.
static func save_neutral_lut(path: String, n := 16) -> Error:
	return LutFile.neutral(n).save_png(path)
