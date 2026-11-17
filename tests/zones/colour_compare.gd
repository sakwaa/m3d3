extends Node3D
## Colour maths comparison (old RGB / HSV vs OKLab, Acerola's "Your Colors Suck"):
##  MODE=tex: a sheet of textures (columns) through filters, old and new maths (rows), and
##    generated ramps; writes OUT/tex_sheet.png + OUT/rows.txt (row labels).
##  MODE=scene ZONE=... VARIANT=saved|ok|ramps: the zone's grade on its textures (in memory)
##    as saved / with every filter switched to OKLab / a values -> colour ramp per group;
##    renders OUT/<variant>_<view>.png from an overview and two eye-level views.
##   tools/godot_run.sh --path . --resolution 960x540 tests/zones/colour_compare.tscn

const TEX := ["res://textures/ground/mud.res", "res://textures/grass/157_green_grass.res", "res://textures/concrete/stucco_3.res",
	"res://textures/roof/red_shingles_1.res", "res://textures/brick/53_old_bricks.res", "res://textures/wood/wood_planks_8.res"]
const CELL := 112


func _ready() -> void:
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _run() -> void:
	var out := OS.get_environment("OUT")
	DirAccess.make_dir_recursive_absolute(out)
	if OS.get_environment("MODE") == "tex":
		_tex_sheet(out)
	else:
		await _scene(out)
	get_tree().quit()


# --- Texture sheet ---

func _rows() -> Array:
	var rows := [["original", []]]
	for ok in [false, true]:
		var hs := GradeHueSat.new()
		hs.hue = 90.0
		hs.saturation = 1.3
		hs.perceptual = ok
		rows.append(["hue +90, sat x1.3 - " + ("OKLab" if ok else "HSV (old)"), [hs]])
	for ok in [false, true]:
		var gm := GradeGradientMap.new()
		gm.blend = GradeFilter.Blend.NORMAL
		gm.gradient = Gradient.new()
		gm.gradient.offsets = PackedFloat32Array([0.0, 1.0])
		gm.gradient.colors = PackedColorArray([Color(0.1, 0.15, 0.45), Color(1.0, 0.7, 0.3)])
		gm.perceptual = ok
		rows.append(["gradient map navy -> orange - " + ("OKLab" if ok else "RGB (old)"), [gm]])
	for ok in [false, true]:
		var po := GradePosterize.new()
		po.levels = 4
		po.perceptual = ok
		rows.append(["posterize 4 - " + ("lightness only (new)" if ok else "per RGB channel (old)"), [po]])
	for spec in [["ramp: moss, 5 steps, temp 30", Color(0.36, 0.52, 0.25), 5, 30.0, true],
			["ramp: brick, smooth, temp 40", Color(0.62, 0.3, 0.22), 6, 40.0, false],
			["ramp: dusk violet, 4 steps, temp -25", Color(0.45, 0.35, 0.6), 4, -25.0, true]]:
		var gm := GradeGradientMap.new()
		gm.blend = GradeFilter.Blend.NORMAL
		gm.perceptual = true
		var lab := GradePalette.oklab(spec[1])
		var c := Vector2(lab.y, lab.z).length()
		gm.gradient = GradeGradientMap.ramp(spec[1], spec[2], spec[3], c * 0.75, c, 0.2, 0.94, spec[4])
		gm.stretch = true
		rows.append([spec[0] + ", stretch", [gm]])
	return rows


func _tex_sheet(out: String) -> void:
	var rows := _rows()
	var sheet := Image.create(CELL * TEX.size() + 0, CELL * rows.size(), false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.12, 0.12, 0.14))
	for ti in TEX.size():
		var tex: Texture2D = load(TEX[ti])
		var src := GradeProcessor.source_image(tex)
		var tint := _tint_for(tex)
		for ri in rows.size():
			var img: Image = GradeProcessor.process(src, rows[ri][1], tint) if not rows[ri][1].is_empty() or not tint.is_empty() else src.duplicate()
			img = img.duplicate()
			if img.is_compressed():
				img.decompress()
			img.clear_mipmaps()
			img.convert(Image.FORMAT_RGBA8)
			img.resize(CELL - 4, CELL - 4, Image.INTERPOLATE_NEAREST)
			sheet.blit_rect(img, Rect2i(0, 0, CELL - 4, CELL - 4), Vector2i(ti * CELL + 2, ri * CELL + 2))
	sheet.save_png(out + "/tex_sheet.png")
	var f := FileAccess.open(out + "/rows.txt", FileAccess.WRITE)
	f.store_string("\n".join(rows.map(func(r): return r[0])))
	f.close()
	print("[cc] sheet ", rows.size(), " rows")


## A texture's combiner tint as the market's materials use it ([] = none).
func _tint_for(tex: Texture2D) -> Array:
	if not ResourceLoader.exists("res://zones/town1/town_1_market_square.tscn"):
		return []
	return []


# --- Scene ---

func _scene(out: String) -> void:
	var variant := OS.get_environment("VARIANT")
	var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	add_child(zone)
	GameState.set_time(float(OS.get_environment("HOUR")) if OS.get_environment("HOUR") != "" else 13.0)
	await _frames(4)
	for c in get_tree().root.find_children("*", "CanvasLayer", true, false):
		c.visible = false
	var lr: LevelRoot = zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
	var g := variant_grade(lr.data.grade as ZoneGrade, variant)
	_apply_textures(g)
	var spawn := Vector3.ZERO
	for n in zone.find_children("*", "Node3D", true, false):
		if n is SpawnPoint:
			spawn = n.global_position
			break
	var box := AABB()
	var first := true
	for m in lr.data.baked_meshes():
		var b := lr.global_transform * m.get_aabb()
		box = b if first else box.merge(b)
		first = false
	var mid := box.get_center()
	var to_mid := ((mid - spawn) * Vector3(1, 0, 1)).normalized()
	var eye := spawn + Vector3.UP * 1.6
	var views := [
		["overview", mid + Vector3(0, box.size.y * 0.5 + 28.0, box.size.z * 0.45 + 18.0), mid],
		["eye_a", eye, eye + to_mid * 10.0],
		["eye_b", mid + Vector3(6, 1.6, 6), mid + Vector3(6, 1.6, 6) + to_mid.rotated(Vector3.UP, 2.4) * 10.0],
	]
	if OS.get_environment("VIEWS") != "":
		views = []
		for spec in OS.get_environment("VIEWS").split(";"):
			var p := spec.split(">")
			views.append([p[0], _vec(p[1]), _vec(p[2])])
	var cam := Camera3D.new()
	cam.fov = 62.0
	add_child(cam)
	for v in views:
		for c in get_tree().root.find_children("*", "Camera3D", true, false):
			if c != cam:
				c.current = false
		cam.make_current()
		cam.global_position = v[1]
		cam.look_at(v[2])
		await _frames(14)
		var img := get_viewport().get_texture().get_image()
		img.resize(960, int(960.0 * img.get_height() / img.get_width()), Image.INTERPOLATE_BILINEAR)
		img.save_png(out + "/%s_%s.png" % [variant, v[0]])
	print("[cc] %s: spawn %s centre %s" % [variant, spawn, mid])


func _vec(s: String) -> Vector3:
	var p := s.split(",")
	return Vector3(float(p[0]), float(p[1]), float(p[2]))


## saved: as is; ok: copies with every filter that has it switched to OKLab; ramps: the
## shared town grade + a colour ramp per texture group on Colour blend (values -> colour).
static func variant_grade(saved: ZoneGrade, variant: String) -> ZoneGrade:
	if saved == null:
		saved = ZoneGrade.new()
	if variant == "saved":
		return saved
	var g := saved.duplicate(true) as ZoneGrade
	if g.shared:
		g.shared = (g.shared as ZoneGrade).duplicate(true)
	for gg in [g, g.shared]:
		if gg == null:
			continue
		for k in gg.stacks:
			for f in gg.stacks[k]:
				if f and &"perceptual" in f:
					f.set(&"perceptual", true)
	if variant == "ramps":
		var spec := {
			"group/ground": [Color(0.6, 0.48, 0.34), 5, 25.0],
			"group/grass": [Color(0.38, 0.55, 0.24), 5, 35.0],
			"group/concrete": [Color(0.78, 0.7, 0.58), 4, 20.0],
			"group/brick": [Color(0.6, 0.34, 0.26), 5, 30.0],
			"group/roof": [Color(0.42, 0.36, 0.34), 4, 25.0],
			"group/wood": [Color(0.5, 0.36, 0.24), 5, 30.0],
		}
		for k in spec:
			var gm := GradeGradientMap.new()
			gm.perceptual = true
			gm.blend = GradeFilter.Blend.COLOUR
			gm.opacity = 0.75
			var s: Array = spec[k]
			var lab := GradePalette.oklab(s[0])
			var c := Vector2(lab.y, lab.z).length()
			gm.gradient = GradeGradientMap.ramp(s[0], s[1], s[2], c * 0.75, c, 0.2, 0.94, false)
			gm.stretch = true
			var list: Array = g.stacks.get(k, []).duplicate()
			list.append(gm)
			g.stacks[k] = list
	return g


## Every paint material's base texture through its chain (like the bake), in memory.
func _apply_textures(g: ZoneGrade) -> void:
	var done := {}
	var seen := {}
	var n := 0
	for mi in get_tree().root.find_children("*", "MeshInstance3D", true, false):
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		if mesh == null:
			continue
		for si in mesh.get_surface_count():
			var mat := (mi as MeshInstance3D).get_active_material(si) as ShaderMaterial
			if mat == null or seen.has(mat):
				continue
			seen[mat] = true
			var base = mat.get_shader_parameter(&"base_tex")
			if not base is Texture2D:
				continue
			var src_tex: Texture2D = base.get_meta(&"grade_source") if base.has_meta(&"grade_source") else base
			var mode: float = mat.get_shader_parameter(&"base_tint_mode") if mat.get_shader_parameter(&"base_tint_mode") != null else 0.0
			var tint := []
			if mode > 0.5:
				tint = [mode, Color(mat.get_shader_parameter(&"base_tint_dark")), Color(mat.get_shader_parameter(&"base_tint_light")), mat.get_shader_parameter(&"base_tint_extra")]
			var key := [src_tex, var_to_str(tint)]
			if not done.has(key):
				var chain := g.chain_for(src_tex, GradeLayers.group_of(src_tex))
				var src := GradeProcessor.source_image(src_tex)
				done[key] = ImageTexture.create_from_image(GradeProcessor.process(src, chain, tint)) if src and not chain.is_empty() else null
			if done[key]:
				mat.set_shader_parameter(&"base_tex", done[key])
				if mode > 0.5:
					mat.set_shader_parameter(&"base_tint_mode", 0.0)
				n += 1
	print("[cc] graded %d textures, %d materials" % [done.size(), n])
