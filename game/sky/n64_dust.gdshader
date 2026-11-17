shader_type spatial;
// WindDust: the sandstorm's look (two big blurry noise layers joined by the combiner -
// colour (T1 - T0) x 0.5 + T0, alpha (T1 - T0) x envA + T0, then mix(ENV, PRIM, colour)) laid
// into the world: the noise is sampled at world positions and blown along the wind, on
// see-through shells round the camera (dust kicked up in town) or one tall ring out past the
// town (a dusty band before the mountains). Densest at the ground and thinning with height,
// soft where it meets walls and ground (depth), clear right at the camera.
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"

uniform sampler2D noise0 : filter_linear, repeat_enable;
uniform sampler2D noise1 : filter_linear, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform vec4 prim : source_color = vec4(1.0, 0.78, 0.39, 1.0);
uniform vec4 env : source_color = vec4(0.78, 0.59, 0.2, 1.0);
// Overall alpha (the weather's dust x this layer's share) and the layers' alpha mix.
uniform float amount = 0.2;
uniform float env_a = 0.5;
// How much of the noise shows in the alpha and colour (0 = an even haze, 1 = the full clouds).
uniform float contrast = 1.0;
// Wind drift of the two layers (texture repeats, accumulated by WindDust).
uniform vec2 drift0 = vec2(0.0);
uniform vec2 drift1 = vec2(0.0);
// Metres per texture repeat (layer 0 across the ground, layer 1 up the walls of dust).
uniform float scale0 = 10.0;
uniform float scale1 = 6.0;
// Ground height and how high the dust reaches (thinning to nothing at the top).
uniform float base_y = 0.0;
uniform float height = 4.0;
// Metres of soft edge where it meets geometry (0 = none) and clear space at the camera.
uniform float soft = 1.5;
uniform float near_clear = 2.0;
// The far ring: its depth as the zone backdrop's (real distance, kept inside the far plane:
// the camera's far clip stops at the fog's end), so it stands in front of the hills behind
// it and behind the town; noise laid round its circumference.
uniform bool ring = false;
uniform vec2 ring_center = vec2(0.0);
uniform float ring_radius = 85.0;

varying vec3 wpos;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec4 clip = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	if (ring) {
		float z = max(clip.z / clip.w, 0.0) + 1e-5 / max(clip.w, 1.0);
		clip.z = z * clip.w;
	}
	POSITION = n64_snap(clip, VIEWPORT_SIZE);
}

void fragment() {
	vec2 p0 = wpos.xz / scale0 * vec2(1.0, 2.0) + drift0;
	vec2 p1 = vec2(wpos.x + wpos.z, wpos.y * 1.6) / scale1 * vec2(1.0, 2.0) + drift1;
	if (ring) {
		// (round the ring: arc length and height)
		// (a whole number of repeats round, so the noise meets itself without a seam)
		vec2 r = wpos.xz - ring_center;
		float turn = atan(r.y, r.x) / 6.2831853;
		float n0 = max(round(6.2831853 * ring_radius / scale0), 1.0);
		float n1 = max(round(6.2831853 * ring_radius * 1.3 / scale1), 1.0);
		p0 = vec2(turn * n0, wpos.y * 1.3 / scale0 * 2.0) + drift0;
		p1 = vec2(turn * n1 + 0.37, wpos.y * 1.8 / scale1 * 2.0) + drift1;
	}
	vec4 t0 = texture(noise0, p0);
	vec4 t1 = texture(noise1, p1);
	float c = (t1.r - t0.r) * 0.5 + t0.r;
	float a = (t1.a - t0.a) * env_a + t0.a;
	a = mix(0.6, a, contrast);
	c = mix(0.5, c, contrast);
	float up = wpos.y - base_y;
	// (thickest at the ground, thinning all the way up: no hard top)
	float top = clamp(1.0 - up / height, 0.0, 1.0);
	float h = top * top * smoothstep(-0.5, 0.2, up);
	float frag_d = -VERTEX.z;
	float k = 1.0;
	if (!ring) {
		if (soft > 0.0) {
			float zr = texture(depth_tex, SCREEN_UV).r;
			vec4 v = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, zr, 1.0);
			float scene_d = -v.z / v.w;
			k *= clamp((scene_d - frag_d) / soft, 0.0, 1.0);
		}
		k *= smoothstep(near_clear * 0.5, near_clear, frag_d);
	}
	ALBEDO = mix(env.rgb, prim.rgb, clamp(c, 0.0, 1.0));
	// (alpha noise dither, as the sandstorm's G_AD_NOISE)
	ALPHA = clamp(a * amount * h * k * (0.85 + 0.3 * hash(FRAGCOORD.xy + TIME * 37.0)), 0.0, 1.0);
}
