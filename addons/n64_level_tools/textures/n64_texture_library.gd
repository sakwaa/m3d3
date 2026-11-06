class_name N64TextureLibrary
extends RefCounted
## Import side of the texture library: copies the hi-res source into an ignored folder,
## converts it and saves an N64Texture under res://textures/<category>/<name>.res.

const ROOT := "res://textures"
const SOURCE_DIR := "res://textures/_source"


## Loads an image from anywhere on disk (or res://) for preview/convert, downscaled to
## at most `max_size` (enough for zoomed-in crops; the converter works at 4x target).
static func load_preview_source(path: String, max_size := 2048) -> Image:
	var img := Image.load_from_file(path)
	if img == null:
		return null
	if img.is_compressed():
		img.decompress()
	var longest := maxi(img.get_width(), img.get_height())
	if longest > max_size:
		var k := float(max_size) / longest
		img.resize(maxi(1, int(img.get_width() * k)), maxi(1, int(img.get_height() * k)), Image.INTERPOLATE_LANCZOS)
	return img


static func texture_path(settings: Dictionary) -> String:
	return "%s/%s/%s.res" % [ROOT, settings.category, settings.name]


## Imports one image. Returns the saved N64Texture, or null on failure.
static func import_image(source_file: String, settings: Dictionary, source: Image = null) -> N64Texture:
	_ensure_source_dir()
	var ext := source_file.get_extension().to_lower()
	var stored := "%s/%s/%s.%s" % [SOURCE_DIR, settings.category, settings.name, ext]
	DirAccess.make_dir_recursive_absolute(stored.get_base_dir())
	if source_file != stored:
		var bytes := FileAccess.get_file_as_bytes(source_file)
		if bytes.is_empty():
			push_error("N64 textures: can't read %s" % source_file)
			return null
		var f := FileAccess.open(stored, FileAccess.WRITE)
		f.store_buffer(bytes)
		f.close()

	if source == null:
		source = load_preview_source(stored)
	if source == null:
		push_error("N64 textures: can't decode %s" % source_file)
		return null
	var result := N64TextureConverter.convert(source, settings)
	var tex := N64Texture.new()
	tex.apply_settings(settings)
	tex.palette = result.palette
	tex.tint_dark = result.tint_dark
	tex.tint_light = result.tint_light
	tex.tint_range = result.tint_range
	tex.source_path = stored
	tex.source_aspect = float(source.get_width()) / source.get_height()
	if settings.get("object", 0) != N64ObjectExtract.Kind.NONE:
		tex.source_aspect = settings.get("object_aspect", tex.source_aspect)
	tex.set_image(with_mipmaps(result.image))

	var path := texture_path(settings)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err := ResourceSaver.save(tex, path)
	if err != OK:
		push_error("N64 textures: failed to save %s (%s)" % [path, error_string(err)])
		return null
	tex.take_over_path(path)
	return tex


## Copy of an N64 texture image with Godot-generated mipmaps (2x2 box averages, so tiling
## stays seamless at every level). The base level keeps the exact N64 colours.
static func with_mipmaps(image: Image) -> Image:
	var out := image.duplicate() as Image
	if not out.has_mipmaps():
		out.generate_mipmaps()
	return out


static func _ensure_source_dir() -> void:
	DirAccess.make_dir_recursive_absolute(SOURCE_DIR)
	var ignore := SOURCE_DIR + "/.gdignore"
	if not FileAccess.file_exists(ignore):
		FileAccess.open(ignore, FileAccess.WRITE).close()
