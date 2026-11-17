extends Node
func _ready() -> void:
	var variants := {
		"if_defined": "shader_type spatial;\n#if defined(M3D3_COVERAGE) && CURRENT_RENDERER == RENDERER_FORWARD_PLUS\n#define F() ALBEDO = vec3(1.0)\n#else\n#define F()\n#endif\nvoid fragment() { F(); }\n",
		"ifdef": "shader_type spatial;\n#ifdef M3D3_COVERAGE\n#define F() ALBEDO = vec3(1.0)\n#else\n#define F()\n#endif\nvoid fragment() { F(); }\n",
		"empty_obj": "shader_type spatial;\n#define F\nvoid fragment() { F; }\n",
	}
	for k in variants:
		var sh := Shader.new()
		sh.code = variants[k]
		var mat := ShaderMaterial.new()
		mat.shader = sh
		var mi := MeshInstance3D.new()
		mi.mesh = BoxMesh.new()
		mi.material_override = mat
		add_child(mi)
		print("[pp] ", k)
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit()
