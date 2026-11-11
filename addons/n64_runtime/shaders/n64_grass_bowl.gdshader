shader_type spatial;
render_mode unshaded, cull_disabled, skip_vertex_transform;
// Where an actor stands in a grass carpet (GrassWake): a small round divot in the carpet
// round its legs. A shallow bowl, its rim at the carpet's top, lined with the carpet's
// texture, light as the carpet at the rim and darker going in to its middle (both sides
// drawn: from low down its near half faces away and would let the feet show). Opaque, depth tested: the legs
// stand in it. The carpet leaves a hole over it (n64_divot, n64_grass_mat).
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"

uniform sampler2D tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform vec4 color : source_color = vec4(1.0);
// Metres one repeat of the texture covers (the carpet's tile).
uniform float tile = 1.5;
// Shade at the rim (as the carpet) and in the middle: light to dark going in.
uniform float rim_shade = 1.0;
uniform float floor_shade = 0.4;

varying vec2 n64_fogv;
varying vec3 n64_fog_tintv;
varying vec2 world_xz;
varying float radius_v;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	n64_fogv = n64_fog_vertex(world);
	n64_fog_tintv = n64_fog_tint_vertex(world);
	world_xz = world.xz;  // (laid from above like the carpet's: the divot is shallow)
	radius_v = length(VERTEX.xz);  // (1 at the rim)
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
}

void fragment() {
	vec4 c = n64_texture(tex, world_xz / tile);
	float shade = mix(floor_shade, rim_shade, smoothstep(0.0, 1.0, radius_v));
	ALBEDO = c.rgb * color.rgb * shade * n64_world_tint.rgb * n64_weather_tint.rgb;
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
}
