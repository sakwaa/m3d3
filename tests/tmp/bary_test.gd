extends Node3D
## Barycentric patch check: a tilted prism; left half shows sample-count coverage, right
## half analytic coverage from BARYCENTRIC (grey = covered share). Prints distinct levels.
func _ready() -> void:
	get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 0, 2.2)
	cam.make_current()
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.0, 0.0, 0.3)
	add_child(env)
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode unshaded;
void fragment() {
#ifdef M3D3_BARYCENTRIC
	vec3 b = BARYCENTRIC;
	vec3 w = max(fwidth(b), vec3(1e-6));
	vec3 e = clamp(b / w + 0.5, 0.0, 1.0);
	float analytic = min(min(e.x, e.y), e.z);
	float counted = float(bitCount(SAMPLE_MASK_IN)) / 4.0;
	ALBEDO = vec3(analytic, b.x + b.y + b.z - 0.5, 0.0);
#else
	ALBEDO = vec3(1.0, 0.0, 1.0);
#endif
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	var mi := MeshInstance3D.new()
	mi.mesh = PrismMesh.new()
	mi.material_override = mat
	mi.rotation.z = 0.17
	add_child(mi)
	for i in 6:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	var levels := {}
	var sums := 0.0
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.r > 0.01 and c.r < 0.99:
				levels[snappedf(c.r, 0.01)] = true
			if c.r > 0.01:
				sums += c.g
				n += 1
	print("[bary] edge pixels with partial coverage: %d distinct levels; barycentric sum (should be 0.5): %.3f" % [levels.size(), sums / max(n, 1)])
	img.save_png(OS.get_environment("OUT"))
	print("[bary] saved; renderer ", RenderingServer.get_current_rendering_method())
	get_tree().quit()
