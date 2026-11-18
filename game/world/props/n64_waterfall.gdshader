shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;
// A waterfall strand (Waterfall): a sheet of water falling down a cliff, streaks scrolling
// down at their own speeds, see-through and frothy at its edges, whiter where it lands;
// `foam` = the churned patch at its foot instead (rings of froth spreading out). N64 fog.
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"

uniform vec4 color : source_color = vec4(0.74, 0.84, 0.88, 1.0);
uniform float opacity = 0.8;
uniform float speed = 1.6;
uniform float seed = 0.0;
// Streak repeats down the strand (its length in metres / ~3).
uniform float repeats = 8.0;
uniform bool foam = false;

varying vec2 n64_fogv;
varying vec3 n64_fog_tintv;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	n64_fogv = n64_fog_vertex(w);
	n64_fog_tintv = n64_fog_tint_vertex(w);
}

void fragment() {
	vec3 albedo;
	float alpha;
	if (foam) {
		// (UV round the foot: churn rings moving out, broken up)
		vec2 p = UV * 2.0 - 1.0;
		float r = length(p);
		float a = atan(p.y, p.x);
		float cell = floor(a * 6.0 / 3.14159);
		float ring = fract(r * 3.0 - n64_time * speed * 0.35 + hash(vec2(cell, seed)));
		float s = step(0.55, ring) * step(0.3, hash(vec2(cell, floor(r * 3.0 - n64_time * speed * 0.35))));
		albedo = mix(color.rgb, vec3(1.0), 0.55 + s * 0.4);
		alpha = opacity * (1.0 - smoothstep(0.55, 1.0, r)) * (0.35 + s * 0.5);
	} else {
		float x = UV.x;
		float col = floor(x * 7.0);
		float v = UV.y * repeats - n64_time * speed * (0.75 + hash(vec2(col, seed)) * 0.5);
		float s = step(0.42, fract(v + hash(vec2(col, seed + 3.0))));
		float edge = 1.0 - pow(abs(x * 2.0 - 1.0), 2.0);
		float land = smoothstep(0.82, 1.0, UV.y);
		albedo = mix(color.rgb, vec3(1.0), s * 0.35 + land * 0.4);
		alpha = opacity * edge * (0.5 + s * 0.35 + land * 0.2) * smoothstep(0.0, 0.03, UV.y);
	}
	ALBEDO = albedo;
	ALPHA = clamp(alpha, 0.0, 1.0);
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
}
