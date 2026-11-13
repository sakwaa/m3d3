extends Node
## Texture anchor (LevelBrush.uv_world): two touching floor brushes whose origins are 1 m
## apart tile on without a seam once World-anchored (in the bake, too); a face placed by
## hand (offset / turn) keeps its look when switched; heights still count from the brush's
## base. Texture scale as X / Y (face_uv_scale): an old single scale reads as both, the bake
## and the editor mesh lay it alike, faces keep it through a remap and don't merge across
## it. Prints PASS / FAIL.
##   godot --headless --path . tests/paint/uv_world.tscn
var fails := 0


func check(label: String, ok: bool, got := "") -> void:
	print(("PASS " if ok else "FAIL ") + label + ("  (%s)" % got if got != "" else ""))
	if not ok:
		fails += 1


## A 2 x 2 m slab (top face 0 up, a side face) centred on its origin, 1 m tall.
func slab(origin: Vector3) -> LevelBrush:
	var b := LevelBrush.new()
	b.vertices = PackedVector3Array([Vector3(-1, 1, -1), Vector3(1, 1, -1), Vector3(1, 1, 1), Vector3(-1, 1, 1),
		Vector3(-1, 0, 1), Vector3(1, 0, 1)])
	var faces: Array[PackedInt32Array] = [PackedInt32Array([0, 3, 2, 1]), PackedInt32Array([3, 4, 5, 2])]
	b.set_faces(faces)
	b.transform = Transform3D(Basis(), origin)
	return b


## The face's base UV at world point `w` (as the bake lays it).
func uv_at(b: LevelBrush, f: int, w: Vector3) -> Vector2:
	return b.face_uv_at(b.transform.affine_inverse() * w, f)


func _ready() -> void:
	var a := slab(Vector3(51.0, 2.0, 0.0))
	var b := slab(Vector3(50.0, 2.0, 2.0))  # next to a along z, origin 1 m off in x
	var w := Vector3(51.3, 3.0, 1.0)  # on the edge a / b share
	print("face 0 normal ", a.get_face_normal(0))
	var d0 := uv_at(a, 0, w) - uv_at(b, 0, w)
	check("brush-anchored: a seam (1 m off)", absf(d0.x) > 0.5, str(d0))
	a.uv_world = true
	b.uv_world = true
	var d1 := uv_at(a, 0, w) - uv_at(b, 0, w)
	check("World-anchored: no seam", d1.length() < 1e-4, str(d1))
	# Hand-placed face keeps its look when switched.
	var h := slab(Vector3(7.3, 0.5, -2.2))
	var uvs := PackedVector4Array([Vector4(0.37, -0.2, 1.5, 90.0), Vector4(0.1, 0.25, 1.0, 0.0)])
	h.face_uv = uvs
	var p0 := Vector3(7.8, 1.5, -2.0)
	var p1 := Vector3(7.5, 1.0, -1.2)
	var before := [uv_at(h, 0, p0), uv_at(h, 1, p1)]
	h.uv_world = true
	var after := [uv_at(h, 0, p0), uv_at(h, 1, p1)]
	check("hand-placed top keeps its look", (before[0] - after[0]).length() < 1e-4, "%s -> %s" % [before[0], after[0]])
	check("hand-placed side keeps its look", (before[1] - after[1]).length() < 1e-4, "%s -> %s" % [before[1], after[1]])
	h.uv_world = false
	check("and back again", (h.get_face_uv(0) - uvs[0]).length() < 1e-4, str(h.get_face_uv(0)))
	# Side faces: v (height) still counts from the brush's base.
	var s := slab(Vector3(3.0, 0.7, 4.0))
	var v_before := uv_at(s, 1, Vector3(3.2, 0.7, 5.0)).y
	s.uv_world = true
	var v_after := uv_at(s, 1, Vector3(3.2, 0.7, 5.0)).y
	check("heights from the brush's base", absf(v_before - v_after) < 1e-4, "%.3f %.3f" % [v_before, v_after])
	# Saved and loaded: not shifted twice.
	ResourceSaver.save(h, "user://uv_world_test.res")
	h.uv_world = true
	ResourceSaver.save(h, "user://uv_world_test.res")
	var loaded := ResourceLoader.load("user://uv_world_test.res", "", ResourceLoader.CACHE_MODE_IGNORE) as LevelBrush
	check("loads as saved", loaded.uv_world and (loaded.get_face_uv(0) - h.get_face_uv(0)).length() < 1e-5,
		"%s vs %s" % [loaded.get_face_uv(0), h.get_face_uv(0)])
	var dup := h.duplicate() as LevelBrush
	check("duplicates as is", (dup.get_face_uv(0) - h.get_face_uv(0)).length() < 1e-5)
	# The bake lays the same UVs.
	var data := LevelData.new()
	data.add_brush(a)
	data.add_brush(b)
	var res := LevelBaker.bake(data, true)
	var worst := 0.0
	var seen := 0
	var meshes: Array = [res.mesh] if res.mesh else []
	meshes.append_array(res.chunks)
	for m: ArrayMesh in meshes:
		for si in m.get_surface_count():
			var arr := m.surface_get_arrays(si)
			var pos: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var uv: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
			for i in pos.size():
				if absf(pos[i].z - 1.0) < 1e-3 and absf(pos[i].y - 3.0) < 1e-3:
					seen += 1
					var want := LevelBrush.tweaked_uv(pos[i], Vector3.UP, LevelBrush.DEFAULT_UV)
					worst = maxf(worst, fposmod((uv[i] - want).x + 0.5, 1.0) - 0.5)
	check("bake: shared edge UVs match world (%d verts)" % seen, seen > 0 and absf(worst) < 1e-3, "%.4f" % worst)
	# X / Y scale.
	var x := slab(Vector3.ZERO)
	x.face_uv = PackedVector4Array([Vector4(0, 0, 2.0, 0), Vector4(0, 0, 1, 0)])
	check("old single scale reads as X and Y", x.get_face_scale(0) == Vector2(2, 2), str(x.get_face_scale(0)))
	x.face_uv_scale = PackedVector2Array([Vector2(2, 0.5), Vector2.ONE])
	var u0 := x.face_uv_at(Vector3(0, 1, 0), 0)
	var ux := x.face_uv_at(Vector3(1, 1, 0), 0) - u0
	var uz := x.face_uv_at(Vector3(0, 1, 1), 0) - u0
	check("X / Y scale: 1 m across = 1/4 tile, 1 m up = 1 tile", absf(absf(ux.x) - 0.25) < 1e-4 and absf(absf(uz.y) - 1.0) < 1e-4, "%s %s" % [ux, uz])
	var em: ArrayMesh = x.build_painted_mesh({rects = {}, size = Vector2i(1, 1)}, 0).mesh
	var eu: PackedVector2Array = em.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
	var ep: PackedVector3Array = em.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var en: PackedVector3Array = em.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
	var worst_e := 0.0
	for i in ep.size():
		if en[i].y > 0.9:  # the top's corners (the side's top corners sit at y 1 too)
			worst_e = maxf(worst_e, (eu[i] - x.face_uv_at(ep[i], 0)).length())
	check("editor mesh lays X / Y scale", worst_e < 1e-4, "%.5f" % worst_e)
	var xd := LevelData.new()
	xd.add_brush(x)
	var xr := LevelBaker.bake(xd, true)
	var worst_b := 0.0
	var xm: Array = [xr.mesh] if xr.mesh else xr.chunks.slice(0, 1)  # (not the far ground LOD's cell-texture UVs)
	for m: ArrayMesh in xm:
		for si in m.get_surface_count():
			var arr := m.surface_get_arrays(si)
			for i in (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size():
				var pv: Vector3 = arr[Mesh.ARRAY_VERTEX][i]
				if (arr[Mesh.ARRAY_NORMAL][i] as Vector3).y > 0.9:
					worst_b = maxf(worst_b, ((arr[Mesh.ARRAY_TEX_UV][i] as Vector2) - x.face_uv_at(pv, 0)).length())
	check("bake lays X / Y scale", worst_b < 1e-4, "%.5f" % worst_b)
	x.remap_faces(PackedInt32Array([1, 0, -1]))
	check("remap carries X / Y scale", x.get_face_uv_stretch(1) == Vector2(2, 0.5) and x.get_face_uv_stretch(2) == Vector2.ONE,
		str(x.face_uv_scale))
	ResourceSaver.save(x, "user://uv_world_test.res")
	var xl := ResourceLoader.load("user://uv_world_test.res", "", ResourceLoader.CACHE_MODE_IGNORE) as LevelBrush
	check("X / Y scale saved", xl.face_uv_scale == x.face_uv_scale)
	# Two flat neighbours, same texture, different X / Y: they stay apart when merging.
	var m2 := LevelBrush.new()
	m2.vertices = PackedVector3Array([Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 0, 0), Vector3(2, 0, 1), Vector3(2, 0, 0)])
	var mf: Array[PackedInt32Array] = [PackedInt32Array([0, 1, 2, 3]), PackedInt32Array([3, 2, 4, 5])]
	m2.set_faces(mf)
	m2.face_uv_scale = PackedVector2Array([Vector2(1, 1), Vector2(1, 2)])
	m2.merge_faces([0, 1], 8.0)
	check("faces with different X / Y scale don't merge", m2.get_face_count() == 2, str(m2.get_face_count()))
	m2.face_uv_scale = PackedVector2Array([Vector2(1, 2), Vector2(1, 2)])
	m2.merge_faces([0, 1], 8.0)
	check("same X / Y scale merges", m2.get_face_count() == 1 and m2.get_face_uv_stretch(0) == Vector2(1, 2), "%d %s" % [m2.get_face_count(), m2.face_uv_scale])
	# A-align with X / Y scale: the texture's origin lands on the edge.
	var al = LevelBrush.uv_aligned_to_edge(Vector4(0, 0, 1, 0), Vector3.UP, Vector3(0.3, 0, 0.7), Vector3(1.3, 0, 0.7),
		Vector3(0.6, 0, 0.7), Vector3(0.6, 0, 0.2), false, Vector2(2, 0.5))
	var at_a := LevelBrush.tweaked_uv(Vector3(0.3, 0, 0.7), Vector3.UP, al, Vector2(2, 0.5))
	check("A-align with X / Y scale starts the texture on the edge", at_a.length() < 1e-4, str(at_a))
	print("DONE fails=%d" % fails)
	get_tree().quit()
