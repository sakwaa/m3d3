extends "res://tests/vines/vine_doorway.gd"
## Vines baked to textures (the doorway scene): the 3D vines rendered straight-on into a
## texture per surface they cover (the wall's front - its hanging strands with it - back and
## top, the ground), their shadow on the surface baked in under them (offset away from the
## sun, softened, translucent), then shown as one flat panel per surface instead of the 3D.
## Prints triangles (one quad a panel; and as N64 64 x 64 texture tiles) and texture memory;
## OUT=dir saves front / walk / oblique for the 3D vines and each bake density.
##   TPM=32,64 (texels a metre) godot --path . --resolution 1280x720 tests/vines/vine_bake.tscn

const VINE_LAYER := 1 << 19
const SUN := Vector3(-0.45, 0.8, 0.4)  # (VineBuilder.SUN: the light the vines are lit by)

## Surfaces: [name, middle, right, up, normal, size (m), in front (m), behind (m), height off surface for shadows (m)]
var surfaces := [
	["front", Vector3(0, 2.16, 0.25), Vector3.RIGHT, Vector3.UP, Vector3.BACK, Vector2(10.6, 4.1), 0.9, 0.05, 0.1],
	["back", Vector3(0, 2.16, -0.25), Vector3.LEFT, Vector3.UP, Vector3.FORWARD, Vector2(10.6, 4.1), 0.9, 0.05, 0.1],
	["top", Vector3(0, 4.0, 0), Vector3.RIGHT, Vector3.FORWARD, Vector3.UP, Vector2(10.6, 1.2), 0.5, 0.05, 0.08],
	["ground", Vector3(0, 0.0, 2.0), Vector3.RIGHT, Vector3.FORWARD, Vector3.UP, Vector2(14.0, 10.0), 0.12, 0.05, 0.06],
]
var panels: Array[Node3D] = []


func _run() -> void:
	for i in 6:
		await get_tree().process_frame
	var tris := 0
	for v in patches:
		v.regrow()
		tris += v.triangle_count()
		for c in v.get_children(true):
			if c is MeshInstance3D:
				(c as MeshInstance3D).layers = VINE_LAYER | 1
	print("BAKE 3D vines: %d tris" % tris)
	var shots := [["front", Vector3(0, 1.7, 7.5), Vector3(0, 2.0, 0)], ["walk", Vector3(0.4, 1.6, 3.0), Vector3(0, 1.7, -3)],
		["oblique", Vector3(5.0, 1.8, 5.0), Vector3(0, 1.9, 0)]]
	for s in shots:
		await _shot("3d_" + s[0], s[1], s[2])
	var tpms: Array = Array(OS.get_environment("TPM").split(",")).map(func(x): return int(x)) if OS.get_environment("TPM") != "" else [32, 64]
	for tpm in tpms:
		for p in panels:
			p.queue_free()
		panels.clear()
		for v in patches:
			v.visible = true
		await get_tree().process_frame
		var quads := 0
		var tiles := 0
		var kb := 0.0
		for sf in surfaces:
			var img := await _bake(sf, tpm)
			_panel(sf, img)
			quads += 1
			tiles += ceili(img.get_width() / 64.0) * ceili(img.get_height() / 64.0)
			kb += img.get_width() * img.get_height() * 0.5 / 1024.0  # (CI4)
			if out != "":
				img.save_png(out + "/tex%d_%s.png" % [tpm, sf[0]])
		for v in patches:
			v.visible = false
		print("BAKE %d texels/m: %d panels = %d tris (as N64 64x64 tiles: %d tiles = %d tris), %.0f KB at CI4" % [tpm, quads, quads * 2, tiles, tiles * 2, kb])
		for s in shots:
			await _shot("bake%d_%s" % [tpm, s[0]], s[1], s[2])
	get_tree().quit()


## Renders the vines in front of a surface straight-on (orthographic, vines only, clear
## background) and composites their baked shadow under them.
func _bake(sf: Array, tpm: int) -> Image:
	var mid: Vector3 = sf[1]
	var right: Vector3 = sf[2]
	var up: Vector3 = sf[3]
	var n: Vector3 = sf[4]
	var size: Vector2 = sf[5]
	var front: float = sf[6]
	var behind: float = sf[7]
	var px := Vector2i(int(size.x * tpm), int(size.y * tpm))
	var vp := SubViewport.new()
	vp.size = px * 2  # (rendered at twice, then halved: the texels average their samples)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_DISABLED
	add_child(vp)
	var c := Camera3D.new()
	c.projection = Camera3D.PROJECTION_ORTHOGONAL
	c.keep_aspect = Camera3D.KEEP_HEIGHT
	c.size = size.y
	c.near = 0.001
	c.far = front + behind
	c.cull_mask = VINE_LAYER
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	c.environment = env
	vp.add_child(c)
	c.global_transform = Transform3D(Basis(right, up, n), mid + n * front)
	c.current = true
	for i in 4:
		await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	# Where the surface itself is (a thin slice round it, the vines hidden): shadows only
	# fall there (not across a doorway).
	for v in patches:
		v.visible = false
	c.cull_mask = 0xFFFFF & ~VINE_LAYER
	c.global_transform = Transform3D(Basis(right, up, n), mid + n * 0.04)
	c.far = 0.08
	for i in 4:
		await RenderingServer.frame_post_draw
	var surf_img := vp.get_texture().get_image()
	for v in patches:
		v.visible = true
	vp.queue_free()
	surf_img.convert(Image.FORMAT_RGBA8)
	surf_img.resize(px.x, px.y, Image.INTERPOLATE_BILINEAR)
	var surf := surf_img.get_data()
	img.convert(Image.FORMAT_RGBA8)
	img.resize(px.x, px.y, Image.INTERPOLATE_BILINEAR)
	var w := px.x
	var hgt := px.y
	var data := img.get_data()
	# 1-bit alpha (cut-out, like the vines' own leaves); the outline as a mask.
	var mask := PackedByteArray()
	mask.resize(w * hgt)
	for i in w * hgt:
		var on := data[i * 4 + 3] > 127
		data[i * 4 + 3] = 255 if on else 0
		mask[i] = 255 if on else 0
	# The shadow: the outline moved away from the sun (as far as something this high off
	# the surface throws it), softened, dark and see-through, under the vines.
	var l := SUN.normalized()
	var h: float = sf[8]
	var off := -Vector2(l.dot(right), -l.dot(up)) / maxf(l.dot(n), 0.25) * h * tpm
	var m_img := Image.create_from_data(w, hgt, false, Image.FORMAT_L8, mask)
	var sh := Image.create(w, hgt, false, Image.FORMAT_L8)
	sh.blit_rect(m_img, Rect2i(0, 0, w, hgt), Vector2i(roundi(off.x), roundi(off.y)))
	sh.resize(maxi(w / 3, 1), maxi(hgt / 3, 1), Image.INTERPOLATE_BILINEAR)
	sh.resize(w, hgt, Image.INTERPOLATE_BILINEAR)
	var sd := sh.get_data()
	for i in w * hgt:
		if data[i * 4 + 3] == 0:
			data[i * 4] = 15
			data[i * 4 + 1] = 18
			data[i * 4 + 2] = 10
			data[i * 4 + 3] = int(sd[i] * 0.55) if surf[i * 4 + 3] > 127 else 0
	return Image.create_from_data(w, hgt, false, Image.FORMAT_RGBA8, data)


## The baked texture on a quad just off the surface (translucent: the shadow darkens it).
func _panel(sf: Array, img: Image) -> void:
	var mid: Vector3 = sf[1]
	var n: Vector3 = sf[4]
	var size: Vector2 = sf[5]
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = size
	mi.mesh = q
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	m.albedo_texture = ImageTexture.create_from_image(img)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	# (QuadMesh faces +Z with +Y up: turned onto the surface)
	mi.global_transform = Transform3D(Basis(sf[2], sf[3], n), mid + n * 0.012)
	panels.append(mi)
