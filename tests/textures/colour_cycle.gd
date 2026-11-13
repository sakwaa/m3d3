extends Node
## Colour cycling (N64Texture.cycle_count): a CI texture rebuilt with a cycle becomes a
## flipbook of its palette shifting along, frame k = the colours moved k steps; the shader
## gets it as a flipbook. Saves the sheet to OUT (if set). Prints PASS / FAIL.
##   [OUT=dir] godot --path . tests/textures/colour_cycle.tscn  (a window: headless can't read the rebuilt image back)
var fails := 0


func check(label: String, ok: bool, got := "") -> void:
	print(("PASS " if ok else "FAIL ") + label + ("  (%s)" % got if got != "" else ""))
	if not ok:
		fails += 1


func _ready() -> void:
	var src := load("res://textures/water/water_6.res") as N64Texture
	var t := src.duplicate() as N64Texture  # (unsaved copy: the project's texture stays as it is)
	t.take_over_path("")
	check("source is CI with a palette", t.format in [N64TextureConverter.Format.CI4, N64TextureConverter.Format.CI8] and t.palette.size() > 2,
		"%s, %d colours" % [N64TextureConverter.FORMAT_NAMES[t.format], t.palette.size()])
	t.cycle_from = 0
	t.cycle_count = 8
	t.cycle_fps = 6.0
	var err := t.rebuild()
	check("rebuilds", err == OK, error_string(err))
	var img := t.get_image()
	img.clear_mipmaps()
	var frame := t.texture_size
	check("sheet holds 8 frames (3 x 3 grid)", img.get_size() == frame * 3, "%s for frames of %s" % [img.get_size(), frame])
	var flip: Vector4 = t.anim_params()[1]
	check("shader gets it as a flipbook", flip == Vector4(3, 3, 8, 6.0), str(flip))
	# Frame 1 = frame 0 with every cycled colour one step on.
	var opaque := t.palette.slice(1) if t.palette[0].a < 0.5 else t.palette
	var step := {}
	for i in 8:
		step[(opaque[i] as Color).to_rgba32()] = (opaque[(i + 1) % 8] as Color).to_rgba32()
	var ok := true
	var changed := 0
	for y in frame.y:
		for x in frame.x:
			var a := img.get_pixel(x, y).to_rgba32()
			var b := img.get_pixel(frame.x + x, y).to_rgba32()
			var want: int = step.get(a, a)
			ok = ok and b == want
			changed += int(b != a)
	check("frame 1 = each cycled colour one step on", ok and changed > 0, "%d texels changed" % changed)
	check("palette sorted darkest first", opaque[0].get_luminance() <= opaque[opaque.size() - 1].get_luminance())
	if OS.get_environment("OUT") != "":
		DirAccess.make_dir_recursive_absolute(OS.get_environment("OUT"))
		img.resize(img.get_width() * 4, img.get_height() * 4, Image.INTERPOLATE_NEAREST)
		img.save_png(OS.get_environment("OUT").path_join("cycle_sheet.png"))
	print("DONE fails=%d" % fails)
	get_tree().quit()
