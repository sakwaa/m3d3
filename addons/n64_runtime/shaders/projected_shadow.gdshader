shader_type spatial;
// ProjectedShadow receiver: a unit box (scaled by the node) that reprojects the depth buffer
// into box space and darkens it by the caster's silhouette, like a Decal but able to read a
// live ViewportTexture. +Y points at the light; uv = local xz. The caster writes stencil 1
// and is skipped, so it never shadows itself.
render_mode unshaded, cull_front, depth_test_disabled, depth_draw_never, blend_mix, shadows_disabled, fog_disabled;
stencil_mode read, compare_not_equal, 1;

#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform sampler2D silhouette : filter_nearest;
uniform vec3 to_light = vec3(0.0, 1.0, 0.0);
uniform float strength = 0.55;
/// Surfaces turned away from the light by less than this (dot) fade out.
uniform float normal_fade = 0.08;

varying flat mat4 world_to_box;

void vertex() {
	world_to_box = inverse(MODEL_MATRIX);
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
	vec3 n = normalize(cross(dFdx(world), dFdy(world)));
	if (dot(n, CAMERA_POSITION_WORLD - world) < 0.0) {
		n = -n;
	}
	float facing = smoothstep(0.0, normal_fade, dot(n, to_light));
	// Fade only the last few % of the box, so long shadows stay solid to the head.
	float reach = smoothstep(-0.5, -0.42, local.y);
	// N64 3-point blend between silhouette texels (same switch as level textures), so the
	// edge fades across the surface instead of stepping in hard pixels.
	vec2 suv = local.xz + 0.5;
	float a = n64_three_point ? n64_sample_level(silhouette, suv, 0).a : texture(silhouette, suv).a;
	ALBEDO = vec3(0.0);
	// Fogged ground hides the shadow too (fog itself isn't applied to the darkening).
	float fogged = n64_fog_amount(distance(world, n64_fog_origin)) * n64_fog.w;
	ALPHA = a * strength * facing * reach * (1.0 - fogged);
	FOG = vec4(0.0);
}
