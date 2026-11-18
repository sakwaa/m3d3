shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never;
// Water pouring (a noria's buckets tipping into its trough): a falling sheet, streaks
// scrolling down, frothy and see-through at its edges, faded in by `amount`.

uniform float amount = 1.0;
uniform float seed = 0.0;
uniform float speed = 3.0;
uniform vec4 color : source_color = vec4(0.72, 0.86, 0.95, 1.0);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	// (always facing the camera round its own vertical line)
	vec3 up = normalize(MODEL_MATRIX[1].xyz);
	vec3 to_cam = normalize(INV_VIEW_MATRIX[3].xyz - MODEL_MATRIX[3].xyz);
	vec3 side = normalize(cross(up, to_cam));
	vec3 world = MODEL_MATRIX[3].xyz + side * VERTEX.x * length(MODEL_MATRIX[0].xyz) + up * VERTEX.y * length(MODEL_MATRIX[1].xyz);
	VERTEX = (inverse(MODEL_MATRIX) * vec4(world, 1.0)).xyz;
}

void fragment() {
	float x = UV.x;
	float streak = floor(x * 6.0);
	float v = UV.y - TIME * speed * (0.8 + hash(vec2(streak, seed)) * 0.4);
	float s = step(0.35, fract(v * 1.5 + hash(vec2(streak, seed + 3.0))));
	float edge = 1.0 - pow(abs(x * 2.0 - 1.0), 3.0);
	ALBEDO = mix(color.rgb, vec3(1.0), s * 0.35);
	ALPHA = amount * edge * (0.45 + s * 0.4) * smoothstep(0.0, 0.15, 1.0 - UV.y);
}
