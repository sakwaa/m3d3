// The N64's colour combiner and blender, for writing effects with the RDP's own recipes.
//
// Combiner: each cycle computes (A - B) * C + D, separately for colour (rgb) and alpha, from
// inputs the RDP had at the pixel: TEXEL0 / TEXEL1 (the two textures), SHADE (vertex colour /
// lighting), PRIMITIVE and ENVIRONMENT (two constant colours per draw: uniforms here), NOISE
// (per-pixel random), LOD_FRACTION (the mip blend), constants 0 and 1. Two-cycle mode feeds
// cycle 1's result in as COMBINED to cycle 2 (e.g. blend two textures, then light the result).
// Libultra's names for the common modes are given as functions below (G_CC_*), so a recipe
// from a decomp or the N64 SDK reads one to one:
//   vec4 c = n64_cc_modulate_rgba(n64_texture(tex, UV), SHADE);           // G_CC_MODULATERGBA
//   vec4 c = n64_cc2(n64_cc_trilerp(t0, t1, lod), shade, ...);           // two-cycle
// Blender (after the combiner): (P * A + M * B) / (A + B), mixing the combined colour with
// the framebuffer, fog or blend colour - here n64_blend() for in-shader use (fog, blend
// colour); framebuffer blending is the material's blend mode.

// --- One cycle ------------------------------------------------------------------------

// (A - B) * C + D on colour and alpha separately (each its own inputs, as the RDP).
vec4 n64_cc(vec3 a, vec3 b, vec3 c, vec3 d, float aa, float ab, float ac, float ad) {
	return vec4((a - b) * c + d, (aa - ab) * ac + ad);
}

// The same with all four as vec4 (colour and alpha from the same inputs).
vec4 n64_cc4(vec4 a, vec4 b, vec4 c, vec4 d) {
	return (a - b) * c + d;
}

// The RDP's per-pixel NOISE input (changes each frame with `time`).
float n64_cc_noise(vec2 frag, float time) {
	return fract(sin(dot(floor(frag) + floor(time * 60.0) * vec2(0.37, 0.71), vec2(12.9898, 78.233))) * 43758.5453);
}

// --- Libultra's modes (gbi.h G_CC_*) ----------------------------------------------------
// Inputs: tex = TEXEL0, shade = SHADE, prim = PRIMITIVE, env = ENVIRONMENT.

// G_CC_PRIMITIVE: flat primitive colour.
vec4 n64_cc_primitive(vec4 prim) { return prim; }
// G_CC_SHADE: vertex colour only.
vec4 n64_cc_shade(vec4 shade) { return shade; }
// G_CC_DECALRGB / G_CC_DECALRGBA: the texture as is.
vec4 n64_cc_decal_rgba(vec4 tex) { return tex; }
// G_CC_MODULATERGB: texture x shade (colour), shade alpha.
vec4 n64_cc_modulate_rgb(vec4 tex, vec4 shade) { return vec4(tex.rgb * shade.rgb, shade.a); }
// G_CC_MODULATERGBA: texture x shade, colour and alpha.
vec4 n64_cc_modulate_rgba(vec4 tex, vec4 shade) { return tex * shade; }
// G_CC_MODULATEIDECALA: texture x shade colour, texture alpha (lit cut-outs).
vec4 n64_cc_modulate_i_decal_a(vec4 tex, vec4 shade) { return vec4(tex.rgb * shade.rgb, tex.a); }
// G_CC_MODULATERGB_PRIM / G_CC_MODULATERGBA_PRIM: texture x primitive.
vec4 n64_cc_modulate_prim(vec4 tex, vec4 prim) { return tex * prim; }
// G_CC_BLENDPE: texture's intensity picks between environment (0) and primitive (1) - the
// classic two-colour tinted effect (fire, magic): lerp(env, prim, tex).
vec4 n64_cc_blend_pe(vec4 tex, vec4 prim, vec4 env) {
	return n64_cc(prim.rgb, env.rgb, tex.rgb, env.rgb, prim.a, env.a, tex.a, env.a);
}
// G_CC_BLENDPEDECALA: as BLENDPE, the texture's own alpha.
vec4 n64_cc_blend_pe_decal_a(vec4 tex, vec4 prim, vec4 env) {
	return vec4((prim.rgb - env.rgb) * tex.rgb + env.rgb, tex.a);
}
// G_CC_BLENDPRIMDECALA-style highlight: (prim - shade) * tex + shade (shade, lit up by the
// texture towards prim).
vec4 n64_cc_blend_prim_shade(vec4 tex, vec4 prim, vec4 shade) {
	return vec4((prim.rgb - shade.rgb) * tex.rgb + shade.rgb, shade.a);
}
// G_CC_TRILERP: two textures blended by the LOD fraction (the N64's mip blend).
vec4 n64_cc_trilerp(vec4 tex0, vec4 tex1, float lod_frac) {
	return (tex1 - tex0) * lod_frac + tex0;
}
// G_CC_INTERFERENCE: texture x texture1 (two-texture modulate: e.g. a scrolling noise mask).
vec4 n64_cc_interference(vec4 tex0, vec4 tex1) { return tex0 * tex1; }
// G_CC_HILITERGB: (prim - shade) * tex + shade, alpha shade (specular-style highlights).
vec4 n64_cc_hilite_rgb(vec4 tex, vec4 prim, vec4 shade) {
	return vec4((prim.rgb - shade.rgb) * tex.rgb + shade.rgb, shade.a);
}
// Second cycle, G_CC_MODULATERGB2 / G_CC_MODULATERGBA2: the first cycle's COMBINED x shade.
vec4 n64_cc2_modulate_rgba(vec4 combined, vec4 shade) { return combined * shade; }
// Second cycle, G_CC_PASS2: the first cycle's result unchanged.
vec4 n64_cc2_pass(vec4 combined) { return combined; }

// --- OoT / MM material recipes (references/combiners/REPORT.md) -----------------------
// Their materials are nearly all "base, then tint": cycle 1 makes a base from the textures,
// cycle 2 tints it (x PRIM in 70 % of asset materials) - two cycles mostly so the blender
// can fog in cycle 1. These pick the forms that cover ~95 % of both games' materials.
// Inputs: t0 / t1 the two textures, shade the vertex colour, prim / env the two constant
// colours, k a blend scalar (their PRIM_LOD_FRAC, ENV alpha or the true LOD fraction).

// Cycle-1 bases (rgb):
//  0 SHADE*T0 (71 %)              1 T0                         2 PRIM*T0
//  3 PRIM*SHADE (untextured)      4 mix(T0, T1, k) (water, MM rooms)
//  5 T0*T1 (base x detail: MM terrain)                          6 mix(ENV, PRIM, T0) (ramp)
//  7 (T0 - PRIM)*k + T0 (contrast about a pivot: shiny get-items, the warp crystal)
//  8 (SHADE - ENV)*PRIM + T0 (MM's metal swords: light added onto an env-mapped texture)
//  9 (T1 - PRIM)*k + T0 (signed detail: Din's Fire, arrows, songs, warps)
vec3 n64_cc_base(int mode, vec4 t0, vec4 t1, vec4 shade, vec4 prim, vec4 env, float k) {
	switch (mode) {
		case 1: return t0.rgb;
		case 2: return prim.rgb * t0.rgb;
		case 3: return prim.rgb * shade.rgb;
		case 4: return mix(t0.rgb, t1.rgb, k);
		case 5: return t0.rgb * t1.rgb;
		case 6: return mix(env.rgb, prim.rgb, t0.rgb);
		case 7: return (t0.rgb - prim.rgb) * k + t0.rgb;
		case 8: return (shade.rgb - env.rgb) * prim.rgb + t0.rgb;
		case 9: return (t1.rgb - prim.rgb) * k + t0.rgb;
	}
	return shade.rgb * t0.rgb;
}

// Alpha sources:
//  0 T0      1 1      2 T0*PRIM      3 PRIM      4 ENV      5 T0*ENV
//  6 T0 - k*(1 - T1) (erosion: the second texture eats holes and wisps into the first)
//  7 mix(T0, T1, k)                  8 k*T1 + T0 (additive: the Ice Arrow)
float n64_cc_alpha(int mode, vec4 t0, vec4 t1, vec4 prim, vec4 env, float k) {
	switch (mode) {
		case 1: return 1.0;
		case 2: return t0.a * prim.a;
		case 3: return prim.a;
		case 4: return env.a;
		case 5: return t0.a * env.a;
		case 6: return (t1.a - 1.0) * k + t0.a;
		case 7: return mix(t0.a, t1.a, k);
		case 8: return k * t1.a + t0.a;
	}
	return t0.a;
}

// Cycle-2 tints (rgb):
//  0 pass   1 x PRIM (70 %)   2 x SHADE (17 %)   3 x ENV (Link's tunic parts)
//  4 mix(ENV, PRIM, COMBINED) (a two-colour ramp over the base's brightness: sky, sun,
//    get-items, every magic effect)
vec3 n64_cc_tint(int mode, vec3 comb, vec4 shade, vec4 prim, vec4 env) {
	switch (mode) {
		case 1: return comb * prim.rgb;
		case 2: return comb * shade.rgb;
		case 3: return comb * env.rgb;
		case 4: return mix(env.rgb, prim.rgb, comb);
	}
	return comb;
}

// The RDP's texgen (G_TEXTURE_GEN): UVs from the normal as the camera sees it (env mapping:
// shiny get-items, metal swords, reflective trims). `view_normal` in view space.
vec2 n64_cc_texgen(vec3 view_normal) {
	vec3 n = normalize(view_normal);
	return vec2(n.x * 0.5 + 0.5, 0.5 - n.y * 0.5);
}

// --- Overflow (Kaze, "3D Art is Math") --------------------------------------------------
// The combiner's results are 9-bit: -0.5..0 reads as 0 and 1..1.5 as 1, but past those
// they wrap round - a value pulled under -0.5 comes out bright, one pushed over 1.5 dark.
// Recipes build on it: glistening water (0 - noise x noise wraps to bright specks), coins
// pushed to the edge of overflowing, and cut-outs whose alpha is clamped on purpose.
vec4 n64_cc_overflow(vec4 v) {
	return clamp(mod(v + 0.5, 2.0) - 0.5, 0.0, 1.0);
}
vec3 n64_cc_overflow3(vec3 v) {
	return clamp(mod(v + 0.5, 2.0) - 0.5, 0.0, 1.0);
}
float n64_cc_overflow1(float v) {
	return clamp(mod(v + 0.5, 2.0) - 0.5, 0.0, 1.0);
}

// A texel-blocky noise texture (the RDP reading a small noise texture point-sampled):
// `uv` in texels.
float n64_cc_noise_texel(vec2 uv) {
	vec2 q = floor(uv);
	q = mod(q, 64.0);  // (a 64 x 64 texture: repeats)
	return fract(sin(dot(q, vec2(12.9898, 78.233))) * 43758.5453);
}

// --- Blender (in-shader parts) ----------------------------------------------------------

// (P * A + M * B) / (A + B), the RDP blender's formula (A + B = 1 in most modes).
vec3 n64_blend(vec3 p, float a, vec3 m, float b) {
	return (p * a + m * b) / max(a + b, 1e-4);
}
// G_RM_FOG_SHADE_A: the colour blended to fog by the shade alpha (fog amount from vertices).
vec3 n64_blend_fog(vec3 c, vec3 fog, float shade_a) {
	return n64_blend(fog, shade_a, c, 1.0 - shade_a);
}
