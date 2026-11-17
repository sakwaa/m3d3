shader_type spatial;
render_mode unshaded, cull_disabled, skip_vertex_transform;
// Creeping vines (WorldVines), N64 style like the trees (n64_tree): unshaded, lighting
// baked into the vertex colours, 3-point filtering, 1-bit alpha leaves, world tints and fog.
// Growth: each vertex carries when the vine reaches it (CUSTOM0.w, 0 at the roots .. 1 at
// the last tip) and the point it grows out of (CUSTOM0.xyz, local: a ring's centre on the
// stem, a leaf's stalk). `grow` (per instance) reveals the vine up to there: past it the
// vertex sits on its point (no area: hidden), and just behind it it's part way out, so the
// tip tapers in and leaves unfold as the vine passes. Growing costs one number a frame.
// Vertex alpha = wind sway weight (leaves only; the stems hug their surface).
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_wind.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_coverage.gdshaderinc"

uniform sampler2D tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform bool cutout = false;
uniform vec4 color : source_color = vec4(1.0);
uniform float shade = 1.0;
uniform float wind = 0.06;
uniform float wind_speed = 1.6;
// How much of the growth (0..1 of the whole) a part takes to come fully out.
uniform float grow_soft = 0.04;

// 0 = nothing yet, 1 = fully grown.
instance uniform float grow = 1.0;

varying N64_SHADE vec2 n64_fogv;
varying N64_SHADE vec3 n64_fog_tintv;
varying N64_SHADE vec3 tint;

void vertex() {
	float k = clamp((grow - CUSTOM0.w) / grow_soft, 0.0, 1.0);
	vec3 local = mix(CUSTOM0.xyz, VERTEX, k);
	vec3 world = (MODEL_MATRIX * vec4(local, 1.0)).xyz;
	float w = COLOR.a;
	if (w > 0.0 && wind > 0.0 && n64_wind.z > 0.0) {
		float gust = n64_wind_push(world.xz);
		float flutter = sin(TIME * 4.0 * wind_speed + world.x * 3.1 + world.z * 2.7 + world.y * 1.3);
		world += vec3(n64_wind.x, 0.4, n64_wind.y) * (gust * 0.6 + flutter * 0.4) * wind * n64_wind.z * w;
	}
	n64_fogv = n64_fog_vertex(world);
	n64_fog_tintv = n64_fog_tint_vertex(world);
	tint = COLOR.rgb;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	N64_SNAP_VIEW;
}

void fragment() {
	// (one-triangle leaves reach past the texture: nothing out there)
	if (cutout && (UV.x < 0.0 || UV.x > 1.0 || UV.y < 0.0)) {
		discard;
	}
	vec4 c = n64_texture(tex, UV);
	ALBEDO = c.rgb * color.rgb * tint * shade * n64_world_tint.rgb * n64_weather_tint.rgb;
	if (cutout && c.a < 0.5) {
		discard;
	}
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
	N64_FOG_GAMMA;
	if (cutout) {
		COVERAGE_TEXEDGE;
	} else {
		N64_COVERAGE_OBJECT;
	}
}
