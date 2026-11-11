shader_type spatial;
// What's past the walls (Backdrop): the zones next door in a few flat-coloured polygons
// (vertex colours), tinted by the time of day / weather. Hazed like the far ring (not the
// zone's fog, which would hide it entirely): thinner close to the walls, as thick as the
// ring's by ring_distance, so the two read as one view. Two-sided: the level faces it
// comes from wind either way once flattened. Past the camera's far plane (the zone clips
// it at the fog's end) it still draws: depth kept just above zero, in order, in front of
// the ring.
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;

#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_weather.gdshaderinc"

// Time of day light (Zone.outdoor_light), like the effect sprites.
global uniform vec4 n64_ambient_light;

/// Fog-colour haze at ring_distance, in fair weather / in full rain (the ring's).
uniform vec2 haze = vec2(0.35, 0.85);
/// Metres from the camera where it's as hazy as the ring.
uniform float ring_distance = 160.0;

varying float dist;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	dist = distance(world, CAMERA_POSITION_WORLD);
	vec4 clip = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
	// Reversed Z (0 = far): never past the far plane, nearer things still in front.
	float z = max(clip.z / clip.w, 0.0) + 1e-5 / max(clip.w, 1.0);
	clip.z = z * clip.w;
	POSITION = clip;
}

void fragment() {
	float h = mix(haze.x, haze.y, clamp(n64_rain.x * 1.5, 0.0, 1.0)) * clamp(dist / ring_distance, 0.3, 1.0);
	ALBEDO = mix(COLOR.rgb * n64_ambient_light.rgb * n64_weather_tint.rgb, n64_fog_color.rgb, h);
}
