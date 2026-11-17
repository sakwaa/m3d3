extends Node3D
## Foliage styles side by side (TreeSpecies.Foliage CARDS / SHELL / BLOBS): each species x
## style alone on grass, from eye height ~16 m off and from under the canopy looking up,
## the normal render over its fill-cost heat map, with triangles and the cost per covered
## pixel (mean / 95th percentile): every cut-out layer (they run the shader even behind
## others) + 1 where solid bark / foliage covers (the depth test spares what's behind it).
##   OUT=dir [SPECIES=sycamore,oak] [SEED=7] tools/godot_run.sh --path . --resolution 960x540 tests/trees/foliage_compare.tscn

const STYLES := ["cards", "shell", "blobs"]

var _od: Node3D
var _cam: Camera3D
var _tree: MeshInstance3D
var _ground: MeshInstance3D
var _occ: MeshInstance3D
var _dc: ShaderMaterial


## Two-sided count, depth tested (against the solid parts drawn first).
func _depth_count() -> ShaderMaterial:
	if _dc == null:
		var sh := Shader.new()
		sh.code = _od.COUNT_CODE.replace(", depth_test_disabled", "") % "cull_disabled"
		_dc = ShaderMaterial.new()
		_dc.shader = sh
	return _dc


func _ready() -> void:
	_od = (load("res://tests/zones/overdraw.gd") as GDScript).new()
	add_child(_od)
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _run() -> void:
	var out := OS.get_environment("OUT")
	DirAccess.make_dir_recursive_absolute(out)
	await _od._calibrate()
	_cam = Camera3D.new()
	_cam.fov = 60.0
	add_child(_cam)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.68, 0.9)
	_cam.environment = env
	_cam.make_current()
	_ground = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(80, 80)
	_ground.mesh = pm
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.35, 0.45, 0.2)
	gmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ground.material_override = gmat
	add_child(_ground)
	_tree = MeshInstance3D.new()
	add_child(_tree)
	# The solid parts as a black depth writer, so cut-out layers behind them don't count.
	_occ = MeshInstance3D.new()
	var om := StandardMaterial3D.new()
	om.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	om.albedo_color = Color.BLACK
	om.cull_mode = BaseMaterial3D.CULL_DISABLED
	_occ.material_override = om
	_occ.visible = false
	add_child(_occ)
	GameState.set_time(15.0)
	var names: Array = Array(OS.get_environment("SPECIES").split(",")) if OS.get_environment("SPECIES") != "" else ["sycamore", "oak"]
	if OS.get_environment("EDGE") != "":
		TreeBuilder.edge = float(OS.get_environment("EDGE"))
	if OS.get_environment("SOLID_REPEAT") != "":
		TreeBuilder.solid_repeat = float(OS.get_environment("SOLID_REPEAT"))
	if OS.get_environment("BLOB_FACES") != "":
		TreeBuilder.blob_faces = int(OS.get_environment("BLOB_FACES"))
	var seed := int(OS.get_environment("SEED")) if OS.get_environment("SEED") != "" else 7
	var rows := []
	var lines := ["| species | style | tris | side mean | side p95 | under mean | under p95 |", "|---|---|---|---|---|---|---|"]
	for nm in names:
		var sp: TreeSpecies = load("res://addons/n64_level_tools/trees/species/%s.tres" % nm)
		var cells := []
		for si in STYLES.size():
			_tree.mesh = TreeBuilder.build(sp, seed, si)
			var aabb := _tree.mesh.get_aabb()
			var mid := aabb.get_center()
			var views := [
				[Vector3(mid.x, 1.6, mid.z + maxf(aabb.size.x, aabb.size.y) * 1.25 + 4.0), Vector3(mid.x, aabb.size.y * 0.5, mid.z)],
				[Vector3(mid.x + 1.2, 1.6, mid.z + 1.5), Vector3(mid.x + 0.5, aabb.end.y, mid.z - 2.0)],
			]
			var row_imgs := []
			var st := []
			var full: ArrayMesh = _tree.mesh
			var cut := ArrayMesh.new()
			var solid := ArrayMesh.new()
			for i in full.get_surface_count():
				var mat := full.surface_get_material(i) as ShaderMaterial
				var into := cut if mat and mat.get_shader_parameter(&"cutout") else solid
				into.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, full.surface_get_arrays(i))
			for v in views:
				_cam.global_position = v[0]
				_cam.look_at(v[1])
				_tree.mesh = full
				_tree.material_override = null
				_cam.environment = env
				await _frames(6)
				var normal: Image = _od._grab()
				var black := Environment.new()
				black.background_mode = Environment.BG_COLOR
				black.background_color = Color.BLACK
				black.tonemap_mode = Environment.TONE_MAPPER_LINEAR
				_cam.environment = black
				_ground.visible = false
				_tree.mesh = cut
				_tree.material_override = _depth_count()
				_occ.mesh = solid
				_occ.visible = true
				await _frames(4)
				var layers: PackedFloat32Array = _od._layers(_od._grab()) if cut.get_surface_count() > 0 else PackedFloat32Array()
				_occ.visible = false
				_tree.mesh = solid
				_tree.material_override = _od.count_material(false)
				await _frames(4)
				var cover: PackedFloat32Array = _od._layers(_od._grab())
				if layers.is_empty():
					layers.resize(cover.size())
				for i in layers.size():
					layers[i] += 1.0 if cover[i] >= 0.5 else 0.0
				_ground.visible = true
				_tree.material_override = null
				_tree.mesh = full
				st.append(_covered(layers))
				var heat: Image = _od._heat(layers, normal.get_width(), normal.get_height())
				row_imgs.append([normal, heat])
			var tris := TreeBuilder.triangles(_tree.mesh)
			cells.append({imgs = row_imgs, label = "%s %s  %d tris" % [nm, STYLES[si], tris]})
			lines.append("| %s | %s | %d | %.1f | %.0f | %.1f | %.0f |" % [nm, STYLES[si], tris, st[0].mean, st[0].p95, st[1].mean, st[1].p95])
			print("[foliage] %s %s: %d tris, side %.1f / p95 %.0f, under %.1f / p95 %.0f" % [nm, STYLES[si], tris, st[0].mean, st[0].p95, st[1].mean, st[1].p95])
		rows.append(cells)
	# Sheet per species: columns = styles; rows = side normal, side heat, under normal, under heat.
	for ri in rows.size():
		var cells: Array = rows[ri]
		var w: int = cells[0].imgs[0][0].get_width()
		var h: int = cells[0].imgs[0][0].get_height()
		var sheet := Image.create(w * cells.size(), h * 4, false, Image.FORMAT_RGB8)
		for ci in cells.size():
			var k := 0
			for pair in cells[ci].imgs:
				for img: Image in pair:
					sheet.blit_rect(img, Rect2i(0, 0, w, h), Vector2i(ci * w, k * h))
					k += 1
		sheet.save_png(out + "/%s.png" % names[ri])
	var f := FileAccess.open(out + "/foliage.md", FileAccess.WRITE)
	f.store_string("\n".join(lines) + "\n")
	f.close()
	get_tree().quit()


## Layer stats over the pixels the tree covers.
func _covered(l: PackedFloat32Array) -> Dictionary:
	var vals := []
	for v in l:
		if v >= 0.5:
			vals.append(v)
	if vals.is_empty():
		return {mean = 0.0, p95 = 0.0}
	vals.sort()
	var s := 0.0
	for v in vals:
		s += v
	return {mean = s / vals.size(), p95 = vals[int(vals.size() * 0.95)]}
