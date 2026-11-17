extends Node3D
## A rope's far-off stand-in (built by the level beside each rope brush): an n64_wire line along
## the rope that draws only once the rope is thinner than ~2 pixels, where its textured cutout
## ribbon breaks up into beads - so a distant rope reads as one steady thin line (its coverage
## as alpha) instead of shimmering dashes. Nearer, the ribbon shows alone.

const WIRE := preload("res://addons/n64_runtime/shaders/n64_wire.gdshader")

## Curves (this node's space), each a polyline.
var curves: Array[PackedVector3Array] = []
var width := 0.06
var color := Color(0.4, 0.33, 0.24)
var _mat: ShaderMaterial


func _ready() -> void:
	var verts := PackedVector3Array()
	var custom := PackedFloat32Array()
	var idx := PackedInt32Array()
	for curve in curves:
		for k in curve.size():
			var tan := (curve[mini(k + 1, curve.size() - 1)] - curve[maxi(k - 1, 0)]).normalized()
			for side in [-1.0, 1.0]:
				verts.append(curve[k])
				custom.append_array([tan.x, tan.y, tan.z, side])
			if k > 0:
				var base := verts.size() - 4
				idx.append_array([base, base + 1, base + 2, base + 1, base + 3, base + 2])
	if idx.is_empty():
		return
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_CUSTOM0] = custom
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {},
		Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	_mat = ShaderMaterial.new()
	_mat.shader = WIRE
	_mat.set_shader_parameter(&"width", width)
	_mat.set_shader_parameter(&"line_color", color)
	_mat.set_shader_parameter(&"thin_only", true)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 2.0
	add_child(mi, false, INTERNAL_MODE_BACK)


func _process(_delta: float) -> void:
	# (the 3D picture's real line count: the wire's pixel maths needs it, not the window's)
	if _mat:
		var vp := get_viewport()
		_mat.set_shader_parameter(&"render_lines", float(vp.get_visible_rect().size.y) * vp.scaling_3d_scale if vp else 0.0)


## The average colour of a texture (its smallest mip), for a rope's line.
static func average_color(tex: Texture2D) -> Color:
	if tex == null:
		return Color(0.4, 0.33, 0.24)
	var img := tex.get_image()
	if img == null or img.is_empty():
		return Color(0.4, 0.33, 0.24)
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	img.resize(1, 1, Image.INTERPOLATE_BILINEAR)
	return img.get_pixel(0, 0)
