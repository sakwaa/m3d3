shader_type spatial;
// See-through surfaces the RDP's way (G_RM_ZB_XLU_SURF / G_RM_ZB_CLD_SURF): blended over
// what's behind, depth tested but not written, and leaving the coverage of what's behind
// alone (patch 0005 keeps the destination alpha), so edges under glass, smoke and clouds stay
// anti-aliased. Texture x colour (alpha from both), lit by the time of day's light, N64 fog.
// `cloud` (CLD_SURF): softer - no shine, alpha fades towards grazing angles.
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"

global uniform vec4 n64_ambient_light;
uniform sampler2D tex : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
uniform vec4 color : source_color = vec4(0.75, 0.88, 0.95, 0.35);
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 scroll = vec2(0.0);
uniform bool cloud = false;
// Glass: a pale sheen towards grazing angles.
uniform float sheen = 0.4;

varying N64_SHADE vec2 n64_fogv;
varying N64_SHADE vec3 n64_fog_tintv;

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	n64_fogv = n64_fog_vertex(w);
	n64_fog_tintv = n64_fog_tint_vertex(w);
	N64_SNAP_MODEL;
}

void fragment() {
	vec4 t = n64_texture(tex, UV * uv_scale + scroll * n64_time);
	vec4 c = t * color;
	float graze = pow(1.0 - abs(dot(normalize(NORMAL), VIEW)), 2.0);
	vec3 light = n64_ambient_light.rgb * n64_weather_tint.rgb;
	if (cloud) {
		ALBEDO = c.rgb * light;
		ALPHA = c.a * (1.0 - graze * 0.8);
	} else {
		ALBEDO = c.rgb * light + vec3(sheen) * graze * light;
		ALPHA = clamp(c.a + graze * sheen, 0.0, 1.0);
	}
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
}
