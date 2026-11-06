shader_type spatial;
render_mode unshaded, cull_back;
// Self-lit props (lantern paper, lit windows, embers): vertex colour x albedo colour (x an
// optional texture), never shaded by the level's light, with the N64 fog.
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"

uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, filter_nearest_mipmap, repeat_enable;
uniform bool has_texture = false;
varying vec2 n64_fogv;
varying vec3 n64_fog_tintv;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	n64_fogv = n64_fog_vertex(world);
	n64_fog_tintv = n64_fog_tint_vertex(world);
}

void fragment() {
	vec4 c = COLOR * albedo_color;
	if (has_texture) {
		c *= n64_texture(albedo_texture, UV);
	}
	ALBEDO = c.rgb;
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
}
