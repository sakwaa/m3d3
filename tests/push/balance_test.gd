extends Node
## BalanceLift test: a scale and a pulley lift standing 1.5 m up over a paved yard.
##  1 empty: level;  2 a block on pan B: B sinks, the block rides it down;
##  3 the player on pan A too (1 against 2): still B down;
##  4 the player off, a heavier block (3) on A (3 against 2): A sinks, the block on B rides up;
##  5 pulley: a block in A's basket raises B's platform.
## Prints PASS / FAIL per case; OUT=dir saves a frame after each.
##   godot --path . --resolution 1280x720 tests/push/balance_test.tscn

const FLOOR_TEX := "res://textures/rock/cobblestone_square.res"
const SHADER := "res://addons/n64_runtime/shaders/n64_textured.gdshader"

var out := ""
var fails := 0
var scale_: BalanceLift
var pulley: BalanceLift
var zone: Zone


func _ready() -> void:
	out = OS.get_environment("OUT")
	GameState.set_time(12.0)
	zone = Zone.new()
	zone.name = "BalanceYard"
	zone.intro = false
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.35, 0.5, 0.8)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.8, 0.8, 0.8)
	zone.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.5, 0)
	zone.add_child(sun)
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER)
	mat.set_shader_parameter(&"albedo_texture", load(FLOOR_TEX))
	mat.set_shader_parameter(&"has_texture", true)
	mat.set_shader_parameter(&"albedo_color", Color(0.8, 0.78, 0.74))
	mat.set_shader_parameter(&"uv_scale", Vector2(4, 4))
	var body := StaticBody3D.new()
	body.position = Vector3(0, -0.5, 0)
	var cs := CollisionShape3D.new()
	cs.shape = BoxShape3D.new()
	(cs.shape as BoxShape3D).size = Vector3(60, 1, 60)
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	(mi.mesh as BoxMesh).size = Vector3(60, 1, 60)
	mi.material_override = mat
	body.add_child(mi)
	zone.add_child(body)
	scale_ = BalanceLift.new()
	scale_.position = Vector3(0, 1.5, 0)
	zone.add_child(scale_)
	pulley = BalanceLift.new()
	pulley.style = BalanceLift.Style.PULLEY
	pulley.pan_b = Vector3(8, 0, 0)
	pulley.position = Vector3(-14, 1.5, 8)
	zone.add_child(pulley)
	get_tree().root.add_child.call_deferred(zone)
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().current_scene = zone
	ZoneManager._adopt_current_scene(&"")
	var p := ZoneManager.player
	p.teleport(Transform3D(Basis.IDENTITY, Vector3(2, 0.05, 9)))
	p._pitch.rotation.x = -0.3
	_run()


func _block(at: Vector3) -> PushBlock:
	var b := PushBlock.new()
	b.position = at
	zone.add_child(b)
	return b


func _wait(seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()


func _check(case: String, ok: bool, detail: String) -> void:
	print("BAL %s %s  %s" % ["PASS" if ok else "FAIL", case, detail])
	if not ok:
		fails += 1


func _run() -> void:
	await _wait(1.0)
	_check("empty", scale_.balance == 0.0, "balance %.3f" % scale_.balance)
	var on_b := _block(Vector3(4, 1.5, 0))
	await _wait(4.0)
	_check("block on B", scale_.balance == -1.0 and absf(on_b.pos.y - 0.3) < 0.02, "balance %.3f, block y %.3f (want 0.3)" % [scale_.balance, on_b.pos.y])
	await _save("2_block_on_b")
	var p := ZoneManager.player
	p.teleport(Transform3D(Basis.IDENTITY, Vector3(0, 2.8, 0)))
	await _wait(3.0)
	_check("player on A", scale_.balance == -1.0 and p.global_position.y > 2.6, "balance %.3f, player y %.3f" % [scale_.balance, p.global_position.y])
	p.teleport(Transform3D(Basis.IDENTITY, Vector3(2, 0.05, 9)))
	var on_a := _block(Vector3(0, 2.8, 0))
	on_a.weight = 3.0  # (heavier than B's: 3 against 2)
	await _wait(5.0)
	_check("blocks 3 v 2", scale_.balance == 1.0 and absf(on_b.pos.y - 2.7) < 0.02 and absf(on_a.pos.y - 0.3) < 0.02,
		"balance %.3f, B block y %.3f (want 2.7), A block y %.3f (want 0.3)" % [scale_.balance, on_b.pos.y, on_a.pos.y])
	await _save("4_tipped_a")
	p.teleport(Transform3D(Basis.IDENTITY, Vector3(-10, 0.05, 17)))
	_block(Vector3(-14, 1.5, 8))
	await _wait(4.0)
	_check("pulley", pulley.balance == 1.0, "balance %.3f" % pulley.balance)
	await _save("5_pulley")
	print("BAL done, %d failed" % fails)
	get_tree().quit(1 if fails else 0)


func _save(name: String) -> void:
	if out == "":
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(out + "/" + name + ".png")
