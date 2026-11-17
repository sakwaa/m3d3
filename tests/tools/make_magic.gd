extends SceneTree
## Writes the starter magic materials (n64_magic.gdshader, OoT / MM's shared magic recipe) to
## game/materials/magic/: fire (Din's-Fire-like), warp (a blue warp beam), ice (an Ice Arrow's
## additive alpha + contrast). Noise textures are generated (NoiseTexture2D, seamless).
##   godot --headless --path . -s tests/tools/make_magic.gd

func _init() -> void:
	var n0 := _noise(0.035, FastNoiseLite.TYPE_PERLIN, 3)
	var n1 := _noise(0.06, FastNoiseLite.TYPE_CELLULAR, 9)
	_save("fire", {texture0 = n0, texture1 = n1, prim = Color(1.0, 0.95, 0.55), env = Color(0.95, 0.15, 0.0), k = 0.7})
	_save("warp", {texture0 = n0, texture1 = n1, prim = Color(0.8, 1.0, 1.0, 0.9), env = Color(0.05, 0.2, 0.9),
		texture0_scroll = Vector2(0.0, 0.5), texture1_scroll = Vector2(0.1, 0.9), k = 0.55})
	_save("ice", {texture0 = n0, texture1 = n1, prim = Color(0.85, 0.95, 1.0, 0.85), env = Color(0.1, 0.35, 0.8),
		recipe = 2, alpha_mode = 2, k = 0.5})
	quit()


func _save(name: String, props: Dictionary) -> void:
	var m := ShaderMaterial.new()
	m.shader = load("res://addons/n64_runtime/shaders/n64_magic.gdshader")
	for k in props:
		m.set_shader_parameter(k, props[k])
	var path := "res://game/materials/magic/%s.tres" % name
	print(path, ": ", ResourceSaver.save(m, path))


func _noise(freq: float, kind: int, seed_: int) -> NoiseTexture2D:
	var n := FastNoiseLite.new()
	n.noise_type = kind
	n.frequency = freq
	n.seed = seed_
	var t := NoiseTexture2D.new()
	t.width = 64
	t.height = 64
	t.seamless = true
	t.noise = n
	return t
