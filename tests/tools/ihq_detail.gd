extends Node
## IHQ detail (N64Texture lod_mode 4), libdragon's trick (mksprite --format IHQ): the texture
## as it is becomes the colour layer, and a fitted intensity layer (I4: 16 greys) at twice its
## resolution carries the fine shading. For each texture the source is converted again at 2x
## with the same settings (the "full-resolution picture"), the texture is scaled up to it
## (bilinear, as the RDP filters), and for each factor f in 0.05..0.5 every texel gets the
## grey I that brings base x (1 - f) + I x f nearest the picture in YUV; the f with the least
## error wins. (Adding a grey moves only Y, so the best I is solved directly, not searched.)
## Saves textures/detail/ihq/<name>_ihq.res; APPLY=1 also sets lod_mode 4 on the texture.
## KEEP=1: the colour-keeping variant (lod_mode 5): base + (I - luma(base)) x f - the same Y
## fit, but the base's chroma isn't scaled down; saved as <name>_ihqc.res.
## ALL=1: every N64Texture with a source under res://textures (not sky, effects, detail).
##   Godot --headless --path . res://tests/tools/ihq_detail.tscn TEXTURES=res://a.res,... [KEEP=1] [APPLY=1]

const OUT := "res://textures/detail/ihq/"
const RATIO := 2


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var list := Array(OS.get_environment("TEXTURES").split(",", false))
	if OS.get_environment("ALL") != "":
		list = _all()
	var t0 := Time.get_ticks_msec()
	for k in list.size():
		_make(list[k])
		if k % 25 == 0:
			print("IHQ progress %d / %d (%d s)" % [k, list.size(), (Time.get_ticks_msec() - t0) / 1000])
	print("IHQ done: %d made, %d skipped of %d (%d s)" % [_made, list.size() - _made, list.size(), (Time.get_ticks_msec() - t0) / 1000])
	get_tree().quit()


var _made := 0


static func _all() -> Array:
	var out := []
	var stack := ["res://textures"]
	while not stack.is_empty():
		var dir: String = stack.pop_back()
		for sub in DirAccess.get_directories_at(dir):
			if sub.begins_with("_") or (dir == "res://textures" and sub in ["sky", "effects", "detail"]):
				continue
			stack.append(dir + "/" + sub)
		for f in DirAccess.get_files_at(dir):
			if f.ends_with(".res"):
				out.append(dir + "/" + f)
	out.sort()
	return out


func _make(path: String) -> void:
	var t := load(path) as N64Texture
	if t == null:
		print("skip (not an N64Texture): ", path)
		return
	if t.category == &"detail":
		return
	var src := Image.load_from_file(t.source_path) if t.source_path != "" else null
	if src == null:
		print("skip (no source image): ", path.get_file())
		return
	var s := t.get_settings()
	var size: Vector2i = s.size
	var full := size * RATIO
	if full.x > src.get_width() / maxf(t.zoom, 1.0) or full.y > src.get_height() / maxf(t.zoom, 1.0):
		print("skip (source smaller than %s): %s" % [full, path.get_file()])
		return
	# The full-resolution picture: the same conversion and grade at 2x, smooth colour.
	s.size = full
	s.no_budget = true
	s.format = N64TextureConverter.Format.RGBA16
	var target: Image = N64TextureConverter.convert(src, s).image
	target = target.duplicate()
	target.clear_mipmaps()
	target.convert(Image.FORMAT_RGBA8)
	# The colour layer: the texture's own top level, scaled up as the RDP would filter it.
	var base := t.get_image().duplicate() as Image
	if base.is_compressed():
		base.decompress()
	base.clear_mipmaps()
	base.convert(Image.FORMAT_RGBA8)
	var up := base.duplicate() as Image
	up.resize(full.x, full.y, Image.INTERPOLATE_BILINEAR)
	var keep := OS.get_environment("KEEP") != ""
	var fit := fit_ihq(target, up, keep)
	var layer := Image.create_from_data(full.x, full.y, false, Image.FORMAT_L8, fit.i)
	layer.generate_mipmaps()
	var tex := ImageTexture.create_from_image(layer)
	var out := OUT + path.get_file().get_basename() + ("_ihqc.res" if keep else "_ihq.res")
	_save(tex, out)
	# What it buys: RMS error (0..255) against the full-res picture, plain base vs IHQ.
	print(("KEEP " if keep else "") + "%-28s %s colour + %s I4, f %.2f   rms plain %.2f -> ihq %.2f   (%d B vs RGBA16 copy %d B)" % [
		path.get_file(), size, full, fit.f, fit.plain_rms * 255.0, fit.rms * 255.0,
		full.x * full.y / 2, full.x * full.y * 2])
	_made += 1
	if OS.get_environment("APPLY") != "":
		t.lod_mode = 5 if keep else 4
		t.detail_texture = load(out)
		t.detail_repeats = 1.0
		t.detail_strength = fit.f
		_save(t, path)


## The fit (display values 0..1): {i: L8 bytes (16 levels), f, rms (combined, RGB), plain_rms}.
static func fit_ihq(target: Image, up: Image, keep := false) -> Dictionary:
	var td := target.get_data()
	var bd := up.get_data()
	var n := target.get_width() * target.get_height()
	var y0 := PackedFloat32Array(); y0.resize(n)
	var yb := PackedFloat32Array(); yb.resize(n)
	var cu := PackedFloat32Array(); cu.resize(n)  # (target chroma, base chroma: U, V)
	var cv := PackedFloat32Array(); cv.resize(n)
	var bu := PackedFloat32Array(); bu.resize(n)
	var bv := PackedFloat32Array(); bv.resize(n)
	var plain := 0.0
	for k in n:
		var r0 := td[k * 4] / 255.0
		var g0 := td[k * 4 + 1] / 255.0
		var b0 := td[k * 4 + 2] / 255.0
		var r := bd[k * 4] / 255.0
		var g := bd[k * 4 + 1] / 255.0
		var b := bd[k * 4 + 2] / 255.0
		y0[k] = 0.299 * r0 + 0.587 * g0 + 0.114 * b0
		cu[k] = -0.14713 * r0 - 0.28886 * g0 + 0.436 * b0
		cv[k] = 0.615 * r0 - 0.51499 * g0 - 0.10001 * b0
		yb[k] = 0.299 * r + 0.587 * g + 0.114 * b
		bu[k] = -0.14713 * r - 0.28886 * g + 0.436 * b
		bv[k] = 0.615 * r - 0.51499 * g - 0.10001 * b
		plain += ((r - r0) * (r - r0) + (g - g0) * (g - g0) + (b - b0) * (b - b0)) / 3.0
	var best := {f = 0.0, err = INF}
	var i_best := PackedByteArray()
	for step in range(1, 11):
		var f := 0.05 * step
		var err := 0.0
		var ib := PackedByteArray(); ib.resize(n)
		for k in n:
			# (I adds the same to R, G, B: only Y moves; U and V just scale by 1 - f - or,
			# keeping colour, stay the base's)
			var cs := 1.0 if keep else 1.0 - f
			var q := roundf(clampf((y0[k] - cs * yb[k]) / f + (yb[k] if keep else 0.0), 0.0, 1.0) * 15.0) / 15.0
			var dy := (q - (yb[k] if keep else 0.0)) * f + cs * yb[k] - y0[k]
			var du := cs * bu[k] - cu[k]
			var dv := cs * bv[k] - cv[k]
			err += dy * dy + du * du + dv * dv
			ib[k] = int(q * 255.0 + 0.5)
		if err < best.err:
			best = {f = f, err = err}
			i_best = ib
	# The combined result's RGB error, comparable with the plain base's.
	var rms := 0.0
	for k in n:
		var q := i_best[k] / 255.0
		var ybk := yb[k]
		for c in 3:
			var bc: float = bd[k * 4 + c] / 255.0
			var v: float = clampf(bc + (q - ybk) * best.f, 0.0, 1.0) if keep else bc * (1.0 - best.f) + q * best.f
			var d: float = v - td[k * 4 + c] / 255.0
			rms += d * d / 3.0
	return {i = i_best, f = best.f, rms = sqrt(rms / n), plain_rms = sqrt(plain / n)}


func _save(r: Resource, path: String) -> void:
	var uid := ResourceLoader.get_resource_uid(path) if ResourceLoader.exists(path) else ResourceUID.INVALID_ID
	var err := ResourceSaver.save(r, path)
	if uid != ResourceUID.INVALID_ID:
		ResourceSaver.set_uid(path, uid)
	r.take_over_path(path)
	if err != OK:
		print("save failed ", path, " ", error_string(err))
