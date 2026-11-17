extends Node3D
## Overdraw survey (Kaze's "fill rate, not triangles"): every surface drawn with a counting
## material (additive, no depth test; two-sided for cut-outs / effects as they draw in game,
## which Godot's own overdraw view doesn't do: it culls back faces, halving card counts) from the build report's kind of viewpoints (floor spots +
## spawns, eye height, 4 yaws), as layers per pixel: the whole scene, then each kind of
## geometry on its own (grass, trees, scatter, decals, effects, ...). Writes a heat map + the
## normal render of the worst views and overdraw.md / overdraw.json to OUT.
##   ZONE=res://... OUT=dir [SPOTS=8] [YAWS=4] [HOUR=15] [WEATHER=rainy] [LIST=1] [VIEW="x,y,z>lx,ly,lz;..."]
##   tools/godot_run.sh --path . --resolution 960x540 tests/zones/overdraw.tscn
## Counts are layers along each pixel's ray, not pixels actually shaded: Godot's depth
## prepass spares hidden opaque pixels most of their cost, but alpha-tested (grass, leaves,
## cutouts) and blended (effects) layers run their fragment shader whatever is in front.

const _BuildReport := preload("res://addons/n64_level_tools/export/build_report.gd")
## Kinds that cost per layer even behind opaque geometry (alpha test / blending).
const COSTLY := ["cutout", "grass", "trees", "scatter", "decals", "fx", "water"]
## Effects whose shader collapses them in dry weather (the overdraw view swaps shaders, so
## it would count them anyway): left out unless WEATHER makes it rain.
const RAIN_ONLY := ["RainDrips", "Rain"]
const WIDTH := 480  # stats / heat maps at this width
const MAX_CAL := 32
const SETTLE := 10  # frames after moving the camera (LOD / tufts follow it)
const SWITCH := 3  # frames after showing / hiding

var _cam: Camera3D
var _zone: Node
var _root: LevelRoot
var _lut := PackedFloat32Array()  # red channel for 0..MAX_CAL layers
var _out := ""


func _ready() -> void:
	_out = OS.get_environment("OUT")
	DirAccess.make_dir_recursive_absolute(_out)
	_cam = Camera3D.new()
	_cam.name = "ShotCam"
	_cam.fov = 70.0
	# Plain linear output: tonemap / glow off (the calibration covers what's left).
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_cam.environment = env
	add_child(_cam)
	_cam.make_current()
	Actor.show_debug = false
	if OS.get_environment("ZONE") == "":
		return  # (used as a library: tests/trees/foliage_compare.gd)
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _grab() -> Image:
	var img := get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	img.resize(WIDTH, int(WIDTH * float(img.get_height()) / img.get_width()), Image.INTERPOLATE_NEAREST)
	return img


func _run() -> void:
	var vp := get_viewport()
	await _calibrate()
	_zone = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	add_child(_zone)
	GameState.set_time(float(OS.get_environment("HOUR")) if OS.get_environment("HOUR") != "" else 15.0)
	if OS.get_environment("WEATHER") != "":
		GameState.set_weather(StringName(OS.get_environment("WEATHER")), 0.0)
	await _frames(3)
	for c in get_tree().root.find_children("*", "CanvasLayer", true, false):
		c.visible = false  # (debug HUD text)
	for c in find_children("*", "Camera3D", true, false):
		if c != _cam:
			c.current = false
	_cam.make_current()
	_cam.environment = (_cam.environment as Environment)  # (keep ours over the zone's)
	var vo := RenderScale.video_out()
	if vo:
		vo.enabled = false
	_root = _zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
	var views := _views()
	print("[overdraw] %d views, calibrated to %d layers" % [views.size(), MAX_CAL])
	var results := []
	for v in views:
		_cam.global_position = v.eye
		_cam.look_at(v.look)
		count_mode(false)
		await _frames(SETTLE)
		count_mode(true)
		var inst := _instances()
		if OS.get_environment("LIST") != "" and results.is_empty():
			for e in inst:
				if e.cat != "opaque":
					print("  [%s] %s %s" % [e.cat, e.node.get_path(), e.node.get_aabb().size])
		var r := {name = v.name, eye = [snappedf(v.eye.x, 0.1), snappedf(v.eye.y, 0.1), snappedf(v.eye.z, 0.1)], yaw = v.yaw}
		# Empty-scene baseline (MSAA edges, leftovers): taken off every pass.
		for e in inst:
			e.node.visible = false
		await _frames(SWITCH)
		var base := _layers(_grab())
		for e in inst:
			e.node.visible = e.visible
		await _frames(SWITCH)
		var layers := _minus(_layers(_grab()), base)
		r.total = _stats(layers)
		r.cats = {}
		r.counts = {}
		for e in inst:
			r.counts[e.cat] = r.counts.get(e.cat, 0) + 1
		for c in r.counts:
			for e in inst:
				e.node.visible = e.visible and e.cat == c
			await _frames(SWITCH)
			r.cats[c] = _stats(_minus(_layers(_grab()), base))
		for e in inst:
			e.node.visible = e.visible
		# Costly layers: the ones that pay per layer regardless of depth.
		var costly := 0.0
		for c in r.cats:
			if c.get_slice("/", 0) in COSTLY:
				costly += r.cats[c].mean
		r.costly_mean = snappedf(costly, 0.01)
		r._layers = layers
		results.append(r)
		print("[overdraw] %s: mean %.2f  p95 %.1f  >8 %.1f%%  costly %.2f" % [r.name, r.total.mean, r.total.p95, r.total.over8, costly])
	results.sort_custom(func(a, b): return a.total.mean > b.total.mean)
	# Worst views: normal render | heat map.
	var worst: int = mini(4, results.size())
	for i in worst:
		var r: Dictionary = results[i]
		_cam.global_position = Vector3(r.eye[0], r.eye[1], r.eye[2])
		var vw: Dictionary = views.filter(func(v): return v.name == r.name)[0]
		_cam.look_at(vw.look)
		count_mode(false)
		if vo:
			vo.enabled = true
		_cam.environment = null
		await _frames(SETTLE)
		var normal := _grab()
		if vo:
			vo.enabled = false
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color.BLACK
		env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		_cam.environment = env
		var heat := _heat(r._layers, normal.get_width(), normal.get_height())
		var both := Image.create(normal.get_width() * 2, normal.get_height(), false, Image.FORMAT_RGB8)
		both.blit_rect(normal, Rect2i(Vector2i.ZERO, normal.get_size()), Vector2i.ZERO)
		both.blit_rect(heat, Rect2i(Vector2i.ZERO, heat.get_size()), Vector2i(normal.get_width(), 0))
		both.save_png(_out + "/worst_%d.png" % (i + 1))
		r.image = "worst_%d.png" % (i + 1)
	_legend().save_png(_out + "/legend.png")
	for r in results:
		r.erase("_layers")
	var f := FileAccess.open(_out + "/overdraw.json", FileAccess.WRITE)
	f.store_string(JSON.stringify({zone = OS.get_environment("ZONE"), views = results}, "\t"))
	f.close()
	_write_md(results)
	print("[overdraw] wrote ", _out)
	get_tree().quit()


const COUNT_CODE := "shader_type spatial;\nrender_mode unshaded, blend_add, %s, depth_draw_never, depth_test_disabled, fog_disabled, shadows_disabled;\nvoid fragment() { ALBEDO = vec3(0.025); }\n"
static var _count_mats := {}


## The counting material: each layer adds the same amount (two-sided or back faces culled).
static func count_material(two_sided: bool) -> ShaderMaterial:
	if not _count_mats.has(two_sided):
		var sh := Shader.new()
		sh.code = COUNT_CODE % ("cull_disabled" if two_sided else "cull_back")
		var m := ShaderMaterial.new()
		m.shader = sh
		_count_mats[two_sided] = m
	return _count_mats[two_sided]


## Every drawn geometry swapped to the counting material (on) or back (off).
func count_mode(on: bool) -> void:
	for g in get_tree().root.find_children("*", "GeometryInstance3D", true, false):
		var gi := g as GeometryInstance3D
		if gi.has_meta(&"_count_keep"):
			continue
		if on:
			if not gi.has_meta(&"_count_orig"):
				var cat := _category(gi)
				gi.set_meta(&"_count_orig", gi.material_override if gi.material_override else false)
				gi.material_override = count_material(not cat in ["opaque", "backdrop", "actors"])
		elif gi.has_meta(&"_count_orig"):
			var o = gi.get_meta(&"_count_orig")
			gi.material_override = o if o is Material else null
			gi.remove_meta(&"_count_orig")


## Columns of 0..MAX_CAL stacked quads, read back: what each layer count reads as.
func _calibrate() -> void:
	var holder := Node3D.new()
	add_child(holder)
	var n := MAX_CAL + 1
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.keep_aspect = Camera3D.KEEP_WIDTH
	_cam.size = float(n)
	_cam.global_position = Vector3(0, 0, 10)
	_cam.look_at(Vector3.ZERO)
	var quad := QuadMesh.new()
	quad.size = Vector2(0.7, 4.0)
	for k in n:
		for j in k:
			var mi := MeshInstance3D.new()
			mi.mesh = quad
			mi.material_override = count_material(false)
			holder.add_child(mi)
			mi.position = Vector3(k - n / 2.0 + 0.5, 0, -j * 0.01)
	await _frames(6)
	var img := get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	_lut.resize(n)
	for k in n:
		var x := int((k + 0.5) / n * img.get_width())
		var y := img.get_height() / 2
		var s := 0.0
		for dy in range(-3, 4):
			for dx in range(-3, 4):
				s += img.get_pixel(x + dx, y + dy).r
		_lut[k] = s / 49.0
	holder.queue_free()
	_cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	print("[overdraw] calibration (red per layer): ", Array(_lut).slice(0, 13).map(func(v): return snappedf(v, 0.001)))


## Layers per pixel (fractional between calibration steps).
func _layers(img: Image) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(img.get_width() * img.get_height())
	var i := 0
	for y in img.get_height():
		for x in img.get_width():
			out[i] = _to_layers(img.get_pixel(x, y).r)
			i += 1
	return out


func _minus(a: PackedFloat32Array, b: PackedFloat32Array) -> PackedFloat32Array:
	for i in a.size():
		a[i] = maxf(a[i] - b[i], 0.0)
	return a


func _to_layers(v: float) -> float:
	if v <= _lut[0]:
		return 0.0
	for k in range(1, _lut.size()):
		if v <= _lut[k]:
			var span := _lut[k] - _lut[k - 1]
			return k - 1 + ((v - _lut[k - 1]) / span if span > 0.0001 else 1.0)
	return float(_lut.size() - 1)  # saturated (MAX_CAL or more)


func _stats(l: PackedFloat32Array) -> Dictionary:
	var s := l.duplicate()
	s.sort()
	var sum := 0.0
	var o4 := 0
	var o8 := 0
	for v in s:
		sum += v
		if v > 4.0:
			o4 += 1
		if v > 8.0:
			o8 += 1
	var n := maxi(s.size(), 1)
	return {mean = snappedf(sum / n, 0.01), p95 = snappedf(s[int(n * 0.95)], 0.1), max = snappedf(s[n - 1], 0.1),
		over4 = snappedf(100.0 * o4 / n, 0.1), over8 = snappedf(100.0 * o8 / n, 0.1)}


## Heat colours: 0 black, 1 dark blue, 2 blue, 3 cyan, 4 green, 6 yellow, 8 orange, 12+ red, 20+ white.
const RAMP := [[0.0, Color(0, 0, 0)], [1.0, Color(0.05, 0.1, 0.35)], [2.0, Color(0.1, 0.3, 0.8)], [3.0, Color(0.1, 0.75, 0.8)],
	[4.0, Color(0.2, 0.8, 0.25)], [6.0, Color(0.95, 0.9, 0.2)], [8.0, Color(1.0, 0.55, 0.1)], [12.0, Color(0.9, 0.1, 0.1)], [20.0, Color(1, 1, 1)]]


func _ramp(v: float) -> Color:
	for i in range(1, RAMP.size()):
		if v <= RAMP[i][0]:
			var t: float = (v - RAMP[i - 1][0]) / (RAMP[i][0] - RAMP[i - 1][0])
			return (RAMP[i - 1][1] as Color).lerp(RAMP[i][1], t)
	return RAMP[-1][1]


func _heat(l: PackedFloat32Array, w: int, h: int) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	for y in h:
		for x in w:
			img.set_pixel(x, y, _ramp(l[y * w + x]))
	return img


func _legend() -> Image:
	var img := Image.create(400, 24, false, Image.FORMAT_RGB8)
	for x in 400:
		var c := _ramp(x / 400.0 * 20.0)
		for y in 24:
			img.set_pixel(x, y, c)
	return img


## [{node, cat, visible}] for every drawn GeometryInstance3D.
func _instances() -> Array:
	var out := []
	for g in get_tree().root.find_children("*", "GeometryInstance3D", true, false):
		var gi := g as GeometryInstance3D
		if not gi.is_visible_in_tree() and not gi.visible:
			continue
		if not _raining() and _rain_only(gi):
			continue
		var cat := _category(gi)
		if cat == "fx":
			# Effects one by one (a big one can cost the screen; named by node, or its parent's).
			var nm := String(gi.name)
			cat = "fx/" + (String(gi.get_parent().name) if nm.begins_with("@") else nm)
		out.append({node = gi, cat = cat, visible = gi.visible})
	return out


func _raining() -> bool:
	return OS.get_environment("WEATHER") in ["rainy", "storm", "stormy", "drizzle"]


func _rain_only(n: Node) -> bool:
	while n:
		if String(n.name) in RAIN_ONLY:
			return true
		n = n.get_parent()
	return false


func _category(gi: GeometryInstance3D) -> String:
	if String(gi.name).begins_with("Decals"):
		return "decals"
	var paths := []
	var over: Material = gi.material_override
	if gi.has_meta(&"_count_orig"):
		var o = gi.get_meta(&"_count_orig")
		over = o if o is Material else null
	if over:
		paths.append(_shader_path(over))
	else:
		var mesh: Mesh = null
		if gi is MeshInstance3D:
			mesh = (gi as MeshInstance3D).mesh
		elif gi is MultiMeshInstance3D and (gi as MultiMeshInstance3D).multimesh:
			mesh = (gi as MultiMeshInstance3D).multimesh.mesh
		if mesh:
			for si in mesh.get_surface_count():
				var m: Material = null
				if gi is MeshInstance3D:
					m = (gi as MeshInstance3D).get_surface_override_material(si)
				if m == null:
					m = mesh.surface_get_material(si)
				paths.append(_shader_path(m))
	if paths.is_empty():
		return "opaque"
	var cats := {}
	for p in paths:
		cats[_path_category(p)] = true
	if cats.size() == 1:
		return cats.keys()[0]
	cats.erase("cutout")  # mixed chunks (opaque + cutout surfaces) count as opaque
	return cats.keys()[0] if cats.size() == 1 else "opaque"


func _shader_path(m: Material) -> String:
	if m is ShaderMaterial and (m as ShaderMaterial).shader:
		return (m as ShaderMaterial).shader.resource_path.get_file()
	if m is BaseMaterial3D:
		var b := m as BaseMaterial3D
		if b.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA or b.blend_mode != BaseMaterial3D.BLEND_MODE_MIX:
			return "standard_blend"
		if b.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			return "standard_cutout"
	return "standard"


func _path_category(p: String) -> String:
	if p.begins_with("n64_grass"):
		return "grass"
	if p.begins_with("n64_tree"):
		return "trees"
	if p.begins_with("n64_scatter"):
		return "scatter"
	if p.begins_with("n64_water"):
		return "water"
	if p.begins_with("n64_backdrop") or p.begins_with("n64_mountains"):
		return "backdrop"
	if p.begins_with("n64_actor"):
		return "actors"
	for fx in ["bulb_glow", "corona", "effect", "rain", "drip", "splash", "glow", "projected_shadow", "standard_blend", "bird"]:
		if p.contains(fx):
			return "fx"
	if p.contains("cutout"):
		return "cutout"
	return "opaque"


func _views() -> Array:
	var out := []
	if OS.get_environment("VIEW") != "":
		var i := 0
		for spec in OS.get_environment("VIEW").split(";"):
			var p := spec.split(">")
			var eye := _vec(p[0])
			var look := _vec(p[1])
			out.append({name = "view %d" % i, eye = eye, look = look, yaw = 0})
			i += 1
		return out
	var spots: Array = _BuildReport._sample_spots(_root.data.baked_meshes(), _root.global_transform, _zone)
	var floors := spots.filter(func(s): return s.kind == "floor")
	floors.sort_custom(func(a, b): return a.position.x + a.position.z * 0.001 < b.position.x + b.position.z * 0.001)
	var want := int(OS.get_environment("SPOTS")) if OS.get_environment("SPOTS") != "" else 8
	var picked := []
	for i in mini(want, floors.size()):
		picked.append(floors[int((i + 0.5) * floors.size() / mini(want, floors.size()))])
	picked.append_array(spots.filter(func(s): return s.kind == "spawn").slice(0, 4))
	var yaws := int(OS.get_environment("YAWS")) if OS.get_environment("YAWS") != "" else 4
	for si in picked.size():
		var s: Dictionary = picked[si]
		var eye: Vector3 = s.position + Vector3.UP * _BuildReport.EYE
		for k in yaws:
			var yaw := TAU * k / yaws
			out.append({name = "%s %d @%d°" % [s.kind, si, roundi(rad_to_deg(yaw))], eye = eye,
				look = eye + Basis(Vector3.UP, yaw) * Vector3(0, -0.1, -1), yaw = roundi(rad_to_deg(yaw))})
	return out


func _vec(s: String) -> Vector3:
	var p := s.split(",")
	return Vector3(float(p[0]), float(p[1]), float(p[2]))


func _write_md(results: Array) -> void:
	var lines := ["# Overdraw: " + OS.get_environment("ZONE"), "",
		"Layers per pixel along the view ray (Godot's overdraw view). *Costly* = alpha-tested and blended kinds (" + ", ".join(COSTLY) + "), which pay per layer even behind walls.", ""]
	var avg := {}
	for r in results:
		for c in r.cats:
			avg[c] = avg.get(c, 0.0) + r.cats[c].mean / results.size()
	var tm := 0.0
	var cm := 0.0
	for r in results:
		tm += r.total.mean / results.size()
		cm += r.costly_mean / results.size()
	lines.append("Average over %d views: **%.2f layers** (costly %.2f)." % [results.size(), tm, cm])
	lines.append("")
	lines.append("| kind | avg layers |")
	lines.append("|---|---|")
	var keys := avg.keys()
	keys.sort_custom(func(a, b): return avg[a] > avg[b])
	for c in keys:
		lines.append("| %s | %.2f |" % [c, avg[c]])
	lines.append("")
	lines.append("| view | mean | p95 | >4 % | >8 % | costly | top kinds |")
	lines.append("|---|---|---|---|---|---|---|")
	for r in results:
		var ks: Array = r.cats.keys()
		ks.sort_custom(func(a, b): return r.cats[a].mean > r.cats[b].mean)
		var top := ", ".join(ks.slice(0, 3).map(func(c): return "%s %.2f" % [c, r.cats[c].mean]))
		lines.append("| %s%s | %.2f | %.1f | %.1f | %.1f | %.2f | %s |" % [r.name, (" (" + r.image + ")") if r.has("image") else "",
			r.total.mean, r.total.p95, r.total.over4, r.total.over8, r.costly_mean, top])
	var f := FileAccess.open(_out + "/overdraw.md", FileAccess.WRITE)
	f.store_string("\n".join(lines) + "\n")
	f.close()
