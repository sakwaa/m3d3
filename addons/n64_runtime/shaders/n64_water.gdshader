shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, diffuse_lambert, specular_disabled;
// N64-style water: a translucent surface showing two copies of a ripple texture scrolling
// different ways (the combiner trick most N64 water used), small vertex waves, a water
// sheen (environment map) that ripples with them, a sun / key-light glint and N64 fog.
// Use on a subdivided plane (waves move vertices); texture tiles in world metres.
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_shine.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_combiner.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_weather.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_ripples.gdshaderinc"

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
// Second layer's own texture (TEXEL1; off = the same texture again).
uniform bool use_texture_b = false;
uniform sampler2D water_texture_b : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
// How the combiner joins the two layers: Average (soft ripples), Multiply (G_CC_INTERFERENCE:
// dark where either is dark, a sparkly mesh where bright crosses bright), Difference (thin
// bright lines where the layers' waves cross: caustic-like shimmer).
uniform int combine : hint_enum("Average", "Multiply", "Difference") = 0;
// Share of the colour that glows (unlit): 0 water, ~1 lava, magma, glowing slime.
uniform float glow_amount : hint_range(0.0, 1.0) = 0.0;
// How much the waves tilt the sheen / glint.
uniform float wave_tilt = 0.35;

// Glisten (Kaze's combiner trick): two blocky noise textures scroll different ways; cycle 1
// multiplies them, cycle 2 takes the product from 0 - only where two bright texels cross does
// it go under -0.5 and wrap round to full brightness: specks of sunlight that pop up and
// vanish all over the surface. 0 = off. Fades out by glisten_far (Sunshine-like: near water
// sparkles, far water calm).
uniform float glisten : hint_range(0.0, 2.0) = 0.0;
// Noise texels per metre (bigger = finer specks).
uniform float glisten_texels = 14.0;
// How hard cycle 2 pushes the product: specks where noise x noise x gain passes 0.5 (0.65: ~3 %
// of texels, 0.8: ~8 %; at or below 0.5 none).
uniform float glisten_gain : hint_range(0.5, 1.5) = 0.65;
// Metres per second the two noise layers slide (opposite ways).
uniform float glisten_speed = 0.35;
uniform float glisten_far = 30.0;
uniform vec4 glisten_color : source_color = vec4(1.0, 0.97, 0.88, 1.0);

// Planar reflection (N64Water node): the scene mirrored in the water plane, low-res.
uniform bool reflect_on = false;
uniform sampler2D reflect_tex : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
uniform float reflect_strength : hint_range(0.0, 1.0) = 0.6;
uniform float reflect_distortion = 0.025;

// Underwater wobble (as Hail to the Dongo's N64 water: pixels tagged as water shift in a
// wave): what's seen through the water is read from the screen a little to the side,
// swaying. The tag here is depth: a shifted read that lands on something in front of the
// water (a leg, the bank) takes the unshifted pixel, so nothing above the surface smears in.
uniform bool wobble_on = true;
// Sway at 5 m away, in screen widths (nearer sways more, farther less).
uniform float wobble_strength = 0.004;
// Waves per metre across the water, and their speed.
uniform float wobble_scale = 1.6;
uniform float wobble_speed = 1.4;
uniform sampler2D screen_tex : hint_screen_texture, filter_nearest, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;

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
	vec2 uvb = uv * layer_b_scale + scroll_b * TIME / max(tile_size, 0.01);
	float tb = use_texture_b ? n64_texture(water_texture_b, uvb).r : n64_texture(water_texture, uvb).r;
	float v = combine == 1 ? n64_cc_interference(vec4(ta), vec4(tb)).r * 1.6
		: combine == 2 ? 1.0 - abs(ta - tb) * 2.0
		: (ta + tb) * 0.5;
	// G_CC_BLENDPE: the combined texel picks between ENV (deep) and PRIM (shallow).
	vec3 albedo = n64_cc_blend_pe(vec4(clamp(v, 0.0, 1.0)), shallow_color, deep_color).rgb;
	vec3 glow_c = albedo * glow_amount;
	albedo *= 1.0 - glow_amount;
	vec3 glow = glow_c + n64_shine(albedo, n64_shine_frag(n64_shine_v, VERTEX, VIEW_MATRIX));
	if (glisten > 0.0) {
		vec2 gp = world_xz * glisten_texels;
		float ga = n64_cc_noise_texel(gp + vec2(1.0, 0.35) * glisten_speed * glisten_texels * TIME);
		float gb = n64_cc_noise_texel(gp * 1.13 + vec2(17.0, 5.0) - vec2(0.4, 1.0) * glisten_speed * glisten_texels * TIME);
		// cycle 1: TEXEL0 x TEXEL1; cycle 2: (0 - COMBINED) x PRIM + 0 -> overflow
		float spark = n64_cc_overflow1((0.0 - ga * gb) * glisten_gain * 1.0 + 0.0);
		float far = 1.0 - smoothstep(glisten_far * 0.5, glisten_far, length(VERTEX));
		glow += glisten_color.rgb * spark * glisten * far * (1.0 - glow_amount);
	}
	// Ripples: raindrops landing, and the ripple simulation (wading wakes, drips, landings):
	// crests catch the sky's light.
	vec3 wpos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float rip = n64_rain_rings(wpos.xz, TIME, n64_rain.x, length(VERTEX))
		+ n64_ripple_sim(wpos.xz, CAMERA_POSITION_WORLD) * 1.2;
	rip = clamp(rip, -1.0, 1.0) * (1.0 - glow_amount);
	glow += mix(n64_fog_color.rgb, vec3(1.0), 0.5) * max(rip, 0.0) * 0.3;
	albedo *= 1.0 + min(rip, 0.0) * 0.2;
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
	vec4 fog = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
	if (wobble_on && alpha < 0.999) {
		float t = TIME * wobble_speed;
		vec2 sway = vec2(sin(world_xz.y * wobble_scale + t), cos(world_xz.x * wobble_scale * 1.3 + t * 1.1));
		vec2 suv = SCREEN_UV + sway * wobble_strength * 5.0 / max(length(VERTEX), 5.0);
		// Reversed depth (nearer = larger): a read in front of the water stays put.
		if (texture(depth_tex, suv).r > FRAGCOORD.z || any(lessThan(suv, vec2(0.0))) || any(greaterThan(suv, vec2(1.0)))) {
			suv = SCREEN_UV;
		}
		vec3 behind = texture(screen_tex, suv).rgb;
		// Drawn opaque: the water's own part as before, the scene behind (already lit and
		// fogged) mixed in as it would have blended.
		ALBEDO = albedo * alpha;
		EMISSION = glow * alpha + behind * (1.0 - alpha);
		ALPHA = 1.0;
		FOG = vec4(fog.rgb, fog.a * alpha);
	} else {
		EMISSION = glow;
		ALBEDO = albedo;
		ALPHA = alpha;
		FOG = fog;
	}
}
