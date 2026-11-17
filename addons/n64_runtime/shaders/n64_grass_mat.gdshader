shader_type spatial;
render_mode unshaded, cull_disabled, skip_vertex_transform;
// The grass carpet (GrassBuilder): a lumpy carpet over the ground (Majora's Mask style), N64
// look like the baked level (unshaded, vertex colours, 3-point filtering, fog, weather tint;
// lit by the ground's baked light keys under it: n64_grass_light.gdshaderinc). It stays still (the tufts sway in the wind), but gusts show on it: a
// lighter sheen where one is passing (the shared gust field, n64_wind.gdshaderinc).
// Wading: the zone's grass simulation (GroundSim, n64_mist_sim.gdshader: `field_map`, b =
// how pressed, rg = how far the blades are pushed) dents it where actors go - a soft dent
// under a standing actor, a pressed, combed trail behind a moving one that springs back. The
// carpet is a slab: where it's pressed, this pixel follows its view ray down into the slab to
// the lowered grass (relief mapping, a few steps) and is drawn there, darker going in, and
// writes that depth - legs in the dent show, projected shadows still land (opaque).
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_wind.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_coverage.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_grass_light.gdshaderinc"

uniform sampler2D tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform float shade = 1.0;
// How much a gust lightens the carpet.
uniform float gust_shine = 0.3;
// The grass simulation (Zone's GroundSim): corner x, z, size (0: none).
uniform sampler2D field_map : filter_linear, repeat_disable, hint_default_black;
uniform vec4 field_rect = vec4(0.0);
// How deep a full press dents the carpet (metres), and how dark the bottom of a dent is.
uniform float dent_depth = 0.36;
uniform float dent_dark = 0.45;
// Metres per texture repeat of the carpet's top (its UVs are world xz / uv_tile): the traced
// texture shift maps straight to UVs (view independent). 0: through screen derivatives.
uniform float uv_tile = 0.0;
// How far the texture is combed along the push (metres per metre of push).
uniform float comb = 0.06;
// How much the lighter patches of the broad variation lean yellow (0: brightness only).
uniform float patch_yellow = 0.5;

varying N64_SHADE vec2 n64_fogv;
varying N64_SHADE vec3 n64_fog_tintv;
varying N64_SHADE vec3 tint;
varying vec3 world_v;
// The ground's baked light under this vertex (CUSTOM0..3: the lighting keys).
varying N64_SHADE vec3 key_light;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	n64_fogv = n64_fog_vertex(world);
	n64_fog_tintv = n64_fog_tint_vertex(world);
	tint = COLOR.rgb;
	key_light = n64_grass_key_light(CUSTOM0.rgb, CUSTOM1.rgb, CUSTOM2.rgb, CUSTOM3.rgb);
	world_v = world;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	N64_SNAP_VIEW;
}

// The field at `xz`: b = pressed (0..1), rg = push (metres).
vec4 field_at(vec2 xz) {
	if (field_rect.z <= 0.0) {
		return vec4(0.0);
	}
	vec2 uv = (xz - field_rect.xy) / field_rect.z;
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
		return vec4(0.0);
	}
	// (faded over the square's outer tenth: no seam where it ends)
	vec2 e = min(uv, 1.0 - uv);
	return textureLod(field_map, uv, 0.0) * smoothstep(0.0, 0.1, min(e.x, e.y));
}

void fragment() {
	vec2 uv = UV;
	// (screen derivatives here, outside the branch: they're undefined inside one)
	vec2 dxz_x = dFdx(world_v.xz);
	vec2 dxz_y = dFdy(world_v.xz);
	vec2 duv_x = dFdx(UV);
	vec2 duv_y = dFdy(UV);
	// Only the carpet's top dents (not the ledge fringe hanging off it, mapped differently).
	bool flat_top = abs(normalize(cross(dFdx(world_v), dFdy(world_v))).y) > 0.7;
	vec3 hit = world_v;
	float depth_in = 0.0;  // metres below the carpet's top where the ray met the grass
	vec4 f0 = flat_top ? field_at(world_v.xz) : vec4(0.0);
	vec3 dir = normalize(world_v - CAMERA_POSITION_WORLD);
	// Seen low across the carpet the dent goes shallow (a grazing ray would cross metres of
	// field: banded, and swimming as the camera turns); seen from above, full depth.
	float depth = dent_depth * smoothstep(0.08, 0.35, -dir.y);
	// Pressed here, or just ahead along the ray (a dent's far wall): trace into the slab.
	float reach = depth / max(-dir.y, 0.08);
	vec4 f1 = flat_top ? field_at(world_v.xz + dir.xz * reach) : vec4(0.0);
	if (max(f0.b, f1.b) > 0.01 && depth > 0.005) {
		float top = world_v.y;
		const float STEPS = 12.0;
		float prev_t = 0.0;
		float prev_gap = clamp(f0.b, 0.0, 1.0) * depth;  // ray above the grass at prev_t
		bool found = false;
		for (float i = 1.0; i <= STEPS; i += 1.0) {
			float t = reach * i / STEPS;
			vec3 p = world_v + dir * t;
			float surf = top - clamp(field_at(p.xz).b, 0.0, 1.0) * depth;
			float gap = p.y - surf;
			if (gap <= 0.0) {
				// Between the last two steps: where the ray crossed the grass (linear).
				float k = prev_gap / max(prev_gap - gap, 1e-5);
				float th = mix(prev_t, t, k);
				hit = world_v + dir * th;
				found = true;
				break;
			}
			prev_t = t;
			prev_gap = gap;
		}
		if (!found) {
			hit = world_v + dir * reach;
		}
		depth_in = clamp(top - hit.y, 0.0, depth);
		vec4 hc = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(hit, 1.0));
		DEPTH = hc.z / hc.w;
	} else {
		DEPTH = FRAGCOORD.z;
	}
	// The texture where the ray landed, combed a little along the push (everywhere the field
	// reaches, so nothing jumps where tracing starts): the top's UVs are world xz / uv_tile
	// (without it, the step mapped through screen derivatives).
	vec2 push = flat_top ? field_at(hit.xz).rg : vec2(0.0);
	push *= min(1.0, 0.5 / max(length(push), 1e-4));
	vec2 dw = hit.xz - world_v.xz - push * comb;
	float det = dxz_x.x * dxz_y.y - dxz_x.y * dxz_y.x;
	if (uv_tile > 0.0) {
		uv = UV + dw / uv_tile;
	} else if (abs(det) > 1e-10) {
		vec2 ia = vec2(dxz_y.y, -dxz_x.y) / det;
		vec2 ib = vec2(-dxz_y.x, dxz_x.x) / det;
		uv = UV + duv_x * dot(ia, dw) + duv_y * dot(ib, dw);
	}
	// Mip level from the carpet's own UVs: the traced shift jumps where tracing starts, and
	// its derivatives would pick blurrier levels there (a seam).
	vec4 c = n64_three_point ? n64_sample_at_lod(tex, uv, n64_lod(tex, UV)) : textureGrad(tex, uv, duv_x, duv_y);
	vec3 col = c.rgb * tint * shade;
	// Broad variation across big lawns (two octaves, ~25 m and ~10 m): lighter, yellower
	// patches and darker lusher ones, so a field doesn't read as one flat green.
	float patchy = n64_value_noise(hit.xz / 25.0) * 0.65 + n64_value_noise(hit.xz / 10.0 + 7.3) * 0.35;
	col *= mix(0.82, 1.14, patchy);
	col = mix(col, col * vec3(1.08, 1.04, 0.8), smoothstep(0.55, 0.9, patchy) * patch_yellow);
	// Pressed grass: darker going in (shadowed between the blades), a little greyer where trodden.
	float d = depth_in / max(dent_depth, 0.01);
	col *= 1.0 - dent_dark * d;
	col = mix(col, vec3(dot(col, vec3(0.299, 0.587, 0.114))), 0.25 * clamp(f0.b, 0.0, 1.0));
	// A gust passing: the blades bend over and show their lighter, yellower undersides.
	float g = n64_gust(hit.xz) * n64_gust_show() * gust_shine;
	col = mix(col, col * 1.35 + vec3(0.025, 0.03, 0.0), g / 0.3);
	ALBEDO = col * n64_grass_light(key_light) * n64_weather_tint.rgb;
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
	N64_FOG_GAMMA;
	N64_COVERAGE;
}
