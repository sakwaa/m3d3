extends SceneTree
## Counts base_lod_mode values on the ShaderMaterials inside a baked level resource.
func _init() -> void:
	var r := ResourceLoader.load(OS.get_environment("RES"), "", ResourceLoader.CACHE_MODE_IGNORE)
	var seen := {}
	var counts := {}
	_walk(r, seen, counts, 0)
	print("lod modes: ", counts)
	quit()

func _walk(o: Variant, seen: Dictionary, counts: Dictionary, depth: int) -> void:
	if depth > 12:
		return
	if o is Object:
		if seen.has(o.get_instance_id()):
			return
		seen[o.get_instance_id()] = true
		if o is ShaderMaterial:
			var m := o as ShaderMaterial
			var lm = m.get_shader_parameter(&"base_lod_mode")
			var bt = m.get_shader_parameter(&"base_tex")
			var key := "%s %s" % [lm, (bt as Resource).resource_path.get_file() if bt is Resource and bt.resource_path != "" else str(bt).left(30)]
			counts[key] = int(counts.get(key, 0)) + 1
		for p in o.get_property_list():
			if p.usage & PROPERTY_USAGE_STORAGE:
				var v = o.get(p.name)
				if v is Object or v is Array or v is Dictionary:
					_walk(v, seen, counts, depth + 1)
	elif o is Array:
		for v in o:
			_walk(v, seen, counts, depth + 1)
	elif o is Dictionary:
		for k in o:
			_walk(o[k], seen, counts, depth + 1)
