shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
// A shaft of daylight (LightShaft): one of a few quads crossed round the beam's axis, added
// on. Bright down the middle and nothing at its edges (UV.x across), faded in where it comes
// in and out towards its foot (UV.y along), and gone where the quad is seen edge-on (so the
// crossed planes never show as lines) or right up close (walking through it). Slow streaks
// and motes drift down it. Fades into the N64 fog by distance (additive: dimmed by the fog's
// amount rather than mixed to its colour) and out at night by the time of day's light.
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"

// The time of day's light (Zone, linear): near white at noon, dark blue at night.
global uniform vec4 n64_ambient_light;

uniform vec4 color : source_color = vec4(1.0, 0.95, 0.82, 1.0);
uniform float intensity = 0.35;
uniform float shimmer = 0.5;
// Quads in the beam (each adds; the brightness is shared out between them).
uniform float planes = 3.0;

varying vec2 n64_fogv;
varying vec3 n64_fog_tintv;
varying float daylight;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = p - i;
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + 1.0), f.x), f.y);
}

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	n64_fogv = n64_fog_vertex(w);
	n64_fog_tintv = n64_fog_tint_vertex(w);
	float lum = dot(n64_ambient_light.rgb, vec3(0.2126, 0.7152, 0.0722));
	daylight = smoothstep(0.08, 0.5, lum);
}

void fragment() {
	float x = UV.x * 2.0 - 1.0;
	float len = UV2.y;
	// (soft profile: a bell across, no edge)
	float across = exp(-x * x * 2.6) * (1.0 - smoothstep(0.6, 1.0, abs(x)));
	float ends = smoothstep(0.0, 0.18, UV.y) * (1.0 - smoothstep(0.5, 1.0, UV.y));
	// (edge-on: the quad thins to a line; fade it well before)
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float edge = smoothstep(0.08, 0.55, facing);
	float near = smoothstep(1.0, 4.0, length(VERTEX));
	// Streaks along the beam and drifting motes, slow.
	float s = 1.0;
	if (shimmer > 0.0) {
		vec2 p = vec2(UV.x * 5.0 + UV2.x * 7.31, UV.y * len / 9.0 - n64_time * 0.035);
		float streak = vnoise(p) * 0.6 + vnoise(p * vec2(2.3, 1.7) + 11.0) * 0.4;
		vec2 m = vec2(UV.x * 22.0 + UV2.x * 3.7, UV.y * len * 1.2 + n64_time * 0.25);
		vec2 cell = floor(m);
		vec2 f = fract(m) - 0.5 - (vec2(hash(cell), hash(cell + 5.0)) - 0.5) * 0.6;
		float mote = step(0.93, hash(cell + UV2.x)) * (1.0 - smoothstep(0.05, 0.2, length(f)));
		s = mix(1.0, 0.3 + streak * 1.4 + mote * 1.5, shimmer);
	}
	float fog = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX).a;
	float k = intensity * across * ends * edge * near * s * daylight * pow(1.0 - fog, 0.6) * 1.6 / planes;
	ALBEDO = color.rgb;
	ALPHA = clamp(k, 0.0, 1.0);
}
