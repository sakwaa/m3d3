// N64 effect sprites (EffectEmitter): one MultiMesh of quads per emitter, simulated in
// script. Per instance: transform (world position, size; flat sprites also their facing),
// COLOR (colour x alpha over life), INSTANCE_CUSTOM.x = flipbook frame, .y = spin (radians,
// camera-facing sprites only). Flat colour (unshaded), 3-point filtered, N64 fog.
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"

uniform sampler2D sprite : source_color, filter_nearest_mipmap, repeat_disable;
// Flipbook grid: columns, rows.
uniform vec2 grid = vec2(1.0);
uniform bool billboard = true;
varying vec2 n64_fogv;
varying vec3 n64_fog_tintv;
varying float frame;

void vertex() {
	frame = INSTANCE_CUSTOM.x;
	vec3 world = MODEL_MATRIX[3].xyz;
	if (billboard) {
		float spin = INSTANCE_CUSTOM.y;
		VERTEX.xy = mat2(vec2(cos(spin), sin(spin)), vec2(-sin(spin), cos(spin))) * VERTEX.xy;
		float size = length(MODEL_MATRIX[0].xyz);
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * size, INV_VIEW_MATRIX[1] * size, INV_VIEW_MATRIX[2] * size, MODEL_MATRIX[3]);
	} else {
		world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	}
	n64_fogv = n64_fog_vertex(world);
	n64_fog_tintv = n64_fog_tint_vertex(world);
}

vec4 effect_color(vec2 uv, vec4 tint) {
	vec2 g = max(grid, vec2(1.0));
	float f = floor(frame + 0.5);
	vec2 cell = vec2(mod(f, g.x), floor(f / g.x));
	vec2 px = vec2(textureSize(sprite, 0)) / g;
	vec2 inside = clamp(uv, 0.5 / px, 1.0 - 0.5 / px);
	return n64_texture(sprite, (inside + cell) / g) * tint;
}
