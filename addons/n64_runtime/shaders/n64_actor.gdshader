shader_type spatial;
render_mode diffuse_lambert, specular_disabled;
// Characters / actors: lit by the scene's lights, flat colour (x optional texture), N64
// per-vertex fog. Writes stencil 1 so ProjectedShadow never darkens the actor itself.
stencil_mode write, compare_always, 1;
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_shine.gdshaderinc"

uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
// Modelled characters: vertex colour tints (rgb); an overlay texture shows through the
// painted mask (colour alpha).
uniform bool use_vertex_color = false;
uniform sampler2D overlay_texture : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
uniform bool has_overlay = false;
varying vec2 n64_fogv;
varying vec3 n64_fog_tintv;

void vertex() {
	VERTEX = n64_reflect_flatten(VERTEX, MODEL_MATRIX, CAMERA_POSITION_WORLD);
	n64_fogv = n64_fog_vertex((MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz);
	n64_fog_tintv = n64_fog_tint_vertex((MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz);
	n64_shine_v = n64_shine_vertex((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz, (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz, VIEW_MATRIX);
}

void fragment() {
	vec3 albedo = albedo_color.rgb * n64_texture(albedo_texture, UV).rgb;
	if (has_overlay) {
		albedo = mix(albedo, n64_texture(overlay_texture, UV).rgb, COLOR.a);
	}
	if (use_vertex_color) {
		albedo *= COLOR.rgb;
	}
	EMISSION = n64_shine(albedo, n64_shine_v);
	ALBEDO = albedo;
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
}
