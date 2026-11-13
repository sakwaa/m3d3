// Rain globals (DynamicSky, RainCover) and what reads them.
// n64_rain: x = how hard it rains (0..1), yz = wind (m/s, world XZ), w = unused.
// n64_wetness: how wet surfaces open to the sky are (0..1; lags the rain: soaks in, dries
// slowly).
global uniform vec4 n64_rain;
global uniform float n64_wetness;
// RainCover: top-down map of the highest surface (packed height, see rain_cover.gd).
global uniform sampler2D n64_rain_cover : filter_nearest;
// xy = world XZ of the map's corner, zw = 1 / its size (0 = no map).
global uniform vec4 n64_rain_cover_area;
// x = height of a packed 0, y = span of the packed range (metres).
global uniform vec2 n64_rain_cover_height;

// The highest surface above world XZ `xz` (where rain lands), or -1e6 for open sky / no map.
float n64_cover_height(vec2 xz) {
	if (n64_rain_cover_area.z == 0.0) {
		return -1e6;
	}
	vec2 uv = (xz - n64_rain_cover_area.xy) * n64_rain_cover_area.zw;
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
		return -1e6;
	}
	vec4 t = textureLod(n64_rain_cover, uv, 0.0);
	if (t.b < 0.5) {
		return -1e6;
	}
	float q = (floor(t.r * 255.0 + 0.5) * 256.0 + floor(t.g * 255.0 + 0.5)) / 65535.0;
	return n64_rain_cover_height.x + q * n64_rain_cover_height.y;
}

// The cover map's height at texel `i` (-1e6: open sky).
float n64_cover_texel(ivec2 i) {
	vec4 t = texelFetch(n64_rain_cover, clamp(i, ivec2(0), textureSize(n64_rain_cover, 0) - 1), 0);
	if (t.b < 0.5) {
		return -1e6;
	}
	float q = (floor(t.r * 255.0 + 0.5) * 256.0 + floor(t.g * 255.0 + 0.5)) / 65535.0;
	return n64_rain_cover_height.x + q * n64_rain_cover_height.y;
}

// How open to the sky world point `p` is: 1 nothing over it, 0 under a roof. Blended between
// the four nearest cover cells (each open or not), so the dry strip under eaves and awnings
// fades out over a cell instead of stepping in square blocks.
float n64_rain_exposed(vec3 p) {
	if (n64_rain_cover_area.z == 0.0) {
		return 1.0;
	}
	vec2 uv = (p.xz - n64_rain_cover_area.xy) * n64_rain_cover_area.zw;
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
		return 1.0;
	}
	vec2 g = uv * vec2(textureSize(n64_rain_cover, 0)) - 0.5;
	ivec2 i = ivec2(floor(g));
	vec2 f = g - floor(g);
	float a = step(n64_cover_texel(i) - 0.2, p.y);
	float b = step(n64_cover_texel(i + ivec2(1, 0)) - 0.2, p.y);
	float c = step(n64_cover_texel(i + ivec2(0, 1)) - 0.2, p.y);
	float d = step(n64_cover_texel(i + ivec2(1, 1)) - 0.2, p.y);
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Colour `c` soaked by `wet` (0..1), like wet earth and stone: darker, a little richer, and
// with more contrast (water darkens the hollows of a texture more than its tops), so the
// texture still reads instead of flattening into one muddy colour.
vec3 n64_wet(vec3 c, float wet) {
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	c = max(mix(vec3(l), c, 1.0 + 0.18 * wet), vec3(0.0));
	c = pow(c, vec3(1.0 + 0.45 * wet));
	return c * (1.0 - 0.22 * wet);
}
