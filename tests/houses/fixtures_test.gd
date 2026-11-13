extends Node3D
## House fronts (headless): shop opening offset, timber posts / rails, doors / windows / signs
## tied to their house (adopt, window spots, add_windows, kept on their walls through a
## resize, sliding along a wall). Prints PASS / FAIL.

var fails := 0
var root: LevelRoot


func check(name: String, ok: bool, got := "") -> void:
	print(("PASS " if ok else "FAIL ") + name + ("  (%s)" % got if got != "" else ""))
	if not ok:
		fails += 1


func _ready() -> void:
	# Builder: the shop opening slides along the front, the room behind with it.
	var spec := HouseSpec.new()
	spec.width = 8.0
	spec.depth = 6.0
	spec.storeys = 2
	spec.shopfront = true
	spec.shop_opening = 3.0
	var centred := _xrange(HouseBuilder.build(spec), spec.floor_texture, true)
	spec.shop_offset = 1.5
	var moved := _xrange(HouseBuilder.build(spec), spec.floor_texture, true)
	check("shop offset slides the room / counter over", absf((moved.x - centred.x) - 1.5) < 0.01, "%s -> %s" % [centred, moved])
	spec.shop_offset = 50.0
	check("shop offset kept inside the wall", spec.shop_span().x + spec.shop_span().y <= spec.width * 0.5 - 0.2, str(spec.shop_span()))
	spec.shop_offset = 0.0
	var plain := HouseBuilder.build(spec).size()
	spec.front_posts = PackedFloat32Array([-3.0, 0.0, 3.0])
	spec.rails = PackedFloat32Array([0.9])
	var timbered := HouseBuilder.build(spec)
	var trim := timbered.filter(func(f): return f.texture == spec.trim_texture).size()
	check("posts and rails add timber faces", trim > 0 and timbered.size() > plain, "%d trim faces" % trim)
	var middle_post := timbered.filter(func(f): return f.texture == spec.trim_texture and absf(f.pts[0].x) < 0.2 and f.normal.z > 0.9)
	var low := INF
	for f in middle_post:
		for p in f.pts:
			low = minf(low, p.y)
	check("a post over the shop opening starts above it", low > spec.foundation + spec.shop_height - 0.05, "bottom %.2f" % low)
	spec.front_posts = PackedFloat32Array()
	spec.rails = PackedFloat32Array()
	check("unset new settings don't change the house's key", _key_without_later(spec) == spec.key())
	# Level: a shop with its sign, tied, filled with windows, resized.
	root = LevelRoot.new()
	root.data = LevelData.new()
	add_child(root)
	var h := LevelBrush.new()
	h.tag = &"house_test"
	h.house = spec
	root.data.add_brush(h)
	root._generate_house(h)
	var sign := LevelBrush.new()
	sign.tag = &"sign_test"
	var ps := PropSpec.new()
	ps.kind = PropSpec.Kind.SIGN
	sign.prop = ps
	sign.transform = h.transform * Transform3D(Basis(), Vector3(0, spec.foundation + spec.shop_height + 0.8, spec.depth * 0.5))
	root.data.add_brush(sign)
	check("adopt ties the sign to the front", HouseFixtures.adopt(root.data) == 1 and sign.host == h.tag and int(sign.mount.z) == 0,
		"host %s mount %s" % [sign.host, sign.mount])
	var spots := HouseFixtures.window_spots(root.data, h, Vector2(0.9, 1.0))
	check("window spots: 2 sides downstairs, front x2 + sides upstairs", spots.size() == 6, str(spots))
	var windows := HouseFixtures.add_windows(root, h)
	check("add_windows cuts and ties them", windows.size() == 6 and windows.all(func(w): return w.host == h.tag and w.window.carved))
	check("again: no free spots left", HouseFixtures.add_windows(root, h).is_empty())
	var side_win: LevelBrush = windows.filter(func(w): return int(w.mount.z) == 1)[0]
	spec.width = 10.0
	root._generate_house(h)
	var expect_x := 5.0 - HouseFixtures._thickness(spec) * 0.5
	check("resized: the right wall's window moved out with the wall", absf(side_win.transform.origin.x - expect_x) < 0.01,
		"x %.2f want %.2f" % [side_win.transform.origin.x, expect_x])
	check("resized: its cut follows", side_win.window.carved_xf.origin.distance_to(side_win.window.opening_xf(side_win.transform).origin) < 0.01)
	var front_win: LevelBrush = windows.filter(func(w): return int(w.mount.z) == 0)[0]
	var m := HouseFixtures.slide(h, front_win, h.transform * Vector3(20.0, 4.3, 3.0), 0.25)
	check("slide: along the wall, clamped to it", m.x <= 5.0 - 0.45 and absf(m.y - (4.3 - spec.foundation)) < 0.2 and int(m.z) == 0, str(m))
	spec.shop_opening = 1.2
	root._generate_house(h)
	check("sign stays on the front after the rebuild", int(sign.mount.z) == 0 and absf(sign.transform.origin.z - spec.depth * 0.5) < 0.01)
	print("DONE fails=%d" % fails)
	get_tree().quit()


## x range (min, max) of faces in `tex` in front of the wall's inside (the shop's own pieces).
func _xrange(faces: Array, tex: Texture2D, _front: bool) -> Vector2:
	var lo := INF
	var hi := -INF
	for f in faces:
		if f.texture != tex:
			continue
		for p in f.pts:
			lo = minf(lo, p.x)
			hi = maxf(hi, p.x)
	return Vector2(lo, hi) if lo < INF else Vector2.ZERO


func _key_without_later(spec: HouseSpec) -> int:
	var parts := [HouseBuilder.VERSION]
	for prop in spec.get_property_list():
		if prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and not prop.name in HouseSpec.NOT_GEOMETRY and not prop.name in HouseSpec.LATER:
			var v = spec.get(prop.name)
			parts.append(v.resource_path if v is Resource else v)
	return hash(parts)
