shader_type spatial;
render_mode unshaded, cull_disabled, skip_vertex_transform, shadows_disabled;
// String light bulbs (StringLights): a round billboard per bulb (VERTEX = its centre, UV =
// the corner, -1..1). By day pale glass in the scene's light; lit (glow 1) a hot core
// fading to the bulb's colour at its rim.
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"

uniform vec4 color : source_color = vec4(1.0, 0.75, 0.4, 1.0);
uniform float radius = 0.045;
uniform float glow = 0.0;

varying vec2 n64_fogv;
varying vec3 n64_fog_tintv;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	n64_fogv = n64_fog_vertex(world);
	n64_fog_tintv = n64_fog_tint_vertex(world);
	vec4 c = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	VERTEX = c.xyz + vec3(UV * radius, 0.0);
	NORMAL = vec3(0.0, 0.0, 1.0);
}

void fragment() {
	float r = length(UV);
	if (r > 1.0) {
		discard;
	}
	vec3 glass = vec3(0.86, 0.84, 0.78) * n64_world_tint.rgb * n64_weather_tint.rgb;
	vec3 hot = mix(color.rgb, vec3(1.0, 0.96, 0.86), smoothstep(0.7, 0.0, r));
	ALBEDO = mix(glass, hot, clamp(glow, 0.0, 1.0));
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
}
