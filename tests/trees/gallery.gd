extends Node3D
## Tree generator gallery: every species preset at a few seeds in a row on grass, with
## triangle counts. Renders a shot to OUT (dir) and quits; SEEDS=a,b,c picks seeds.
##   godot --path . --resolution 1600x700 tests/trees/gallery.tscn   (OUT=dir)

const SPECIES := ["sycamore", "oak", "fir", "willow"]

var _frames := 0
var _width := 0.0


func _ready() -> void:
	var seeds := [1]
	if OS.get_environment("SEEDS") != "":
		seeds = Array(OS.get_environment("SEEDS").split(",")).map(func(x): return int(x))
	var names: Array = SPECIES
	var want := OS.get_environment("SPECIES")
	if want == "all":
		names = []
		for f in DirAccess.get_files_at("res://addons/n64_level_tools/trees/species/"):
			if f.ends_with(".tres"):
				names.append(f.get_basename())
	elif want != "":
		names = Array(want.split(","))
	# CARDS=1: each species' photo card stands beside its trees (to compare).
	var cards := OS.get_environment("CARDS") != ""
	var x := 0.0
	var row := 0.0
	var per_row := int(OS.get_environment("PER_ROW")) if OS.get_environment("PER_ROW") != "" else 99
	var col := 0
	for name in names:
		var sp: TreeSpecies = load("res://addons/n64_level_tools/trees/species/%s.tres" % name)
		if cards and sp.card_texture:
			var q := MeshInstance3D.new()
			var qm := QuadMesh.new()
			var ts := sp.card_texture.get_size()
			qm.size = Vector2(sp.height * ts.x / ts.y, sp.height)
			q.mesh = qm
			var m := StandardMaterial3D.new()
			m.albedo_texture = sp.card_texture
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			q.material_override = m
			q.position = Vector3(x, sp.height * 0.5, row)
			add_child(q)
			x += 16.0
		for s in seeds:
			var mi := MeshInstance3D.new()
			mi.mesh = TreeBuilder.build(sp, s)
			mi.position = Vector3(x, 0, row)
			add_child(mi)
			print("%s seed %d: %d triangles" % [name, s, TreeBuilder.triangles(mi.mesh)])
			x += 16.0
		col += 1
		if col >= per_row:
			col = 0
			_width = maxf(_width, x)
			x = 0.0
			row -= 30.0
	_width = maxf(_width, x)
	x = _width
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, 400)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.45, 0.6, 0.3)
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ground.material_override = gm
	add_child(ground)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.7, 0.9)
	add_child(env)
	var cam := Camera3D.new()
	cam.fov = 40
	var mid := (x - 16.0) * 0.5
	var depth := -float(int((names.size() - 1) / per_row)) * 30.0 if per_row < 99 else 0.0
	cam.position = Vector3(mid, 10.0 - depth * 0.6, 20.0 + x * 0.8)
	add_child(cam)
	cam.look_at(Vector3(mid, 5, depth * 0.5))
	cam.make_current()


func _process(_delta: float) -> void:
	_frames += 1
	if _frames == 8:
		var out := OS.get_environment("OUT")
		if out != "":
			get_viewport().get_texture().get_image().save_png(out + "/gallery.png")
		get_tree().quit()
