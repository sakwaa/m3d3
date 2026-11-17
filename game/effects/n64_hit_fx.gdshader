shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
// OotHitFx's look (the games' combiners):
//  mode 0 hit mark: colour mix(ENV, PRIM, texel), alpha PRIM.a x texel, noise-dithered
//    (G_AD_NOISE); `tex` holds 8 frames side by side, `frame` picks one.
//  mode 1 clang streaks: colour mix(ENV, PRIM, texel), alpha PRIM.a x texel.
//  mode 2 blood: the vertex colour, alpha the texel only (G_CC_SHADEDECALA: they fade by
//    darkening).

uniform sampler2D tex : filter_linear, repeat_disable, hint_default_white;
uniform int mode = 0;
uniform int frame = 0;
uniform vec4 prim : source_color = vec4(1.0);
uniform vec4 env : source_color = vec4(1.0);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 uv = UV;
	if (mode == 0) {
		uv.x = (uv.x + float(frame)) / 8.0;
	}
	float t = texture(tex, uv).r;
	if (mode == 2) {
		ALBEDO = COLOR.rgb;
		ALPHA = t;
	} else {
		ALBEDO = mix(env.rgb, prim.rgb, t);
		float a = prim.a * t;
		if (mode == 0) {
			// G_AD_NOISE: the alpha jittered by per-pixel noise (the N64's sparkle).
			// (scaled, so where the texture is empty stays empty)
			a = clamp(a * (0.7 + 0.6 * hash(FRAGCOORD.xy + vec2(TIME * 61.0, TIME * 37.0))), 0.0, 1.0);
		}
		ALPHA = a;
	}
}
