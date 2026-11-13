extends Node
## Border tool, a side left out (Alt+click): repainting clears the band painted there before
## and keeps the rest. Prints PASS / FAIL.
##   godot --headless --path . tests/paint/border_sides.tscn
var fails := 0


func check(label: String, ok: bool, got := "") -> void:
	print(("PASS " if ok else "FAIL ") + label + ("  (%s)" % got if got != "" else ""))
	if not ok:
		fails += 1


func _ready() -> void:
	await get_tree().process_frame
	var data := LevelData.new()
	data.layers = [PaintLayer.new()]
	var root := LevelRoot.new()
	root.data = data
	add_child(root)
	# A 4 x 4 m floor of 1 m faces (facing up).
	var b := LevelBrush.new()
	var verts := PackedVector3Array()
	for z in 5:
		for x in 5:
			verts.append(Vector3(x, 0, z))
	var faces: Array[PackedInt32Array] = []
	for z in 4:
		for x in 4:
			var i := z * 5 + x
			faces.append(PackedInt32Array([i, i + 5, i + 6, i + 1]))
	b.vertices = verts
	b.set_faces(faces)
	data.add_brush(b)
	await get_tree().process_frame
	print("face 0 normal ", b.get_face_normal(0))
	var region := []
	for f in b.get_face_count():
		region.append({brush = b, face = f})
	var paint := LevelPaintTool.new()
	paint.layer = 1
	paint.border_follow = false
	var apply := func(masks: Array) -> void:
		for m: Dictionary in masks:
			b.set_face_mask(m.face, 0, m.image)
	apply.call(paint.border_masks(root, region, 1.0, 0))
	# Face 0: corner (x 0..1, z 0..1); face 1: on the z = 0 side only; face 5: inside.
	var cover := func(face: int) -> float:
		var img := b.get_face_mask(face, 0)
		if img == null:
			return 0.0
		var s := 0.0
		for y in img.get_height():
			for x in img.get_width():
				s += img.get_pixel(x, y).r
		return s / (img.get_width() * img.get_height())
	check("band painted along z = 0", cover.call(1) > 0.9, "%.2f" % cover.call(1))
	check("inside face left alone", cover.call(5) < 0.01, "%.2f" % cover.call(5))
	# Leave out the z = 0 side.
	var sides := LevelPaintTool.border_sides(LevelPaintTool.border_segments(root, region))
	check("four sides", sides.size() == 4, str(sides.size()))
	var segs := LevelPaintTool.border_segments(root, region)
	var z0 := ""
	for side in sides:
		var all_z0 := true
		for i in side.segs:
			all_z0 = all_z0 and absf(segs[i][0].z) < 0.01 and absf(segs[i][1].z) < 0.01
		if all_z0:
			z0 = side.key
	check("found the z = 0 side", z0 != "")
	paint.border_off[z0] = true
	apply.call(paint.border_masks(root, region, 1.0, 0, false, 1.0))
	check("side left out: its band cleared", cover.call(1) < 0.01, "%.2f" % cover.call(1))
	check("corner keeps the x = 0 side's band", cover.call(0) > 0.4, "%.2f" % cover.call(0))
	check("x = 0 side kept", cover.call(4) > 0.9, "%.2f" % cover.call(4))
	# Every side off: all cleared.
	for side in sides:
		paint.border_off[side.key] = true
	apply.call(paint.border_masks(root, region, 1.0, 0, false, 1.0))
	check("all sides off: nothing left", cover.call(0) + cover.call(4) < 0.01, "%.2f" % (cover.call(0) + cover.call(4)))
	print("DONE fails=%d" % fails)
	get_tree().quit()
