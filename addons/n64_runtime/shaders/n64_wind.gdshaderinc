// The shared wind (Acerola's flow field, "Modern Foliage Rendering"): n64_wind = direction
// x / z, strength, gustiness (DynamicSky: the zone's wind x the weather's). n64_gust(xz) is
// where the gusts are: a sine travelling down the wind whose wavefronts are bent by value
// noise (the "marble" trick), so gusts arrive as twisting patches, not straight bands, and
// the noise rides along with them (a patch keeps its shape as it crosses a field). Grass
// tufts, the carpet's sheen and trees all read the same field: one gust bends the grass,
// lights the carpet, then reaches the tree behind it.
global uniform vec4 n64_wind;

float n64_wind_hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float n64_wind_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = n64_wind_hash(i);
	float b = n64_wind_hash(i + vec2(1.0, 0.0));
	float c = n64_wind_hash(i + vec2(0.0, 1.0));
	float d = n64_wind_hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Gust at world xz, 0 (lull) .. 1 (a gust's heart). Gusts travel at 3-7 m/s (stronger
// wind, faster), ~14 m apart, patches ~10-20 m across.
float n64_gust(vec2 xz) {
	vec2 d = n64_wind.xy;
	vec2 s = vec2(-d.y, d.x);
	float speed = 3.0 + 4.0 * clamp(n64_wind.z, 0.0, 1.0);
	// The wind's frame, travelling with the gusts (and drifting slowly across them).
	vec2 q = vec2(dot(xz, d) - TIME * speed, dot(xz, s) + TIME * 0.4);
	float warp = n64_wind_noise(q * 0.06) * 0.65 + n64_wind_noise(q * 0.13 + 17.0) * 0.35;
	float phase = q.x * 0.45 + warp * 7.0;
	float g = 0.5 + 0.5 * sin(phase);
	// Gaps across the wind: not every front is a whole line.
	float gaps = smoothstep(0.25, 0.75, n64_wind_noise(q * vec2(0.035, 0.08) + 41.0));
	return g * g * gaps;
}

// The lean for a gust value `g` (n64_gust).
float n64_wind_push_g(float g) {
	return mix(0.5, 0.3 + g, clamp(n64_wind.w, 0.0, 1.0));
}

// How visible gusts are (sheen): gustiness x strength, 0..1.
float n64_gust_show() {
	return clamp(n64_wind.w, 0.0, 1.0) * clamp(n64_wind.z * 1.5, 0.0, 1.0);
}

// How hard to lean at xz (about 0.5 at rest in a steady wind; gusty winds swing from a lull
// near 0.3 up to ~1.3 in a gust).
float n64_wind_push(vec2 xz) {
	return n64_wind_push_g(n64_gust(xz));
}
