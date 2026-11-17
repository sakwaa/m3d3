extends Node3D
## Combiner library compile + look check: four quads, each a libultra mode on a gradient.
func _ready() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 0, 4)
	cam.make_current()
	var modes := ["n64_cc_blend_pe(t, vec4(1.0, 0.85, 0.2, 1.0), vec4(0.6, 0.05, 0.0, 1.0))",
		"n64_cc_modulate_rgba(t, vec4(COLOR.rgb, 1.0))",
		"n64_cc2_modulate_rgba(n64_cc_trilerp(t, t.gbra, 0.5), vec4(0.4, 0.6, 1.0, 1.0))",
		"vec4(n64_blend_fog(t.rgb, vec3(0.5, 0.55, 0.7), 0.6), 1.0)"]
	for i in modes.size():
		var sh := Shader.new()
		sh.code = "shader_type spatial;\nrender_mode unshaded;\n#include \"res://addons/n64_runtime/shaders/n64_combiner.gdshaderinc\"\nvoid fragment() {\n\tvec4 t = vec4(UV.x, UV.y, 1.0 - UV.x, 1.0);\n\tvec4 c = %s;\n\tALBEDO = c.rgb;\n}\n" % modes[i]
		var m := ShaderMaterial.new()
		m.shader = sh
		var mi := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(0.9, 0.9)
		mi.mesh = q
		mi.material_override = m
		mi.position = Vector3(-1.5 + i, 0, 0)
		add_child(mi)
	for k in 5:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(OS.get_environment("OUT"))
	get_tree().quit()
