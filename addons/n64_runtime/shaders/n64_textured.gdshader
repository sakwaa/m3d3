shader_type spatial;
render_mode diffuse_lambert, specular_disabled;
// General N64-look material for props, characters and doors: albedo texture x colour
// (x vertex colour), alpha cut-out, 3-point filtering via the project-wide toggle.
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_shine.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_lod_fade.gdshaderinc"

uniform sampler2D albedo_texture : source_color, filter_nearest_mipmap, repeat_enable;
uniform bool has_texture = true;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec2 uv_scale = vec2(1.0);
// Animated textures: UV repeats per second the texture slides (conveyors, waterfalls on
// props), and a flipbook (columns, rows, frames, fps; frames <= 1 = off).
uniform vec2 uv_scroll = vec2(0.0);
uniform vec4 flip = vec4(1.0, 1.0, 1.0, 0.0);
// Anti-tiling: x = 0 off / 1 offset / 2 offset+rotate, y = hex size in repeats.
uniform vec2 anti_tiling = vec2(0.0, 0.75);
// Combiner tint: 0 none / 1 multiply (by tint_light) / 2 gradient (tint_dark -> tint_light).
uniform float tint_mode = 0.0;
uniform vec3 tint_dark : source_color = vec3(0.2);
uniform vec3 tint_light : source_color = vec3(1.0);
// x = amount (0 original .. 1 full tint), yz = luminance range mapped to the gradient.
uniform vec3 tint_extra = vec3(1.0, 0.0, 1.0);
uniform bool use_vertex_color = false;
// Baked AO in the vertex colour alpha (door / passage dressing); hideable in the editor.
uniform bool vertex_ao_in_alpha = false;
uniform float alpha_cutoff : hint_range(0.0, 1.0) = 0.5;
uniform bool cutout = false;
varying vec2 n64_fogv;
varying vec3 n64_fog_tintv;

void vertex() {
	VERTEX = n64_reflect_flatten(VERTEX, MODEL_MATRIX, CAMERA_POSITION_WORLD);
	n64_fogv = n64_fog_vertex((MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz);
	n64_fog_tintv = n64_fog_tint_vertex((MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz);
	n64_shine_v = n64_shine_vertex((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz, (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz, VIEW_MATRIX);
}

void fragment() {
	n64_lod_dither(CAMERA_POSITION_WORLD, MODEL_MATRIX, FRAGCOORD.xy);
	vec4 c = albedo_color;
	if (has_texture) {
		float time = n64_time;
		vec2 uv = UV * uv_scale + uv_scroll * time;
		vec4 t = flip.z > 1.5 ? n64_texture_frame(albedo_texture, uv, flip, time) : n64_texture_tiled(albedo_texture, uv, anti_tiling);
		c *= vec4(n64_tint(t.rgb, tint_mode, tint_dark, tint_light, tint_extra), t.a);
	}
	if (use_vertex_color) {
		c *= COLOR;
	}
	if (vertex_ao_in_alpha) {
		c.rgb *= mix(1.0, COLOR.a, n64_vertex_ao);
	}
	vec3 albedo = c.rgb;
	EMISSION = n64_shine(albedo, n64_shine_v);
	ALBEDO = albedo;
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
	if (cutout) {
		ALPHA = c.a;
		ALPHA_SCISSOR_THRESHOLD = alpha_cutoff;
	}
}
