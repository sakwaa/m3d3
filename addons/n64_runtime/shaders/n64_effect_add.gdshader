shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add;
// Additive effect sprites (sparks, fire, flashes): glow, fading into the fog rather than
// taking its colour. Code: n64_effect.gdshaderinc.
#include "res://addons/n64_runtime/shaders/n64_effect.gdshaderinc"

void fragment() {
	vec4 c = effect_color(UV, COLOR);
	vec4 fog = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
	ALBEDO = c.rgb * c.a * (1.0 - fog.a);
}
