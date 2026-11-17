shader_type spatial;
render_mode unshaded, cull_disabled, skip_vertex_transform;
// Generated trees (TreeBuilder), N64 style like the baked level: unshaded, the lighting
// baked into the vertex colours (leaf cards shaded as one soft crown, not card by card),
// 3-point filtering, 1-bit alpha on the leaves, lit by the day / night and weather tints
// and fogged like the level. Vertex alpha = how much the vertex sways in the wind (0 at
// the trunk's foot, 1 out at the leaves).
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_wind.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_coverage.gdshaderinc"

uniform sampler2D tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform bool cutout = false;
uniform vec4 color : source_color = vec4(1.0);
uniform float shade = 1.0;
// Sway (metres at full weight in a strength-1 wind) and how fast; the wind itself is the
// shared n64_wind (direction, strength, gusts: zone x weather).
uniform float wind = 0.3;
uniform float wind_speed = 1.3;

varying N64_SHADE vec2 n64_fogv;
varying N64_SHADE vec3 n64_fog_tintv;
varying N64_SHADE vec3 tint;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float w = COLOR.a;
	if (w > 0.0 && wind > 0.0 && n64_wind.z > 0.0) {
		vec3 base = MODEL_MATRIX[3].xyz;
		vec2 dir = n64_wind.xy;
		float t = TIME * wind_speed * (0.6 + n64_wind.z);
		// The shared gust field at the trunk (the gust that just crossed the grass), plus a
		// little across the crown so a big tree's far side lags.
		float gust = n64_wind_push(base.xz + (world.xz - base.xz) * 0.5);
		float sway = sin(t + base.x * 0.21 + base.z * 0.17) * 0.6 + sin(t * 2.3 + world.y * 0.4) * 0.25;
		float flutter = sin(TIME * 5.0 + world.x * 3.1 + world.z * 2.7) * 0.2;
		vec2 side = vec2(-dir.y, dir.x);
		world.xz += (dir * (0.6 + sway) * gust + side * flutter) * wind * n64_wind.z * w;
	}
	n64_fogv = n64_fog_vertex(world);
	n64_fog_tintv = n64_fog_tint_vertex(world);
	tint = COLOR.rgb;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	N64_SNAP_VIEW;
}

void fragment() {
	vec4 c = n64_texture(tex, UV);
	ALBEDO = c.rgb * color.rgb * tint * shade * n64_world_tint.rgb * n64_weather_tint.rgb;
	// Cut-outs: the RDP's alpha compare (discard; not ALPHA + scissor - with MSAA that path
	// broke the coverage tag: trees came out white).
	if (cutout && c.a < 0.5) {
		discard;
	}
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
	N64_FOG_GAMMA;
	// The RDP's texture-edge mode (G_RM_AA_TEX_EDGE): coverage x texel alpha, so the leaves'
	// cut edges get partial coverage and the VI blend softens them; solid parts are objects.
	if (cutout) {
		COVERAGE_TEXEDGE;
	} else {
		N64_COVERAGE_OBJECT;
	}
}
