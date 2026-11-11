shader_type spatial;
// N64 rain: a couple of thousand thin streaks in a box around the camera, each a short
// string of drops (like the roof drips, n64_drip.gdshader, at a size that reads across town). Each streak's place is
// fixed in the world (its seed x the box, falling with time) and wraps around the box, so
// moving the camera moves the box, never the rain. Streaks stop on the RainCover (none under
// roofs or awnings); n64_rain.x picks how many show, n64_rain.yz slants them.
// Mesh (Rain.make_mesh): a quad per streak, CUSTOM0 = (seed xyz in 0..1, pick), UV = corner
// (x across, y along the streak).
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled, world_vertex_coords;

#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_weather.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_rain_light.gdshaderinc"

// The box (metres), centred a little ahead of the camera; streaks fade out towards its edge
// (fade_from .. 0.5 of its width from the camera), so the rain reaches well past the player.
uniform vec3 box = vec3(56.0, 20.0, 56.0);
uniform float fade_from = 0.38;
uniform float fall_speed = 15.0;
uniform float streak_length = 0.9;
// Streak width (metres), widened with distance so far streaks stay about a pixel wide.
uniform float streak_width = 0.012;
uniform float pixel_angle = 0.0018;
// Drops per streak; how much of each is water in light rain / at full rain.
uniform float drops = 2.5;
uniform vec2 drop_fill = vec2(0.4, 0.75);
// Tint on the light the rain catches (n64_rain_light.gdshaderinc), and its opacity when lit.
uniform vec4 rain_color : source_color = vec4(0.95, 0.97, 1.0, 0.55);

varying float alpha;
varying vec4 lit;
varying float seed;
varying float dist;

void vertex() {
	vec3 vel = vec3(n64_rain.y, -fall_speed, n64_rain.z);
	vec3 dir = normalize(vel);
	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 ahead = -INV_VIEW_MATRIX[2].xyz;
	ahead.y = 0.0;
	ahead = length(ahead) > 0.01 ? normalize(ahead) : vec3(0.0, 0.0, -1.0);
	vec3 lo = cam + ahead * box.x * 0.2 - box * 0.5;
	// World-anchored, wrapped into the box.
	vec3 top = lo + mod(CUSTOM0.xyz * box + vel * TIME - lo, box);
	float cover = n64_cover_height(top.xz);
	vec3 bottom = top + dir * streak_length;
	bottom.y = max(bottom.y, cover);
	vec3 p = mix(top, bottom, UV.y);
	float d = distance(p, cam);
	vec3 side = normalize(cross(dir, normalize(cam - p)));
	p += side * max(streak_width, d * pixel_angle) * (UV.x * 2.0 - 1.0);
	bool shown = CUSTOM0.w < n64_rain.x && top.y > cover;
	alpha = shown ? (1.0 - smoothstep(box.x * fade_from, box.x * 0.5, d)) * smoothstep(0.4, 1.5, d) : 0.0;
	seed = fract(CUSTOM0.x * 13.7 + CUSTOM0.z * 7.3);
	dist = d;
	// Lit per streak (its middle), so every vertex of it agrees.
	lit = n64_rain_lit(mix(top, bottom, 0.5), cam, seed, 0.0);
	VERTEX = shown ? p : cam - vec3(0.0, 1000.0, 0.0);
}

void fragment() {
	// A string of drops, each brightest at its leading (lower) end; heavier rain joins them.
	// Far off (a pixel wide) the gaps would only shimmer: there it's an even faint line.
	float fill = mix(drop_fill.x, drop_fill.y, clamp(n64_rain.x * 1.6, 0.0, 1.0));
	float b = fract(UV.y * drops + seed * 3.0);
	float drop = (1.0 - smoothstep(fill * 0.7, fill, b)) * mix(0.45, 1.0, clamp(b / fill, 0.0, 1.0));
	drop = mix(drop, fill * 0.75, smoothstep(10.0, 20.0, dist));
	// Soft across, like the drips' streams.
	float thin = 1.0 - smoothstep(0.3, 0.5, abs(UV.x - 0.5));
	ALBEDO = rain_color.rgb * lit.rgb;
	ALPHA = rain_color.a * lit.w * alpha * drop * thin;
}
