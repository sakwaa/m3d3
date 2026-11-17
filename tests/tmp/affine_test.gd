extends Node3D
## Affine shading check: a 40 m floor of 2 triangles, red near / blue far, seen low. Left
## half: plain (perspective-correct) varying; right: N64_SHADE (noperspective on the patched
## engine). On the patched engine the right half's gradient bends (the N64 look).
func _ready() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 1.5, 2)
	cam.look_at(Vector3(0, 0, -20))
	cam.make_current()
	for side in [-1.0, 1.0]:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var pts := [Vector3(0, 0, 1), Vector3(10 * side, 0, 1), Vector3(10 * side, 0, -40), Vector3(0, 0, -40)]
		var cols := [Color.RED, Color.YELLOW, Color.BLUE, Color.GREEN]
		for i in [0, 1, 2, 0, 2, 3]:
			st.set_color(cols[i])
			st.add_vertex(pts[i])
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		var sh := Shader.new()
		sh.code = "shader_type spatial;\nrender_mode unshaded, cull_disabled;\n#include \"res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc\"\nvarying %s vec4 c;\nvoid vertex() { c = COLOR; }\nvoid fragment() { ALBEDO = c.rgb; }\n" % ("N64_SHADE" if side > 0.0 else "")
		var m := ShaderMaterial.new()
		m.shader = sh
		mi.material_override = m
		add_child(mi)
	for i in 6:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(OS.get_environment("OUT"))
	get_tree().quit()
