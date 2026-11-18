shader_type spatial;
render_mode diffuse_lambert, specular_disabled, vertex_lighting;
// General N64-look material for props, characters and doors: albedo texture x colour
// (x vertex colour), alpha cut-out, 3-point filtering via the project-wide toggle.
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_shine.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_lod_fade.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_combiner.gdshaderinc"
// Coverage code: object_id (stable ID: counted / outlined by N64VideoOut), 127 while faded.
#define N64_OBJECT_CODE n64_object_code_id(MODEL_MATRIX, object_id, fade)
#include "res://addons/n64_runtime/shaders/n64_coverage.gdshaderinc"

uniform sampler2D albedo_texture : source_color, filter_nearest_mipmap, repeat_enable;
uniform bool has_texture = true;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec2 uv_scale = vec2(1.0);
// Animated textures: UV repeats per second the texture slides (conveyors, waterfalls on
// props), and a flipbook (columns, rows, frames, fps; frames <= 1 = off).
uniform vec2 uv_scroll = vec2(0.0);
// Stepped tile offsets (repeats) for TEXEL0 / TEXEL1, as the games scrolled tiles a tick at a
// time (N64MaterialAnim sets these).
uniform vec2 uv_offset = vec2(0.0);
uniform vec2 texture1_offset = vec2(0.0);
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
// See-through drawn solid with dropped pixels (G_AC_DITHER): alpha (texture x colour x fade)
// against the magic square, or per-frame noise. Ghosts, glass, fading props.
uniform bool alpha_dither = false;
uniform bool fade_noise = false;
// Stable object ID for the video output (1..62; 0 = hashed from position).
instance uniform int object_id = 0;
instance uniform float fade : hint_range(0.0, 1.0) = 1.0;
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
// Close-up texture LOD: 0 off, 1 sharpen, 2 detail texture (detail = repeats per albedo
// repeat, strength).
uniform int lod_mode : hint_enum("Off", "Sharpen", "Detail", "Hi-res", "IHQ", "IHQ colour") = 0;
uniform sampler2D detail_texture : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
uniform vec2 detail = vec2(4.0, 0.0);
// Swap by distance (SM64's paintings: the mip level picks the picture): swap_texture shows
// as the albedo texture's mip level goes from swap_lod.x to .y (far: 1; near: swap_near).
uniform sampler2D swap_texture : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
uniform bool use_swap = false;
uniform vec2 swap_lod = vec2(0.5, 2.0);
uniform bool swap_near = false;
// --- Combiner tricks (Kaze, "3D Art is Math (on the N64)") ---
// Clamp cut-out: alpha = pattern x cut_scale + a per-vertex alpha, the pixel dropped under 0.5
// (the RDP's alpha compare after the combiner clamped): where the vertex alpha is 0.75 or
// more everything stays, where it's 0 only the pattern's brightest parts do. Vertex alpha:
// paint it (a sail torn only along its bottom: one texture, no second cut-out copy). Near
// player: it falls from 1 at cut_far to 0 at cut_near metres from the player, per vertex -
// things close to the player open up into the pattern (n64_see_through's position).
uniform int cut_mode : hint_enum("Off", "Vertex alpha", "Near player") = 0;
// The pattern: the texture's alpha, or a hexagon grid (bright centres) of hex_size per UV repeat.
uniform int cut_pattern : hint_enum("Texture alpha", "Hexagons") = 0;
uniform float cut_scale : hint_range(0.0, 1.0) = 0.75;
uniform float hex_size = 6.0;
uniform float cut_near = 1.0;
uniform float cut_far = 3.0;
// Texture alpha used as a second picture (IA textures: intensity + alpha are two images):
// Alpha (as usual), Reflect mask (where reflect_texture shows: a building's glass catching a
// starry sky), Glow mask (where glow_color is added unlit: lit windows, runes).
uniform int alpha_as : hint_enum("Alpha", "Reflect mask", "Glow mask") = 0;
uniform sampler2D reflect_texture : source_color, filter_nearest_mipmap, repeat_enable, hint_default_black;
// Reflection lookup: Env map (by the normal as seen from the camera, like the shine), Screen
// (fixed to the screen: a window onto somewhere else), World (fixed in the world, by xz).
uniform int reflect_space : hint_enum("Env map", "Screen", "World") = 0;
uniform float reflect_strength : hint_range(0.0, 2.0) = 0.6;
uniform vec2 reflect_scale = vec2(1.0);
uniform vec4 glow_color : source_color = vec4(1.0, 0.85, 0.5, 1.0);
// Push: the colour x push.rgb + push.a, through the combiner's overflow (push_wrap) or
// clamped - colours on the edge of overflowing (Kaze's coins: one grey texture, pushed until
// the light parts burn to full and the darks fall to nothing; wrap: past 1.5 they turn dark).
uniform vec4 push = vec4(1.0, 1.0, 1.0, 0.0);
uniform bool push_wrap = false;
// --- OoT / MM combiner (references/combiners/REPORT.md) ---
// On: the colour is made the way OoT and MM materials were - a base from the textures (cycle
// 1), then a tint (cycle 2), and an alpha source - instead of the tint / vertex colour
// options above. SHADE = the vertex colour (use_vertex_color; lighting comes on top as usual).
// Common setups: level / props SHADE*T0 x PRIM; Link's tunic parts SHADE*T0 x ENV; water and
// two-layer walls mix(T0, T1, k) x SHADE with k from ENV alpha; MM terrain T0*T1 x SHADE;
// shiny get-items contrast + texgen, then the ramp; MM swords lit-add + texgen.
uniform bool cc_on = false;
uniform int cc_base : hint_enum("SHADE*T0", "T0", "PRIM*T0", "PRIM*SHADE", "mix(T0,T1,k)", "T0*T1", "mix(ENV,PRIM,T0)", "(T0-PRIM)*k+T0", "(SHADE-ENV)*PRIM+T0", "(T1-PRIM)*k+T0") = 0;
uniform int cc_tint : hint_enum("Pass", "x PRIM", "x SHADE", "x ENV", "mix(ENV,PRIM,COMB)") = 1;
uniform int cc_alpha : hint_enum("T0", "1", "T0*PRIM", "PRIM", "ENV", "T0*ENV", "T0-k(1-T1)", "mix(T0,T1,k)", "k*T1+T0") = 0;
uniform vec4 cc_prim : source_color = vec4(1.0);
uniform vec4 cc_env : source_color = vec4(0.0, 0.0, 0.0, 1.0);
// k: a value (their PRIM_LOD_FRAC), the environment colour's alpha (what scenes animated for
// water), or the texture's mip fraction (the RDP's own LOD_FRACTION: near T0, far T1).
uniform float cc_k : hint_range(0.0, 1.0) = 0.5;
uniform int cc_k_from : hint_enum("Value", "ENV alpha", "Mip fraction") = 0;
// TEXEL1: the second texture, its own scale and scroll (repeats per second).
uniform sampler2D texture1 : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
uniform vec2 texture1_scale = vec2(1.0);
uniform vec2 texture1_scroll = vec2(0.0);
// TEXEL0 looked up by texgen (G_TEXTURE_GEN: by the normal as the camera sees it, per vertex).
uniform bool cc_texgen = false;
varying N64_SHADE float n64_cutv;  // the per-vertex alpha (clamp cut-out)
varying vec3 n64_worldv;

// Hexagon grid: 1 at each hex's centre .. 0 at its edge (`p` in hexes).
float n64_hex_pattern(vec2 p) {
	const vec2 r = vec2(1.0, 1.7320508);
	vec2 h = r * 0.5;
	vec2 a = mod(p, r) - h;
	vec2 b = mod(p - h, r) - h;
	vec2 g = dot(a, a) < dot(b, b) ? a : b;
	g = abs(g);
	float d = max(dot(g, normalize(r)), g.x);  // 0 centre .. 0.5 edge
	return clamp(1.0 - d * 2.0, 0.0, 1.0);
}

varying N64_SHADE vec2 n64_fogv;
varying N64_SHADE vec4 n64_colv;  // COLOR, affine
varying N64_SHADE vec3 n64_fog_tintv;

void vertex() {
	n64_colv = COLOR;
	n64_worldv = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	n64_cutv = 1.0;
	if (cut_mode == 1) {
		n64_cutv = COLOR.a;
	} else if (cut_mode == 2 && n64_see_through.w > 0.0) {
		n64_cutv = smoothstep(cut_near, cut_far, distance(n64_worldv, n64_see_through.xyz));
	}
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
	n64_lod_dither(CAMERA_POSITION_WORLD, MODEL_MATRIX, FRAGCOORD.xy);
	if (!IN_SHADOW_PASS) {
		n64_see_through_dither((INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz, CAMERA_POSITION_WORLD, FRAGCOORD.xy);  // (the sun's view: no holes)
	}
	vec4 c = albedo_color;
	float tex_a = 1.0;
	vec2 tex_uv = UV * uv_scale;
	vec4 t0s = vec4(1.0);
	if (has_texture) {
		float time = n64_time;
		vec2 uv = (cc_on && cc_texgen ? n64_shine_frag(n64_shine_v, VERTEX, VIEW_MATRIX).xy : UV) * uv_scale + uv_scroll * time + uv_offset;
		ivec2 wrap = ivec2(wrap_s, wrap_t);
		vec4 t = use_palette ? n64_texture_ci(albedo_texture, palette_lut, uv, palette_row, wrap)
			: flip.z > 1.5 ? n64_texture_frame(albedo_texture, uv, flip, time)
			: wrap != ivec2(0) ? n64_texture_wrap(albedo_texture, uv, wrap)
			: n64_texture_tiled(albedo_texture, uv, anti_tiling);
		if (use_swap) {
			float k = smoothstep(swap_lod.x, swap_lod.y, n64_lod(albedo_texture, uv));
			t = mix(t, n64_texture(swap_texture, uv), swap_near ? 1.0 - k : k);
		}
		if (lod_mode > 0 && !use_palette) {
			t = n64_lod_detail(t, albedo_texture, uv, lod_mode == 1 && anti_tiling.x > 0.5 ? 0 : lod_mode, detail_texture, uv * detail.x, detail.y);
		}
		tex_a = t.a;
		tex_uv = uv;
		t0s = t;
		if (!cc_on) c *= vec4(n64_tint(t.rgb, tint_mode, tint_dark, tint_light, tint_extra), alpha_as == 0 ? t.a : 1.0);
	}
	if (cc_on) {
		vec4 shade = use_vertex_color ? n64_colv : vec4(1.0);
		vec4 t1 = n64_texture(texture1, UV * texture1_scale + texture1_scroll * n64_time + texture1_offset);
		float k = cc_k_from == 1 ? cc_env.a : cc_k_from == 2 && has_texture ? clamp(n64_lod(albedo_texture, tex_uv), 0.0, 1.0) : cc_k;
		vec3 base = clamp(n64_cc_base(cc_base, t0s, t1, shade, cc_prim, cc_env, k), 0.0, 1.0);
		float a = clamp(n64_cc_alpha(cc_alpha, t0s, t1, cc_prim, cc_env, k), 0.0, 1.0);
		c = albedo_color * vec4(clamp(n64_cc_tint(cc_tint, base, shade, cc_prim, cc_env), 0.0, 1.0), a);
	} else if (use_vertex_color) {
		c *= n64_colv;
	}
	if (vertex_ao_in_alpha) {
		c.rgb *= mix(1.0, n64_colv.a, n64_vertex_ao);
	}
	if (!n64_alpha_dither(fade * (alpha_dither ? c.a : 1.0), FRAGCOORD.xy, fade_noise, n64_time)) {
		discard;
	}
	if (cut_mode > 0 && !(cut_mode == 2 && IN_SHADOW_PASS)) {
		float pattern = cut_pattern == 1 ? n64_hex_pattern(UV * uv_scale * hex_size) : tex_a;
		// (TEXEL0 alpha x PRIM alpha + SHADE alpha, clamped, then the alpha compare)
		if (clamp(pattern * cut_scale + n64_cutv, 0.0, 1.0) < 0.5) {
			discard;
		}
	}
	vec3 albedo = c.rgb;
	if (push != vec4(1.0, 1.0, 1.0, 0.0)) {
		vec3 v = albedo * push.rgb + push.a;
		albedo = push_wrap ? n64_cc_overflow3(v) : clamp(v, 0.0, 1.0);
	}
	EMISSION = n64_shine(albedo, n64_shine_frag(n64_shine_v, VERTEX, VIEW_MATRIX));
	if (alpha_as == 1) {
		vec2 ruv = reflect_space == 0 ? n64_shine_frag(n64_shine_v, VERTEX, VIEW_MATRIX).xy
			: reflect_space == 1 ? FRAGCOORD.xy / VIEWPORT_SIZE.y
			: n64_worldv.xz * 0.1;
		// (TEXEL0 alpha x TEXEL1 x ENV + the base: added on top, unlit)
		EMISSION += n64_texture(reflect_texture, ruv * reflect_scale).rgb * tex_a * reflect_strength;
	} else if (alpha_as == 2) {
		EMISSION += glow_color.rgb * glow_color.a * tex_a;
	}
	ALBEDO = albedo;
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
	if (prim_fog >= 0.0) {
		FOG = vec4(n64_fog_color.rgb, clamp(prim_fog, 0.0, 1.0));
	}
	EMISSION += dissolve_color.rgb * dis_glow * 2.0;
	if (cutout) {
		ALPHA = c.a;
		ALPHA_SCISSOR_THRESHOLD = alpha_cutoff;
	}
	N64_FOG_GAMMA;
	N64_COVERAGE_OBJECT_CUTOUT;
}
