shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled, fog_disabled;
// Magic effects the way OoT and MM drew nearly all of theirs - Din's Fire, Farore's Wind,
// Nayru's Love, every arrow, the spin attack, the ocarina songs' effects, warps, Ganondorf's
// magic (references/combiners/REPORT.md, "Din's Fire, arrows, ocarina songs, warps"):
// two greyscale textures scrolling differently over a mesh (a dome, a cylinder, a beam),
//   cycle 1:  colour (T1 - PRIM) * k + T0   - the second texture pushes the first up and
//             down around PRIM (signed detail), so the pattern churns;
//             alpha  T0 - k * (1 - T1)      - the second texture eats holes and wisps into
//             the first (below 0 clamps: gone);
//   cycle 2:  colour mix(ENV, PRIM, COMBINED) - the brightness mapped onto two colours, ENV
//             in the dark parts, PRIM in the bright; alpha x PRIM alpha x vertex alpha (the
//             mesh's edges painted out).
// Translucent, no fog (G_RM_PASS + XLU / CLD surface), no depth write. Animate prim / env /
// k / strength (a tween or AnimationPlayer) as the games keyed theirs per frame.

#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_combiner.gdshaderinc"

uniform sampler2D texture0 : source_color, filter_linear_mipmap, repeat_enable, hint_default_white;
uniform sampler2D texture1 : source_color, filter_linear_mipmap, repeat_enable, hint_default_white;
uniform vec2 texture0_scale = vec2(1.0);
uniform vec2 texture0_scroll = vec2(0.0, -0.6);
uniform vec2 texture1_scale = vec2(1.6, 1.0);
uniform vec2 texture1_scroll = vec2(0.15, -1.1);
// Cycle 1: Signed detail (most magic), Cross-fade mix(T0, T1, k) (Song of Storms), Contrast
// (T0 - PRIM) * k + T0 (the warp crystal, shiny things), T0 alone (the one-cycle ramp:
// explosions, sparks, Navi).
uniform int recipe : hint_enum("Signed detail", "Cross-fade", "Contrast", "T0") = 0;
// Alpha: Erode T0 - k(1 - T1), Cross-fade, Additive k * T1 + T0 (the Ice Arrow), T0.
uniform int alpha_mode : hint_enum("Erode", "Cross-fade", "Additive", "T0") = 0;
// PRIM: the bright colour (and the signed detail's pivot grey, by its brightness); ENV: the
// dark colour. Their alphas: PRIM's scales the whole effect's alpha.
uniform vec4 prim : source_color = vec4(1.0, 0.95, 0.6, 1.0);
uniform vec4 env : source_color = vec4(0.9, 0.15, 0.0, 1.0);
// The games' PRIM_LOD_FRAC / ENV alpha: how hard the second texture works.
uniform float k : hint_range(0.0, 1.0) = 0.6;
// Overall alpha (fade the effect in and out).
uniform float strength : hint_range(0.0, 1.0) = 1.0;
// Textures' alpha from their brightness (intensity textures); off: their own alpha.
uniform bool alpha_from_intensity = true;

varying float n64_va;

void vertex() {
	n64_va = COLOR.a;
}

vec4 intensity_texel(sampler2D t, vec2 uv) {
	vec4 c = n64_texture(t, uv);
	float i = dot(c.rgb, vec3(0.299, 0.587, 0.114));
	return vec4(vec3(i), alpha_from_intensity ? i : c.a);
}

void fragment() {
	float time = n64_time;
	vec4 t0 = intensity_texel(texture0, UV * texture0_scale + texture0_scroll * time);
	vec4 t1 = intensity_texel(texture1, UV * texture1_scale + texture1_scroll * time);
	vec4 pivot = vec4(vec3(dot(prim.rgb, vec3(0.299, 0.587, 0.114))), 1.0);
	// cycle 1 (as n64_cc_base / n64_cc_alpha; the pivot is PRIM's grey)
	vec3 comb = recipe == 0 ? n64_cc_base(9, t0, t1, vec4(1.0), pivot, env, k)
		: recipe == 1 ? n64_cc_base(4, t0, t1, vec4(1.0), pivot, env, k)
		: recipe == 2 ? n64_cc_base(7, t0, t1, vec4(1.0), pivot, env, k)
		: t0.rgb;
	float a = n64_cc_alpha(alpha_mode == 0 ? 6 : alpha_mode == 1 ? 7 : alpha_mode == 2 ? 8 : 0, t0, t1, prim, env, k);
	comb = clamp(comb, 0.0, 1.0);
	a = clamp(a, 0.0, 1.0);
	// cycle 2: the ramp; alpha x PRIM alpha x vertex alpha
	ALBEDO = n64_cc_tint(4, comb, vec4(1.0), prim, env);
	ALPHA = a * prim.a * n64_va * strength;
}
