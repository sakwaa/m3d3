extends Node3D
## The mesh builder's editing view over the model: every piece's wireframe, the selected
## piece's edges, the selection (faces filled, edges / vertices highlighted), vertex dots
## (Blender-style, fixed size on screen), the loop-cut preview and an ortho grid.
## Important lines are screen-space strips (thick enough for a phone; GL lines are 1 px).

const DOT_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_never%s;
uniform float size_px = 22.0;
uniform vec3 rim : source_color = vec3(0.92);
void vertex() {
	vec4 view = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	view.xyz -= normalize(view.xyz) * 0.01;
	vec4 clip = PROJECTION_MATRIX * view;
	clip.xy += (UV * 2.0 - 1.0) * size_px / VIEWPORT_SIZE * clip.w;
	POSITION = clip;
}
void fragment() {
	float r = length(UV * 2.0 - 1.0);
	if (r > 1.0) { discard; }
	ALBEDO = r > 0.66 ? rim : COLOR.rgb;
}
"""

## Segments as quads widened in screen space: VERTEX = this end, CUSTOM0 = the other end,
## UV.x = side (-1 / 1).
const LINE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_never%s;
uniform float width_px = 4.0;
void vertex() {
	vec4 a = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0) + vec4(0.0, 0.0, 0.008, 0.0));
	vec4 b = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(CUSTOM0.xyz, 1.0) + vec4(0.0, 0.0, 0.008, 0.0));
	vec2 sa = a.xy / a.w * VIEWPORT_SIZE;
	vec2 sb = b.xy / b.w * VIEWPORT_SIZE;
	vec2 d = normalize(sb - sa + vec2(1e-5));
	vec2 n = vec2(-d.y, d.x);
	a.xy += n * UV.x * width_px / VIEWPORT_SIZE * a.w;
	POSITION = a;
}
void fragment() {
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a;
}
"""

const WIRE := Color(0.08, 0.08, 0.1)
const WIRE_SEE := Color(0.85, 0.85, 0.9, 0.5)
const PIECE := Color(1, 1, 1)
const SELECT := Color(1.0, 0.55, 0.05)
const CUT := Color(1.0, 0.85, 0.15)
const PINNED := Color(0.2, 0.9, 1.0)
const DOT := Color(0.02, 0.02, 0.02)
## Vertices of pieces other than the selected one (Vertex mode shows them all).
const DOT_OTHER := Color(0.42, 0.43, 0.46)

var _wire := MeshInstance3D.new()
var _lines := MeshInstance3D.new()
var _lines_top := MeshInstance3D.new()
var _fill := MeshInstance3D.new()
var _dots := MeshInstance3D.new()
var _cut := MeshInstance3D.new()
var _grid := MeshInstance3D.new()
var _wire_mat := StandardMaterial3D.new()
var _wire_top_mat := StandardMaterial3D.new()
var _line_mat: ShaderMaterial
var _line_top_mat: ShaderMaterial
var _dot_mat: ShaderMaterial
var _dot_top_mat: ShaderMaterial
var _fill_mat := StandardMaterial3D.new()
var _grid_mat := StandardMaterial3D.new()


func _ready() -> void:
	for m in [_wire_mat, _wire_top_mat, _fill_mat, _grid_mat]:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.vertex_color_use_as_albedo = true
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_wire_top_mat.no_depth_test = true
	_wire_top_mat.render_priority = 5
	_fill_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_fill_mat.render_priority = 4
	_fill_mat.no_depth_test = true
	_grid_mat.render_priority = -1
	_line_mat = _shader_mat(LINE_SHADER % "", 6)
	_line_top_mat = _shader_mat(LINE_SHADER % ", depth_test_disabled", 7)
	_dot_mat = _shader_mat(DOT_SHADER % "", 10)
	_dot_top_mat = _shader_mat(DOT_SHADER % ", depth_test_disabled", 10)
	var s := _ui_scale()
	_line_mat.set_shader_parameter(&"width_px", 3.0 * s)
	_line_top_mat.set_shader_parameter(&"width_px", 3.0 * s)
	_dot_mat.set_shader_parameter(&"size_px", 16.0 * s)
	_dot_top_mat.set_shader_parameter(&"size_px", 16.0 * s)
	for mi in [_grid, _wire, _fill, _lines, _lines_top, _cut, _dots]:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)


## Pixels of the window per design pixel (phones: ~3).
func _ui_scale() -> float:
	return maxf(DisplayServer.screen_get_scale(), 1.0)


func _shader_mat(code: String, priority: int) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = code
	var m := ShaderMaterial.new()
	m.shader = sh
	m.render_priority = priority
	return m


## Redraws for the model's geometry and selection. `mirrored`: the selection is on the
## right-side mirrored copy of the selected piece.
func refresh(model: ActorModel, mirrored: bool) -> void:
	if model == null or model.data == null:
		return
	var see := model.sees_through()
	# Every piece's wireframe.
	var wire := PackedVector3Array()
	for entry in ActorMannequin.expanded(model, model.data.pieces):
		var ep: ActorPiece = entry[0]
		var xf := model.piece_transform(ep)
		for poly in ep.faces():
			for k in poly.size():
				wire.append_array([xf * ep.vertices[poly[k]], xf * ep.vertices[poly[(k + 1) % poly.size()]]])
	_wire.mesh = _line_mesh(wire, WIRE_SEE if see else WIRE)
	_wire.material_override = _wire_top_mat if see else _wire_mat
	_refresh_dots(model, mirrored, see)
	var p := _shown_piece(model, mirrored)
	if p == null:
		for mi in [_lines, _lines_top, _fill]:
			mi.mesh = null
		return
	var xf := model.piece_transform(p)
	var f := p.faces()
	var edges := PackedVector3Array()
	var sel_edges := PackedVector3Array()
	var tris := PackedVector3Array()
	for fi in f.size():
		var poly := f[fi]
		var picked := model.select_mode == ActorModel.Select.FACE and model.sel_faces.has(fi)
		for k in poly.size():
			var a := xf * p.vertices[poly[k]]
			var b := xf * p.vertices[poly[(k + 1) % poly.size()]]
			edges.append_array([a, b])
			if picked:
				sel_edges.append_array([a, b])
		if picked:
			for k in range(1, poly.size() - 1):
				tris.append_array([xf * p.vertices[poly[0]], xf * p.vertices[poly[k]], xf * p.vertices[poly[k + 1]]])
	if model.select_mode == ActorModel.Select.EDGE:
		for e in model.sel_edges:
			sel_edges.append_array([xf * p.vertices[e.x], xf * p.vertices[e.y]])
	_lines.mesh = _strip_mesh(edges, PIECE)
	_lines.material_override = _line_top_mat if see else _line_mat
	_lines_top.mesh = _strip_mesh(sel_edges, SELECT)
	_lines_top.material_override = _line_top_mat
	_fill.mesh = _tri_mesh(tris, Color(SELECT, 0.3))
	_fill.material_override = _fill_mat



## Vertex mode: dots on every piece's vertices (grey), the selected piece's dark with
## its selection orange, so any vertex can be seen and tapped without picking a piece.
func _refresh_dots(model: ActorModel, mirrored: bool, see: bool) -> void:
	if model.select_mode != ActorModel.Select.VERTEX:
		_dots.mesh = null
		return
	var pts := PackedVector3Array()
	var cols := PackedColorArray()
	for entry in ActorMannequin.expanded(model, model.data.pieces):
		var ep: ActorPiece = entry[0]
		var xf := model.piece_transform(ep)
		var chosen: bool = entry[1] == model.sel_piece and entry[2] == mirrored
		for v in ep.vertices.size():
			pts.append(xf * ep.vertices[v])
			if not chosen:
				cols.append(DOT_OTHER)
			else:
				cols.append(SELECT if model.sel_verts.has(v) else (PINNED if ep.pins.has(v) else DOT))
	_dots.mesh = _dot_mesh(pts, cols) if not pts.is_empty() else null
	_dots.material_override = _dot_top_mat if see else _dot_mat


## The selected piece as drawn on the side it was picked (the source, or its mirror copy).
func _shown_piece(model: ActorModel, mirrored: bool) -> ActorPiece:
	if model.sel_piece < 0:
		return null
	for entry in ActorMannequin.expanded(model, model.data.pieces):
		if entry[1] == model.sel_piece and entry[2] == mirrored:
			return entry[0]
	return model.selected_piece()


## Loop-cut preview: points (model space) of the cut line; `closed` joins the ends.
func show_cut(points: PackedVector3Array, closed: bool) -> void:
	var seg := PackedVector3Array()
	for i in points.size() - (0 if closed else 1):
		seg.append_array([points[i], points[(i + 1) % points.size()]])
	_cut.mesh = _strip_mesh(seg, CUT)
	_cut.material_override = _line_top_mat


func clear_cut() -> void:
	_cut.mesh = null


## A grid in the view plane near `centre` (ortho views), every `step` metres, lines on
## multiples of `step` (where snapped vertices land); bold every `major`, brighter on
## whole metres, brightest through the origin.
func show_grid(camera: Camera3D, centre: Vector3, step: float, major: float, extent: float) -> void:
	var right := camera.global_basis.x
	var up := camera.global_basis.y
	var n := mini(int(extent / step) + 1, 60)
	# Line indices relative to the origin, so lines sit on snap positions.
	var ci := roundi(centre.dot(right) / step)
	var cj := roundi(centre.dot(up) / step)
	var base := centre - right * (centre.dot(right) - ci * step) - up * (centre.dot(up) - cj * step)
	var lines := PackedVector3Array()
	var cols := PackedColorArray()
	for k in range(-n, n + 1):
		for spec in [[right, up, ci + k], [up, right, cj + k]]:
			var along: Vector3 = spec[0]
			var across: Vector3 = spec[1]
			var idx: int = spec[2]
			var at_len := idx * step
			var bold := absf(at_len / major - roundf(at_len / major)) < 1e-3
			var metre := absf(at_len - roundf(at_len)) < 1e-4
			var c := Color(1, 1, 1, 0.3 if idx == 0 else (0.2 if metre and bold else (0.13 if bold else 0.05)))
			var at := base + along * k * step
			lines.append_array([at - across * n * step, at + across * n * step])
			cols.append_array([c, c])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = lines
	arrays[Mesh.ARRAY_COLOR] = cols
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	_grid.mesh = m
	_grid.material_override = _grid_mat


func hide_grid() -> void:
	_grid.mesh = null


# --- Mesh builders -------------------------------------------------------------------------

func _line_mesh(seg: PackedVector3Array, color: Color) -> ArrayMesh:
	if seg.is_empty():
		return null
	var cols := PackedColorArray()
	cols.resize(seg.size())
	cols.fill(color)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = seg
	arrays[Mesh.ARRAY_COLOR] = cols
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return m


## Segment pairs -> screen-width strips (see LINE_SHADER).
func _strip_mesh(seg: PackedVector3Array, color: Color) -> ArrayMesh:
	if seg.size() < 2:
		return null
	var verts := PackedVector3Array()
	var other := PackedFloat32Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	for i in range(0, seg.size() - 1, 2):
		var a := seg[i]
		var b := seg[i + 1]
		var base := verts.size()
		# a-left, a-right, b-right, b-left (b's side flips: its "other end" is a).
		for spec in [[a, b, -1.0], [a, b, 1.0], [b, a, -1.0], [b, a, 1.0]]:
			verts.append(spec[0])
			var o: Vector3 = spec[1]
			other.append_array([o.x, o.y, o.z, 0.0])
			uvs.append(Vector2(spec[2], 0))
			cols.append(color)
		idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_CUSTOM0] = other
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
		Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	m.custom_aabb = AABB(Vector3.ONE * -50.0, Vector3.ONE * 100.0)
	return m


func _tri_mesh(tris: PackedVector3Array, color: Color) -> ArrayMesh:
	if tris.is_empty():
		return null
	var cols := PackedColorArray()
	cols.resize(tris.size())
	cols.fill(color)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = tris
	arrays[Mesh.ARRAY_COLOR] = cols
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


func _dot_mesh(pts: PackedVector3Array, cols: PackedColorArray) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var idx := PackedInt32Array()
	for i in pts.size():
		var base := verts.size()
		for uv in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]:
			verts.append(pts[i])
			uvs.append(uv)
			colors.append(cols[i])
		idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	m.custom_aabb = AABB(Vector3.ONE * -50.0, Vector3.ONE * 100.0)
	return m
