shader_type spatial;
// A box decal (scorch marks, blood, paint splats, blob shadows) that stays on the one
// surface it was put on: like ProjectedShadow it reprojects the depth buffer into the box,
// and with `clip_to_surface` it also reads the coverage tag under each pixel (the colour's
// alpha: brush / object code) and draws only where it matches the surface at the decal's
// centre - not up the crate beside it, the wall behind, or an actor walking through. (The
// RDP's decal mode, but by surface identity instead of depth.)
render_mode unshaded, cull_front, depth_test_disabled, depth_draw_never, blend_mix, shadows_disabled, fog_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;
uniform sampler2D decal : source_color, filter_nearest, hint_default_white;
uniform vec4 tint : source_color = vec4(0.08, 0.05, 0.03, 0.9);
uniform bool clip_to_surface = true;
/// Debug: 1 box-local position as colour, 2 surface codes as colour.
uniform int debug_view = 0;

varying flat mat4 world_to_box;
varying flat vec4 centre_clip;

void vertex() {
	world_to_box = inverse(MODEL_MATRIX);
	// The surface the decal was put on: under its centre, at the bottom of the box.
	centre_clip = PROJECTION_MATRIX * VIEW_MATRIX * MODEL_MATRIX * vec4(0.0, -0.45, 0.0, 1.0);
}

bool tagged(float a) {
	return a > 0.5 && abs(a - round(a)) < 0.02;
}

float code_at(vec2 uv) {
	float a = texture(screen_tex, uv).a;
	return tagged(a) ? floor(a / 16.0) : -1.0;
}

bool same_surface(float a, float b) {
	if (a < 0.0 || b < 0.0 || a >= 64.0 || b >= 64.0) {
		return a == b;
	}
	// Level geometry: same facing and the same brush (7: no brush ID - facing alone).
	return floor(a / 8.0) == floor(b / 8.0) && (mod(a, 8.0) == mod(b, 8.0) || mod(a, 8.0) == 7.0);
}

void fragment() {
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	view.xyz /= view.w;
	vec3 world = (INV_VIEW_MATRIX * vec4(view.xyz, 1.0)).xyz;
	vec3 local = (world_to_box * vec4(world, 1.0)).xyz;
	if (any(greaterThan(abs(local), vec3(0.5)))) {
		discard;
	}
	if (clip_to_surface) {
		vec2 cuv = centre_clip.xy / centre_clip.w * 0.5 + 0.5;
		if (!same_surface(code_at(SCREEN_UV), code_at(cuv))) {
			discard;
		}
	}
	vec4 d = texture(decal, local.xz + 0.5);
	ALBEDO = tint.rgb * d.rgb;
	ALPHA = tint.a * d.a;
	if (debug_view == 1) {
		ALBEDO = local + 0.5;
		ALPHA = 1.0;
	} else if (debug_view == 2) {
		float k = code_at(SCREEN_UV);
		ALBEDO = vec3(fract(k * 0.137), fract(k * 0.311), fract(k * 0.071));
		ALPHA = 1.0;
	}
	FOG = vec4(0.0);
}
