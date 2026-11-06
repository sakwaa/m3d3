class_name CollisionView
extends MeshInstance3D
## Debug overlay (DebugHud F9): every level collision face, coloured by its Surface
## (Surface.color: a colour per footstep sound, red damage, black void-out, cyan slippery,
## fainter no-camera), drawn over the level, with a legend of the surfaces present (and how
## many triangles each). Rebuilt when the collision changes (zones load).

const CHECK_INTERVAL := 1.0

var _check_t := 0.0
var _signature := 0
var _legend: RichTextLabel


func _ready() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.render_priority = 10
	mat.disable_fog = true
	material_override = mat
	var layer := CanvasLayer.new()
	layer.layer = 91
	add_child(layer)
	_legend = RichTextLabel.new()
	_legend.bbcode_enabled = true
	_legend.fit_content = true
	_legend.scroll_active = false
	_legend.autowrap_mode = TextServer.AUTOWRAP_OFF
	_legend.custom_minimum_size = Vector2(260, 0)
	_legend.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_legend.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_legend.position = Vector2(12, -12)
	_legend.add_theme_color_override(&"font_outline_color", Color.BLACK)
	_legend.add_theme_constant_override(&"outline_size", 4)
	layer.add_child(_legend)
	_rebuild()


func _process(delta: float) -> void:
	_check_t += delta
	if _check_t >= CHECK_INTERVAL:
		_check_t = 0.0
		if _shapes_signature() != _signature:
			_rebuild()


func _shapes() -> Array:
	return get_tree().root.find_children("*", "CollisionShape3D", true, false).filter(
		func(cs): return cs.shape is ConcavePolygonShape3D and cs.is_inside_tree() and not cs.disabled)


func _shapes_signature() -> int:
	return hash(_shapes().map(func(cs): return cs.get_instance_id()))


func _rebuild() -> void:
	_signature = _shapes_signature()
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var lines := PackedVector3Array()
	var tris := {}  # surface -> triangles
	for cs: CollisionShape3D in _shapes():
		var s: int = cs.get_meta(Surface.META, 0)
		var c := Surface.color(s)
		var xf := cs.global_transform
		var faces := (cs.shape as ConcavePolygonShape3D).get_faces()
		tris[s] = tris.get(s, 0) + faces.size() / 3
		for i in range(0, faces.size() - 2, 3):
			var a := xf * faces[i]
			var b := xf * faces[i + 1]
			var d := xf * faces[i + 2]
			# Lifted along the face normal so it doesn't z-fight with the level.
			var lift := (b - a).cross(d - a).normalized() * -0.015
			for p in [a, b, d]:
				verts.append(p + lift)
				cols.append(c)
			lines.append_array([a + lift, b + lift, b + lift, d + lift, d + lift, a + lift])
	var mesh := ArrayMesh.new()
	if not verts.is_empty():
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_COLOR] = cols
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var line_arrays := []
		line_arrays.resize(Mesh.ARRAY_MAX)
		line_arrays[Mesh.ARRAY_VERTEX] = lines
		var lc := PackedColorArray()
		lc.resize(lines.size())
		lc.fill(Color(0, 0, 0, 0.12))
		line_arrays[Mesh.ARRAY_COLOR] = lc
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, line_arrays)
	self.mesh = mesh
	var text := "[b]Collision surfaces[/b] (F9)"
	var keys := tris.keys()
	keys.sort()
	for s in keys:
		text += "\n[color=#%s]■[/color] %s  [color=#aaaaaa]%d tris[/color]" % [Surface.color(s).to_html(false), Surface.describe(s), tris[s]]
	_legend.text = text
