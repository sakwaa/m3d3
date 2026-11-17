extends Node3D
## Coverage built-ins check (patched engine): a quad showing SAMPLE_MASK_IN as colour
## (left: popcount / 8 as grey; right: COVERAGE written, alpha read back as grey).
func _ready() -> void:
	get_viewport().msaa_3d = Viewport.MSAA_8X
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 0, 3)
	cam.make_current()
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.0, 0.0, 0.5)
	add_child(env)
	var sh := Shader.new()
	sh.code = "shader_type spatial;\nrender_mode unshaded;\nvoid fragment() {\n#ifdef M3D3_COVERAGE\nALBEDO = vec3(float(bitCount(SAMPLE_MASK_IN)) / 8.0, float(SAMPLE_MASK_IN & 255) / 255.0, 0.0);\n#else\nALBEDO = vec3(1.0, 0.0, 1.0);\n#endif\n}\n"
	var mat := ShaderMaterial.new()
	mat.shader = sh
	var mi := MeshInstance3D.new()
	var pm := PrismMesh.new()
	mi.mesh = pm
	mi.material_override = mat
	mi.rotation.z = 0.3
	add_child(mi)
	for i in 6:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var c := img.get_pixel(img.get_width() / 2, img.get_height() / 2)
	print("[cov] centre pixel ", c, " (r = covered share, g = mask/255)")
	img.save_png(OS.get_environment("OUT"))
	get_tree().quit()
