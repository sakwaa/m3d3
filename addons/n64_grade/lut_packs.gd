@tool
class_name LutPacks
extends RefCounted
## LUT packs for the Grade screen's LUT filter: folders of LUTs under DIR (one folder per
## pack), each LUT a small strip PNG (LutFile's form, 32 levels). Importing takes a folder or
## .zip of HaldCLUT PNGs / .cube files (film emulation packs: RawTherapee's HaldCLUT
## collection, G'MIC presets exported as HaldCLUTs...) and converts each. DIR has a
## .gdignore: Godot doesn't import them; LutFile reads the files directly.

const DIR := "res://textures/_grade/luts"
const LEVELS := 32


static func packs() -> PackedStringArray:
	_ensure_dir()
	var out := PackedStringArray(DirAccess.get_directories_at(DIR))
	out.sort()
	return out


## LUT files of a pack (paths), sorted by name.
static func luts(pack: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DIR.path_join(pack)
	for f in DirAccess.get_files_at(d):
		if f.get_extension().to_lower() in ["png", "cube"]:
			out.append(d.path_join(f))
	out.sort()
	return out


## Imports every LUT in `source` (a folder, searched recursively, or a .zip) into pack
## `name`. Returns [imported, skipped]. `progress` (optional): called (done, total).
static func import_pack(source: String, name: String, progress := Callable()) -> Array:
	_ensure_dir()
	var dest := DIR.path_join(_safe(name))
	DirAccess.make_dir_recursive_absolute(dest)
	var items := []  # [file name, PackedByteArray or path]
	if source.get_extension().to_lower() == "zip":
		var z := ZIPReader.new()
		if z.open(source) != OK:
			return [0, 0]
		for f in z.get_files():
			if _is_lut(f):
				items.append([f.get_file(), z.read_file(f)])
		z.close()
	else:
		for f in _walk(source):
			items.append([f.get_file(), f])
	var done := 0
	var skipped := 0
	for i in items.size():
		var file: String = items[i][0]
		var strip: Image = null
		if items[i][1] is PackedByteArray:
			var bytes: PackedByteArray = items[i][1]
			if file.get_extension().to_lower() == "cube":
				strip = LutFile.strip_from_cube(bytes.get_string_from_utf8(), LEVELS)
			else:
				var img := Image.new()
				if img.load_png_from_buffer(bytes) == OK:
					strip = LutFile.strip_from_image(img, LEVELS)
		else:
			strip = LutFile.load_strip(items[i][1], LEVELS)
		if strip == null:
			skipped += 1
		else:
			strip.save_png(dest.path_join(_safe(file.get_basename()) + ".png"))
			done += 1
		if progress.is_valid():
			progress.call(i + 1, items.size())
	return [done, skipped]


static func _is_lut(f: String) -> bool:
	return f.get_extension().to_lower() in ["png", "cube"] and not f.get_file().begins_with(".")


static func _walk(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(dir):
		if _is_lut(f):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		out.append_array(_walk(dir.path_join(d)))
	return out


static func _safe(s: String) -> String:
	return s.strip_edges().validate_filename().replace(" ", "_")


static func _ensure_dir() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	if not FileAccess.file_exists(DIR.path_join(".gdignore")):
		FileAccess.open(DIR.path_join(".gdignore"), FileAccess.WRITE).store_string("")
