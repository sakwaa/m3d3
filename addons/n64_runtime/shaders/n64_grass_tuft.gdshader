shader_type spatial;
render_mode unshaded, cull_disabled, skip_vertex_transform;
// Grass tufts over the mat (GrassBuilder), MultiMesh instances in two levels of detail:
// near, two crossed quads that sway in the shared wind (n64_wind) and part round the
// player (n64_bender0..3); further out, one quad turned to the camera (a card, 2
// triangles). Each level fades with a screen-door dither (no blending: the 1-bit cut-out
// stays): across the `fade` band at near_end the card dissolves into the crossed tuft pixel
// by pixel (the two take complementary pixels, never both, never neither), and over the
// last `grow` metres before far_end the cards dissolve away. Instance colour = tint; UV.y 0 at the tips (they move), 1 at the root.
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"

uniform sampler2D tex : source_color, filter_nearest_mipmap, repeat_disable;
uniform float shade = 1.0;
// 0: near crossed tufts, 1: far cards.
uniform int level = 0;
// Near tufts show out to near_end, cards from near_end to far_end; both swap over within
// `fade` metres of near_end; cards dissolve out over the last `grow` metres before far_end.
uniform float near_end = 14.0;
uniform float far_end = 40.0;
uniform float fade = 3.0;
uniform float grow = 10.0;
// Sway (metres at the tips at wind strength 1) and how far tufts part round a bender.
uniform float sway = 0.12;
uniform float part = 0.35;
global uniform vec4 n64_wind;
global uniform vec4 n64_bender0;
global uniform vec4 n64_bender1;
global uniform vec4 n64_bender2;
global uniform vec4 n64_bender3;

varying vec2 n64_fogv;
varying vec3 n64_fog_tintv;
varying vec3 tint;
varying float near_v;  // 1 all crossed tuft .. 0 all card
varying float far_v;  // the card's fade out at the far end (1 shown)

vec2 push(vec4 b, vec3 p) {
	if (b.w <= 0.0 || abs(b.y - p.y) > 2.0) {
		return vec2(0.0);
	}
	vec2 d = p.xz - b.xz;
	float l = length(d);
	if (l > b.w * 1.3 || l < 0.0001) {
		return vec2(0.0);
	}
	return d / l * (1.0 - smoothstep(b.w * 0.3, b.w * 1.3, l));
}

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float size = length(MODEL_MATRIX[1].xyz);
	vec3 world;
	if (level == 1) {
		// Card: turned to the camera around Y.
		vec3 to_cam = INV_VIEW_MATRIX[3].xyz - origin;
		to_cam.y = 0.0;
		vec3 right = length(to_cam) > 0.0001 ? normalize(vec3(to_cam.z, 0.0, -to_cam.x)) : vec3(1.0, 0.0, 0.0);
		world = origin + right * VERTEX.x * length(MODEL_MATRIX[0].xyz) + vec3(0.0, VERTEX.y * size, 0.0);
	} else {
		world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	}
	float tip = 1.0 - UV.y;
	if (tip > 0.0) {
		float along = dot(origin.xz, n64_wind.xy);
		float gust = 0.5 + 0.5 * sin(along * 0.35 - TIME * (1.2 + n64_wind.z)) * n64_wind.w;
		float flick = sin(TIME * 3.3 + origin.x * 2.1 + origin.z * 1.7) * 0.3;
		vec2 lean = n64_wind.xy * (gust + flick) * sway * n64_wind.z;
		if (level == 0) {
			vec2 p = push(n64_bender0, origin) + push(n64_bender1, origin) + push(n64_bender2, origin) + push(n64_bender3, origin);
			lean += p * part;
			world.y -= length(p) * part * 0.5 * tip * size;
		}
		world.xz += lean * tip * size;
	}
	// Level of detail: how far through the swap band and the far fade (per vertex; the
	// fragment dithers by them).
	float dist = distance(INV_VIEW_MATRIX[3].xyz, origin);
	near_v = 1.0 - smoothstep(near_end - fade, near_end, dist);
	far_v = 1.0 - smoothstep(far_end - grow, far_end, dist);
	n64_fogv = n64_fog_vertex(world);
	n64_fog_tintv = n64_fog_tint_vertex(world);
	tint = COLOR.rgb;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
}

// 4 x 4 ordered dither threshold for this pixel (0..1).
float bayer(vec2 p) {
	ivec2 q = ivec2(mod(p, 4.0));
	int m[16] = int[16](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
	return (float(m[q.y * 4 + q.x]) + 0.5) / 16.0;
}

void fragment() {
	float b = bayer(FRAGCOORD.xy);
	if (level == 0 ? b >= near_v : (b < near_v || b >= far_v)) {
		discard;
	}
	vec4 c = n64_texture(tex, UV);
	ALBEDO = c.rgb * tint * shade * n64_world_tint.rgb * n64_weather_tint.rgb;
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
}
