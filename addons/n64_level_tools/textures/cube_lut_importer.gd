@tool
extends EditorImportPlugin
## Imports Adobe / Resolve .cube colour LUTs as LUT strip textures (LutFile: N slices of
## N x N, at most 32 levels), so a downloaded .cube can be dropped onto a ScreenLook or the
## texture grade like any image, and ships with the game as an ordinary texture.


func _get_importer_name() -> String:
	return "n64.cube_lut"


func _get_visible_name() -> String:
	return "N64 LUT (.cube)"


func _get_recognized_extensions() -> PackedStringArray:
	return PackedStringArray(["cube"])


func _get_save_extension() -> String:
	return "res"


func _get_resource_type() -> String:
	return "ImageTexture"


func _get_preset_count() -> int:
	return 1


func _get_preset_name(_i: int) -> String:
	return "Default"


func _get_import_options(_path: String, _preset: int) -> Array[Dictionary]:
	return [{name = "max_levels", default_value = 32, property_hint = PROPERTY_HINT_RANGE, hint_string = "8,64,1"}]


func _get_option_visibility(_path: String, _option: StringName, _options: Dictionary) -> bool:
	return true


func _get_priority() -> float:
	return 1.0


func _get_import_order() -> int:
	return 0


func _import(source_file: String, save_path: String, options: Dictionary, _platform_variants: Array[String], _gen_files: Array[String]) -> Error:
	var strip := LutFile.strip_from_cube(FileAccess.get_file_as_string(source_file), int(options.get("max_levels", 32)))
	if strip == null:
		push_error("N64 LUT import: %s isn't a 3D .cube LUT." % source_file)
		return ERR_PARSE_ERROR
	return ResourceSaver.save(ImageTexture.create_from_image(strip), "%s.%s" % [save_path, _get_save_extension()])
