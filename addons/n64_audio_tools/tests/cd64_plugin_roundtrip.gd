extends SceneTree
## Round trip of a real CD64 plugin export (cd64 convert / the plugin's Export) through
## N64Cd64Importer: every imported sample must decode to exactly the export's samples/*.wav.
## Imports into a throwaway bank and deletes it (and its copied recordings) afterwards.
##   Godot --headless --path . --script res://addons/n64_audio_tools/tests/cd64_plugin_roundtrip.gd -- <export folder>

const BANK := "res://audio/banks/zz_cd64_roundtrip.res"


func _initialize() -> void:
	var export_dir: String = OS.get_cmdline_user_args()[0]
	var imp = load("res://addons/n64_audio_tools/cs/N64Cd64Importer.cs").new()
	var err: String = imp.Import(export_dir, BANK)
	var fails := 0
	if err != "":
		print("FAIL import: ", err)
		quit(1)
		return
	print("  ", imp.Summary)
	var bank = ResourceLoader.load(BANK, "", ResourceLoader.CACHE_MODE_IGNORE)
	var sidecar: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(imp.SidecarFor(export_dir)))
	var by_name := {}
	for s in bank.Samples:
		by_name[s.Name] = s
	for entry in sidecar.samples:
		var s = by_name.get(entry.name)
		var wav := FileAccess.get_file_as_bytes(export_dir.path_join(entry.preview))
		var pcm: PackedByteArray = s.PcmBytes() if s else PackedByteArray()
		# data chunk is last in our WAVs: compare the tail
		var ok: bool = s != null and wav.size() >= pcm.size() and wav.slice(wav.size() - pcm.size()) == pcm
		if not ok:
			fails += 1
			print("FAIL ", entry.id)
	print("%d samples, %d instruments, %d mismatches" % [sidecar.samples.size(), bank.Instruments.size(), fails])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(BANK))
	var src := ProjectSettings.globalize_path("res://audio/_source/zz_cd64_roundtrip")
	for f in DirAccess.get_files_at(src):
		DirAccess.remove_absolute(src.path_join(f))
	DirAccess.remove_absolute(src)
	quit(1 if fails else 0)
