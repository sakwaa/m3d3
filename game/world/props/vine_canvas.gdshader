shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, skip_vertex_transform;
// VineCanvas display: the vines the compute shader grew into `canvas`, shown where the
// growth front has passed (`reach` <= grow, texels from the source) - grow and shrink cost
// one number - with their shadow on the surface under them (the vines' outline a few texels
// away from the sun, see-through dark). World tints and fog like the level.
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"

uniform sampler2D canvas : source_color, filter_nearest, repeat_disable;
uniform sampler2D reach : filter_nearest, repeat_disable;
// Texels from the source the growth has reached (shown up to here).
uniform float grow = 1e9;
// Where the shadow falls (texture space, texels) and how dark.
uniform vec2 shadow_offset = vec2(3.0, 4.0);
uniform float shadow = 0.5;
uniform vec2 texels = vec2(512.0, 256.0);

varying N64_SHADE vec2 n64_fogv;
varying N64_SHADE vec3 n64_fog_tintv;

bool shown(vec2 uv) {
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
		return false;
	}
	float r = texture(reach, uv).r;
	return texture(canvas, uv).a > 0.5 && r > 0.0 && r <= grow;
}

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	n64_fogv = n64_fog_vertex(world);
	n64_fog_tintv = n64_fog_tint_vertex(world);
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	N64_SNAP_VIEW;
}

void fragment() {
	vec4 c = texture(canvas, UV);
	if (shown(UV)) {
		ALBEDO = c.rgb * n64_world_tint.rgb * n64_weather_tint.rgb;
		ALPHA = 1.0;
	} else {
		// (the shadow: soft from four taps round the offset)
		vec2 o = shadow_offset / texels;
		vec2 px = 1.0 / texels;
		float s = (float(shown(UV - o)) + float(shown(UV - o + vec2(px.x, 0.0))) + float(shown(UV - o + vec2(0.0, px.y)))
			+ float(shown(UV - o - px))) * 0.25;
		if (s <= 0.0) {
			discard;
		}
		ALBEDO = vec3(0.04, 0.05, 0.03);
		ALPHA = s * shadow;
	}
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
	N64_FOG_GAMMA;
}
