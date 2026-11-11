class_name WireframeView
extends CanvasLayer
## Debug overlay (DebugHud F10): the game's triangles as wireframe, in real time, to see
## where triangles pile up. The same world drawn a second time in a wireframe viewport
## following the game's camera; its lines tinted and laid over the textured game (OVERLAY),
## or alone over black (LINES). With the frame's triangle and draw-call counts.

enum Mode { OVERLAY, LINES }

const TINT := Color(0.3, 1.0, 0.95, 0.75)
const LINE_SHADER := """
shader_type canvas_item;
uniform vec4 tint : source_color;
void fragment() {
	vec4 c = texture(TEXTURE, UV);
	COLOR = vec4(tint.rgb, c.a > 0.01 ? tint.a : 0.0);
}
"""

var mode := Mode.OVERLAY:
	set(v):
		mode = v
		_apply_mode()

var _vp: SubViewport
var _cam: Camera3D
var _rect: TextureRect
var _back: ColorRect
var _label: Label


func _init() -> void:
	layer = 80  # under the HUD
	name = "WireframeView"


func _ready() -> void:
	_back = ColorRect.new()
	_back.color = Color(0.02, 0.02, 0.04)
	_back.set_anchors_preset(Control.PRESET_FULL_RECT)
	_back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_back)
	_vp = SubViewport.new()
	_vp.transparent_bg = true
	_vp.debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
	_vp.world_3d = get_viewport().world_3d
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	_cam = Camera3D.new()
	_vp.add_child(_cam)
	_rect = TextureRect.new()
	_rect.texture = _vp.get_texture()
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = LINE_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter(&"tint", TINT)
	_rect.material = mat
	add_child(_rect)
	_label = Label.new()
	_label.add_theme_color_override(&"font_outline_color", Color.BLACK)
	_label.add_theme_constant_override(&"outline_size", 4)
	_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_label.position = Vector2(12, -40)
	add_child(_label)
	_apply_mode()


func _apply_mode() -> void:
	if _back:
		_back.visible = mode == Mode.LINES


func _process(_delta: float) -> void:
	var main := get_viewport()
	var size := Vector2i(main.get_visible_rect().size)
	if _vp.size != size:
		_vp.size = size
	var src := main.get_camera_3d()
	if src:
		_cam.global_transform = src.global_transform
		_cam.projection = src.projection
		_cam.fov = src.fov
		_cam.size = src.size
		_cam.near = src.near
		_cam.far = src.far
		_cam.keep_aspect = src.keep_aspect
		_cam.cull_mask = src.cull_mask
		_cam.current = true
	var tris := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	# (Both passes are counted: the game's own frame is about half.)
	_label.text = "Wireframe (%s)  [F10] next / off   ~%d tris, ~%d draws in the game's view" % [
		"over the game" if mode == Mode.OVERLAY else "lines only", tris / 2, draws / 2]
