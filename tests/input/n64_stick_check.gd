extends SceneTree
## N64Stick.shape check: key readings and a picture (OUT/stick.png): left, the raw round
## stick coloured by its direction; right, where each reading lands after shaping
## (octagon gate, notch snapping, per-axis dead zone, steps).  -- <out dir>

func _init() -> void:
	var cases := {
		"full forward": Vector2(0, -1), "full diagonal": Vector2(0.7071, -0.7071),
		"between notches (22.5 deg)": Vector2.from_angle(deg_to_rad(-67.5)),
		"5 deg off forward": Vector2.from_angle(deg_to_rad(-85.0)),
		"forward + slight drift": Vector2(0.07, -0.9), "small push": Vector2(0, -0.12),
		"75% forward": Vector2(0, -0.75), "half forward": Vector2(0, -0.5),
	}
	for k in cases:
		var o := N64Stick.shape(cases[k])
		print("%-28s in %s -> out (%.3f, %.3f) len %.3f angle %.1f" % [k, cases[k], o.x, o.y, o.length(), rad_to_deg(o.angle()) if o != Vector2.ZERO else 0.0])
	var n := 256
	var img := Image.create(n * 2 + 8, n, false, Image.FORMAT_RGB8)
	img.fill(Color(0.12, 0.12, 0.14))
	for y in n:
		for x in n:
			var v := Vector2(x, y) / (n - 1) * 2.0 - Vector2.ONE
			if v.length() > 1.0:
				continue
			var col := Color.from_hsv(fposmod(v.angle() / TAU, 1.0), clampf(v.length(), 0.0, 1.0), 1.0)
			img.set_pixel(x, y, col)
			var o := N64Stick.shape(v)
			var p := ((o + Vector2.ONE) * 0.5 * (n - 1)).round()
			img.set_pixel(n + 8 + int(p.x), int(p.y), col)
	var out := OS.get_cmdline_user_args()[0]
	img.save_png(out + "/stick.png")
	quit()
