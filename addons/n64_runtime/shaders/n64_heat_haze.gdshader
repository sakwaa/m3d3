shader_type spatial;
// Heat haze (fires, torches, lava, hot stones): a camera-facing card that redraws what's
// behind it shifted by rising, wavering noise. Only what's behind the card shifts - a read
// that lands on something in front (a hand, the torch itself) keeps its own pixel - the
// tag here is depth, as the water's wobble. Fades to nothing at the card's edges and top.
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable, hint_default_white;
// Sway at 5 m (share of the screen width), ripples per metre, rise speed (m/s).
uniform float strength = 0.012;
uniform float scale = 2.5;
uniform float rise = 1.2;
uniform float amount : hint_range(0.0, 1.0) = 1.0;

varying vec2 local_uv;

void vertex() {
	local_uv = UV;
	// Billboard about Y (stays upright over the fire).
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 to_cam = INV_VIEW_MATRIX[3].xyz - origin;
	to_cam.y = 0.0;
	vec3 right = length(to_cam) > 1e-4 ? normalize(vec3(to_cam.z, 0.0, -to_cam.x)) : vec3(1.0, 0.0, 0.0);
	vec3 world = origin + right * VERTEX.x * length(MODEL_MATRIX[0].xyz) + vec3(0.0, VERTEX.y * length(MODEL_MATRIX[1].xyz), 0.0);
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	POSITION = PROJECTION_MATRIX * vec4(VERTEX, 1.0);
}

void fragment() {
	float edge = smoothstep(0.0, 0.25, local_uv.x) * smoothstep(1.0, 0.75, local_uv.x)
		* smoothstep(0.0, 0.35, local_uv.y) * smoothstep(1.0, 0.85, local_uv.y);
	// Rising wobble: crossed sine waves climbing the card (cheap, no texture needed).
	float y = local_uv.y * scale * 4.0 - n64_time * rise * 6.0;
	vec2 sway = vec2(sin(y + sin(local_uv.x * 9.0 + n64_time * 2.0) * 1.5), cos(y * 0.7 + local_uv.x * 5.0)) * 0.5;
	vec2 suv = SCREEN_UV + sway * strength * 2.0 * 5.0 / max(length(VERTEX), 1.0) * edge * amount;
	// (a read landing in front of the card stays put)
	if (texture(depth_tex, suv).r > FRAGCOORD.z || any(lessThan(suv, vec2(0.0))) || any(greaterThan(suv, vec2(1.0)))) {
		suv = SCREEN_UV;
	}
	if (texture(depth_tex, SCREEN_UV).r > FRAGCOORD.z) {
		discard;  // (something in front of the card covers this pixel)
	}
	ALBEDO = texture(screen_tex, suv).rgb;
	ALPHA = 1.0;  // (the transparent pass: where the screen texture holds the scene)
}
