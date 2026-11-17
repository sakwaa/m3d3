extends SceneTree
## N64Synth output options check + listening WAVs (N64OutputCheck.cs).
##   Godot --headless --path . --script res://tests/audio/output_check.gd -- <out dir>


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else OS.get_user_data_dir() + "/n64_output_check"
	var check = load("res://addons/n64_audio_tools/tests/N64OutputCheck.cs").new()
	var fails: int = check.Run(out)
	print("WAVs in ", out)
	quit(1 if fails > 0 else 0)
