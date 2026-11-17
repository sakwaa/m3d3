shader_type spatial;
render_mode diffuse_lambert, specular_disabled, vertex_lighting;
// Characters / actors: lit by the scene's lights, flat colour (x optional texture), N64
// per-vertex fog. Writes stencil 1 so ProjectedShadow never darkens the actor itself.
stencil_mode write, compare_always, 1;
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_shine.gdshaderinc"
// Coverage code: object_id (stable ID: counted / outlined by N64VideoOut), 127 while faded.
#define N64_OBJECT_CODE n64_object_code_id(MODEL_MATRIX, object_id, fade)
#include "res://addons/n64_runtime/shaders/n64_coverage.gdshaderinc"

uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
// Modelled characters: vertex colour tints (rgb); an overlay texture shows through the
// painted mask (colour alpha).
uniform bool use_vertex_color = false;
uniform sampler2D overlay_texture : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
uniform bool has_overlay = false;
// Texture tile wrap per axis (the RDP's): 0 wrap, 1 mirror, 2 clamp.
uniform int wrap_s : hint_enum("Wrap", "Mirror", "Clamp") = 0;
uniform int wrap_t : hint_enum("Wrap", "Mirror", "Clamp") = 0;
// Palette texture (N64PaletteTexture): albedo_texture holds the indices, palette_lut the
// palettes; each instance picks its row (palette swaps).
uniform bool use_palette = false;
uniform sampler2D palette_lut : source_color, filter_nearest, repeat_disable, hint_default_white;
instance uniform int palette_row = 0;
// Lens of Truth (LensOfTruth sets these per instance): lens = screen centre (0..1),
// radius (share of screen height), strength (0 off). lens_mode 1: hidden, shown only inside
// the lens; 2: false (a fake wall), gone inside it. Faded by the RDP's dither: no sorting.
instance uniform vec4 lens = vec4(0.5, 0.5, 0.0, 0.0);
instance uniform int lens_mode = 0;
// Threshold dissolve (the RDP's alpha compare against a moving threshold, G_AC_THRESHOLD):
// `dissolve` 0 whole .. 1 gone, pixels dropped where the noise texture is under it, a glowing
// rim (dissolve_color) just ahead of the cut. Per instance (Actor.dissolve).
instance uniform float dissolve : hint_range(0.0, 1.0) = 0.0;
uniform float dissolve_scale = 3.0;
uniform vec4 dissolve_color : source_color = vec4(1.0, 0.55, 0.15, 1.0);
uniform float dissolve_rim = 0.06;
// Fog by primitive (G_RM_FOG_PRIM_A): one fog amount for the whole object (0..1; < 0 = the
// usual per-vertex fog) - silhouettes, things fading into the distance in a cutscene.
instance uniform float prim_fog = -1.0;
// Dithered fade (G_AC_DITHER): 1 solid .. 0 gone, pixels dropped by the magic square (or
// per-frame noise), per instance (Actor.fade). No sorting, keeps depth and coverage.
// Stable object ID for the video output (1..62; 0 = hashed from position).
instance uniform int object_id = 0;
instance uniform float fade : hint_range(0.0, 1.0) = 1.0;
uniform bool fade_noise = false;
varying N64_SHADE vec2 n64_fogv;
varying N64_SHADE vec3 n64_fog_tintv;

// Readability (DynamicSky sets both by the sun's height): `lift` = a share of the actor's own
// colour added back (rgb tint, a amount), so it never sinks below the baked level round it at
// night; `rim` = a sky-coloured edge on the silhouette (rgb, a strength), tinted by the
// actor's colour so it reads as light, not a glow.
global uniform vec4 n64_actor_lift;
global uniform vec4 n64_actor_rim;

void vertex() {
	VERTEX = n64_reflect_flatten(VERTEX, MODEL_MATRIX, CAMERA_POSITION_WORLD);
	n64_fogv = n64_fog_vertex((MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz);
	n64_fog_tintv = n64_fog_tint_vertex((MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz);
	n64_shine_v = n64_shine_vertex((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz, (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz, VIEW_MATRIX);
	N64_SNAP_MODEL;
}

void fragment() {
	float dis_glow = 0.0;
	if (dissolve > 0.0) {
		float nz = n64_value_noise(UV * dissolve_scale * 4.0) * 0.65 + n64_value_noise(UV * dissolve_scale * 11.0) * 0.35;
		if (nz < dissolve * 1.02) {
			discard;
		}
		dis_glow = 1.0 - smoothstep(dissolve, dissolve + dissolve_rim, nz);
	}
	if (lens_mode > 0) {
		vec2 sp = (FRAGCOORD.xy / VIEWPORT_SIZE - lens.xy) * vec2(VIEWPORT_SIZE.x / VIEWPORT_SIZE.y, 1.0);
		float inside = (1.0 - smoothstep(lens.z * 0.85, lens.z, length(sp))) * lens.w;
		float show = lens_mode == 1 ? inside : 1.0 - inside;
		if (!n64_alpha_dither(show, FRAGCOORD.xy, false, n64_time)) {
			discard;
		}
	}
	if (!n64_alpha_dither(fade, FRAGCOORD.xy, fade_noise, n64_time)) {
		discard;
	}
	ivec2 wrap = ivec2(wrap_s, wrap_t);
	vec3 albedo = albedo_color.rgb * (use_palette ? n64_texture_ci(albedo_texture, palette_lut, UV, palette_row, wrap)
		: n64_texture_wrap(albedo_texture, UV, wrap)).rgb;
	if (has_overlay) {
		albedo = mix(albedo, n64_texture_wrap(overlay_texture, UV, wrap).rgb, COLOR.a);
	}
	if (use_vertex_color) {
		albedo *= COLOR.rgb;
	}
	EMISSION = n64_shine(albedo, n64_shine_frag(n64_shine_v, VERTEX, VIEW_MATRIX));
	float edge = 1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	EMISSION += albedo * (n64_actor_lift.rgb * n64_actor_lift.a + n64_actor_rim.rgb * n64_actor_rim.a * edge * edge * edge);
	ALBEDO = albedo;
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
	if (prim_fog >= 0.0) {
		FOG = vec4(n64_fog_color.rgb, clamp(prim_fog, 0.0, 1.0));
	}
	EMISSION += dissolve_color.rgb * dis_glow * 2.0;
	N64_FOG_GAMMA;
	N64_COVERAGE_OBJECT;
}
