@tool
class_name N64Texture
extends ImageTexture
## Texture converted to N64 spec (format, TMEM-sized, quantised colours / palette).
## Remembers its import settings and hi-res source so it can be rebuilt any time.

@export var category: StringName
@export var usage := N64TextureConverter.Usage.SURFACE
@export var tiling := N64TextureConverter.Tiling.SEAMLESS
@export var format := N64TextureConverter.Format.RGBA16
@export var texture_size := Vector2i(32, 32)
## Metres covered by one repeat (width; height follows the aspect) when used on levels.
## 0 = Auto: width in texels / the project's texel density (n64/textures/texels_per_metre),
## so texels are the same size on every surface.
@export_range(0.0, 16.0, 0.1) var world_size := 0.0
## Hides repetition in the shader. Offset / Offset + Rotate: hex tiling (organic
## textures). Row shuffle: each row of repeats slides sideways by a random amount
## (bricks, planks; courses stay whole).
@export_enum("Off", "Offset", "Offset + Rotate", "Row shuffle") var anti_tiling := 0
## Hex cell size in texture repeats.
@export_range(0.25, 4.0, 0.05) var anti_tiling_scale := 0.75
## Offset + Rotate: how far each cell may turn (1 = any angle). Full rotation reads as
## swirls on organic textures; small angles hide repetition without it.
@export_range(0.0, 1.0, 0.05) var anti_tiling_rotation := 0.15
@export_group("Tint")
## Colour combiner: None, Multiply (texel x light), Gradient (lerp dark -> light by texel).
@export var tint_mode := N64TextureConverter.TintMode.NONE
## Gradient colours picked from the photo at import (rebuild re-picks them).
@export var tint_auto := true
@export var tint_dark := Color(0.2, 0.2, 0.2)
@export var tint_light := Color.WHITE
## How much of the tint replaces the texture's own colours (0 = original, 1 = full tint).
@export_range(0.0, 1.0, 0.05) var tint_amount := 0.5
## Luminance range mapped onto the gradient (set at import; 0..1 for greyscale textures).
@export var tint_range := Vector2(0.0, 1.0)
@export_group("Surface")
## Footstep sound where this texture is the ground (base texture, or an overlay layer
## covering most of a face). Auto: from the category and name (grass, wood, sand...).
@export_enum("Auto:-1", "Default:0", "Grass:1", "Dirt:2", "Stone:3", "Wood:4", "Sand:5", "Water:6", "Metal:7",
	"Snow:8", "Carpet:9") var surface_sound := -1
## Gameplay flags the texture brings with it. Hazards (damage, void-out) and no-camera
## are painted per face with the Surface layer instead.
@export_flags("Slippery", "Climbable", "Hookshot") var surface_flags := 0
## Also flags from the name: "ice" is slippery.
@export var surface_auto_flags := true
@export_group("Animation")
## Metres per second the texture slides (0 = still): waterfalls, lava, conveyor belts.
@export_range(-8.0, 8.0, 0.05, "or_greater", "or_less", "suffix:m/s") var scroll_speed := 0.0
## World direction it slides, projected onto each face: (0, -1, 1) runs down walls and
## towards +Z on floors. A face it points straight into doesn't move.
@export var scroll_direction := Vector3(0, -1, 1)
## Flipbook: frames laid out left to right, top to bottom in a grid of this many columns
## (1 frame = no flipbook). One frame covers the tile size.
@export_range(1, 64) var flip_frames := 1
@export_range(1, 16) var flip_columns := 1
@export_range(0.5, 60.0, 0.5, "suffix:fps") var flip_fps := 8.0
@export_group("")
## 0 = the source already tiles (no seam blending).
@export_range(0.0, 1.0) var seam_blend := 0.35
## Use a 1/zoom subsection of the source (closer-up, chunkier detail), around crop_center.
@export_range(1.0, 8.0, 0.25) var zoom := 1.0
## Centre of the zoomed region in the source, 0..1.
@export var crop_center := Vector2(0.5, 0.5)
## Bricks / planks: whole courses per repeat (0 = auto, ~16 texels per course). Used by
## auto zoom at import.
@export_range(0, 16) var courses := 0
## Zoom and centre were chosen by image analysis at import.
@export var zoom_auto := false
## Unsharp mask at the final size (object photos default to some; tiling textures 0).
@export_range(0.0, 2.0, 0.05) var sharpen := 0.0
## Keeps thin dark lines (plank gaps, outlines) from averaging away when shrinking.
@export_range(0.0, 1.0, 0.05) var keep_lines := 0.0
@export_range(0.0, 2.0) var saturation := 1.0
@export_range(0.0, 2.0) var contrast := 1.0
@export_range(-0.5, 0.5) var brightness := 0.0
## Palette for CI4 / CI8 textures (RGBA5551 colours).
@export var palette := PackedColorArray()
## Object photo (plain background): cut out and cropped for this use before converting.
@export var object := N64ObjectExtract.Kind.NONE
## Object photos: mirrored left-right (doors: so the hinges end up on the left edge).
@export var mirror := false
## Doors: background seen through them (glass, screens, bars) as dark glass or cut out.
@export var holes := N64ObjectExtract.Holes.GLASS
## Hi-res original (kept under res://textures/_source, ignored by Godot's importer).
@export_file var source_path := ""
## Width / height of the source; decals use it to keep proportions on surfaces.
@export var source_aspect := 1.0
## Re-runs the conversion from the source with the settings above.
@export_tool_button("Rebuild From Source", "Reload") var rebuild_button := rebuild


const DENSITY_SETTING := "n64/textures/texels_per_metre"
const DEFAULT_DENSITY := 32


## Project texel density (texels per metre) for Auto world sizes.
static func texels_per_metre() -> float:
	return maxf(float(ProjectSettings.get_setting(DENSITY_SETTING, DEFAULT_DENSITY)), 1.0)


## Metres per repeat on levels: world_size, or Auto from the texel density.
func metres_per_repeat() -> float:
	if world_size > 0.0:
		return world_size
	return texture_size.x / texels_per_metre()


const _CATEGORY_SOUNDS := {
	grass = Surface.Sound.GRASS, plants = Surface.Sound.GRASS, ground = Surface.Sound.DIRT,
	rock = Surface.Sound.STONE, cement = Surface.Sound.STONE, tiles = Surface.Sound.STONE,
	brick = Surface.Sound.STONE, roof = Surface.Sound.STONE, concrete = Surface.Sound.STONE,
	stairs = Surface.Sound.STONE, flowers = Surface.Sound.GRASS, wood = Surface.Sound.WOOD,
	metal = Surface.Sound.METAL, water = Surface.Sound.WATER, fabric = Surface.Sound.CARPET,
}
## Words in a texture's name that beat its category (sand is filed under ground).
const _NAME_SOUNDS := {
	sand = Surface.Sound.SAND, beach = Surface.Sound.SAND, snow = Surface.Sound.SNOW,
	mud = Surface.Sound.DIRT, dirt = Surface.Sound.DIRT, soil = Surface.Sound.DIRT, path = Surface.Sound.DIRT,
	gravel = Surface.Sound.STONE, cobble = Surface.Sound.STONE, ice = Surface.Sound.STONE,
	plank = Surface.Sound.WOOD, planks = Surface.Sound.WOOD, carpet = Surface.Sound.CARPET, rug = Surface.Sound.CARPET,
	grass = Surface.Sound.GRASS, moss = Surface.Sound.GRASS, metal = Surface.Sound.METAL, water = Surface.Sound.WATER,
}


## Shader scroll (direction xyz, speed) and flipbook (columns, rows, frames, fps) params.
func anim_params() -> Array:
	var scroll := Vector4(scroll_direction.x, scroll_direction.y, scroll_direction.z, scroll_speed) \
		if scroll_direction.length() > 0.001 else Vector4.ZERO
	var cols := clampi(flip_columns, 1, maxi(flip_frames, 1))
	var flip := Vector4(cols, ceili(float(flip_frames) / cols), flip_frames, flip_fps) if flip_frames > 1 else Vector4(1, 1, 1, 0)
	return [scroll, flip]


## Surface (Surface.Sound | flags) faces showing this texture get.
func surface() -> int:
	var words := _name_words()
	var snd := surface_sound
	if snd < 0:
		snd = _CATEGORY_SOUNDS.get(String(category), Surface.Sound.DEFAULT)
		for w in words:
			if _NAME_SOUNDS.has(w):
				snd = _NAME_SOUNDS[w]
				break
	var flags := 0
	if surface_flags & 1 or (surface_auto_flags and words.has("ice")):
		flags |= Surface.SLIPPERY
	if surface_flags & 2:
		flags |= Surface.CLIMBABLE
	if surface_flags & 4:
		flags |= Surface.HOOKSHOT
	return snd | flags


## Lower-case words of the file name ("Ice_Floor02" -> ["ice", "floor"]).
func _name_words() -> PackedStringArray:
	var out := PackedStringArray()
	var word := ""
	for ch in resource_path.get_file().get_basename().to_lower():
		if ch >= "a" and ch <= "z":
			word += ch
		elif word != "":
			out.append(word)
			word = ""
	if word != "":
		out.append(word)
	return out


func get_settings() -> Dictionary:
	return {
		name = resource_path.get_file().get_basename(), category = String(category), usage = usage,
		tiling = tiling, format = format, size = texture_size, seam_blend = seam_blend,
		saturation = saturation, contrast = contrast, brightness = brightness,
		zoom = zoom, crop_center = crop_center, zoom_auto = zoom_auto, world_size = world_size, courses = courses,
		anti_tiling = anti_tiling, anti_tiling_scale = anti_tiling_scale, anti_tiling_rotation = anti_tiling_rotation,
		tint_mode = tint_mode, tint_auto = tint_auto, tint_dark = tint_dark, tint_light = tint_light,
		tint_amount = tint_amount, tint_range = tint_range, object = object, mirror = mirror, holes = holes,
		sharpen = sharpen, keep_lines = keep_lines,
	}


func apply_settings(s: Dictionary) -> void:
	category = StringName(s.category)
	usage = s.usage
	tiling = s.tiling
	format = s.format
	texture_size = s.size
	seam_blend = s.seam_blend
	saturation = s.saturation
	contrast = s.contrast
	brightness = s.brightness
	zoom = s.get("zoom", 1.0)
	crop_center = s.get("crop_center", Vector2(0.5, 0.5))
	zoom_auto = s.get("zoom_auto", false)
	world_size = s.get("world_size", 0.0)
	courses = s.get("courses", 0)
	anti_tiling = s.get("anti_tiling", 0)
	anti_tiling_scale = s.get("anti_tiling_scale", 0.75)
	anti_tiling_rotation = s.get("anti_tiling_rotation", 0.15)
	tint_mode = s.get("tint_mode", N64TextureConverter.TintMode.NONE)
	tint_auto = s.get("tint_auto", true)
	tint_dark = s.get("tint_dark", Color(0.2, 0.2, 0.2))
	tint_light = s.get("tint_light", Color.WHITE)
	tint_amount = s.get("tint_amount", 0.5)
	tint_range = s.get("tint_range", Vector2(0.0, 1.0))
	object = s.get("object", N64ObjectExtract.Kind.NONE)
	mirror = s.get("mirror", false)
	holes = s.get("holes", N64ObjectExtract.Holes.GLASS)
	sharpen = s.get("sharpen", 0.0)
	keep_lines = s.get("keep_lines", 0.0)


func rebuild() -> Error:
	var source := Image.load_from_file(source_path)
	if source == null:
		push_error("N64Texture: can't load source %s" % source_path)
		return ERR_FILE_NOT_FOUND
	var result := N64TextureConverter.convert(source, get_settings())
	palette = result.palette
	tint_dark = result.tint_dark
	tint_light = result.tint_light
	tint_range = result.tint_range
	set_image(N64TextureLibrary.with_mipmaps(result.image))
	if not resource_path.is_empty() and not resource_path.contains("::"):
		return ResourceSaver.save(self)
	return OK
