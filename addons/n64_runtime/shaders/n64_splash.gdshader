shader_type spatial;
// Rain splashes: a small ring flickering open on the surface (the same as the roof drips'
// splashes, n64_drip.gdshader), each at a new random spot every PERIOD seconds, in a box
// around the camera, on the first surface below (RainCover: roofs, awnings, ground). How
// many show follows the rain.
// Mesh (Rain.make_splash_mesh): a quad per splash, CUSTOM0 = (seed x, seed z, phase, pick),
// UV = corner.
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled, world_vertex_coords;

#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_weather.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_rain_light.gdshaderinc"

uniform float box = 28.0;
uniform float period = 0.45;
// Ring radius at its widest (metres).
uniform float ring_size = 0.12;
// Tint on the light the splash catches (n64_rain_light.gdshaderinc), and its opacity when lit.
uniform vec4 splash_color : source_color = vec4(0.95, 0.97, 1.0, 0.45);

varying float age;
varying float shown;
varying vec4 lit;

vec2 splash_hash(vec2 p) {
	return fract(sin(vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)))) * 43758.5453);
}

void vertex() {
	float t = TIME / period + CUSTOM0.z;
	float cycle = floor(t);
	age = fract(t);
	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 ahead = -INV_VIEW_MATRIX[2].xyz;
	ahead.y = 0.0;
	ahead = length(ahead) > 0.01 ? normalize(ahead) : vec3(0.0, 0.0, -1.0);
	vec2 lo = cam.xz + ahead.xz * box * 0.2 - vec2(box * 0.5);
	vec2 xz = lo + mod(splash_hash(CUSTOM0.xy * 91.7 + cycle * 0.173) * box * 7.0 - lo, vec2(box));
	float h = n64_cover_height(xz);
	shown = CUSTOM0.w < n64_rain.x && h > -1e5 ? 1.0 : 0.0;
	vec3 base = vec3(xz.x, h + 0.03, xz.y);
	vec2 c = UV * 2.0 - 1.0;
	vec3 p = base + vec3(c.x, 0.0, c.y) * ring_size * 1.3;
	float far = 1.0 - smoothstep(box * 0.35, box * 0.5, distance(base, cam));
	shown *= far;
	// Lit per splash (its centre; always open to the sky, it's where rain lands).
	lit = n64_rain_lit(base + vec3(0.0, 0.05, 0.0), cam, fract(CUSTOM0.x * 7.1 + cycle * 0.37), 0.0);
	VERTEX = shown > 0.0 ? p : cam - vec3(0.0, 1000.0, 0.0);
}

void fragment() {
	// A thin ring opening out, fading as it goes (as the drips' splashes).
	float r = length(UV * 2.0 - 1.0) * 1.3;
	float a = (1.0 - smoothstep(0.0, 0.3, abs(r - age))) * (1.0 - age);
	ALBEDO = splash_color.rgb * lit.rgb;
	ALPHA = splash_color.a * lit.w * a * shown;
}
