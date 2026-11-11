extends Node3D
## Terrace joins (HouseTerrace): a row of four houses (deeper, taller, stepped forward, a hip
## roof turned round), their joins printed and the row drawn from the front and the back
## (SHOT: png path prefix; windowed).

const TEX := "res://textures/concrete/stucco_3.res"


func _house(w: float, d: float, storeys: int, roof := HouseSpec.Roof.GABLE) -> HouseSpec:
	var h := HouseSpec.new()
	h.width = w
	h.depth = d
	h.storeys = storeys
	h.roof = roof
	return h


func _ready() -> void:
	var specs := [
		[_house(6, 5, 1), Vector3(0, 0, 0), 0.0],
		[_house(5, 7, 2), Vector3(5.5, 0, -1), 0.0],
		[_house(4, 5, 1), Vector3(10, 0, 1), 0.0],
		[_house(5, 5, 1, HouseSpec.Roof.HIP), Vector3(14.5, 0.3, 0), PI],
	]
	var houses := []
	for s in specs:
		var b := LevelBrush.new()
		b.house = s[0]
		b.transform = Transform3D(Basis(Vector3.UP, s[2]), s[1])
		b.tag = StringName("h%d" % houses.size())
		houses.append(b)
	var total := 0
	for b: LevelBrush in houses:
		var j := HouseTerrace.joins(b, houses)
		var faces := HouseBuilder.build(b.house, j)
		var plain := HouseBuilder.build(b.house)
		var drawn := faces.filter(func(f): return f.get("bake", 0) != 2)
		var tris := 0
		for f in drawn:
			tris += f.pts.size() - 2
		total += tris
		print("%s joins %s  faces %d (alone %d)  drawn tris %d" % [b.tag, j.keys(), faces.size(), plain.size(), tris])
		_draw(b, drawn)
	print("row drawn tris: ", total)
	var shot := OS.get_environment("SHOT")
	if shot == "":
		get_tree().quit()
		return
	var cam := Camera3D.new()
	add_child(cam)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.75, 1.0)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.5, 0.5, 0.5)
	add_child(env)
	var views := {front = [Vector3(7, 5, 16), Vector3(7, 2, 0)], back = [Vector3(9, 7, -15), Vector3(7, 2, 0)],
		top = [Vector3(7, 22, 3), Vector3(7, 0, 0)]}
	for v in views:
		cam.look_at_from_position(views[v][0], views[v][1])
		for i in 4:
			await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png("%s_%s.png" % [shot, v])
	get_tree().quit()


func _draw(b: LevelBrush, faces: Array) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(b.tag)
	var tint := Color.from_hsv(rng.randf(), 0.35, 1.0)
	for f in faces:
		var c: Color = f.color * tint
		for i in range(1, f.pts.size() - 1):
			for p in [f.pts[0], f.pts[i], f.pts[i + 1]]:
				st.set_color(c)
				st.set_normal(f.normal)
				st.add_vertex(p)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_FRONT  # (faces wound counter-clockwise to their normal)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	mi.transform = b.transform
	add_child(mi)
	# Edges: thin black lines.
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for f in faces:
		for i in f.pts.size():
			im.surface_add_vertex(f.pts[i] + f.normal * 0.005)
			im.surface_add_vertex(f.pts[(i + 1) % f.pts.size()] + f.normal * 0.005)
	im.surface_end()
	var lines := MeshInstance3D.new()
	lines.mesh = im
	var lm := StandardMaterial3D.new()
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lm.albedo_color = Color.BLACK
	lines.material_override = lm
	lines.transform = b.transform
	add_child(lines)
