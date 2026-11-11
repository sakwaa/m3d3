shader_type spatial;
render_mode unshaded, cull_disabled, skip_vertex_transform;
// (Opaque: in the depth buffer, so projected shadows land on it. Round the player's legs it
// leaves a hole (n64_divot, set by GrassWake) that GrassWake's bowl fills: the dip.)
// The grass carpet (GrassBuilder): a lumpy carpet over the ground (Majora's Mask style), N64
// look like the baked level (unshaded, vertex colours, 3-point filtering, fog, day / night
// and weather tints). It stays still (the tufts sway in the wind; what wades through it parts
// it with GrassWake's rings).
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"

uniform sampler2D tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform float shade = 1.0;
// The divot: world x, top y, z, rim radius (0: none). Its edge ragged like blade tips over
// the rim: the outer `divot_band` of the radius, tips `divot_tip` metres.
global uniform vec4 n64_divot;
uniform float divot_band = 0.3;
uniform float divot_tip = 0.035;

varying vec2 n64_fogv;
varying vec3 n64_fog_tintv;
varying vec3 tint;
varying vec3 world_v;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	n64_fogv = n64_fog_vertex(world);
	n64_fog_tintv = n64_fog_tint_vertex(world);
	tint = COLOR.rgb;
	world_v = world;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	if (n64_divot.w > 0.0 && abs(world_v.y - n64_divot.y) < 0.4) {
		float r = distance(world_v.xz, n64_divot.xz) / n64_divot.w;
		float edge = (r - (1.0 - divot_band)) / divot_band;
		if (r < 1.0 && (edge <= 0.0 || hash(floor(world_v.xz / divot_tip)) >= pow(edge, 1.5) * 1.1)) {
			discard;
		}
	}
	vec4 c = n64_texture(tex, UV);
	ALBEDO = c.rgb * tint * shade * n64_world_tint.rgb * n64_weather_tint.rgb;
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
}
