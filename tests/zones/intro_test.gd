extends Node
## Area intro (Zone.play_intro): travels into ZONE through the ZoneManager as on a first
## visit and saves frames at AT seconds after arrival (comma separated) into OUT; then
## travels in again to check it doesn't play twice.
##   ZONE=res://... OUT=dir [AT=0.3,2.5,4,6.2] tools/godot_run.sh --path . --resolution 1280x720 tests/zones/intro_test.tscn


func _ready() -> void:
	var shooter := Node.new()
	shooter.set_script(_Shooter)
	get_tree().root.add_child.call_deferred(shooter)
	ZoneManager.travel.call_deferred(OS.get_environment("ZONE"))


class _Shooter:
	extends Node

	func _ready() -> void:
		var at := (OS.get_environment("AT") if OS.get_environment("AT") != "" else "0.3,2.5,4,6.2").split(",")
		await ZoneManager.zone_changed
		var start := Time.get_ticks_msec()
		print("arrived; intro playing: ", Cutscenes.is_playing())
		for t in at:
			while (Time.get_ticks_msec() - start) / 1000.0 < float(t):
				await get_tree().process_frame
			get_viewport().get_texture().get_image().save_png("%s/intro_%s.png" % [OS.get_environment("OUT"), t])
			print("t %s: playing %s" % [t, Cutscenes.is_playing()])
		while Cutscenes.is_playing():
			await get_tree().process_frame
		ZoneManager.travel(OS.get_environment("ZONE"))
		await ZoneManager.zone_changed
		await get_tree().process_frame
		print("second visit; intro playing: ", Cutscenes.is_playing())
		get_tree().quit()
