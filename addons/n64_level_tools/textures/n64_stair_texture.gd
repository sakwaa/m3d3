@tool
class_name N64StairTexture
extends N64Texture
## Painted-on stairs for ramps (OoT / MM style). Paint it as a face's base texture: the
## face renders `base` (e.g. stone bricks) at its normal texel density, overlays (moss)
## apply as on any face of that base, and a greyscale stair template (CC0 set by Emerald
## Eel, res://textures/_source/stairs) shades the result in UVs fitted to the ramp: the
## template spans the slope's width once (side rails on the edges) and repeats down it a
## whole number of times, one step per `step_length` along the slope, so a ramp twice as
## long shows twice the steps and resized ramps keep whole steps. The image of this resource is only a preview (thumbnails); duplicate it and swap
## `base` for another variant.

const TEMPLATE_DIR := "res://textures/_source/stairs"

## Greyscale stair template (any of the pack's sizes).
@export_file("*.png") var template := "":
	set(value):
		template = value
		_auto_rebuild()
## Level texture under the steps (usually the floor / wall texture around them).
@export var base: Texture2D:
	set(value):
		base = value
		_auto_rebuild()
## How strongly the template's light / dark shapes the surface (0 = flat ramp).
@export_range(0.0, 3.0, 0.05) var strength := 1.5:
	set(value):
		strength = value
		_auto_rebuild()
## Contrast kept from the base (1 = all). Busy textures (cobbles, bricks) need it lower so
## the steps read over their own light / dark pattern. Overlays keep theirs.
@export_range(0.0, 1.0, 0.05) var base_detail := 0.5:
	set(value):
		base_detail = value
		_auto_rebuild()
## Steps drawn in one repeat of the template (detected when the template is set).
@export_range(1, 32) var steps_per_repeat := 4:
	set(value):
		steps_per_repeat = value
		emit_changed()
## Metres along the slope per painted step: a 6 m ramp with 0.75 m steps shows 8 steps,
## a 12 m one 16 (counted along the slope, so steeper ramps of the same footprint get a few
## more).
@export_range(0.1, 4.0, 0.05, "suffix:m") var step_length := 0.75:
	set(value):
		step_length = value
		emit_changed()

## Template as a greyscale texture for the shader, its average grey ("no change") and the
## base's average colour (what base_detail fades towards). Set by rebuild().
@export_storage var template_texture: Texture2D
@export_storage var template_neutral := 0.5
@export_storage var base_mean := Color(0.5, 0.5, 0.5)

var _rebuild_queued := false


## Older resources stored `step_height` (metres of rise per step, default 0.25); keep their
## look on a typical 1:3 ramp by carrying it over as three times the slope length.
func _set(property: StringName, value: Variant) -> bool:
	if property == &"step_height":
		step_length = clampf(float(value) * 3.0, 0.1, 4.0)
		return true
	return false


## Slope length covered by one repeat of the template.
func length_per_repeat() -> float:
	return steps_per_repeat * step_length


func _auto_rebuild() -> void:
	if Engine.is_editor_hint() and not _rebuild_queued:
		_rebuild_queued = true
		_apply_edit.call_deferred()


## Rebuilds after inspector edits only: loading sets the same properties, but the stored
## image / template data is already right then.
func _apply_edit() -> void:
	_rebuild_queued = false
	var editor := Engine.get_singleton(&"EditorInterface")
	if editor == null or editor.get_inspector().get_edited_object() != self:
		return
	if template.is_empty() or base == null or resource_path.is_empty():
		return
	if template != source_path:  # new template: count its steps
		steps_per_repeat = detect_steps(template)
	rebuild()


func rebuild() -> Error:
	var tpl := Image.load_from_file(ProjectSettings.globalize_path(template))
	if tpl == null:
		push_error("N64StairTexture: can't load template %s" % template)
		return ERR_FILE_NOT_FOUND
	if base == null or base.get_image() == null:
		push_error("N64StairTexture: set a base texture first.")
		return ERR_UNCONFIGURED
	tpl.convert(Image.FORMAT_RGBA8)
	var src: Image = base.get_image().duplicate()
	if src.is_compressed():
		src.decompress()
	src.clear_mipmaps()
	src.convert(Image.FORMAT_RGBA8)
	var w := tpl.get_width()
	var h := tpl.get_height()
	var grey := Image.create(w, h, false, Image.FORMAT_L8)
	var neutral := 0.0
	for y in h:
		for x in w:
			var v := tpl.get_pixel(x, y).get_luminance()
			grey.set_pixel(x, y, Color(v, v, v))
			neutral += v
	template_neutral = maxf(neutral / (w * h), 0.05)
	grey.generate_mipmaps()
	template_texture = ImageTexture.create_from_image(grey)
	var bw := src.get_width()
	var bh := src.get_height()
	var mean := Color(0, 0, 0)
	for y in bh:
		for x in bw:
			mean += src.get_pixel(x, y)
	base_mean = mean / (bw * bh)
	# Preview (picker thumbnails): what a 1:1 patch looks like.
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var b := base_mean.lerp(src.get_pixel(x % bw, y % bh), base_detail)
			var k := maxf(lerpf(1.0, tpl.get_pixel(x, y).get_luminance() / template_neutral, strength), 0.0)
			out.set_pixel(x, y, Color(b.r * k, b.g * k, b.b * k, 1.0))
	texture_size = Vector2i(w, h)
	format = N64TextureConverter.Format.RGBA16
	anti_tiling = 0
	tint_mode = N64TextureConverter.TintMode.NONE
	source_path = template
	source_aspect = float(w) / h
	set_image(N64TextureLibrary.with_mipmaps(out))
	emit_changed()
	if not resource_path.is_empty() and not resource_path.contains("::"):
		return ResourceSaver.save(self)
	return OK


## Dark step bands down the template's middle column.
static func detect_steps(path: String) -> int:
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	if img == null:
		return 4
	img.convert(Image.FORMAT_RGBA8)
	var x := img.get_width() / 2
	var vals := PackedFloat32Array()
	var mean := 0.0
	var lo := 1.0
	for y in img.get_height():
		var v := img.get_pixel(x, y).get_luminance()
		vals.append(v)
		mean += v
		lo = minf(lo, v)
	mean /= vals.size()
	var threshold := lo + (mean - lo) * 0.5
	var bands := 0
	var inside := vals[vals.size() - 1] < threshold
	for v in vals:
		var dark := v < threshold
		if dark and not inside:
			bands += 1
		inside = dark
	return maxi(bands, 1)


## Fitted frame for a run of coplanar faces (points `pts` in mesh space, normal `n`): u
## spans their width once, v runs down the slope in whole repeats per `per_repeat` metres
## along it. Returns the shader's [stair_u, stair_v]: uv = (dot(vec4(p, 1), u), ...).
static func frame(pts: PackedVector3Array, n: Vector3, per_repeat: float) -> Array[Vector4]:
	var down := Vector3.DOWN - n * n.dot(Vector3.DOWN)
	var flat := down.length_squared() < 1e-4
	if flat:  # floor-like face: steps run along +Z
		down = Vector3.BACK - n * n.dot(Vector3.BACK)
	down = down.normalized()
	var across := n.cross(down).normalized()
	var a := Vector2(INF, -INF)
	var d := Vector2(INF, -INF)
	for p in pts:
		var pa := p.dot(across)
		var pd := p.dot(down)
		a = Vector2(minf(a.x, pa), maxf(a.y, pa))
		d = Vector2(minf(d.x, pd), maxf(d.y, pd))
	var repeats := maxf(1.0, roundf((d.y - d.x) / maxf(per_repeat, 0.01)))
	var su := maxf(a.y - a.x, 0.001)
	var sv := maxf(d.y - d.x, 0.001) / repeats
	return [Vector4(across.x / su, across.y / su, across.z / su, -a.x / su),
		Vector4(down.x / sv, down.y / sv, down.z / sv, -d.x / sv)]
