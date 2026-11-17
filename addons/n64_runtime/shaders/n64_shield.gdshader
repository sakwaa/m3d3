shader_type spatial;
// Energy shields, barriers, magic domes (N64 style): two textures scrolling against each other
// through the colour combiner - their difference (bright lines where the patterns cross,
// shimmering) picks between ENV (dark) and PRIM (bright) colours (G_CC_BLENDPE) - added on
// top of the scene, brighter at the rim (seen edge-on), where it meets other geometry, and in
// a flash when struck (`hit`, 1 -> 0).
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_combiner.gdshaderinc"

uniform sampler2D tex_a : filter_linear_mipmap, repeat_enable, hint_default_white;
uniform sampler2D tex_b : filter_linear_mipmap, repeat_enable, hint_default_white;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec4 prim : source_color = vec4(0.55, 0.9, 1.0, 1.0);
uniform vec4 env : source_color = vec4(0.05, 0.15, 0.45, 1.0);
uniform vec2 scroll_a = vec2(0.06, 0.11);
uniform vec2 scroll_b = vec2(-0.09, 0.05);
uniform vec2 repeats = vec2(4.0, 2.0);
// Interference: 0 average, 1 multiply, 2 difference (lines).
uniform int combine = 2;
uniform float strength = 0.8;
uniform float rim = 1.5;
// Metres over which it glows where it meets geometry.
uniform float contact = 0.3;
uniform float hit = 0.0;

void fragment() {
	vec2 uv = UV * repeats;
	float a = texture(tex_a, uv + scroll_a * n64_time).r;
	float b = texture(tex_b, uv * 1.37 + scroll_b * n64_time).r;
	float v = combine == 1 ? n64_cc_interference(vec4(a), vec4(b)).r * 1.8
		: combine == 2 ? pow(1.0 - abs(a - b), 6.0)
		: (a + b) * 0.5;
	vec3 c = n64_cc_blend_pe(vec4(clamp(v, 0.0, 1.0)), prim, env).rgb;
	float edge = pow(1.0 - abs(dot(normalize(NORMAL), VIEW)), 2.0) * rim;
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 sv = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float gap = length(sv.xyz / sv.w) - length(VERTEX);
	float touch = 1.0 - smoothstep(0.0, contact, gap);
	ALBEDO = c * (v * strength + edge + touch * 1.5) + prim.rgb * hit * 1.5;
}
