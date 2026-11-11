shader_type spatial;
// Rain running off an edge (RainDrip): thin strings of drops falling from it, one per roof
// tile channel, and a splash where each lands, shown only while it rains (n64_rain.x).
// Like real eaves without a gutter: water leaves at the channels a hand's width apart, not
// as a sheet; light rain is separate drops, heavy rain joins them into broken strings.
// Mesh (RainDrip.add_to): UV = metres (along the edge, down / across), COLOR.r = seed,
// COLOR.g = 0 curtain / 1 splashes, COLOR.a = density (share of the channels running).
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_weather.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_rain_light.gdshaderinc"

// Metres between channels (a tile's width), and how far a stream may sit off its channel.
uniform float stream_spacing = 0.28;
uniform float stream_jitter = 0.07;
// Stream thickness, metres (drawn at least ~a pixel wide, fainter when that's wider).
uniform float stream_width = 0.012;
uniform float fall_speed = 5.5;
// Tint on the light the water catches (n64_rain_light.gdshaderinc), and its opacity when lit.
uniform vec4 water_color : source_color = vec4(0.95, 0.97, 1.0, 0.4);
// How far the eave keeps the sky's light off the streams (0..1).
uniform float shelter = 0.6;

varying vec3 world;

void vertex() {
	world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Dry: collapsed, nothing drawn.
	if (n64_rain.x <= 0.001) {
		VERTEX = vec3(0.0);
	}
}

float n64_hash1(float n) {
	return fract(sin(n * 127.1) * 43758.5453);
}

void fragment() {
	float rain = clamp(n64_rain.x * 1.6, 0.0, 1.0);
	float a = 0.0;
	float col = floor(UV.x / stream_spacing);
	float h = n64_hash1(col + COLOR.r * 97.0);
	// Running channels: more of them the harder it rains.
	float running = h < COLOR.a * mix(0.45, 1.0, rain) ? 1.0 : 0.0;
	float centre = (col + 0.5) * stream_spacing + (n64_hash1(col * 3.7 + COLOR.r * 13.0) - 0.5) * 2.0 * stream_jitter;
	if (COLOR.g < 0.5) {
		// A string of drops: short bright beads in light rain, longer broken runs in heavy.
		float px = max(fwidth(UV.x), 1e-4);
		float half_w = max(stream_width * 0.5, px * 0.6);
		float thin = (1.0 - smoothstep(half_w * 0.5, half_w, abs(UV.x - centre))) * min(1.0, stream_width * 0.5 / half_w * 1.5);
		float v = UV.y * 0.9 - TIME * fall_speed * (0.85 + 0.3 * h) + h * 9.0;
		float len = mix(0.12, 0.45, rain);
		float drop = 1.0 - smoothstep(len * 0.6, len, fract(v));
		// The film gathers at the edge: a little denser just under it.
		float top = mix(1.0, 0.7, smoothstep(0.0, 0.4, UV.y));
		a = thin * drop * top * running;
	} else {
		// Splashes: a small ring flickering open where each running stream lands.
		vec2 p = vec2(UV.x - centre, UV.y - 0.25);
		float age = fract(TIME * (2.2 + h) + h * 5.0);
		float r = length(p) / 0.09;
		a = (1.0 - smoothstep(0.0, 0.3, abs(r - age))) * (1.0 - age) * running * (0.4 + 0.6 * rain);
	}
	if (a < 0.002) {
		discard;
	}
	// Lit where it is (only the drawn pixels pay for it): dim under the eave, bright by a lamp.
	vec4 lit = n64_rain_lit(world, CAMERA_POSITION_WORLD, h, COLOR.g < 0.5 ? shelter : 0.0);
	ALBEDO = water_color.rgb * lit.rgb;
	ALPHA = water_color.a * lit.w * a;
}
