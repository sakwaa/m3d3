// Level paint: per-face base texture + up to 4 overlay layers, each blended through a
// painted mask (UV2 atlas). UV is world-aligned metres (+ per-face tweaks).
// Layers are unrolled (no sampler-array indexing) so this also runs on Compatibility.
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_lod_fade.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_weather.gdshaderinc"

uniform sampler2D base_tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform bool has_base = false;
// Overlay layers' textures turn this many quarter turns on these faces (bricks following a
// border the other way); masks, noise and variation stay put.
uniform int overlay_turns = 0;
// Then rotated (radians: along a sloped border edge) and shifted (metres) so the texture
// lines up with a border's edge.
uniform float overlay_angle = 0.0;
uniform vec2 overlay_offset = vec2(0.0);
// Then a general linear map (columns xy, zw): a border continuing its neighbour's texture
// over an edge (scale / shear where that neighbour's projection is stretched).
uniform vec4 overlay_basis = vec4(1.0, 0.0, 0.0, 1.0);
// A border continuing a stair over an edge: overlay layer `overlay_stair_layer` shows the
// stair's base, calmed and shaded by its template (stair_tex / stair_params, stair off) in
// stair UVs = basis * UV + offset, as on the stair itself. -1 = none.
uniform int overlay_stair_layer = -1;
uniform vec4 overlay_stair_basis = vec4(1.0, 0.0, 0.0, 1.0);
uniform vec2 overlay_stair_offset = vec2(0.0);
uniform vec4 base_color : source_color = vec4(0.55, 0.55, 0.55, 1.0);
// Multiplies the base texture (e.g. a converted StandardMaterial's albedo colour).
uniform vec4 base_tint : source_color = vec4(1.0);
uniform float base_tile = 1.0;
// Vertex colour range: 1 = modulate, 2 = modulate x 2 (meshes store colours halved).
uniform float vertex_color_scale = 1.0;
// Recolour (a texture look): the texture gives only brightness and the vertex colour the
// colour, like the N64's intensity textures x SHADE: texel brightness (relative to the
// texture's average) x painted colour, so the colour picked is the colour seen on average
// (white = the texture in light greys; Brightness above 1 in 2x levels lightens it).
uniform bool base_recolour = false;
// Anti-tiling per texture: x = 0 off / 1 offset / 2 offset+rotate, y = hex size (repeats).
uniform vec2 base_anti = vec2(0.0, 0.75);
// Combiner tint per texture: mode (0 none / 1 multiply / 2 gradient), dark, light.
uniform float base_tint_mode = 0.0;
uniform vec3 base_tint_dark : source_color = vec3(0.2);
uniform vec3 base_tint_light : source_color = vec3(1.0);
// x = amount (0 original colours .. 1 full tint), yz = luminance range mapped to the gradient
uniform vec3 base_tint_extra = vec3(1.0, 0.0, 1.0);
uniform int layer_count = 0;
// Animated textures: scroll = world direction xyz + speed (m/s), flip = (columns, rows,
// frames, fps); frames <= 1 = no flipbook.
uniform vec4 base_scroll = vec4(0.0);
uniform vec4 base_flip = vec4(1.0, 1.0, 1.0, 0.0);
uniform vec4 scroll_0 = vec4(0.0);
uniform vec4 scroll_1 = vec4(0.0);
uniform vec4 scroll_2 = vec4(0.0);
uniform vec4 scroll_3 = vec4(0.0);
uniform vec4 flip_0 = vec4(1.0, 1.0, 1.0, 0.0);
uniform vec4 flip_1 = vec4(1.0, 1.0, 1.0, 0.0);
uniform vec4 flip_2 = vec4(1.0, 1.0, 1.0, 0.0);
uniform vec4 flip_3 = vec4(1.0, 1.0, 1.0, 0.0);
// Baked vertex lighting mode (LevelData.lighting_mode).
uniform bool vertex_lit = false;
// Baked Timed: number of lighting keys stored in CUSTOM0..3 (0 = single bake in COLOR).
uniform int light_keys = 0;
// Baked modes: 0 = light multiplied in linear space (soft shading), 1 = in display space
// like the N64 (half the light looks half as bright: punchy shadows and dusk / night).
uniform float light_contrast = 1.0;
// Baked Vertex / Timed Dynamic: how much of the bake shows; the scene's own ambient fills the rest.
uniform float bake_strength = 1.0;
// Baked modes: the darkest baked light shows as on screen, as a fraction of the surface's
// fully lit look (MM's dark scenes keep about a fifth); 0 = no floor.
uniform float light_floor = 0.0;
// Baked Timed Dynamic: the keys already carry the time of day (no world tint on top).
uniform bool timed_bake = false;

varying vec3 key_light;

// Baked shading on screen: `shade` (paint x AO x light) through the contrast curve, held
// above light_floor of the painted colour alone, in the light's own hue (night stays blue).
// A soft maximum, so shading eases into the floor instead of flattening at it.
vec3 n64_baked_shade(vec3 shade, vec3 paint, vec3 light) {
	vec3 s = mix(shade, pow(shade, vec3(2.2)), light_contrast);
	if (light_floor <= 0.0) {
		return s;
	}
	vec3 p = mix(paint, pow(paint, vec3(2.2)), light_contrast);
	float f = mix(light_floor, pow(light_floor, 2.2), light_contrast);
	vec3 hue = light / max(max(light.r, max(light.g, light.b)), 1e-4);
	vec3 fl = f * p * hue;
	vec3 k = fl * 0.5;
	return 0.5 * (s + fl + sqrt((s - fl) * (s - fl) + k * k));
}
varying vec2 n64_fogv;
varying vec3 n64_fog_tintv;

// Painted-on stairs (N64StairTexture): a greyscale template shades the finished surface
// (base + overlays, at their normal texel density) in UVs fitted to the ramp: stair_u /
// stair_v map the mesh position to (across 0..1, down the slope in whole repeats).
uniform bool stair_on = false;
uniform sampler2D stair_tex : filter_nearest_mipmap, repeat_enable, hint_default_white;
uniform vec4 stair_u = vec4(0.0);
uniform vec4 stair_v = vec4(0.0);
// strength, base detail kept, template neutral grey
uniform vec3 stair_params = vec3(1.5, 0.5, 0.5);
uniform vec3 stair_base_mean = vec3(0.5);
varying vec2 stair_uv;

void vertex() {
	VERTEX = n64_reflect_flatten(VERTEX, MODEL_MATRIX, CAMERA_POSITION_WORLD);
	n64_fogv = n64_fog_vertex((MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz);
	n64_fog_tintv = n64_fog_tint_vertex((MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz);
	if (stair_on) {
		stair_uv = vec2(dot(vec4(VERTEX, 1.0), stair_u), dot(vec4(VERTEX, 1.0), stair_v));
	}
	key_light = vec3(1.0);
	if (light_keys > 0) {
		vec4 k[4] = vec4[](CUSTOM0, CUSTOM1, CUSTOM2, CUSTOM3);
		int a = clamp(int(n64_light_blend.x + 0.5), 0, light_keys - 1);
		int b = clamp(int(n64_light_blend.y + 0.5), 0, light_keys - 1);
		key_light = mix(k[a].rgb, k[b].rgb, clamp(n64_light_blend.z, 0.0, 1.0));
	}
}

uniform sampler2D layer_tex_0 : source_color, filter_nearest_mipmap, repeat_enable;
uniform sampler2D layer_tex_1 : source_color, filter_nearest_mipmap, repeat_enable;
uniform sampler2D layer_tex_2 : source_color, filter_nearest_mipmap, repeat_enable;
uniform sampler2D layer_tex_3 : source_color, filter_nearest_mipmap, repeat_enable;
uniform sampler2D mask_0 : hint_default_black, filter_linear, repeat_disable;
uniform sampler2D mask_1 : hint_default_black, filter_linear, repeat_disable;
uniform sampler2D mask_2 : hint_default_black, filter_linear, repeat_disable;
uniform sampler2D mask_3 : hint_default_black, filter_linear, repeat_disable;
// x = blend mode, y = opacity, z = metres per repeat, w = 0 off / 1 textured / 2 shade (no texture)
uniform vec4 layer_0 = vec4(0.0, 1.0, 1.0, 0.0);
uniform vec4 layer_1 = vec4(0.0, 1.0, 1.0, 0.0);
uniform vec4 layer_2 = vec4(0.0, 1.0, 1.0, 0.0);
uniform vec4 layer_3 = vec4(0.0, 1.0, 1.0, 0.0);
uniform vec3 grad_dark_0 : source_color = vec3(0.2);
uniform vec3 grad_dark_1 : source_color = vec3(0.2);
uniform vec3 grad_dark_2 : source_color = vec3(0.2);
uniform vec3 grad_dark_3 : source_color = vec3(0.2);
// x = tint mode, yzw = light colour
uniform vec4 grad_0 = vec4(0.0, 1.0, 1.0, 1.0);
uniform vec4 grad_1 = vec4(0.0, 1.0, 1.0, 1.0);
uniform vec4 grad_2 = vec4(0.0, 1.0, 1.0, 1.0);
uniform vec4 grad_3 = vec4(0.0, 1.0, 1.0, 1.0);
uniform vec3 grad_extra_0 = vec3(1.0, 0.0, 1.0);
uniform vec3 grad_extra_1 = vec3(1.0, 0.0, 1.0);
uniform vec3 grad_extra_2 = vec3(1.0, 0.0, 1.0);
uniform vec3 grad_extra_3 = vec3(1.0, 0.0, 1.0);
uniform vec2 anti_0 = vec2(0.0, 0.75);
uniform vec2 anti_1 = vec2(0.0, 0.75);
uniform vec2 anti_2 = vec2(0.0, 0.75);
uniform vec2 anti_3 = vec2(0.0, 0.75);
uniform vec4 tint_0 : source_color = vec4(1.0);
uniform vec4 tint_1 : source_color = vec4(1.0);
uniform vec4 tint_2 : source_color = vec4(1.0);
uniform vec4 tint_3 : source_color = vec4(1.0);
// Large-scale variation that breaks up repetition: one shared seamless noise, per
// texture x = strength, y = metres per noise repeat, z = mode (0 light & dark, 1 darken).
uniform sampler2D variation_tex : filter_linear_mipmap, repeat_enable, hint_default_white;
uniform vec3 base_var = vec3(0.0, 8.0, 0.0);
uniform vec3 var_0 = vec3(0.0, 8.0, 0.0);
uniform vec3 var_1 = vec3(0.0, 8.0, 0.0);
uniform vec3 var_2 = vec3(0.0, 8.0, 0.0);
uniform vec3 var_3 = vec3(0.0, 8.0, 0.0);
// Noise mask per layer (same shared noise, decorrelated): x = coverage (0 off), y = metres
// per noise repeat, z = softness, w = combine (0 noise only, 1 painted + noise, 2 painted x noise).
uniform vec4 noise_0 = vec4(0.0, 4.0, 0.3, 1.0);
uniform vec4 noise_1 = vec4(0.0, 4.0, 0.3, 1.0);
uniform vec4 noise_2 = vec4(0.0, 4.0, 0.3, 1.0);
uniform vec4 noise_3 = vec4(0.0, 4.0, 0.3, 1.0);
// Height blend edge: x = sharpness, y = noise, z = darken
uniform vec3 edge_0 = vec3(0.6, 0.5, 0.35);
uniform vec3 edge_1 = vec3(0.6, 0.5, 0.35);
uniform vec3 edge_2 = vec3(0.6, 0.5, 0.35);
uniform vec3 edge_3 = vec3(0.6, 0.5, 0.35);
// Extra height from the layer's place in the list (Height by order; 0 otherwise).
uniform float order_0 = 0.0;
uniform float order_1 = 0.0;
uniform float order_2 = 0.0;
uniform float order_3 = 0.0;
// Shadow a Height-blended layer casts onto what's below, just outside its edge (0 off).
uniform float shadow_0 = 0.0;
uniform float shadow_1 = 0.0;
uniform float shadow_2 = 0.0;
uniform float shadow_3 = 0.0;

const vec3 LUMA = vec3(0.299, 0.587, 0.114);
// How strongly texel height (luminance minus the texture's average) pushes the edge.
const float HEIGHT_DEPTH = 2.0;
// Most a layer's place in the list can push its Height-by-order edge.
const float ORDER_PUSH = 0.45;
// Width of the cast shadow (in edge-threshold units: how far below covering it reaches)
// and how dark it gets at full strength.
const float SHADOW_WIDTH = 0.3;
const float SHADOW_DARK = 0.65;

vec4 tex(sampler2D t, vec2 uv) {
	return n64_texture(t, uv);
}

// UV (metres) -> texture UV: `tile` metres across, height following the texture's aspect
// so non-square N64 textures (e.g. 64x32 bricks) aren't stretched.
vec2 tile_uv(sampler2D t, vec2 uv, float tile) {
	vec2 size = vec2(textureSize(t, 0));
	return uv / max(tile, 0.001) * vec2(1.0, size.x / max(size.y, 1.0));
}

// A texture sampled with its animation: flipbook frames (one frame = `tile` metres, its own
// aspect; no anti-tiling) or the usual tiled read. `uv` already scrolled.
vec4 anim_texture(sampler2D t, vec2 uv, float tile, vec2 anti, vec4 flip, float time) {
	if (flip.z > 1.5) {
		vec2 cell = vec2(textureSize(t, 0)) / max(flip.xy, vec2(1.0));
		return n64_texture_frame(t, uv / max(tile, 0.001) * vec2(1.0, cell.x / max(cell.y, 1.0)), flip, time);
	}
	return n64_texture_tiled(t, tile_uv(t, uv, tile), anti);
}

#if defined(N64_CUTOUT)
// Cutout alpha with an anisotropic mip level (like 16x anisotropic filtering): seen at a
// grazing angle (a fence along its length) the usual level comes from the stretched axis,
// whose small mips average thin rails away into the gaps, so they dissolve before the
// colour does. This takes the level from the short axis (at most 4 levels finer).
float cutout_alpha(sampler2D t, vec2 uv) {
	vec2 size = vec2(textureSize(t, 0));
	float a = length(dFdx(uv) * size);
	float b = length(dFdy(uv) * size);
	float lod = max(log2(max(max(a, b), 1e-8)) - 4.0, log2(max(min(a, b), 1e-8)));
	return textureLod(t, uv, clamp(lod, 0.0, floor(log2(max(size.x, size.y))))).a;
}
#endif

// Height of a texel: brightness relative to its texture's average (the last mip).
float texel_height(sampler2D t, vec3 raw) {
	return dot(raw, LUMA) - dot(textureLod(t, vec2(0.5), 16.0).rgb, LUMA);
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x),
		mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0)), f.x), f.y);
}

// Hides the shared noise's repeat: a much larger, differently rotated copy of the noise
// (at an off-ratio scale, so its repeat never lines up with the noise's own) displaces the
// lookup, bending every repeat differently. `p` is in noise-tile units. 2 extra reads.
vec2 noise_warp(vec2 p) {
	vec2 q = mat2(vec2(0.8829, 0.4695), vec2(-0.4695, 0.8829)) * p * 0.1913;
	vec2 w = vec2(texture(variation_tex, q).r, texture(variation_tex, q + vec2(0.523, 0.191)).r);
	return p + (w - 0.5) * 0.8;
}

// Noise in the face's world-aligned projection (metres), turned ~37° so its repeat never
// lines up with the texture grid.
vec3 apply_variation(vec3 c, vec2 uv, vec3 v) {
	if (v.x <= 0.001) {
		return c;
	}
	vec2 p = noise_warp(mat2(vec2(0.7986, 0.6018), vec2(-0.6018, 0.7986)) * uv / max(v.y, 0.05));
	// FBM values cluster mid-grey; stretch so the strength slider spans real patches.
	float n = smoothstep(0.25, 0.75, texture(variation_tex, p).r);
	if (v.z < 0.5) {
		return c * (1.0 + (n - 0.5) * 2.0 * v.x);
	}
	return c * (1.0 - n * v.x);
}

// Layer coverage from painting and / or the noise mask (in the face's own projection, so
// walls and floors get independent patterns).
float layer_mask(float painted, vec2 uv, vec4 nm) {
	if (nm.x <= 0.001) {
		return painted;
	}
	vec2 p = noise_warp(mat2(vec2(0.5446, -0.8387), vec2(0.8387, 0.5446)) * uv / max(nm.y, 0.05) + vec2(0.37, 0.71));
	float n = texture(variation_tex, p).r;
	float edge = 1.0 - nm.x;
	float soft = max(nm.z, 0.01) * 0.5;
	float m = smoothstep(edge - soft, edge + soft, n);
	if (nm.w < 0.5) {
		return m;
	} else if (nm.w < 1.5) {
		return max(painted, m);
	}
	return painted * m;
}

vec3 blend_mode(vec3 c, vec3 t, float mode, float m) {
	vec3 r;
	if (mode < 0.5) {
		r = t;
	} else if (mode < 1.5) {
		r = c * t;
	} else if (mode < 2.5) {
		r = c + t;
	} else if (mode < 3.5) {
		r = c - t;
	} else if (mode < 4.5) {
		r = 1.0 - (1.0 - c) * (1.0 - t);
	} else {
		r = mix(2.0 * c * t, 1.0 - 2.0 * (1.0 - c) * (1.0 - t), step(0.5, c));
	}
	return mix(c, clamp(r, 0.0, 1.0), clamp(m, 0.0, 1.0));
}

// `h` carries the texel height of the surface so far, `ho` its layer-order height (Height
// by order), for Height-blended layers above.
vec3 apply_layer(vec3 c, inout float h, inout float ho, sampler2D t, sampler2D mask, vec4 p, vec4 tint, vec2 anti, vec4 grad, vec3 dark, vec3 extra, vec3 edge, float order, float shadow, vec3 var, vec4 nm, vec2 uv, vec2 uv2, vec2 suv, vec2 tuv, vec4 flip, float time, vec2 stair) {
	if (p.w < 0.5) {
		return c;
	}
	// Mask first: unpainted pixels skip the texture work entirely.
	float mk = layer_mask(texture(mask, uv2).r, uv, nm);
	if (mk * p.y <= 0.001) {
		return c;
	}
	if (p.x > 6.5 && p.x < 7.5 && p.w < 1.5) {
		// Shine: the layer texture is a reflection map looked up by the view-space normal
		// (like the N64's texgen environment mapping), added through the mask.
		return c + n64_texture(t, suv).rgb * tint.rgb * mk * p.y;
	}
	vec4 s;
	float hl = 0.0;
	if (p.w > 1.5) {
		// Untextured shade layer: a flat colour through the mask (e.g. noise darkening).
		s = vec4(tint.rgb, 1.0);
	} else {
		s = anim_texture(t, tuv, p.z, anti, flip, time);
		hl = p.x > 5.5 ? texel_height(t, s.rgb) : 0.0;
		s.rgb = n64_tint(s.rgb, grad.x, dark, grad.yzw, extra);
		s *= tint;
		s.rgb = apply_variation(s.rgb, uv, var);
		// A continued stair: calmed like the stair's base, then its template's shading.
		if (stair.y > 0.5) {
			s.rgb = mix(stair_base_mean, s.rgb, stair_params.y) * stair.x;
		}
	}
	if (p.x < 5.5) {
		return blend_mode(c, s.rgb, p.x, mk * p.y * s.a);
	}
	// Height: threshold the mask, pushed by the height difference and world noise, so the
	// taller texture wins texel by texel. Fades to nothing at the mask's outer rim.
	float n = value_noise(uv * 2.5) * 0.65 + value_noise(uv * 7.0) * 0.35;
	// Height by order: standing higher than what's below pushes the edge out, capped so the
	// edge still lands where texel detail can break it up (not on the mask's soft rim).
	float push = clamp((order - ho) * HEIGHT_DEPTH, -ORDER_PUSH, ORDER_PUSH);
	float x = mk + (hl - h) * HEIGHT_DEPTH + push + (n - 0.5) * edge.y;
	float e = mix(0.35, 0.02, edge.x);
	float rim = smoothstep(0.0, order > 0.0 ? 0.04 : 0.15, mk);
	float w = smoothstep(0.5 - e, 0.5 + e, x) * rim * p.y * s.a;
	// Cast shadow: on the uncovered side, darkest right at the edge.
	// (Fades out before the mask does: unpainted texels skip the layer altogether.)
	float cast = shadow * (1.0 - w) * smoothstep(0.5 - SHADOW_WIDTH, 0.5 - e, x) * smoothstep(0.0, 0.1, mk) * p.y;
	c *= 1.0 - SHADOW_DARK * cast;
	c = mix(c, s.rgb, w);
	h = mix(h, hl, w);
	ho = mix(ho, order, w);
	// Darken the band around the edge (widest where the mask is half covered).
	float band = 1.0 - abs(2.0 * clamp(x, 0.0, 1.0) - 1.0);
	return c * (1.0 - edge.z * 0.5 * band * rim * p.y);
}

// UV with a layer's scroll applied (flow in world space -> view space for the derivatives).
vec2 scrolled_uv(vec4 flow, vec2 uv, vec3 view_pos, mat4 view, float time) {
	return uv + n64_scroll_uv(flow, (view * vec4(flow.xyz, 0.0)).xyz, view_pos, uv, time);
}

void fragment() {
	n64_lod_dither(CAMERA_POSITION_WORLD, MODEL_MATRIX, FRAGCOORD.xy);
	vec3 c = base_color.rgb;
	float h = 0.0;
	float ho = 0.0;
	float time = n64_time;
	float base_alpha = 1.0;
	if (has_base) {
		vec2 buv = scrolled_uv(base_scroll, UV, VERTEX, VIEW_MATRIX, time);
		vec4 bs = anim_texture(base_tex, buv, base_tile, base_anti, base_flip, time);
		c = bs.rgb;
		base_alpha = bs.a;
#if defined(N64_CUTOUT)
		if (base_flip.z <= 1.5 && base_anti.x < 0.5) {
			base_alpha = cutout_alpha(base_tex, tile_uv(base_tex, buv, base_tile));
		}
#endif
		h = texel_height(base_tex, c);
		if (base_recolour) {
			// Brightness relative to the texture's mean (its smallest mip): an average texel
			// shows the painted colour itself, the texture adds light / dark detail around it.
			// The painted colour is picked on screen (sRGB): to linear so it shows as picked.
			float mean = dot(textureLod(base_tex, vec2(0.5), 16.0).rgb, LUMA);
			vec3 picked = pow(max(COLOR.rgb * vertex_color_scale, vec3(0.0)), vec3(2.2));
			c = picked * (dot(c, LUMA) / max(mean, 0.05)) * base_tint.rgb;
		} else {
			c = n64_tint(c, base_tint_mode, base_tint_dark, base_tint_light, base_tint_extra) * base_tint.rgb;
		}
		c = apply_variation(c, UV, base_var);
		// Busy bases (bricks, cobbles) calm down so the painted steps read.
		if (stair_on) {
			c = mix(stair_base_mean, c, stair_params.y);
		}
	}
	vec2 suv = normalize(NORMAL).xy * vec2(0.5, -0.5) + 0.5;
	vec2 luv = overlay_turns == 1 ? vec2(-UV.y, UV.x) : overlay_turns == 2 ? -UV : overlay_turns == 3 ? vec2(UV.y, -UV.x) : UV;
	if (overlay_angle != 0.0) {
		float ca = cos(overlay_angle);
		float sa = sin(overlay_angle);
		luv = vec2(luv.x * ca - luv.y * sa, luv.x * sa + luv.y * ca);
	}
	luv = overlay_basis.xy * luv.x + overlay_basis.zw * luv.y + overlay_offset;
	vec2 st = vec2(1.0, 0.0);
	if (overlay_stair_layer >= 0) {
		vec2 sbuv = overlay_stair_basis.xy * UV.x + overlay_stair_basis.zw * UV.y + overlay_stair_offset;
		float g = n64_texture(stair_tex, sbuv).r;
		st = vec2(max(mix(1.0, g / max(stair_params.z, 0.05), stair_params.x), 0.0), 1.0);
	}
	if (layer_count > 0) { c = apply_layer(c, h, ho, layer_tex_0, mask_0, layer_0, tint_0, anti_0, grad_0, grad_dark_0, grad_extra_0, edge_0, order_0, shadow_0, var_0, noise_0, UV, UV2, suv, scrolled_uv(scroll_0, luv, VERTEX, VIEW_MATRIX, time), flip_0, time, overlay_stair_layer == 0 ? st : vec2(1.0, 0.0)); }
	if (layer_count > 1) { c = apply_layer(c, h, ho, layer_tex_1, mask_1, layer_1, tint_1, anti_1, grad_1, grad_dark_1, grad_extra_1, edge_1, order_1, shadow_1, var_1, noise_1, UV, UV2, suv, scrolled_uv(scroll_1, luv, VERTEX, VIEW_MATRIX, time), flip_1, time, overlay_stair_layer == 1 ? st : vec2(1.0, 0.0)); }
	if (layer_count > 2) { c = apply_layer(c, h, ho, layer_tex_2, mask_2, layer_2, tint_2, anti_2, grad_2, grad_dark_2, grad_extra_2, edge_2, order_2, shadow_2, var_2, noise_2, UV, UV2, suv, scrolled_uv(scroll_2, luv, VERTEX, VIEW_MATRIX, time), flip_2, time, overlay_stair_layer == 2 ? st : vec2(1.0, 0.0)); }
	if (layer_count > 3) { c = apply_layer(c, h, ho, layer_tex_3, mask_3, layer_3, tint_3, anti_3, grad_3, grad_dark_3, grad_extra_3, edge_3, order_3, shadow_3, var_3, noise_3, UV, UV2, suv, scrolled_uv(scroll_3, luv, VERTEX, VIEW_MATRIX, time), flip_3, time, overlay_stair_layer == 3 ? st : vec2(1.0, 0.0)); }
	if (stair_on) {
		float g = n64_texture(stair_tex, stair_uv).r;
		c *= max(mix(1.0, g / max(stair_params.z, 0.05), stair_params.x), 0.0);
	}
	// Rain: surfaces open to the sky (RainCover) darken and saturate as they soak; the ground
	// (walls much less) also picks up a dim sheen of the sky towards grazing angles.
	if (n64_wetness > 0.0) {
		vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
		float up = smoothstep(0.3, 0.8, (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y);
		float wet = n64_wetness * n64_rain_exposed(world) * mix(0.35, 1.0, up);
		c = n64_wet(c, wet);
		float graze = pow(1.0 - clamp(dot(normalize(NORMAL), VIEW), 0.0, 1.0), 4.0);
		c += n64_fog_color.rgb * graze * up * wet * 0.35;
	}
	// Vertex colours (painted x baked lighting) shade the result, like the N64's per-vertex
	// colour. Vertex-lit levels are unlit: the colour goes out through EMISSION so scene
	// lights and ambient don't light them twice.
	// Painted vertex colour x baked vertex AO (alpha), AO hideable in the editor.
	// (Recoloured faces took their colour in the gradient; AO still shades them.)
	vec3 paint = base_recolour ? vec3(1.0) : COLOR.rgb * vertex_color_scale;
	vec3 vc = paint * mix(1.0, COLOR.a, n64_vertex_ao);
	// N64 fog: flat colour blended in last (after lighting), amount from the vertices.
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
#if defined(N64_CUTOUT)
	// Cutout (fences, grilles): the base texture's alpha cuts holes, both sides drawn.
	ALPHA = base_alpha;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
#endif
#if defined(N64_HYBRID)
	// Baked light (one key, or the time-of-day keys, in CUSTOM0..3) through EMISSION; live
	// lights on ALBEDO. The
	// scene's ambient comes back as the bake fades (AO only dims ambient, not lights).
	vec3 light = key_light * (timed_bake ? vec3(1.0) : n64_world_tint.rgb);
	ALBEDO = c * vc * n64_weather_tint.rgb;
	EMISSION = c * n64_baked_shade(vc * light, paint, light) * n64_weather_tint.rgb * bake_strength;
	AO = clamp(1.0 - bake_strength, 0.0, 1.0);
#elif defined(N64_UNSHADED)
	// Baked lighting variant: unshaded, colour through ALBEDO (decals such as character
	// shadows then still apply; EMISSION would ignore them).
	vec3 light = light_keys > 0 ? key_light : n64_world_tint.rgb;
	ALBEDO = c * n64_baked_shade(vc * light, paint, light) * n64_weather_tint.rgb;
#else
	if (vertex_lit) {
		vec3 light = light_keys > 0 ? key_light : n64_world_tint.rgb;
		ALBEDO = vec3(0.0);
		EMISSION = c * n64_baked_shade(vc * light, paint, light) * n64_weather_tint.rgb;
	} else {
		ALBEDO = c * vc;
	}
#endif
}
