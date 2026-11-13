@tool
class_name GradePalettes
extends RefCounted
## Colour palettes for the Palette filter: .hex (Lospec: one rrggbb per line), .gpl (GIMP)
## or .png (its distinct colours) under DIR. Lospec palettes download by name
## (lospec.com/palette-list/<name>). DIR has a .gdignore.

const DIR := "res://textures/_grade/palettes"


static func list() -> PackedStringArray:
	ensure_dir()
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(DIR):
		if f.get_extension().to_lower() in ["hex", "gpl", "png"]:
			out.append(DIR.path_join(f))
	out.sort()
	return out


static func lospec_url(slug: String) -> String:
	return "https://lospec.com/palette-list/%s.hex" % slug.strip_edges().to_lower()


static func path_for(slug: String) -> String:
	return DIR.path_join(slug.strip_edges().to_lower().validate_filename() + ".hex")


## A palette file's colours (empty if unreadable).
static func load_colours(path: String) -> PackedColorArray:
	var out := PackedColorArray()
	if path == "" or not FileAccess.file_exists(path):
		return out
	match path.get_extension().to_lower():
		"hex":
			for line in FileAccess.get_file_as_string(path).split("\n"):
				var h := line.strip_edges().trim_prefix("#")
				if h.length() >= 6 and h.substr(0, 6).is_valid_hex_number():
					out.append(Color.html(h.substr(0, 6)))
		"gpl":
			for line in FileAccess.get_file_as_string(path).split("\n"):
				var parts := line.strip_edges().split_floats(" ", false)
				if parts.size() >= 3 and not line.begins_with("#") and line.strip_edges()[0].is_valid_int():
					out.append(Color8(int(parts[0]), int(parts[1]), int(parts[2])))
		"png":
			var img := Image.load_from_file(path)
			if img:
				img.convert(Image.FORMAT_RGBA8)
				var seen := {}
				for y in img.get_height():
					for x in img.get_width():
						var c := img.get_pixel(x, y)
						if c.a > 0.5 and not seen.has(c.to_rgba32()):
							seen[c.to_rgba32()] = true
							out.append(Color(c, 1.0))
							if out.size() >= 256:
								return out
	return out


## A strip image of the colours (for a swatch).
static func swatch(colours: PackedColorArray, h := 1) -> Image:
	var img := Image.create(maxi(colours.size(), 1), h, false, Image.FORMAT_RGBA8)
	for i in colours.size():
		for y in h:
			img.set_pixel(i, y, colours[i])
	return img


static func ensure_dir() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	if not FileAccess.file_exists(DIR.path_join(".gdignore")):
		FileAccess.open(DIR.path_join(".gdignore"), FileAccess.WRITE).store_string("")
