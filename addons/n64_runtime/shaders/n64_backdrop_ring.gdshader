shader_type spatial;
// The far ring (Backdrop): what lies beyond the zones next door, painted at bake time onto
// a ring of cards round the camera, drawn behind everything (only the sky is further), so
// it never gets closer however far you walk, like the N64's painted backgrounds. Hazed
// towards the fog colour (more in rain).
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled, depth_draw_always;

#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_weather.gdshaderinc"

// Time of day light (Zone.outdoor_light), like the effect sprites.
global uniform vec4 n64_ambient_light;

uniform sampler2D ring : source_color, filter_linear, repeat_disable;
/// How far it fades into the fog colour: in fair weather / in full rain.
uniform vec2 haze = vec2(0.35, 0.85);

void vertex() {
	// Round the camera, at the far end of the depth range (reversed Z: 0 is far).
	vec3 world = CAMERA_POSITION_WORLD + VERTEX;
	vec4 clip = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
	clip.z = clip.w * 1e-9;  // behind the near backdrop too
	POSITION = clip;
}

void fragment() {
	vec4 c = texture(ring, UV);
	if (c.a < 0.5) {
		discard;
	}
	float h = mix(haze.x, haze.y, clamp(n64_rain.x * 1.5, 0.0, 1.0));
	ALBEDO = mix(c.rgb * n64_ambient_light.rgb * n64_weather_tint.rgb, n64_fog_color.rgb, h);
}
