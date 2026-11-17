shader_type canvas_item;
render_mode unshaded, blend_disabled;
// GroundSim's output: the newest field copied into a viewport of its own, so materials can
// bind one texture for good (the simulation itself ping-pongs between two).
uniform sampler2D src : filter_nearest, repeat_disable, hint_default_black;

void fragment() {
	COLOR = texture(src, UV);
}
