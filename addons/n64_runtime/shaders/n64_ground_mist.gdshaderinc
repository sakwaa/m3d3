// Ground mist (GroundMist): a slab of mist on the ground, `mist_height` deep, drawn as ONE
// shell (the slab's lid, ground + mist_height; plus a floor shell used only while the camera
// is inside the slab) that marches its own view ray through the slab in a few steps. The mist
// is a field of columns: the drifting cloud reads (two, scrolling apart: the combiner's
// two-texture trick) set how high the mist stands at each spot, so the top billows into
// silhouettes and thins into holes. Opacity builds with the distance travelled through it
// (Beer's law): thin seen from above, thick seen low - a volume, not stacked sheets. The steps
// start at a per-pixel offset from the RDP's magic square, so the stepping turns into a fine
// dither the VI's de-dither smooths away.
// Lit by the time of day like the effects, in the fog's colour, tops lighter; parted round
// actors (part_map); the march ends at the scene's depth, so walls and legs stand in it.
// The blended and dithered (G_AC_DITHER) shaders include this.
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_wind.gdshaderinc"

global uniform vec4 n64_ambient_light;

uniform sampler2D height_map : filter_linear, repeat_disable;
uniform bool has_map = false;
// x, z of the map's corner and its size (metres).
uniform vec4 map_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform sampler2D cloud_tex : filter_linear_mipmap, repeat_enable, hint_default_white;
uniform float mist_height = 0.7;
// Steps along each ray through the slab.
uniform float layer_count = 6.0;
uniform float amount = 1.0;
uniform float patch = 60.0;
// Metres per cloud repeat (two reads, the second smaller and turning the other way).
uniform float cloud_size = 12.0;
// Drift (metres / second at wind 1).
uniform float churn = 0.35;
uniform float density = 0.55;
// Opacity per metre travelled through full mist.
uniform float thickness = 1.6;
uniform vec3 mist_tint : source_color = vec3(1.0);
// Own colour (wind-blown dust: WindDust's sand colours, already toned for the hour) instead of
// the fog-pale, ambient-lit mist colour.
uniform bool solid_tint = false;
// Metres of clear air round the camera while it's inside (dust: you see the clouds blow past,
// not a wash right in front of you). 0 = none (the mist).
uniform float near_clear = 0.0;
// Inside the slab, march from the camera on the floor patch stretched over the whole screen
// (and skip the lid) instead of on the shells: a slab you stand in (dust, metres tall) has its
// shells behind walls and over terraces, and their edges would show (n64_ground_mist_open).
uniform bool screen_floor = false;
// Bunches (dust): a big, slow cloud read over the mist (metres per repeat; 0 = off) - inside a
// bunch the mist is `bunch_peak` x as thick and stands taller, elsewhere only `bunch_floor` x:
// mostly a light cover with the odd thick clump blowing through.
uniform float bunch_size = 0.0;
uniform float bunch_floor = 1.0;
uniform float bunch_peak = 1.0;
uniform vec2 bunch_range = vec2(0.45, 0.75);
// Brighter tops (light from above), darker floor of the mist.
uniform float top_light = 0.35;
// Disturbance (GroundMist's simulation, n64_mist_sim.gdshader): rg = how far the mist is
// pushed (metres), b = thinning, a = pile-up; part_rect = corner x, z, size.
uniform sampler2D part_map : filter_linear, repeat_disable, hint_default_black;
uniform vec4 part_rect = vec4(0.0, 0.0, 1.0, 1.0);

varying float is_lid;
varying float ground_ok;
varying vec3 world_pos;
varying vec2 n64_fogv;
varying vec3 n64_fog_tintv;

float mist_ground(vec2 xz) {
	vec2 uv = (xz - map_rect.xy) / map_rect.zw;
	if (!has_map || any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
		return -10000.0;
	}
	vec2 m = textureLod(height_map, uv, 0.0).rg;
	return m.g > 0.5 ? m.r : -10000.0;
}

// The height to put a vertex at: real ground, or the nearest ground's (filled cells), so the
// patch never folds down off the level.
float mist_vertex_height(vec2 xz) {
	vec2 uv = clamp((xz - map_rect.xy) / map_rect.zw, vec2(0.0), vec2(1.0));
	return has_map ? textureLod(height_map, uv, 0.0).r : 0.0;
}

void vertex() {
	is_lid = INSTANCE_CUSTOM.x;
	vec3 grid = VERTEX;
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	ground_ok = has_map ? 1.0 : 0.0;
	w.y = mist_vertex_height(w.xz) + (is_lid > 0.5 ? mist_height : 0.02);
	world_pos = w;
	VERTEX = (inverse(MODEL_MATRIX) * vec4(w, 1.0)).xyz;
	if (screen_floor && is_lid < 0.5) {
		// (the grid's square onto the screen's, past its edges and clamped: the grid is whole
		// spacings, a little short of the patch)
		POSITION = vec4(clamp(grid.xz / (patch * 0.4), vec2(-1.0), vec2(1.0)), 0.5, 1.0);
	} else {
		// (a shader that writes POSITION anywhere must write it everywhere)
		POSITION = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	}
	n64_fogv = n64_fog_vertex(w);
	n64_fog_tintv = n64_fog_tint_vertex(w);
}

// How high the mist stands at `xz`, 0..1 of the slab.
float mist_column(vec2 xz, float time) {
	vec2 wind = n64_wind.xy * churn * (0.5 + n64_wind.z);
	vec2 a = (xz - wind * time) / cloud_size;
	vec2 b = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * (xz + wind.yx * time * 0.7) / (cloud_size * 0.55);
	float d = texture(cloud_tex, a).r * 0.65 + texture(cloud_tex, b).r * 0.55;
	return clamp((d - (1.0 - density)) / max(density, 0.05) + 0.25, 0.0, 1.0);
}

// 0..1: how much of a bunch `xz` is in (blown with the wind, a little slower than the mist).
float mist_bunch(vec2 xz, float time) {
	if (bunch_size <= 0.0) {
		return 0.0;
	}
	vec2 wind = n64_wind.xy * churn * (0.5 + n64_wind.z) * 0.8;
	vec2 a = (xz - wind * time) / bunch_size;
	vec2 b = mat2(vec2(0.6, -0.8), vec2(0.8, 0.6)) * (xz - wind * time * 0.9) / (bunch_size * 0.6) + 0.37;
	float d = texture(cloud_tex, a).r * 0.7 + texture(cloud_tex, b).r * 0.3;
	return smoothstep(bunch_range.x, bunch_range.y, d);
}

// (kept for the dithered shader: the share one step adds)
float mist_layer_alpha() {
	return 1.0;
}

void mist_fragment(vec2 frag, vec2 screen_uv, vec3 view_pos, mat4 inv_proj, mat4 inv_view, sampler2D depth_tex,
		vec3 cam, float time, out vec3 color, out float alpha) {
	alpha = 0.0;
	color = vec3(0.0);
	if (ground_ok < 0.5) {
		return;
	}
	float gcam = mist_vertex_height(cam.xz);
	bool inside = cam.y < gcam + mist_height;
	// Outside (above) the slab: the lid starts the ray. Inside: the camera does, and the floor
	// shell catches the rays that never reach the lid.
	if (!inside && is_lid < 0.5) {
		return;
	}
	if (screen_floor && inside && is_lid > 0.5) {
		return;
	}
	vec3 start = inside ? cam : world_pos;
	// The ray ends at the scene (ground, a wall, a leg) or, inside, at this shell.
	float depth = texture(depth_tex, screen_uv).r;
	vec4 sv = inv_proj * vec4(screen_uv * 2.0 - 1.0, depth, 1.0);
	vec3 scene = (inv_view * vec4(sv.xyz / sv.w, 1.0)).xyz;
	vec3 end = scene;
	if (inside && !screen_floor && distance(cam, world_pos) < distance(cam, scene)) {
		end = world_pos;
	}
	vec3 ray = end - start;
	float len = length(ray);
	if (len <= 0.01 || (!inside && dot(ray, start - cam) < 0.0)) {
		return;
	}
	len = min(len, 18.0);  // (a ray skimming the slab: past this it's all mist anyway)
	vec3 dir = ray / length(ray);
	float steps = clamp(layer_count, 2.0, 12.0);
	float dl = len / steps;
	// Step offsets from a 4 x 4 ordered dither (all 16 levels: the magic square's 8 left the
	// steps lining up into contour lines up close); the VI's de-dither smooths it.
	ivec2 q = ivec2(frag) & ivec2(3);
	const float m[16] = float[16](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
	float jit = (m[q.x + q.y * 4] + 0.5) / 16.0;
	float od = 0.0;     // optical depth
	float lit = 0.0;    // height-weighted, for the light
	for (float i = 0.0; i < 12.0; i += 1.0) {
		if (i >= steps) {
			break;
		}
		vec3 p = start + dir * dl * (i + jit);
		float g = mist_vertex_height(p.xz);
		float y = (p.y - g) / max(mist_height, 0.05);
		if (y > 1.02 || y < -0.05) {
			continue;
		}
		// Disturbed: the columns read from where the mist was pushed from (dragged, streaked),
		// lowered where it's thinned, raised where it's heaped up.
		vec2 puv = (p.xz - part_rect.xy) / part_rect.z;
		vec4 dist = vec4(0.0);
		if (all(greaterThan(puv, vec2(0.0))) && all(lessThan(puv, vec2(1.0)))) {
			vec2 pe = min(puv, 1.0 - puv);
			dist = textureLod(part_map, puv, 0.0) * smoothstep(0.0, 0.1, min(pe.x, pe.y));
		}
		float col = mist_column(p.xz - dist.rg, time);
		col = col * (1.0 - 0.9 * clamp(dist.b, 0.0, 1.0)) + 0.45 * clamp(dist.a, 0.0, 1.0);
		float bunch = mist_bunch(p.xz, time);
		col = bunch_size > 0.0 ? col * mix(0.7, 1.15, bunch) : col;
		float inm = smoothstep(col + 0.22, col - 0.22, y);
		inm *= bunch_size > 0.0 ? mix(bunch_floor, bunch_peak, bunch) : 1.0;
		if (near_clear > 0.0) {
			inm *= smoothstep(near_clear * 0.3, near_clear, distance(p, cam));
		}
		od += inm * dl;
		lit += inm * dl * clamp(y, 0.0, 1.0);
	}
	if (od <= 0.0) {
		return;
	}
	float dist = length(start.xz - cam.xz);
	float far = 1.0 - smoothstep(patch * 0.38, patch * 0.5, dist);
	float near = inside ? 1.0 : smoothstep(0.3, 1.5, length(view_pos));
	alpha = (1.0 - exp(-thickness * od)) * far * near * amount;
	// Mist scatters the sky's light: pale, only part lit by the time of day (night mist goes
	// blue-grey with the ambient, never ground-coloured); its tops lighter.
	float h = lit / od;
	vec3 light = mix(n64_ambient_light.rgb, vec3(max(max(n64_ambient_light.r, n64_ambient_light.g), n64_ambient_light.b)), 0.5);
	if (solid_tint) {
		// (lit by the time of day like everything round it, so it never glows at dusk)
		color = mist_tint * mix(light, vec3(1.0), 0.45) * (1.0 - top_light * 0.5 + top_light * h);
		return;
	}
	vec3 base = mix(n64_fog_color.rgb, vec3(1.0), 0.55) * mist_tint;
	color = base * mix(light, vec3(1.0), 0.35) * (1.0 - top_light * 0.5 + top_light * h);
}
