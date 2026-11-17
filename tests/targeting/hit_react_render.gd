extends Node
# Hit reaction render: a lone Wolfos takes three scripted blows - a slash across its head
# from its left, a stab into the chest from the front, a heavy finisher on the flank - and
# each is caught from contact to recovery (frames 0, 4, 8 = hitstop end, 12, 18, 26, 40).
# REACT=0: springs off (as before). OUT=file.png saves the strip; FRAMES=dir every other
# frame. Run with --fixed-fps 60.
const WOLFOS := preload("res://game/actors/enemies/wolfos/wolfos.gd")
const OFFSETS := [0, 4, 8, 12, 18, 26, 40]
var w: Actor
var by: Actor
var t := 0.0
var frame := 0
var hit_i := -1
var hit_frame := 0
var shots := []  # [hit, offset index, image]
var cam: Camera3D
# [name, attacker offset from the wolfos, push dir, strike point height / side, heavy]
var hits := [
	["slash at head, from its left", Vector3(-1.6, 0, 0), Vector3(0.35, 0, -1.0), Vector3(0.0, 0.75, -0.75), false],
	["stab at chest, from the front", Vector3(0, 0, -1.8), Vector3(0, 0, 1.0), Vector3(0.0, 0.6, -0.45), false],
	["finisher on the flank", Vector3(1.6, 0, 0), Vector3(-1.0, 0, 0.2), Vector3(0.25, 0.55, 0.0), true],
]

func _ready() -> void:
	Actor.show_debug = false
	HitReact.enabled = OS.get_environment("REACT") != "0"
	var floor := StaticBody3D.new(); var cs := CollisionShape3D.new(); var sh := BoxShape3D.new(); sh.size = Vector3(60, 1, 60)
	cs.shape = sh; floor.add_child(cs); floor.position.y = -0.5; add_child(floor)
	var fm := MeshInstance3D.new(); var bm := BoxMesh.new(); bm.size = sh.size; fm.mesh = bm; floor.add_child(fm)
	var fmat := StandardMaterial3D.new(); fmat.albedo_color = Color(0.42, 0.5, 0.36); fm.material_override = fmat
	var env := WorldEnvironment.new(); var e := Environment.new()
	e.background_mode = Environment.BG_COLOR; e.background_color = Color(0.5, 0.6, 0.75)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; e.ambient_light_color = Color(0.6, 0.6, 0.65)
	env.environment = e; add_child(env)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-50, 30, 0); add_child(sun)
	w = WOLFOS.new()
	w.position = Vector3(0, 0.1, 0)
	add_child(w)
	w.max_health = 99; w.health = 99
	by = Actor.new(); by.team = 7; by.position = Vector3(0, 0, -20); add_child(by)
	cam = Camera3D.new(); add_child(cam)
	cam.position = Vector3(2.4, 1.3, 1.5); cam.look_at(Vector3(-0.2, 0.55, -0.1)); cam.fov = 45.0

func _physics_process(delta: float) -> void:
	t += delta
	frame += 1
	# Each hit 1.2 s apart, the wolfos put back in place (and facing -Z) before each.
	var next := int((t - 0.6) / 1.2)
	if t >= 0.6 and next != hit_i and next < hits.size():
		hit_i = next
		w.global_position = Vector3(0, 0.1, 0); w.velocity = Vector3.ZERO; w.impulse = Vector3.ZERO
		w.facing = Vector3(0, 0, -1)
		var h: Array = hits[hit_i]
		by.global_position = w.global_position + h[1]
		var at: Vector3 = w.global_position + h[3]
		w.take_hit(1, by, 4.0, {dir = (h[2] as Vector3).normalized(), at = at, strength = 1.5 if h[4] else 1.0, heavy = h[4]})
		w.hitstop(8.0 / 60.0)
		w.flash(Color(1.0, 0.12, 0.1, 0.85), 14.0 / 60.0, 4.0 / 60.0)
		hit_frame = frame
	if OS.get_environment("FRAMES") != "" and t >= 0.5:
		# FRAMES=dir: every other frame as a numbered PNG (for a GIF).
		if frame % 2 == 0:
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(OS.get_environment("FRAMES").path_join("f%04d.png" % (frame / 2)))
	if hit_i >= 0 and hit_i < hits.size():
		var k := OFFSETS.find(frame - hit_frame)
		if k >= 0:
			await RenderingServer.frame_post_draw
			shots.append([hit_i, k, get_viewport().get_texture().get_image()])
	if t > 0.6 + 1.2 * hits.size():
		_save()
		get_tree().quit()

func _save() -> void:
	var out := OS.get_environment("OUT")
	if out == "" or shots.is_empty():
		return
	var cw := 320; var ch := 240
	var sheet := Image.create(cw * OFFSETS.size(), ch * hits.size(), false, Image.FORMAT_RGBA8)
	for s in shots:
		var img: Image = s[2]; img.convert(Image.FORMAT_RGBA8)
		var c := img.get_region(Rect2i(img.get_width() / 2 - img.get_height() * 2 / 3, 0, img.get_height() * 4 / 3, img.get_height()))
		c.resize(cw, ch, Image.INTERPOLATE_BILINEAR)
		sheet.blit_rect(c, Rect2i(0, 0, cw, ch), Vector2i(s[1] * cw, s[0] * ch))
	sheet.save_png(out)
