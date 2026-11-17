shader_type spatial;
// Far mountains (MountainRange): flat-shaded low-poly ridges far outside the level, drawn
// behind everything but the sky (in front of the backdrop ring's sky gap, behind the ring's
// painted neighbours), so the fog's draw distance never clips them, like the N64's distant
// ranges. Each layer hazes towards the fog colour by its own amount (UV.x: atmospheric
// perspective), more in rain and in thick fog; lit by the time of day's ambient.
// Far translation (Ocarina of Time's backgrounds, Kaze's render-matrix trick): the range
// moves with the camera's position (`follow`, 1 = fully: infinitely far, no parallax however
// far you walk; less keeps a hint of it), never its rotation. Textures stay put on the
// mountains (they're sampled where the ridge was built).
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled, depth_draw_always;

#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_weather.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_coverage.gdshaderinc"

global uniform vec4 n64_ambient_light;

// Large-scale textures per face kind (UV.y: 0 foot, 1 rock, 2 snow), projected from the
// face's main axis in world metres. They add detail around the face's own colour (the
// texture divided by its average), so the colours stay MountainRange's.
uniform sampler2D foot_tex : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
uniform sampler2D rock_tex : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
uniform sampler2D snow_tex : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
uniform float tex_scale = 60.0;
uniform float detail = 0.8;
// > 1: the textures' light and dark pushed apart (soft photos read at a distance).
uniform float tex_contrast = 1.8;
// The zone's fog start / end as set (before the time of day scales it): MountainRange.
uniform vec2 fog_ref = vec2(90.0, 220.0);
// Far translation: share of the camera's offset from the range's centre the range follows.
uniform float follow = 1.0;
// ... and of its height (0: the range stays on the ground - climbing up shows more of it,
// never its underside).
uniform float follow_height = 0.0;
// Two-scale ground (OoT's Hyrule Field look) on the foot and rock faces when ground_tex is
// set: a detail texture (dirt) tiled small, mottled by a blend texture tiled large, both
// around their own average (the colours stay the range's). blend_amount 0 = detail only.
uniform sampler2D ground_tex : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
uniform sampler2D blend_tex : source_color, filter_nearest_mipmap, repeat_enable, hint_default_white;
uniform bool use_ground = false;
uniform float ground_scale = 14.0;
uniform float blend_scale = 160.0;
uniform float blend_amount = 0.7;

varying vec3 col;
varying float haze;
varying vec2 tuv;
varying vec2 wuv;  // world metres on the face's main axis
varying float kind;

void vertex() {
	vec3 built = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 off = CAMERA_POSITION_WORLD - MODEL_MATRIX[3].xyz;
	vec3 world = built + vec3(off.x * follow, off.y * follow_height, off.z * follow);
	vec4 clip = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
	// Reversed Z: tiny depths are far. Farther ridges smaller still, so layers sort right,
	// all behind the level and the backdrop ring (1e-9).
	float d = max(distance(world, CAMERA_POSITION_WORLD), 1.0);
	clip.z = clip.w * 2e-7 / d;
	clip.xy = mat2(n64_distort.xy, n64_distort.zw) * clip.xy;  // (ScreenDistortion)
	POSITION = clip;
	col = pow(COLOR.rgb, vec3(2.2));
	kind = UV.y;
	vec3 n = abs(normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz));
	wuv = n.y > max(n.x, n.z) ? built.xz : (n.x > n.z ? built.zy : built.xy);
	if (n.y <= max(n.x, n.z)) {
		wuv.y = -wuv.y;  // (walls: the texture upright)
	}
	tuv = wuv / tex_scale;
	// Fogged like the level: each layer stands at the virtual distance where the zone's own
	// (daytime) fog gives its haze (fog_ref: that fog's start / end), and the fog now - the
	// time key closing it in at night, the weather, a room - decides how much shows.
	float dv = mix(fog_ref.x, fog_ref.y, UV.x);
	float f = clamp((dv - n64_fog.x) / max(n64_fog.y - n64_fog.x, 1.0), 0.0, 1.0);
	float h = mix(UV.x, f, clamp(n64_fog.w, 0.0, 1.0));
	// Rain hides the far ranges more.
	haze = clamp(h + (1.0 - h) * n64_rain.x * 0.6, 0.0, 1.0);
}

void fragment() {
	vec3 t;
	vec3 mean;
	if (kind < 0.5) {
		t = n64_texture(foot_tex, tuv).rgb;
		mean = textureLod(foot_tex, vec2(0.5), 16.0).rgb;
	} else if (kind < 1.5) {
		t = n64_texture(rock_tex, tuv).rgb;
		mean = textureLod(rock_tex, vec2(0.5), 16.0).rgb;
	} else {
		t = n64_texture(snow_tex, tuv).rgb;
		mean = textureLod(snow_tex, vec2(0.5), 16.0).rgb;
	}
	vec3 d = mix(vec3(1.0), clamp(pow(t / max(mean, vec3(0.02)), vec3(tex_contrast)), 0.0, 2.5), detail);
	if (use_ground && kind < 1.5) {
		vec3 g = n64_texture(ground_tex, wuv / ground_scale).rgb;
		vec3 gm = textureLod(ground_tex, vec2(0.5), 16.0).rgb;
		vec3 b = n64_texture(blend_tex, wuv / blend_scale).rgb;
		vec3 bm = textureLod(blend_tex, vec2(0.5), 16.0).rgb;
		vec3 gd = clamp(pow(g / max(gm, vec3(0.02)), vec3(tex_contrast)), 0.0, 2.5);
		vec3 bd = clamp(pow(b / max(bm, vec3(0.02)), vec3(tex_contrast)), 0.0, 2.5);
		d = mix(vec3(1.0), gd * mix(vec3(1.0), bd, blend_amount), detail);
	}
	vec3 lit = col * d * n64_ambient_light.rgb * n64_weather_tint.rgb;
	ALBEDO = mix(lit, n64_fog_color.rgb, haze);
	N64_COVERAGE;
}
