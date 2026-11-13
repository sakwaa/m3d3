shader_type spatial;
// Far mountains (MountainRange): flat-shaded low-poly ridges far outside the level, drawn
// behind everything but the sky (in front of the backdrop ring's sky gap, behind the ring's
// painted neighbours), so the fog's draw distance never clips them, like the N64's distant
// ranges. Each layer hazes towards the fog colour by its own amount (UV.x: atmospheric
// perspective), more in rain and in thick fog; lit by the time of day's ambient.
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled, depth_draw_always;

#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_weather.gdshaderinc"

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

varying vec3 col;
varying float haze;
varying vec2 tuv;
varying float kind;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec4 clip = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
	// Reversed Z: tiny depths are far. Farther ridges smaller still, so layers sort right,
	// all behind the level and the backdrop ring (1e-9).
	float d = max(distance(world, CAMERA_POSITION_WORLD), 1.0);
	clip.z = clip.w * 2e-7 / d;
	POSITION = clip;
	col = pow(COLOR.rgb, vec3(2.2));
	kind = UV.y;
	vec3 n = abs(normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz));
	tuv = (n.y > max(n.x, n.z) ? world.xz : (n.x > n.z ? world.zy : world.xy)) / tex_scale;
	if (n.y <= max(n.x, n.z)) {
		tuv.y = -tuv.y;  // (walls: the texture upright)
	}
	// Thicker fog (short fog end) and rain hide the far ranges more.
	float fog_thick = smoothstep(160.0, 60.0, n64_fog.y) * n64_fog.w;
	float extra = clamp(fog_thick + n64_rain.x * 0.6, 0.0, 1.0);
	haze = clamp(UV.x + (1.0 - UV.x) * extra, 0.0, 1.0);
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
	vec3 lit = col * d * n64_ambient_light.rgb * n64_weather_tint.rgb;
	ALBEDO = mix(lit, n64_fog_color.rgb, haze);
}
