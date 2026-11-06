extends SceneTree
## Imports the hi-res textures dropped in res://texture_inbox, the same way the N64
## Textures panel does (Claude runs it when asked to "import the inbox"):
##   Godot --headless --path . --script res://addons/n64_level_tools/textures/inbox_import.gd -- list <out.json>
##   Godot --headless --path . --script res://addons/n64_level_tools/textures/inbox_import.gd -- import <plan.json> <out.json> [sheet.png]
## list: every inbox image (archives extracted, non-colour maps skipped) with the settings
##   the panel would pick (file name rules + image analysis).
## import: plan = [{file, archive, ...setting overrides}]: converts each with its guessed settings
##   plus the overrides, saves textures/<category>/<name>.res (source kept in
##   textures/_source), deletes the inbox file, and optionally writes a contact sheet of
##   the results.
## Settings in JSON: enums as ints, size [w, h], crop_center [x, y], colours [r, g, b, a].

const C := preload("res://addons/n64_level_tools/textures/n64_texture_converter.gd")
const INBOX := "res://texture_inbox"

var _imported := PackedStringArray()


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var out := {}
	if args.size() >= 2 and args[0] == "list":
		out = {items = _list()}
		_write(args[1], out)
	elif args.size() >= 3 and args[0] == "import":
		var plan = JSON.parse_string(FileAccess.get_file_as_string(args[1]))
		out = {results = _import(plan if plan is Array else [], args[3] if args.size() > 3 else "")}
		_write(args[2], out)
	else:
		printerr("usage: -- list <out.json> | -- import <plan.json> <out.json> [sheet.png]")
	quit()


## Inbox images ready to convert: plain images, and colour maps out of archives.
## {file, archive} (archive: the inbox file it came from, or the file itself).
func _sources() -> Array:
	var dir := ProjectSettings.globalize_path(INBOX)
	DirAccess.make_dir_recursive_absolute(dir)
	var out := []
	for file in DirAccess.get_files_at(dir):
		var path := dir.path_join(file)
		var ext := file.get_extension().to_lower()
		var maps := PackedStringArray()
		if ext == "zip":
			maps = TextureInbox.extract_zip(path)
		elif ext in TextureInbox.ARCHIVE_EXTENSIONS:
			maps = TextureInbox.extract_archive(path)
		elif ext in TextureInbox.IMAGE_EXTENSIONS and not C.is_non_color_map(file):
			maps = PackedStringArray([path])
		for m in maps:
			out.append({file = m, archive = path})
	return out


## The panel's automatic settings for one image.
func _guess(path: String, source: Image) -> Dictionary:
	var aspect := float(source.get_width()) / source.get_height()
	var s := C.guess_settings(path, source.detect_alpha() != Image.ALPHA_NONE, aspect)
	var a := N64ObjectExtract.analyse(source, path)
	if a.background and a.kind != N64ObjectExtract.Kind.NONE:
		C.apply_object(s, a.kind, a.mirror, a.aspect, a.holes)
	elif s.zoom_auto:
		N64TextureAnalysis.apply(N64TextureAnalysis.measure(source), s)
		if s.tiling == C.Tiling.NONE:
			s.zoom_auto = false
	return s


func _list() -> Array:
	var items := []
	for src: Dictionary in _sources():
		var path: String = src.file
		var source := N64TextureLibrary.load_preview_source(path)
		if source == null:
			items.append({file = path, archive = src.archive, error = "unreadable"})
			continue
		items.append({file = path, archive = src.archive, width = source.get_width(), height = source.get_height(),
			alpha = source.detect_alpha() != Image.ALPHA_NONE, settings = _to_json(_guess(path, source))})
	return items


func _import(plan: Array, sheet: String) -> Array:
	var results := []
	var images: Array[Image] = []
	for entry: Dictionary in plan:
		var path: String = entry.get("file", "")
		var source := N64TextureLibrary.load_preview_source(path)
		if source == null:
			results.append({file = path, error = "unreadable"})
			continue
		var s := _guess(path, source)
		for key in entry:
			if key != "file" and key != "archive" and s.has(key):
				s[key] = _from_json(entry[key], s[key])
		var tex := N64TextureLibrary.import_image(path, s, source)
		if tex == null:
			results.append({file = path, error = "import failed"})
			continue
		images.append(tex.get_image())
		results.append({file = path, path = N64TextureLibrary.texture_path(s), category = s.category, name = s.name,
			format = C.FORMAT_NAMES[s.format], size = [s.size.x, s.size.y], usage = C.USAGE_NAMES[s.usage],
			tiling = C.TILING_NAMES[s.tiling]})
		# Imported: the inbox file goes (a copy stays in textures/_source; an archive goes
		# once all its maps are in).
		_imported.append(entry.get("archive", path))
	var inbox := ProjectSettings.globalize_path(INBOX)
	for f in _imported:
		if f.begins_with(inbox) and FileAccess.file_exists(f):
			DirAccess.remove_absolute(f)
	if sheet != "" and not images.is_empty():
		_contact_sheet(images).save_png(sheet)
	return results


## Results side by side, each tiled 2x2 (seams show) and scaled up 4x.
func _contact_sheet(images: Array[Image]) -> Image:
	var cell := 256
	var cols := mini(images.size(), 4)
	var rows := ceili(images.size() / float(cols))
	var out := Image.create(cols * (cell + 8), rows * (cell + 8), false, Image.FORMAT_RGBA8)
	out.fill(Color(0.15, 0.15, 0.15))
	for i in images.size():
		var img := images[i].duplicate() as Image
		if img.is_compressed():
			img.decompress()
		img.clear_mipmaps()
		img.convert(Image.FORMAT_RGBA8)
		var tile := Image.create(img.get_width() * 2, img.get_height() * 2, false, Image.FORMAT_RGBA8)
		for k in 4:
			tile.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i(k % 2, k / 2) * img.get_size())
		var k := float(cell) / maxi(tile.get_width(), tile.get_height())
		tile.resize(maxi(1, int(tile.get_width() * k)), maxi(1, int(tile.get_height() * k)), Image.INTERPOLATE_NEAREST)
		out.blit_rect(tile, Rect2i(Vector2i.ZERO, tile.get_size()), Vector2i(i % cols, i / cols) * (cell + 8) + Vector2i(4, 4))
	return out


func _to_json(s: Dictionary) -> Dictionary:
	var out := {}
	for k in s:
		var v = s[k]
		if v is Vector2i or v is Vector2:
			out[k] = [v.x, v.y]
		elif v is Color:
			out[k] = [v.r, v.g, v.b, v.a]
		else:
			out[k] = v
	return out


## A JSON value as the type of the setting it replaces.
func _from_json(v, like):
	if like is Vector2i:
		return Vector2i(int(v[0]), int(v[1]))
	if like is Vector2:
		return Vector2(v[0], v[1])
	if like is Color:
		return Color(v[0], v[1], v[2], v[3] if v.size() > 3 else 1.0)
	if like is int:
		return int(v)
	if like is float:
		return float(v)
	if like is bool:
		return bool(v)
	return v


func _write(path: String, data: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "\t"))
