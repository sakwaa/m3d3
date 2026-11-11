shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
// Alpha-blended effect sprites (dust, smoke, splashes), lit like the level. Code:
// n64_effect.gdshaderinc.
#include "res://addons/n64_runtime/shaders/n64_effect.gdshaderinc"

void fragment() {
	vec4 c = effect_color(UV, COLOR);
	ALBEDO = c.rgb * effect_light;
	ALPHA = c.a;
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
}
