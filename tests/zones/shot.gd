extends Node3D
## Renders a zone from a set camera (to compare with its reference photo) and quits.
##   ZONE=res://... CAM=x,y,z LOOK=x,y,z [FOV=50] [HOUR=15] [NOFOG=1] [PLAYER=x,y,z[,yaw]]
##   [WEATHER=rainy] [RAIN_OLD=1] [GRADE=1: tests/zones/grade.gd] [WIRE=1: wireframe] [NOAO=1] OUT=dir godot --path . --resolution 1280x960 tests/zones/shot.tscn

var _frames := 0


func _ready() -> void:
	if OS.get_environment("WIRE") != "":
		# WIRE=1: wireframe (the triangles as built).
		RenderingServer.set_debug_generate_wireframes(true)
		get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
	if OS.get_environment("GRADE") != "":
		preload("res://tests/zones/grade.gd").apply_globals()
	if OS.get_environment("NOAO") != "":
		# NOAO=1: the baked vertex AO left out of the shading (as the editor's AO toggle).
		RenderingServer.global_shader_parameter_set(&"n64_vertex_ao", 0.0)
	if OS.get_environment("TEXWS") != "":
		preload("res://tests/zones/grade.gd").apply_textures()
	var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
	if OS.get_environment("NOFOG") != "":
		# Overhead / far shots: no fog, no clipping at the fog's end.
		zone.set(&"fog", null)
		zone.set(&"clip_at_fog_end", false)
	if OS.get_environment("LEVEL_OVERRIDE") != "":
		# LEVEL_OVERRIDE=path.res: the zone's level data swapped for another (a test bake).
		var lr: Node = zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
		lr.set(&"data", ResourceLoader.load(OS.get_environment("LEVEL_OVERRIDE"), "", ResourceLoader.CACHE_MODE_IGNORE))
	if OS.get_environment("GRASS") != "":
		# GRASS="style,height[,mound width]": the carpet built in another edge style
		# (0 carpet, 1 ledge, 2 mound; render only).
		var lr: Node = zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
		var gp := OS.get_environment("GRASS").split(",")
		var gs: GrassSettings = (lr.get(&"data") as LevelData).grass.duplicate()
		gs.edge_style = int(gp[0])
		gs.height = float(gp[1])
		if gp.size() > 2:
			gs.mound_width = float(gp[2])
		(lr.get(&"data") as LevelData).grass = gs
	if OS.get_environment("FOG") != "":
		# FOG="start,end": the zone's fog distances (render only).
		var fv := OS.get_environment("FOG").split(",")
		var fs: Resource = (zone.get(&"fog") as Resource).duplicate()
		fs.set(&"start", float(fv[0]))
		fs.set(&"end", float(fv[1]))
		zone.set(&"fog", fs)
	if OS.get_environment("MOUNTAINS") != "":
		# MOUNTAINS=seed: a MountainRange round the zone (render only).
		var mr: Node3D = (load("res://addons/n64_runtime/world/mountain_range.gd") as Script).new()
		mr.set(&"seed", int(OS.get_environment("MOUNTAINS")))
		if OS.get_environment("MOUNTAIN_ROCK") != "":
			mr.set(&"rock_texture", load(OS.get_environment("MOUNTAIN_ROCK")))
		zone.add_child(mr)
	add_child(zone)
	if OS.get_environment("GRASS_PAINT") != "":
		# GRASS_PAINT="x,z,radius,style,height;…": carpet painted (style -1 = the level's;
		# render only).
		var lr: LevelRoot = zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
		lr.data.grass = lr.data.grass.duplicate()
		var tool := LevelGrassTool.new()
		for stroke in OS.get_environment("GRASS_PAINT").split(";"):
			var v := stroke.split(",")
			tool.style = int(v[3])
			tool.height = float(v[4])
			tool.begin(lr, lr.to_global(Vector3(float(v[0]), 0.0, float(v[1]))), float(v[2]), false)
			tool.end()
	if OS.get_environment("PLAYER") != "":
		# PLAYER=x,y,z[,yaw]: the player standing there (scripted, idle).
		var pp := OS.get_environment("PLAYER").split(",")
		var player: Node3D = (load("res://player/player.tscn") as PackedScene).instantiate()
		player.set(&"scripted", true)
		add_child(player)
		player.global_position = Vector3(float(pp[0]), float(pp[1]), float(pp[2]))
		if pp.size() > 3:
			player.call(&"face", Vector3.FORWARD.rotated(Vector3.UP, deg_to_rad(float(pp[3]))))
	var cam := Camera3D.new()
	cam.name = "ShotCam"
	cam.fov = float(OS.get_environment("FOV")) if OS.get_environment("FOV") != "" else 50.0
	add_child(cam)
	cam.position = _vec(OS.get_environment("CAM"))
	cam.look_at(_vec(OS.get_environment("LOOK")))
	cam.make_current()
	GameState.set_time(float(OS.get_environment("HOUR")) if OS.get_environment("HOUR") != "" else 15.0)
	if OS.get_environment("WEATHER") != "":
		GameState.set_weather(StringName(OS.get_environment("WEATHER")), 0.0)
	if OS.get_environment("RAIN_OLD") != "":
		# The rain as it was (2400 streaks in the shader's default box, no far sheet).
		for r in zone.find_children("*", "Rain", true, false) + _all(zone).filter(func(n): return n is Rain):
			r.mesh = Rain.make_mesh(2400)
			(r.material_override as ShaderMaterial).set_shader_parameter(&"box", Vector3(56, 20, 56))
			for c in r.get_children(true):
				if c.name == "Sheet":
					c.visible = false
	Actor.show_debug = false


func _vec(s: String) -> Vector3:
	var p := s.split(",")
	return Vector3(float(p[0]), float(p[1]), float(p[2]))


func _process(_delta: float) -> void:
	_frames += 1
	if _frames == 2:
		# AA=none|msaa2|msaa4|fxaa|smaa, RES=3D render scale (bilinear upscale): look trials.
		var vp := get_viewport()
		match OS.get_environment("AA"):
			"msaa2": vp.msaa_3d = Viewport.MSAA_2X
			"msaa4": vp.msaa_3d = Viewport.MSAA_4X
			"fxaa": vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
			"smaa": vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_SMAA
		if OS.get_environment("VOUT") != "":
			# VOUT="16bit,dither,dedither,soft,bleed": the N64 video output's settings
			# (game/video_out.tres, applied by RenderScale; render only).
			var v := OS.get_environment("VOUT").split(",")
			var e: Resource = load("res://game/video_out.tres")
			e.set(&"color_16bit", v[0] == "1")
			e.set(&"dither", float(v[1]))
			e.set(&"dedither", float(v[2]))
			e.set(&"horizontal_soft", float(v[3]))
			e.set(&"composite_bleed", float(v[4]))
		if OS.get_environment("SCREEN") != "":
			# SCREEN="grade,r,g,b,echo": the screen filters (RenderScale.screen_to, instant).
			var v := OS.get_environment("SCREEN").split(",")
			RenderScale.screen_to(float(v[0]), Color(float(v[1]), float(v[2]), float(v[3])), float(v[4]), 0.0)
		if OS.get_environment("KEYLOOKS") != "":
			# KEYLOOKS="weather:key:look,…": screen looks on weather keys (in memory, instant).
			for item in OS.get_environment("KEYLOOKS").split(","):
				var kv := item.split(":")
				var lk: ScreenLook = (load("res://game/looks/%s.tres" % kv[2]) as ScreenLook).duplicate()
				lk.blend_time = 0.0
				GameState.weather_table.find(StringName(kv[0])).get_key(int(kv[1])).screen_look = lk
		if OS.get_environment("LOOK_RES") != "":
			# LOOK_RES=res://…tres: a ScreenLook forced on at once.
			RenderScale.force_look(load(OS.get_environment("LOOK_RES")), 0.0)
		if OS.get_environment("ECHO") != "":
			# ECHO="rate,soften": the echo's pictures a second and blur (pixels).
			var ev := OS.get_environment("ECHO").split(",")
			RenderScale.video_out().set(&"echo_rate", float(ev[0]))
			RenderScale.video_out().set(&"echo_soften", int(ev[1]))
		if OS.get_environment("VSTEPS") != "":
			# VSTEPS=n: value groups (with SCREEN=1,1,1,1,0 for greyscale).
			RenderScale.video_out().set(&"value_steps", int(OS.get_environment("VSTEPS")))
		if OS.get_environment("CV") != "":
			# CV=1..3: colour-blind correction (protanopia / deuteranopia / tritanopia).
			RenderScale.video_out().set(&"colour_vision", int(OS.get_environment("CV")))
		if OS.get_environment("RES") != "":
			vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
			vp.scaling_3d_scale = float(OS.get_environment("RES"))
	if _frames == 3:
		for c in find_children("*", "Camera3D", true, false):
			if c.name != "ShotCam":
				c.current = false
		(get_node("ShotCam") as Camera3D).make_current()
	if _frames == 30 and OS.get_environment("NO_FAR") != "":
		# NO_FAR=1: far stand-ins hidden (which LOD a spot shows).
		for g in get_tree().root.find_children("*", "GeometryInstance3D", true, false):
			if (g as GeometryInstance3D).visibility_range_begin > 0.0:
				g.visible = false
	if OS.get_environment("NO_NEAR") != "" and _frames == 30:
		for g in get_tree().root.find_children("*", "GeometryInstance3D", true, false):
			if (g as GeometryInstance3D).visibility_range_end > 0.0 and (g as GeometryInstance3D).visibility_range_begin <= 0.0:
				g.visible = false
	if OS.get_environment("LIGHTFX") != "" and _frames == 8:
		# LIGHTFX="floor,contrast": the level's light floor / contrast on every baked material.
		var lv := OS.get_environment("LIGHTFX").split(",")
		for mi: MeshInstance3D in get_tree().root.find_children("*", "MeshInstance3D", true, false):
			for si in (mi.mesh.get_surface_count() if mi.mesh else 0):
				var m := mi.get_active_material(si) as ShaderMaterial
				if m and m.get_shader_parameter(&"light_floor") != null:
					m.set_shader_parameter(&"light_floor", float(lv[0]))
					m.set_shader_parameter(&"light_contrast", float(lv[1]))
					if lv.size() > 2:
						m.set_shader_parameter(&"bake_strength", float(lv[2]))
	if OS.get_environment("ADJ") != "" and _frames == 8:
		# ADJ="name:brightness:saturation;...": a ColourAdjust on materials whose base texture
		# file name contains `name` (hybrid materials only; render only).
		for spec in OS.get_environment("ADJ").split(";"):
			var p := spec.split(":")
			var a := ColourAdjust.new()
			a.brightness = float(p[1])
			a.saturation = float(p[2]) if p.size() > 2 else 1.0
			if p.size() > 4:
				# name:bright:sat:shadow_hex:light_hex = start from grey with that ramp
				a.from_grey = true
				a.shadow = Color(p[3])
				a.colorize = Color(p[4])
				a.colorize_amount = 1.0
			var prm := ColourAdjust.params(a)
			for mi: MeshInstance3D in get_tree().root.find_children("*", "MeshInstance3D", true, false):
				for si in (mi.mesh.get_surface_count() if mi.mesh else 0):
					var m := mi.get_active_material(si) as ShaderMaterial
					var bt = m.get_shader_parameter(&"base_tex") if m else null
					if bt is Texture2D and (bt as Texture2D).resource_path.get_file().contains(p[0]):
						for k in 4:
							m.set_shader_parameter(StringName("base_adj%d" % k), prm[k])
	if OS.get_environment("FIX_LIME") != "" and _frames == 8:
		# FIX_LIME=1: the courtyard's lime vertex paint shown as plain (in memory).
		for mi: MeshInstance3D in get_tree().root.find_children("*", "MeshInstance3D", true, false):
			var mesh := mi.mesh as ArrayMesh
			if mesh == null:
				continue
			var fixed := ArrayMesh.new()
			var any := false
			for si in mesh.get_surface_count():
				var arr := mesh.surface_get_arrays(si)
				var col = arr[Mesh.ARRAY_COLOR]
				if col is PackedColorArray:
					var pc: PackedColorArray = col
					for i in pc.size():
						var c := pc[i]
						if c.g > 0.98 and c.r < 0.95 and c.b < c.r + 0.05:
							pc[i] = Color(0.949, 0.949, 0.949, c.a)
							any = true
					arr[Mesh.ARRAY_COLOR] = pc
				var custom := 0
				for ch in 4:
					custom |= Mesh.ARRAY_FORMAT_CUSTOM_MASK << (Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT + ch * Mesh.ARRAY_FORMAT_CUSTOM_BITS)
				fixed.add_surface_from_arrays(mesh.surface_get_primitive_type(si), arr, [], {}, mesh.surface_get_format(si) & custom)
				fixed.surface_set_material(si, mesh.surface_get_material(si))
			if any:
				fixed.custom_aabb = mesh.custom_aabb
				mi.mesh = fixed
	if OS.get_environment("GRADE_VERTEX") != "" and _frames == 8:
		# GRADE_VERTEX=1: a sample vertex grade (cool light shadows, night-only blue gradient
		# map, AO warm at noon / blue at night) through GradeVertex into every paint material.
		_grade_vertex_demo()
	if OS.get_environment("GRADE_DEMO") != "" and _frames == 8:
		# GRADE_DEMO=1: a sample Grade stack (zone gradient map on soft light, grass and
		# ground levels, cool multiply glaze on brick) run through GradeProcessor and swapped
		# into the level's materials by base texture (render only).
		_grade_demo()
	if OS.get_environment("TEXGRADE") != "" and _frames == 8:
		# TEXGRADE=current | uniform:<sample>: a texture grade previewed in memory.
		preload("res://tests/zones/texgrade_preview.gd").apply(get_tree().root, OS.get_environment("TEXGRADE"))
	if OS.get_environment("NO_GRASS") != "" and _frames == 30:
		# NO_GRASS=1: grass mat + tufts hidden.
		for g in get_tree().root.find_children("Grass*", "GeometryInstance3D", true, false):
			g.visible = false
	if OS.get_environment("NO_LAYERS") != "" and _frames == 30:
		# NO_LAYERS=1: painted layers off on paint_hybrid materials.
		for g in get_tree().root.find_children("*", "MeshInstance3D", true, false):
			var mi := g as MeshInstance3D
			for s in (mi.mesh.get_surface_count() if mi.mesh else 0):
				var m := mi.get_active_material(s) as ShaderMaterial
				if m and m.get_shader_parameter(&"layer_count") != null:
					m.set_shader_parameter(&"layer_count", 0)
	if OS.get_environment("NO_LIGHTS") != "" and _frames == 30:
		# NO_LIGHTS=1: live Light3Ds off (bake only).
		for g in get_tree().root.find_children("*", "Light3D", true, false):
			print("light off: ", g.get_path(), " ", g.get_class(), " shadow ", (g as Light3D).shadow_enabled)
			g.visible = false
	if OS.get_environment("NO_3PT") != "" and _frames == 30:
		RenderingServer.global_shader_parameter_set(&"n64_three_point", false)
	if OS.get_environment("VAR") != "" and _frames == 30:
		# VAR="strength,size,mode" VARTEX=res://… VARBASE=name: try a base variation on the
		# materials whose base texture's file name contains VARBASE (render only).
		var v := OS.get_environment("VAR").split(",")
		var vt: Texture2D = load(OS.get_environment("VARTEX")) if OS.get_environment("VARTEX") != "" else null
		for g in get_tree().root.find_children("*", "MeshInstance3D", true, false):
			var mi := g as MeshInstance3D
			for s in (mi.mesh.get_surface_count() if mi.mesh else 0):
				var m := mi.get_active_material(s) as ShaderMaterial
				var bt = m.get_shader_parameter(&"base_tex") if m else null
				if bt is Texture2D and (bt as Texture2D).resource_path.get_file().contains(OS.get_environment("VARBASE")):
					m.set_shader_parameter(&"base_var", Vector3(float(v[0]), float(v[1]), float(v[2])))
					if vt:
						m.set_shader_parameter(&"base_variation_tex", vt)
	if OS.get_environment("PAN") != "" and _frames > 3:
		# PAN=degrees a frame: the camera turning (shows the echo blur).
		(get_node("ShotCam") as Camera3D).rotate_y(deg_to_rad(float(OS.get_environment("PAN"))))
	if _frames == 40:
		get_viewport().get_texture().get_image().save_png(OS.get_environment("OUT") + "/shot.png")
		get_tree().quit()


func _all(n: Node) -> Array:
	var out := []
	for c in n.get_children(true):
		out.append(c)
		out.append_array(_all(c))
	return out


func _grade_demo() -> void:
	var g := ZoneGrade.new()
	var gm := GradeGradientMap.new()
	gm.opacity = 0.7
	var lv_ground := GradeLevels.new()
	lv_ground.gamma = 1.35
	lv_ground.out_white = 1.0
	var lv_grass := GradeLevels.new()
	lv_grass.gamma = 0.85
	var glaze := GradeFill.new()
	glaze.colour = Color(0.55, 0.6, 0.85)
	glaze.blend = GradeFilter.Blend.MULTIPLY
	glaze.opacity = 0.3
	g.stacks = {"zone": [gm], "group/ground": [lv_ground], "group/grass": [lv_grass], "group/brick": [glaze]}
	if OS.get_environment("GRADE_DEMO") == "identity":
		g.stacks = {"zone": [GradeLevels.new()]}
	if OS.get_environment("GRADE_DEMO") == "tiny":
		var t := GradeLevels.new()
		t.gamma = 1.05
		g.stacks = {"zone": [t]}
	var done := {}
	var n := 0
	for mi in get_tree().root.find_children("*", "MeshInstance3D", true, false):
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		if mesh == null:
			continue
		for si in mesh.get_surface_count():
			var mat := (mi as MeshInstance3D).get_active_material(si) as ShaderMaterial
			if mat == null or mat.has_meta(&"grade_demo"):
				continue  # (shared materials: grade once, never the graded texture again)
			mat.set_meta(&"grade_demo", true)
			var base = mat.get_shader_parameter(&"base_tex")
			if not base is Texture2D:
				continue
			if OS.get_environment("GRADE_DEBUG") != "" and n < 400:
				print("[gd] ", base.resource_path.get_file(), " ", base.get_class(), " ", base.get_size(), " shader=", mat.shader.resource_path.get_file(), " mode=", mat.get_shader_parameter(&"base_tint_mode"), " recolour=", mat.get_shader_parameter(&"base_recolour"), " adj1=", mat.get_shader_parameter(&"base_adj1"))
			var mode: float = mat.get_shader_parameter(&"base_tint_mode") if mat.get_shader_parameter(&"base_tint_mode") != null else 0.0
			var tint := []
			if mode > 0.5:
				tint = [mode, Color(mat.get_shader_parameter(&"base_tint_dark")), Color(mat.get_shader_parameter(&"base_tint_light")), mat.get_shader_parameter(&"base_tint_extra")]
			var k := [base, var_to_str(tint)]
			if not done.has(k):
				var chain := g.chain_for(base, GradeLayers.group_of(base))
				var src := GradeProcessor.source_image(base)
				done[k] = ImageTexture.create_from_image(GradeProcessor.process(src, chain, tint)) if src and not chain.is_empty() else null
				if OS.get_environment("GRADE_DEBUG") != "" and done[k] and (base.resource_path.contains("stucco") or base.resource_path.contains("green_grass")):
					src.save_png(OS.get_environment("OUT") + "/src_" + base.resource_path.get_file().get_basename() + ".png")
					done[k].get_image().save_png(OS.get_environment("OUT") + "/out_" + base.resource_path.get_file().get_basename() + ".png")
					print("[gd] chain ", chain.map(func(f): return [f.title(), f.blend, f.opacity]), " tint ", tint)
			if done[k]:
				mat.set_shader_parameter(&"base_tex", done[k])
				if mode > 0.5:
					mat.set_shader_parameter(&"base_tint_mode", 0.0)
			n += 1
	print("[grade demo] %d textures graded, %d surfaces" % [done.size(), n])


func _grade_vertex_demo() -> void:
	var g := ZoneGrade.new()
	var bal := GradeBalance.new()
	bal.shadows = Color(0.35, 0.42, 0.68)
	bal.highlights = Color(0.6, 0.53, 0.42)
	bal.on_light = true
	var night := GradeGradientMap.new()
	night.on_light = true
	night.keys = 1  # (Night only)
	night.blend = GradeFilter.Blend.COLOUR
	night.opacity = 0.6
	night.gradient.colors = PackedColorArray([Color(0.02, 0.03, 0.12), Color(0.15, 0.2, 0.45), Color(0.7, 0.75, 0.95)])
	g.stacks = {"vertex/light": [bal, night]}
	var ao := GradeAO.new()
	ao.linked = false
	ao.strength = PackedFloat32Array([1.4, 1.1, 1.1, 1.2])
	ao.curve = PackedFloat32Array([0.7, 1.0, 1.0, 0.9])
	ao.tint = PackedColorArray([Color(0.05, 0.08, 0.3), Color(0.3, 0.2, 0.25), Color(0.4, 0.28, 0.16), Color(0.3, 0.15, 0.25)])
	g.ao = ao
	GradeVertex.prepare(g)
	var params := GradeVertex.compile(g)
	for k in params:
		if params[k] is Image:
			params[k] = ImageTexture.create_from_image(params[k])
	var n := 0
	var seen := {}
	for mi in get_tree().root.find_children("*", "MeshInstance3D", true, false):
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		if mesh == null:
			continue
		for si in mesh.get_surface_count():
			var mat := (mi as MeshInstance3D).get_active_material(si) as ShaderMaterial
			if mat == null or seen.has(mat) or not PaintAtlas.is_paint_shader(mat.shader):
				continue
			seen[mat] = true
			mat.set_shader_parameter(&"grade_vertex", true)
			for k in params:
				mat.set_shader_parameter(k, params[k])
			n += 1
	print("[grade vertex] %d materials, light %s ao %s" % [n, params.get("grade_light_on"), params.get("grade_ao_on")])
