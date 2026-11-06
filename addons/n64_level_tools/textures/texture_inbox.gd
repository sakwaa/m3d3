class_name TextureInbox
extends RefCounted
## Watches a folder (e.g. ~/Downloads) for new texture downloads. Files are reported once
## their size has stopped changing; archives are extracted and their colour maps returned
## (zip natively; rar / 7z through the system's bsdtar, which ships with macOS).
## Downloads stay a normal, logged-in browser action — this only picks up the results.

const IMAGE_EXTENSIONS := ["png", "jpg", "jpeg", "webp", "tga", "bmp"]
const ARCHIVE_EXTENSIONS := ["zip", "rar", "7z"]
const EXTRACT_DIR := "user://n64_texture_inbox"

var folder := ""
var _started := 0
var _sizes := {}  # path -> last seen size (pending)
var _done := {}   # path -> true (handled)


func start(path: String) -> void:
	folder = path
	_started = int(Time.get_unix_time_from_system())
	_sizes.clear()
	_done.clear()


func stop() -> void:
	folder = ""


func is_watching() -> bool:
	return not folder.is_empty()


## Call periodically. Returns image paths ready to import (archives already extracted).
func poll() -> PackedStringArray:
	var ready := PackedStringArray()
	if folder.is_empty() or not DirAccess.dir_exists_absolute(folder):
		return ready
	for file in DirAccess.get_files_at(folder):
		var ext := file.get_extension().to_lower()
		if not (ext in IMAGE_EXTENSIONS or ext in ARCHIVE_EXTENSIONS):
			continue  # includes Chrome's .crdownload partials
		var path := folder.path_join(file)
		if _done.has(path) or FileAccess.get_modified_time(path) < _started:
			continue
		var size := _file_size(path)
		if _sizes.get(path, -1) != size or size == 0:
			_sizes[path] = size  # still downloading; check again next poll
			continue
		_done[path] = true
		_sizes.erase(path)
		if ext == "zip":
			ready.append_array(extract_zip(path))
		elif ext in ARCHIVE_EXTENSIONS:
			ready.append_array(extract_archive(path))
		else:
			ready.append(path)
	return ready


## Extracts the colour maps of a texture zip; skips normal/bump/roughness/... maps.
static func extract_zip(zip_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var zip := ZIPReader.new()
	if zip.open(zip_path) != OK:
		push_error("Texture inbox: can't open %s" % zip_path)
		return out
	var dest := EXTRACT_DIR.path_join(zip_path.get_file().get_basename())
	DirAccess.make_dir_recursive_absolute(dest)
	for entry in zip.get_files():
		var name := entry.get_file()
		if name.is_empty() or name.begins_with(".") or entry.contains("__MACOSX"):
			continue
		if not name.get_extension().to_lower() in IMAGE_EXTENSIONS or N64TextureConverter.is_non_color_map(name):
			continue
		var path := dest.path_join(name)
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(zip.read_file(entry))
		f.close()
		out.append(ProjectSettings.globalize_path(path))
	zip.close()
	return out


## Extracts the colour maps of a rar / 7z with bsdtar (entries are flattened by name;
## bsdtar refuses absolute and ".." paths).
static func extract_archive(archive_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var listing := []
	if OS.execute("bsdtar", ["-tf", archive_path], listing) != 0 or listing.is_empty():
		push_error("Texture inbox: can't read %s (needs bsdtar)" % archive_path)
		return out
	var dest := ProjectSettings.globalize_path(EXTRACT_DIR.path_join(archive_path.get_file().get_basename()))
	DirAccess.make_dir_recursive_absolute(dest)
	for entry in String(listing[0]).split("\n", false):
		var name := entry.get_file()
		if name.is_empty() or name.begins_with(".") or entry.contains("__MACOSX"):
			continue
		if not name.get_extension().to_lower() in IMAGE_EXTENSIONS or N64TextureConverter.is_non_color_map(name):
			continue
		var path := dest.path_join(name)
		if OS.execute("bsdtar", ["-xf", archive_path, "-C", dest, "-s", "|.*/||", entry]) == 0 and FileAccess.file_exists(path):
			out.append(path)
	return out


static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var size := f.get_length()
	f.close()
	return size
