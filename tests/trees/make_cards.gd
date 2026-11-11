extends Node
## Renders far cards (the whole tree, side on, transparent background) for the species
## presets without a photo card (the hand-made ones): one per seed in SEEDS (variants a
## tree picks by its seed), into texture_inbox/tree_card_<name>_<n>.png, and their
## width / height into species/cards.json. Then import them (tools/tree_import/
## import_cards.sh does both and the species update). Needs a window (not --headless):
##   godot --path . tests/trees/make_cards.tscn   [SPECIES=a,b] [SEEDS=1,2,3,4]

const DIR := "res://addons/n64_level_tools/trees/species/"
const HEIGHT := 256


func _ready() -> void:
	var names := []
	if OS.get_environment("SPECIES") != "":
		names = Array(OS.get_environment("SPECIES").split(","))
	else:
		for f in DirAccess.get_files_at(DIR):
			if f.ends_with(".tres"):
				names.append(f.get_basename())
	var seeds := [1, 2, 3, 4]
	if OS.get_environment("SEEDS") != "":
		seeds = Array(OS.get_environment("SEEDS").split(",")).map(func(x): return int(x))
	var aspects := {}
	if FileAccess.file_exists(DIR + "cards.json"):
		aspects = JSON.parse_string(FileAccess.get_file_as_string(DIR + "cards.json"))
	for name in names:
		var sp: Resource = load(DIR + name + ".tres")
		if String(sp.get(&"reference")).begins_with("Imported from"):
			continue  # photo species: their card is the photo
		var list := []
		for k in seeds.size():
			var img := await _render(sp, seeds[k])
			img.save_png(ProjectSettings.globalize_path("res://texture_inbox/tree_card_%s_%d.png" % [name, k + 1]))
			list.append(float(img.get_width()) / img.get_height())
			print("card ", name, " seed ", seeds[k], " ", img.get_size())
		aspects[name] = list
	var f := FileAccess.open(DIR + "cards.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(aspects, " "))
	f.close()
	get_tree().quit()


func _render(sp: Resource, seed: int) -> Image:
	var mesh: ArrayMesh = TreeBuilder.build(sp, seed)
	var box := mesh.get_aabb()
	var w := maxf(box.size.x, box.size.z) * 1.04
	var h := box.end.y * 1.02
	var px_w := int(ceil(HEIGHT * w / h))
	var vp := SubViewport.new()
	vp.size = Vector2i(px_w * 4, HEIGHT * 4)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	for i in mesh.get_surface_count():
		# Still air for the shot.
		var m: ShaderMaterial = mesh.surface_get_material(i).duplicate()
		m.set_shader_parameter(&"wind", 0.0)
		mi.set_surface_override_material(i, m)
	vp.add_child(mi)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = h
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.position = Vector3(box.get_center().x, h * 0.5, 60.0)
	cam.far = 200.0
	vp.add_child(cam)
	cam.make_current()
	for i in 4:
		await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	vp.queue_free()
	img.resize(px_w, HEIGHT, Image.INTERPOLATE_BILINEAR)
	# 1-bit alpha (the N64 cut-out).
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			img.set_pixel(x, y, Color(c.r, c.g, c.b, 1.0) if c.a >= 0.5 else Color(0, 0, 0, 0))
	return img
