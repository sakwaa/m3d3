extends Node
## Screenshot of the dialogue box (a talk line and a sign) for checking the text look.
##   OUT=/path.png [OLD=1: the 12-px raster] tools/godot_run.sh --path . --resolution 1920x1080 tests/ui/dialogue_shot.tscn


func _ready() -> void:
	var box := DialogueBox.new()
	if OS.get_environment("OLD") != "":
		var f := box.font as FontFile
		f.fixed_size = 12
		f.fixed_size_scale_mode = TextServer.FIXED_SIZE_SCALE_INTEGER_ONLY
	add_child(box)
	var bg := ColorRect.new()
	bg.color = Color(0.35, 0.5, 0.4)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	var under := CanvasLayer.new()
	under.layer = -1
	under.add_child(bg)
	add_child(under)
	box.show_line({style = DialogueLine.Style.BOX, name = "Tomas", color = Color.ORANGE, icon = null,
		text = "Morning! The market opens at six, but the baker\nalways sneaks out early. Wanna try a roll? 123 ?!"})
	box._finish_page()
	for i in 10:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OS.get_environment("OUT"))
	get_tree().quit()
