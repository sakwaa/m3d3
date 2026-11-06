@tool
extends EditorExportPlugin
## Builds ship banks and songs without authoring data: each sample's recording path, hash
## and processing settings, each song's MIDI parts, and CD64 import / library tags (on
## samples, instruments, bank sets) are cleared. Everything in this addon is left out
## (export presets too), and of the instrument library its index and recordings (the game
## loads bank sets, which reference the instrument and sample files they need).

const TOOLS_DIR := "res://addons/n64_audio_tools/"


func _get_name() -> String:
	return "N64AudioToolsStrip"


func _begin_customize_resources(_platform: EditorExportPlatform, _features: PackedStringArray) -> bool:
	return true


func _get_customization_configuration_hash() -> int:
	return 2


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if path.begins_with(TOOLS_DIR) or _skips(path, _library_root()):
		skip()


## The library's index (editor only) and recordings (_source is ignored by Godot anyway).
static func _skips(path: String, root: String) -> bool:
	return path == root + "/library.tres" or path.begins_with(root + "/_source/")


static func _library_root() -> String:
	var p := str(ProjectSettings.get_setting("n64/audio/library_path", "res://audio/library"))
	return (p if p != "" else "res://audio/library").trim_suffix("/")


func _customize_resource(resource: Resource, _path: String) -> Resource:
	return stripped(resource)


## `resource` as builds ship it (a stripped copy), or null if it ships as it is.
static func stripped(resource: Resource) -> Resource:
	if "Samples" in resource and "Instruments" in resource:
		var bank := resource.duplicate(true)
		for s in bank.Samples:
			_strip(s)
		for ins in bank.Instruments:
			_untag(ins)
		return bank
	# Songs: the MIDI parts they were built from (paths, part settings) stay home.
	if "Events" in resource and "Tracks" in resource:
		var song := resource.duplicate()
		song.Tracks = []
		return song
	if "Adpcm" in resource and "SourcePath" in resource:
		var s := resource.duplicate(true)
		_strip(s)
		return s
	# Library instruments and bank sets, music and sound-effect sets alike (zones / entries
	# keep referencing the files; areas ship as they are).
	if ("Zones" in resource and "Envelope" in resource) or ("Entries" in resource and "Kind" in resource):
		var r := resource.duplicate()
		_untag(r)
		return r
	return null


static func _strip(s: Resource) -> void:
	if s:
		s.SourcePath = ""
		s.SourceHash = ""
		s.Settings = {}
		_untag(s)


## Provenance of CD64 imports (N64Cd64Importer.TagMeta / IdMeta / ChannelMeta,
## N64LibraryTools.NameMeta / VariantMeta).
static func _untag(r: Resource) -> void:
	if r:
		for m in [&"cd64_export", &"cd64_id", &"cd64_channel", &"cd64_name", &"variant_of"]:
			if r.has_meta(m):
				r.remove_meta(m)
