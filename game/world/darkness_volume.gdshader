shader_type spatial;
// Multiplies every opaque pixel inside the box toward black along local -Z.
// Drawn as back faces without depth test so it also works with the camera inside.
render_mode unshaded, blend_mul, cull_front, depth_test_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec3 box_min = vec3(-1.5, -0.5, -5.0);
uniform vec3 box_max = vec3(1.5, 3.5, 0.0);
// 0 = the box_max.z face (threshold), 1 = the box_min.z face (deep end).
uniform float fade_start : hint_range(0.0, 1.0) = 0.1;
uniform float fade_end : hint_range(0.0, 1.0) = 0.8;
// Pixels that see through the box (nothing inside it) take the fade at its exit point,
// so looking down a corridor past its floor shows black instead of sky.
uniform bool black_beyond = true;
// The threshold's opening (x from / to, y from / to; all zero = none): surfaces at or in front
// of the threshold (z >= 0) outside it, i.e. the room's wall around the doorway, stay lit.
uniform vec4 opening = vec4(0.0);
// Arched opening: x = 1 round / 2 pointed (0 flat), y = springing height; round: z = half
// width, w = rise; pointed: z = arc centre x, w = radius.
uniform vec4 opening_arch = vec4(0.0);

bool outside_arch(vec3 p) {
	if (opening_arch.x < 0.5 || p.y <= opening_arch.y) {
		return false;
	}
	vec2 q = vec2(p.x, p.y - opening_arch.y);
	if (opening_arch.x < 1.5) {
		vec2 e = q / max(opening_arch.zw + vec2(0.02), vec2(0.001));
		return dot(e, e) > 1.0;
	}
	return length(vec2(-abs(q.x) - opening_arch.z, q.y)) > opening_arch.w + 0.02;
}

void fragment() {
	float depth = texture(depth_texture, SCREEN_UV).r;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	view.xyz /= view.w;
	mat4 to_local = inverse(MODEL_MATRIX);
	vec3 scene = (to_local * (INV_VIEW_MATRIX * vec4(view.xyz, 1.0))).xyz;
	vec3 cam = (to_local * vec4(INV_VIEW_MATRIX[3].xyz, 1.0)).xyz;

	// Clip the camera -> scene segment against the box (slab test, t in 0..1).
	vec3 dir = scene - cam;
	vec3 inv_dir = 1.0 / dir;
	vec3 t0 = (box_min - cam) * inv_dir;
	vec3 t1 = (box_max - cam) * inv_dir;
	vec3 t_lo = min(t0, t1);
	vec3 t_hi = max(t0, t1);
	float t_enter = max(max(t_lo.x, t_lo.y), t_lo.z);
	float t_exit = min(min(t_hi.x, t_hi.y), t_hi.z);
	if (t_exit < max(t_enter, 0.0) || t_enter > 1.0) {
		discard;
	}
	vec3 p = scene;
	if (t_exit < 1.0) {
		// Only rays that leave through the deep end (looking down the corridor) go dark;
		// leaving through the top or sides is open sky / the zone, untouched.
		bool deep_end = dir.z < 0.0 && t_hi.z <= min(t_hi.x, t_hi.y);
		if (!black_beyond || !deep_end) {
			discard;
		}
		p = cam + dir * t_exit;
	} else if (opening != vec4(0.0) && p.z > -0.05
			&& (p.x < opening.x - 0.02 || p.x > opening.y + 0.02 || p.y < opening.z - 0.02 || p.y > opening.w + 0.02
				|| outside_arch(p))) {
		discard;
	}
	float into = clamp((box_max.z - p.z) / max(box_max.z - box_min.z, 0.001), 0.0, 1.0);
	// Half linear, half eased: darkening starts visibly at the front edge, no hard knee.
	float t = clamp((into - fade_start) / max(fade_end - fade_start, 0.001), 0.0, 1.0);
	ALBEDO = vec3(1.0 - mix(t, t * t * (3.0 - 2.0 * t), 0.5));
}
