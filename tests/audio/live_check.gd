extends SceneTree
## N64Synth playing live: mixing thread + DAC output stage, a note started from the main
## thread while the thread mixes; the note's voice must decay away (the thread is mixing).
##   Godot --path . --script res://tests/audio/live_check.gd   (with a window: a real audio driver)

var _synth: Node
var _t := 0.0
var _phase := 0


func _init() -> void:
	var check = load("res://addons/n64_audio_tools/tests/N64OutputCheck.cs").new()
	_synth = ClassDB.instantiate(&"N64Synth") if ClassDB.class_exists(&"N64Synth") else load("res://game/audio/N64Synth.cs").new()
	_synth.set(&"Bank", check.MakeBank())
	_synth.call(&"SetReverbPreset", "dungeon")
	root.add_child.call_deferred(_synth)


func _process(delta: float) -> bool:
	_t += delta
	if _phase == 0 and _t > 0.3:
		_phase = 1
		print("mix rate ", AudioServer.get_mix_rate(), " driver ", AudioServer.get_driver_name() if AudioServer.has_method(&"get_driver_name") else "")
		for k in [60, 64, 67]:
			_synth.call(&"NoteOn", 0, k, 110)
		print("voices after note-on ", _synth.call(&"ActiveVoices"))
	elif _phase == 1 and _t > 0.8:
		_phase = 2
		for k in [60, 64, 67]:
			_synth.call(&"NoteOff", 0, k)
		print("voices at note-off ", _synth.call(&"ActiveVoices"))
	elif _phase == 2 and _t > 2.0:
		var left: int = _synth.call(&"ActiveVoices")
		print("voices 1.2 s after note-off ", left, " -> ", "PASS (thread mixed them out)" if left == 0 else "FAIL (nothing mixed)")
		quit(0 if left == 0 else 1)
	return false
