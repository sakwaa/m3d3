extends Node3D
## Renders a few effect presets side by side against a mid-grey wall (smoke, dust, splash,
## sparks) after they've run a moment, to compare looks (OLD=1: the old PNG sprites,
## texture colour x tint, for a before / after).
##   OUT=dir [OLD=1] godot --path . --resolution 960x540 tests/effects/effects_shot.tscn
const PRESETS := ["smoke", "dust_puff", "water_splash", "hit_sparks"]
const OLD_SPRITES := {"smoke": "puff", "dust_puff": "puff", "water_splash": "soft_dot", "hit_sparks": "spark"}


func _ready() -> void:
	RenderingServer.global_shader_parameter_set(&"n64_ambient_light", Color(1, 1, 1, 1))
	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.2, 4.2)
	add_child(cam)
	cam.look_at(Vector3(0, 0.9, 0))
	var wall := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(12, 6)
	wall.mesh = q
	var wm := StandardMaterial3D.new()
	wm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	wm.albedo_color = Color(0.32, 0.36, 0.3)
	wall.material_override = wm
	wall.position = Vector3(0, 1.5, -1.5)
	add_child(wall)
	var old := OS.get_environment("OLD") != ""
	for i in PRESETS.size():
		var e: N64Effect = (load("res://game/effects/%s.tres" % PRESETS[i]) as N64Effect).duplicate()
		if old:
			e.texture = load("res://game/effects/sprites/%s.png" % OLD_SPRITES[PRESETS[i]])
			e.intensity = false
		e.rate = maxf(e.rate, 6.0)
		var em := EffectEmitter.new()
		em.effect = e
		em.position = Vector3(-2.1 + i * 1.4, 0.4, 0)
		add_child(em)
	for f in 50:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var out := OS.get_environment("OUT")
	DirAccess.make_dir_recursive_absolute(out)
	get_viewport().get_texture().get_image().save_png(out.path_join("effects.png"))
	get_tree().quit()
