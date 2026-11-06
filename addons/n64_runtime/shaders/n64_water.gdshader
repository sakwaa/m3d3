shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, diffuse_lambert, specular_disabled;
// N64-style water: a translucent surface showing two copies of a ripple texture scrolling
// different ways (the combiner trick most N64 water used), small vertex waves, a water
// sheen (environment map) that ripples with them, a sun / key-light glint and N64 fog.
// Use on a subdivided plane (waves move vertices); texture tiles in world metres.
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_shine.gdshaderinc"

uniform sampler2D water_texture : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
uniform vec4 shallow_color : source_color = vec4(0.25, 0.5, 0.6, 1.0);
uniform vec4 deep_color : source_color = vec4(0.06, 0.18, 0.28, 1.0);
uniform float opacity : hint_range(0.0, 1.0) = 0.72;
// Metres per texture repeat, and the two layers' scroll (metres / second).
uniform float tile_size = 2.0;
uniform vec2 scroll_a = vec2(0.12, 0.05);
uniform vec2 scroll_b = vec2(-0.07, 0.1);
// Second layer's size relative to the first (different sizes hide the repeat).
uniform float layer_b_scale = 1.37;
uniform float wave_height = 0.04;
uniform float wave_speed = 1.2;
// How much the waves tilt the sheen / glint.
uniform float wave_tilt = 0.35;

// Planar reflection (N64Water node): the scene mirrored in the water plane, low-res.
uniform bool reflect_on = false;
uniform sampler2D reflect_tex : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
uniform float reflect_strength : hint_range(0.0, 1.0) = 0.6;
uniform float reflect_distortion = 0.025;

varying vec2 n64_fogv;
varying vec3 n64_fog_tintv;
varying vec2 world_xz;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_xz = world.xz;
	float t = TIME * wave_speed;
	float a = world.x * 1.7 + world.z * 0.6 + t;
	float b = world.z * 1.3 - world.x * 0.4 + t * 1.3;
	VERTEX.y += (sin(a) + sin(b)) * 0.5 * wave_height;
	// Wave slope tilts the normal, so the sheen and glint ripple.
	vec3 n = normalize(vec3(-(cos(a) * 1.7 - cos(b) * 0.4), 1.0 / max(wave_tilt, 0.01), -(cos(a) * 0.6 + cos(b) * 1.3)));
	NORMAL = n;
	n64_fogv = n64_fog_vertex((MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz);
	n64_fog_tintv = n64_fog_tint_vertex((MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz);
	n64_shine_v = n64_shine_vertex((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz, (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz, VIEW_MATRIX);
}

void fragment() {
	vec2 uv = world_xz / max(tile_size, 0.01);
	float ta = n64_texture(water_texture, uv + scroll_a * TIME / max(tile_size, 0.01)).r;
	float tb = n64_texture(water_texture, uv * layer_b_scale + scroll_b * TIME / max(tile_size, 0.01)).r;
	float v = (ta + tb) * 0.5;
	vec3 albedo = mix(deep_color.rgb, shallow_color.rgb, v);
	vec3 glow = n64_shine(albedo, n64_shine_v);
	float alpha = opacity;
	if (reflect_on) {
		// Mirror image is left-right flipped (see N64Water); the waves wobble it.
		vec2 ruv = vec2(1.0 - SCREEN_UV.x, SCREEN_UV.y) + NORMAL.xz * reflect_distortion;
		ruv = clamp(ruv, vec2(0.001), vec2(0.999));
		vec3 refl = n64_three_point ? n64_sample_level(reflect_tex, ruv, 0).rgb : texture(reflect_tex, ruv).rgb;
		// More mirror-like at grazing angles (Fresnel-ish), unlit.
		float k = reflect_strength * mix(0.55, 1.0, pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0));
		albedo *= 1.0 - k;
		glow += refl * k;
		alpha = mix(alpha, 1.0, k);
	}
	EMISSION = glow;
	ALBEDO = albedo;
	ALPHA = alpha;
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
}
