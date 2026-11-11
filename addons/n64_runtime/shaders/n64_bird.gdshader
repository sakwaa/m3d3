shader_type spatial;
// Small birds (BirdFlock): two dozen triangles each, drawn as one MultiMesh per flock. Wings
// flap and fold here, from the instance's custom data:
//   x = flap phase (radians), y = flap amount (0 glide .. 1 full beat), z = fold (0 spread,
//   1 tucked against the body, on the ground), w = shade variation (0..1).
// Mesh (BirdFlock.make_mesh): COLOR.r = face shade (top lit, underside darker), COLOR.g = part
// (0 body, 0.33 belly, 0.66 wings / tail / head, 1 beak), COLOR.a = 1 on wing vertices.
render_mode unshaded, cull_disabled, shadows_disabled;

#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"

uniform vec4 body_color : source_color = vec4(0.45, 0.36, 0.28, 1.0);
uniform vec4 belly_color : source_color = vec4(0.82, 0.76, 0.66, 1.0);
uniform vec4 wing_color : source_color = vec4(0.3, 0.24, 0.19, 1.0);
uniform vec4 beak_color : source_color = vec4(0.8, 0.62, 0.3, 1.0);

varying vec2 n64_fogv;
varying vec3 n64_fog_tintv;
varying vec3 col;

void vertex() {
	vec4 c = INSTANCE_CUSTOM;
	if (COLOR.a > 0.5) {
		float side = sign(VERTEX.x);
		float span = abs(VERTEX.x);
		float fold = c.z;
		vec3 v = VERTEX;
		// Tucked: drawn in along the body and back towards the tail.
		v.x = side * mix(span, span * 0.25, fold);
		v.z += fold * span * 0.55;
		v.y += fold * 0.012;
		// Beat: the wing turns about the body's long axis, a little above level at rest.
		float a = (sin(c.x) * 1.0 * c.y + 0.12) * (1.0 - fold) * side;
		VERTEX = vec3(v.x * cos(a) - v.y * sin(a), v.x * sin(a) + v.y * cos(a), v.z);
	}
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	n64_fogv = n64_fog_vertex(world);
	n64_fog_tintv = n64_fog_tint_vertex(world);
	vec3 part = COLOR.g < 0.16 ? body_color.rgb : COLOR.g < 0.5 ? belly_color.rgb : COLOR.g < 0.83 ? wing_color.rgb : beak_color.rgb;
	col = part * COLOR.r * mix(0.85, 1.1, c.w);
}

void fragment() {
	ALBEDO = col * n64_world_tint.rgb * n64_weather_tint.rgb;
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
}
