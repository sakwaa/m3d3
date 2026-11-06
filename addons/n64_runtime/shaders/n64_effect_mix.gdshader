shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
// Alpha-blended effect sprites (dust, smoke, splashes). Code: n64_effect.gdshaderinc.
#include "res://addons/n64_runtime/shaders/n64_effect.gdshaderinc"

void fragment() {
	vec4 c = effect_color(UV, COLOR);
	ALBEDO = c.rgb;
	ALPHA = c.a;
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
}
