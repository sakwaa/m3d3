shader_type spatial;
render_mode diffuse_lambert, specular_disabled, vertex_lighting;
// Merged level paint (the build's MaterialMerge): many plain base-textured surfaces of a
// chunk drawn as one. Each vertex carries its material's index (UV2.x); the base textures
// sit in one array (each upscaled by a whole number to the array's size, so every texel is
// a block of identical array texels) and are read at their own native size, so the N64
// 3-point filter and mip levels match paint_hybrid exactly. Per-material settings come from
// a small table (params). Lighting, fog, LOD fade and weather as in paint_body.gdshaderinc
// (Baked Vertex / Timed Dynamic, the N64_HYBRID path).
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_lod_fade.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_weather.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_ripples.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_coverage.gdshaderinc"

uniform sampler2DArray base_array : source_color, filter_nearest_mipmap, repeat_enable;
// Per material (column = index): row 0 tile, anti.x, anti.y, native size; 1 tint mode, dark;
// 2 recolour, light; 3 extra, array layer; 4 base_tint; 5 variation; 6..9 colour adjust.
uniform sampler2D params : filter_nearest, repeat_disable;
uniform float array_size = 128.0;
uniform float vertex_color_scale = 1.0;
uniform sampler2D variation_tex : filter_linear_mipmap, repeat_enable, hint_default_white;
// Base textures' own variation textures (MaterialMerge); params row 5 .w = layer + 1, 0 =
// the shared noise.
uniform sampler2DArray variation_array : filter_linear_mipmap, repeat_enable;
uniform int light_keys = 0;
uniform float light_contrast = 1.0;
uniform float bake_strength = 1.0;
uniform float light_floor = 0.0;
uniform bool timed_bake = false;

varying N64_SHADE vec3 key_light;
varying flat float brush_code;
// The baked light at this pixel (decoded from its display-value interpolation).
#if N64_GAMMA_MIX
#define KEY_LIGHT n64_dec(key_light)
#else
#define KEY_LIGHT key_light
#endif
varying N64_SHADE vec2 n64_fogv;
varying N64_SHADE vec4 n64_colv;  // COLOR, affine
varying N64_SHADE vec3 n64_fog_tintv;
varying flat float mat_id;

const vec3 LUMA = vec3(0.299, 0.587, 0.114);

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

void vertex() {
	n64_colv = COLOR;
	VERTEX = n64_reflect_flatten(VERTEX, MODEL_MATRIX, CAMERA_POSITION_WORLD);
	n64_fogv = n64_fog_vertex((MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz);
	n64_fog_tintv = n64_fog_tint_vertex((MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz);
	mat_id = UV2.x;
	key_light = vec3(1.0);
	brush_code = 7.0;
	if (light_keys > 0) {
		float bid = floor(CUSTOM0.a * 255.0 + 0.5) - 1.0;
		brush_code = bid >= 0.0 && bid < 7.0 ? bid : 7.0;
	}
	if (light_keys > 0) {
		vec4 k[4] = vec4[](CUSTOM0, CUSTOM1, CUSTOM2, CUSTOM3);
		int a = clamp(int(n64_light_blend.x + 0.5), 0, light_keys - 1);
		int b = clamp(int(n64_light_blend.y + 0.5), 0, light_keys - 1);
		key_light = n64_shade8(mix(k[a].rgb, k[b].rgb, clamp(n64_light_blend.z, 0.0, 1.0)));
	}
#if N64_GAMMA_MIX
	key_light = n64_enc(key_light);  // (interpolated across the triangle on display values: decoded per pixel)
#endif
	N64_SNAP_MODEL;
}

// --- The array read at a layer's native size (n64_sampling's functions, for the array) ---

float m_lod_grad(float size, vec2 dx, vec2 dy) {
	vec2 a = dx * size;
	vec2 b = dy * size;
	float rho = max(dot(a, a), dot(b, b));
	return clamp(0.5 * log2(max(rho, 1e-8)), 0.0, floor(log2(size)));
}

// Native mip `level` of layer `layer`: the array's level log2(array / native) + level holds
// exactly that mip (a whole-number upscale's box mips).
vec4 m_fetch(vec2 uv, float layer, float array_level) {
	return textureLod(base_array, vec3(uv, layer), array_level);
}

vec4 m_sample_level(vec2 uv, float layer, float size, int level) {
	float s = max(size / exp2(float(level)), 1.0);
	float al = log2(array_size / size) + float(level);
	vec2 p = uv * s - 0.5;
	vec2 f = fract(p);
	vec2 i = floor(p);
	vec4 a = m_fetch((i + vec2(0.5)) / s, layer, al);
	vec4 b = m_fetch((i + vec2(1.5, 0.5)) / s, layer, al);
	vec4 c = m_fetch((i + vec2(0.5, 1.5)) / s, layer, al);
	vec4 d = m_fetch((i + vec2(1.5)) / s, layer, al);
	if (f.x + f.y <= 1.0) {
		return a + f.x * (b - a) + f.y * (c - a);
	}
	return d + (1.0 - f.x) * (c - d) + (1.0 - f.y) * (b - d);
}

vec4 m_sample_at_lod(vec2 uv, float layer, float size, float lod) {
	int l0 = int(floor(lod));
	float blend = clamp((lod - float(l0) - 0.5) / N64_MIP_BAND + 0.5, 0.0, 1.0);
	if (blend <= 0.0) {
		return m_sample_level(uv, layer, size, l0);
	}
	if (blend >= 1.0) {
		return m_sample_level(uv, layer, size, l0 + 1);
	}
	return mix(m_sample_level(uv, layer, size, l0), m_sample_level(uv, layer, size, l0 + 1), blend);
}

vec4 m_read(vec2 uv, vec2 dx, vec2 dy, float layer, float size, float lod) {
	if (!n64_three_point) {
		return textureGrad(base_array, vec3(uv, layer), dx, dy);
	}
	return m_sample_at_lod(uv, layer, size, lod);
}

vec4 m_hex_tap(vec2 uv, vec2 cell, float w, float mode, float layer, float size, float lod, vec2 dx, vec2 dy) {
	if (w <= 0.0) {
		return vec4(0.0);
	}
	vec2 h = n64_hash2(cell);
	float a = (h.x * 2.0 - 1.0) * clamp(mode - 1.0, 0.0, 1.0) * 3.14159265;
	mat2 r = mat2(vec2(cos(a), sin(a)), vec2(-sin(a), cos(a)));
	return m_read(r * uv + h * 7.31, r * dx, r * dy, layer, size, lod) * w;
}

vec4 m_texture_tiled(vec2 uv, vec2 anti, float layer, float size) {
	vec2 dx = dFdx(uv);
	vec2 dy = dFdy(uv);
	float lod = m_lod_grad(size, dx, dy);
	if (anti.x < 0.5) {
		return m_read(uv, dx, dy, layer, size, lod);
	}
	if (anti.x > 2.5) {
		return m_read(uv + vec2(n64_hash2(vec2(floor(uv.y), 17.0)).x, 0.0), dx, dy, layer, size, lod);
	}
	vec2 st = uv / max(anti.y, 0.05) * 3.4641016;
	vec2 skewed = vec2(st.x - 0.57735027 * st.y, 1.15470054 * st.y);
	vec2 base = floor(skewed);
	vec3 f = vec3(fract(skewed), 0.0);
	f.z = 1.0 - f.x - f.y;
	float s = step(0.0, -f.z);
	float s2 = 2.0 * s - 1.0;
	vec3 w = vec3(-f.z * s2, s - f.y * s2, s - f.x * s2);
	w = pow(max(w, vec3(0.0)), vec3(8.0));
	w /= max(w.x + w.y + w.z, 1e-6);
	w *= step(vec3(0.05), w);
	w /= max(w.x + w.y + w.z, 1e-6);
	return m_hex_tap(uv, base + vec2(s, s), w.x, anti.x, layer, size, lod, dx, dy)
		+ m_hex_tap(uv, base + vec2(s, 1.0 - s), w.y, anti.x, layer, size, lod, dx, dy)
		+ m_hex_tap(uv, base + vec2(1.0 - s, s), w.z, anti.x, layer, size, lod, dx, dy);
}

// --- Variation (paint_body's) ---------------------------------------------------------------

vec2 noise_warp(vec2 p) {
	vec2 q = mat2(vec2(0.8829, 0.4695), vec2(-0.4695, 0.8829)) * p * 0.1913;
	vec2 w = vec2(texture(variation_tex, q).r, texture(variation_tex, q + vec2(0.523, 0.191)).r);
	return p + (w - 0.5) * 0.8;
}

// ColourAdjust (Paint panel > Colour adjust): a0 = hue turn (rad), saturation, brightness,
// contrast; a1 = temperature, tint, gamma, on (1; 2 = start from grey); a2 = colorize rgb,
// amount; a3 = shadow rgb (start from grey: the ramp's dark end). Display space.
vec3 colour_adjust(vec3 c, vec4 a0, vec4 a1, vec4 a2, vec4 a3) {
	if (a1.w < 0.5) {
		return c;
	}
	vec3 s = pow(max(c, vec3(0.0)), vec3(1.0 / 2.2));
	float l = dot(s, vec3(0.299, 0.587, 0.114));
	if (a1.w > 1.5) {
		// Start from grey: brightness through the shadow -> colorize ramp.
		vec3 ramp = mix(pow(max(a3.rgb, vec3(0.0)), vec3(1.0 / 2.2)), pow(max(a2.rgb, vec3(0.0)), vec3(1.0 / 2.2)), l);
		s = mix(vec3(l), ramp, a2.a);
	} else if (a2.a > 0.0) {
		vec3 col = pow(max(a2.rgb, vec3(0.0)), vec3(1.0 / 2.2));
		s = mix(s, col * (l / max(dot(col, vec3(0.299, 0.587, 0.114)), 0.05)), a2.a);
	}
	if (a0.x != 0.0) {
		// Hue turned in YIQ (brightness kept).
		vec3 yiq = mat3(vec3(0.299, 0.596, 0.211), vec3(0.587, -0.274, -0.523), vec3(0.114, -0.322, 0.312)) * s;
		float cs = cos(a0.x);
		float sn = sin(a0.x);
		yiq.yz = vec2(yiq.y * cs - yiq.z * sn, yiq.y * sn + yiq.z * cs);
		s = mat3(vec3(1.0, 1.0, 1.0), vec3(0.956, -0.272, -1.106), vec3(0.621, -0.647, 1.703)) * yiq;
	}
	l = dot(s, vec3(0.299, 0.587, 0.114));
	s = mix(vec3(l), s, a0.y);
	s *= vec3(1.0 + a1.x * 0.12, 1.0 - a1.y * 0.1, 1.0 - a1.x * 0.12);
	s = (s - 0.5) * a0.w + 0.5;
	s *= a0.z;
	s = pow(max(s, vec3(0.0)), vec3(1.0 / max(a1.z, 0.05)));
	return pow(max(s, vec3(0.0)), vec3(2.2));
}


// `vl`: variation_array layer + 1 (0 = the shared noise).
vec3 apply_variation(vec3 c, vec2 uv, vec3 v, float vl) {
	if (v.x <= 0.001) {
		return c;
	}
	vec2 p = noise_warp(mat2(vec2(0.7986, 0.6018), vec2(-0.6018, 0.7986)) * uv / max(v.y, 0.05));
	vec3 s = vl > 0.5 ? texture(variation_array, vec3(p, vl - 1.0)).rgb : texture(variation_tex, p).rgb;
	if (v.z > 1.5) {
		vec3 mean = vl > 0.5 ? textureLod(variation_array, vec3(0.5, 0.5, vl - 1.0), 16.0).rgb : vec3(0.5);
		return c * mix(vec3(1.0), pow(s, vec3(2.2)) / max(pow(mean, vec3(2.2)), vec3(0.005)), v.x);
	}
	float n = smoothstep(0.25, 0.75, s.r);
	if (v.z < 0.5) {
		return c * (1.0 + (n - 0.5) * 2.0 * v.x);
	}
	return c * (1.0 - n * v.x);
}

void fragment() {
	n64_lod_dither(CAMERA_POSITION_WORLD, MODEL_MATRIX, FRAGCOORD.xy);
	if (!IN_SHADOW_PASS) {
		n64_see_through_dither((INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz, CAMERA_POSITION_WORLD, FRAGCOORD.xy);  // (the sun's view: no holes)
	}
	int id = int(mat_id + 0.5);
	vec4 p0 = texelFetch(params, ivec2(id, 0), 0);
	vec4 p1 = texelFetch(params, ivec2(id, 1), 0);
	vec4 p2 = texelFetch(params, ivec2(id, 2), 0);
	vec4 p3 = texelFetch(params, ivec2(id, 3), 0);
	vec4 tint = texelFetch(params, ivec2(id, 4), 0);
	vec4 var = texelFetch(params, ivec2(id, 5), 0);
	float layer = p3.w;
	float size = p0.w;
	// Square textures only (MaterialMerge): `tile` metres across.
	vec2 tuv = UV / max(p0.x, 0.001);
	vec3 c = m_texture_tiled(tuv, p0.yz, layer, size).rgb;
	if (p2.x > 0.5) {
		float mean = dot(textureLod(base_array, vec3(0.5, 0.5, layer), 16.0).rgb, LUMA);
		vec3 picked = pow(max(n64_colv.rgb * vertex_color_scale, vec3(0.0)), vec3(2.2));
		c = picked * (dot(c, LUMA) / max(mean, 0.05)) * tint.rgb;
	} else {
		c = n64_tint(c, p1.x, p1.yzw, p2.yzw, p3.xyz) * tint.rgb;
	}
	c = colour_adjust(c, texelFetch(params, ivec2(id, 6), 0), texelFetch(params, ivec2(id, 7), 0), texelFetch(params, ivec2(id, 8), 0), texelFetch(params, ivec2(id, 9), 0));
	c = apply_variation(c, UV, var.xyz, var.w);
	if (soft_ground > 0.0) {
		vec3 fw = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
		float fup = smoothstep(0.5, 0.9, (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y);
		c = n64_footprints(c, fw.xz, CAMERA_POSITION_WORLD, n64_key_light.xz, fup);
	}
	if (n64_wetness > 0.0) {
		vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
		float up = smoothstep(0.3, 0.8, (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y);
		float wet = n64_wetness * n64_rain_exposed(world) * mix(0.35, 1.0, up);
		c = n64_wet(c, wet);
		float graze = pow(1.0 - clamp(dot(normalize(NORMAL), VIEW), 0.0, 1.0), 4.0);
		c += n64_fog_color.rgb * graze * up * wet * 0.15;
		// Ripples on the wet ground: raindrops where it's open to the sky, and the ripple
		// simulation (drips off the eaves, footsteps, landings) wherever it's wet. Crests catch
		// the sky's light, troughs darken a little.
		float rd = length(world - CAMERA_POSITION_WORLD);
		float rip = n64_rain_rings(world.xz, n64_time, n64_rain.x, rd) * wet
			+ n64_ripple_sim(world.xz, CAMERA_POSITION_WORLD) * n64_wetness * up * 1.6;
		rip = clamp(rip, -1.0, 1.0) * up;
		c += mix(n64_fog_color.rgb, vec3(1.0), 0.4) * max(rip, 0.0) * 0.6;
		c *= 1.0 + min(rip, 0.0) * 0.35;
	}
	vec3 paint = p2.x > 0.5 ? vec3(1.0) : n64_colv.rgb * vertex_color_scale;
	vec3 vc = paint * mix(1.0, n64_colv.a, n64_vertex_ao);
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
	vec3 light = KEY_LIGHT * (timed_bake ? vec3(1.0) : n64_world_tint.rgb);
	ALBEDO = c * vc * n64_weather_tint.rgb;
	EMISSION = c * n64_baked_shade(vc * light, paint, light) * n64_weather_tint.rgb * bake_strength;
	AO = clamp(1.0 - bake_strength, 0.0, 1.0);
	N64_FOG_GAMMA;
	N64_COVERAGE_BRUSH(brush_code);
}
