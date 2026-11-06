shader_type spatial;
render_mode unshaded, cull_disabled, skip_vertex_transform;
// Scattered cut-outs on levels (flowers, grass tufts): MultiMesh instances of a quad,
// N64 style: texture with 1-bit alpha, 3-point filtering, lit by the day / night and
// weather tints (like the unshaded baked levels), fogged like the level. Billboard
// quads turn around Y to face the camera; others keep their instance rotation (crossed
// quads, flat heads on the ground). Instance colour = per-instance brightness variation.
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"

uniform sampler2D tex : source_color, filter_nearest_mipmap, repeat_disable;
uniform bool billboard = false;
// Overall brightness (sits the cut-outs into the ground's shading).
uniform float shade = 0.9;
// The cut-out's outer ring of texels (opaque, next to a transparent one): 0 as is,
// 1 darkened by edge_dark (a contact shadow outline, like the Height blend's), 2 trimmed
// (the ground shows through; hides a pale fringe left from the photo's background).
uniform int edge_mode = 1;
uniform float edge_dark = 0.55;

varying vec2 n64_fogv;
varying vec3 n64_fog_tintv;
varying vec3 tint;

void vertex() {
	vec3 world;
	if (billboard) {
		vec3 origin = MODEL_MATRIX[3].xyz;
		vec2 size = vec2(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz));
		vec3 to_cam = INV_VIEW_MATRIX[3].xyz - origin;
		to_cam.y = 0.0;
		vec3 right = length(to_cam) > 0.0001 ? normalize(vec3(to_cam.z, 0.0, -to_cam.x)) : vec3(1.0, 0.0, 0.0);
		world = origin + right * VERTEX.x * size.x + vec3(0.0, 1.0, 0.0) * VERTEX.y * size.y;
	} else {
		world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	}
	n64_fogv = n64_fog_vertex(world);
	n64_fog_tintv = n64_fog_tint_vertex(world);
	tint = COLOR.rgb;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
}

// Whether the texel at `uv` is on the cut-out's edge.
bool cutout_edge(vec2 uv) {
	ivec2 size = textureSize(tex, 0);
	ivec2 p = clamp(ivec2(uv * vec2(size)), ivec2(0), size - 1);
	if (texelFetch(tex, p, 0).a < 0.5) {
		return false;
	}
	for (int i = 0; i < 4; i++) {
		ivec2 q = p + ivec2(i == 0 ? 1 : (i == 1 ? -1 : 0), i == 2 ? 1 : (i == 3 ? -1 : 0));
		if (q.x < 0 || q.y < 0 || q.x >= size.x || q.y >= size.y || texelFetch(tex, q, 0).a < 0.5) {
			return true;
		}
	}
	return false;
}

void fragment() {
	vec4 c = n64_texture(tex, UV);
	if (edge_mode > 0 && cutout_edge(UV)) {
		if (edge_mode == 2) {
			discard;
		}
		c.rgb *= edge_dark;
	}
	ALBEDO = c.rgb * tint * shade * n64_world_tint.rgb * n64_weather_tint.rgb;
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
}
