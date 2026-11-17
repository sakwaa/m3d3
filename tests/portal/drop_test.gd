extends Node
## DropPortal test: a small made-up zone (a paved square with a 3 m hole in the middle) whose
## hole drops into the market's sky. Saves frames: approaching the hole (the other zone in
## it), falling in, and after the swap (falling into the market, then landed).
##   STYLE=seamless|rdp  OUT=dir  [TARGET=res://...tscn] [EXIT=x,y,z] [YAW=deg]
##   godot --path . --resolution 1280x720 tests/portal/drop_test.tscn

const FLOOR_TEX := "res://textures/rock/cobblestone_square.res"
const SHADER := "res://addons/n64_runtime/shaders/n64_textured.gdshader"

var out := ""
var portal: DropPortal


func _ready() -> void:
	out = OS.get_environment("OUT")
	GameState.set_time(float(OS.get_environment("HOUR")) if OS.get_environment("HOUR") != "" else 12.0)
	var zone := Zone.new()
	zone.name = "DropSource"
	zone.intro = false
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.35, 0.5, 0.8)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.8, 0.8, 0.8)
	zone.add_child(env)
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER)
	mat.set_shader_parameter(&"albedo_texture", load(FLOOR_TEX))
	mat.set_shader_parameter(&"has_texture", true)
	mat.set_shader_parameter(&"albedo_color", Color(0.8, 0.78, 0.74))
	mat.set_shader_parameter(&"uv_scale", Vector2(4, 4))
	# 40 x 40 m of paving round a 3 x 3 m hole (four slabs), and a low wall at the back.
	var h := 1.5
	for r in [Rect2(-20, -20, 40, 20 - h), Rect2(-20, h, 40, 20 - h), Rect2(-20, -h, 20 - h, 2 * h), Rect2(h, -h, 20 - h, 2 * h)]:
		_box(zone, Vector3(r.position.x + r.size.x * 0.5, -0.25, r.position.y + r.size.y * 0.5), Vector3(r.size.x, 0.5, r.size.y), mat)
	_box(zone, Vector3(0, 1.0, -14), Vector3(12, 2, 1), mat)
	portal = DropPortal.new()
	portal.target_zone = OS.get_environment("TARGET") if OS.get_environment("TARGET") != "" else "res://zones/town1/town_1_market_square.tscn"
	var e := OS.get_environment("EXIT").split(",") if OS.get_environment("EXIT") != "" else PackedStringArray(["5", "38", "2"])
	portal.exit_position = Vector3(float(e[0]), float(e[1]), float(e[2]))
	portal.exit_yaw = float(OS.get_environment("YAW")) if OS.get_environment("YAW") != "" else 0.0
	portal.style = DropPortal.Style.RDP if OS.get_environment("STYLE") == "rdp" else DropPortal.Style.SEAMLESS
	portal.size = Vector2(3, 3)
	zone.add_child(portal)
	get_tree().root.add_child.call_deferred(zone)
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().current_scene = zone
	ZoneManager._adopt_current_scene(&"")
	var p := ZoneManager.player
	p.teleport(Transform3D(Basis.IDENTITY, Vector3(0, 0.05, 4.5)))
	_run()


func _box(parent: Node, at: Vector3, size: Vector3, mat: Material) -> void:
	var body := StaticBody3D.new()
	body.position = at
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.material_override = mat
	body.add_child(mi)
	parent.add_child(body)


func _run() -> void:
	# Wait for the other zone to load into the hole.
	var t0 := Time.get_ticks_msec()
	while portal.get(&"_preview") == null and Time.get_ticks_msec() - t0 < 30000:
		await get_tree().process_frame
	print("DROP preview ready after ", Time.get_ticks_msec() - t0, " ms: ", portal.get(&"_preview") != null)
	for i in 30:
		await get_tree().process_frame
	await _save("1_approach")
	# Step to the hole's edge and look down into it.
	var p := ZoneManager.player
	p.teleport(Transform3D(Basis.IDENTITY, Vector3(0, 0.05, 2.2)))
	p._pitch.rotation.x = -0.9
	for i in 20:
		await get_tree().process_frame
	await _save("2_edge")
	# Over the hole: fall in.
	p.teleport(Transform3D(Basis.IDENTITY, Vector3(0, 0.6, 0.3)))
	p._pitch.rotation.x = -0.9
	var shots := 0
	var swapped_at := -1
	for i in 400:
		await get_tree().process_frame
		if ZoneManager.zone != null and ZoneManager.zone.name != "DropSource" and swapped_at < 0:
			swapped_at = i
			print("DROP swapped at frame ", i, " into ", ZoneManager.zone.name, " player ", ZoneManager.player.global_position, " vel ", ZoneManager.player.velocity)
		if i == 8:
			await _save("3_falling_in")
		if swapped_at >= 0 and (i - swapped_at) in [4, 30, 60]:
			shots += 1
			await _save("4_after_%d" % shots)
		if swapped_at >= 0 and ZoneManager.player.is_on_floor() and i - swapped_at > 60:
			print("DROP landed at ", ZoneManager.player.global_position, " hp ", ZoneManager.player.get(&"health"))
			for k in 20:
				await get_tree().process_frame
			await _save("5_landed")
			break
	get_tree().quit()


func _save(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out + "/" + name + ".png")
