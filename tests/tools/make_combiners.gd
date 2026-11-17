extends SceneTree
## Writes the starter screen combiners (ScreenLooks in Combiner mode) to game/looks/combiners/.
##   godot --headless --path . -s tests/tools/make_combiners.gd

const I := ScreenCombiner.Source


func _init() -> void:
	# Tharo's N64 bloom: the picture redrawn at half size (three times) and added back on
	# top - here with a bright pass first (FRAME x FRAME, twice) so lamps, windows and sky
	# spill into their surroundings while the rest stays put; cycle 2 leans a little of the
	# soft copy in for the glow's body.
	var bloom := _c(2, [I.BLUR, I.ZERO, I.ENVIRONMENT, I.FRAME], [I.BLUR, I.COMBINED, I.PRIM_ALPHA, I.COMBINED])
	bloom.primitive = Color(1, 1, 1, 0.0)
	bloom.environment = Color(0.9, 0.82, 0.7, 0)
	bloom.blur = ScreenCombiner.Blur.EIGHTH
	bloom.blur_bright = 2
	_save("bloom", bloom, 1.0, 1.5)
	# Peak out: 2 x picture - grey (a cool grey: warm channels clip first) - highlights burn
	# out to full like a hard sun, shadows sink.
	var peak := _c(1, [I.FRAME, I.ENVIRONMENT, I.ONE, I.FRAME])
	peak.environment = Color(0.36, 0.38, 0.44, 0)
	_save("sun_peak", peak, 0.5, 1.0)
	# Distance glow: far things lean into the soft copy and glow a little (hazy, dreamy).
	var glow := _c(2, [I.BLUR, I.FRAME, I.DEPTH, I.FRAME], [I.BLUR, I.ZERO, I.ENVIRONMENT, I.COMBINED])
	glow.environment = Color(0.16, 0.16, 0.18, 0)
	glow.blur = ScreenCombiner.Blur.EIGHTH
	glow.depth_far = 80.0
	_save("distance_glow", glow, 1.0, 2.0)
	# Static: the picture leaning into the RDP's noise (Lens of Truth, a failing memory).
	var stat := _c(1, [I.NOISE, I.FRAME, I.PRIM_ALPHA, I.FRAME])
	stat.primitive = Color(1, 1, 1, 0.3)
	_save("static", stat, 1.0, 0.5)
	# Fade to static: farther = more noise (the Nowhere room's edges).
	var far := _c(2, [I.NOISE, I.FRAME, I.DEPTH, I.FRAME], [I.COMBINED, I.ZERO, I.PRIMITIVE, I.ZERO])
	far.primitive = Color(0.85, 0.85, 0.95, 1)
	far.depth_far = 40.0
	_save("fade_to_static", far, 1.0, 1.0)
	# Corruption: the picture pushed up by a different amount per channel until bright
	# colours wrap past 1.5 into darks (the RDP's 9-bit overflow); cycle 2 leans half way
	# back to the picture.
	var wrap := _c(2, [I.FRAME, I.ZERO, I.PRIMITIVE, I.FRAME], [I.COMBINED, I.FRAME, I.ENV_ALPHA, I.FRAME])
	wrap.primitive = Color(0.75, 0.55, 0.95, 1)
	wrap.environment = Color(0, 0, 0, 0.6)
	_save("corruption", wrap, 1.0, 0.3)
	# Depth view (MM's debug z_viszbuf, IA): the picture replaced by distance - near ENV, far
	# PRIM - a stylised fog / silhouette look.
	var dv := _c(1, [I.PRIMITIVE, I.ENVIRONMENT, I.DEPTH, I.ENVIRONMENT])
	dv.primitive = Color(0.85, 0.9, 1.0)
	dv.environment = Color(0.1, 0.05, 0.2)
	dv.depth_far = 80.0
	_save("depth_view", dv, 1.0, 0.5)
	# Depth bands (its RGBA read): psychedelic contours of distance over the picture.
	var db := _c(2, [I.DEPTH_BANDS, I.ZERO, I.ONE, I.ZERO], [I.COMBINED, I.FRAME, I.PRIM_ALPHA, I.FRAME])
	db.primitive = Color(1, 1, 1, 0.7)
	_save("depth_bands", db, 1.0, 0.5)
	# Market test set (game/looks/combiners/market_*.tres).
	# Lamp bloom for evenings: a stronger bright pass (lamps, windows, string lights spill).
	var mb := _c(2, [I.BLUR, I.ZERO, I.ENVIRONMENT, I.FRAME], [I.BLUR, I.COMBINED, I.PRIM_ALPHA, I.COMBINED])
	mb.primitive = Color(1, 1, 1, 0.0)
	mb.environment = Color(1.0, 0.82, 0.55)
	mb.blur = ScreenCombiner.Blur.EIGHTH
	mb.blur_bright = 1
	mb.overflow = ScreenCombiner.Overflow.CLAMP
	_save("market_lamp_bloom", mb, 1.0, 2.0)
	# Noon heat: a gentler sun peak (warm channels clip first).
	var mp := _c(1, [I.FRAME, I.ENVIRONMENT, I.ONE, I.FRAME])
	mp.environment = Color(0.3, 0.33, 0.42)
	_save("market_noon_heat", mp, 0.35, 2.0)
	# Hazy distance: far stalls and roofs lean into the soft copy and glow.
	var mh := _c(2, [I.BLUR, I.FRAME, I.DEPTH, I.FRAME], [I.BLUR, I.ZERO, I.ENVIRONMENT, I.COMBINED])
	mh.environment = Color(0.12, 0.11, 0.1)
	mh.blur = ScreenCombiner.Blur.QUARTER
	mh.depth_far = 45.0
	_save("market_haze_glow", mh, 0.8, 2.0)
	# Dusk duotone (MM's VisMono: grey, then two colours): a memory / flashback look.
	var md := _c(2, [I.FRAME_I, I.ZERO, I.ONE, I.ZERO], [I.PRIMITIVE, I.ENVIRONMENT, I.COMBINED, I.ENVIRONMENT])
	md.primitive = Color(1.0, 0.86, 0.62)
	md.environment = Color(0.16, 0.08, 0.14)
	md.overflow = ScreenCombiner.Overflow.CLAMP
	_save("market_dusk_duotone", md, 1.0, 1.0)
	quit()


func _c(cycles: int, c1: Array, c2 := []) -> ScreenCombiner:
	var c := ScreenCombiner.new()
	c.cycles = cycles
	c.c1_a = c1[0]; c.c1_b = c1[1]; c.c1_c = c1[2]; c.c1_d = c1[3]
	if not c2.is_empty():
		c.c2_a = c2[0]; c.c2_b = c2[1]; c.c2_c = c2[2]; c.c2_d = c2[3]
	return c


func _save(name: String, c: ScreenCombiner, strength: float, blend: float) -> void:
	var look := ScreenLook.new()
	look.mode = ScreenLook.Mode.COMBINER
	look.combiner = c
	look.strength = strength
	look.blend_time = blend
	var path := "res://game/looks/combiners/%s.tres" % name
	print(path, ": ", ResourceSaver.save(look, path), "\n", c.formula())
