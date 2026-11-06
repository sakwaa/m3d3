extends SceneTree
## Parity reference generator entry point (test-only; see N64ParityRefGen.cs).
## godot --headless --path <m3d3> -s res://addons/n64_audio_tools/tests/make_reference.gd -- <plugin/tests> <out dir>


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		push_error("usage: -- <plugin tests dir> <reference out dir>")
		quit(2)
		return
	var gen = load("res://addons/n64_audio_tools/tests/N64ParityRefGen.cs").new()
	quit(gen.Run(args[0], args[1]))
