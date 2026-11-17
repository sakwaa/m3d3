shader_type spatial;
// LightningBolts: colour (PRIM - ENV) x texel + ENV (cyan in the dim texels, white in the
// core), alpha PRIM.a x texel (at most half opaque), depth-tested (mountains hide them), no
// depth write, no fog.
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform sampler2D frames : filter_linear, repeat_disable;
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"

void vertex() {
	// Behind everything but the sky (the zone's camera stops at the fog's end; OoT's bolts
	// stand 9500 units out): depth just in front of the far plane, so mountains and roofs
	// still hide them.
	vec4 clip = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	clip.xy = mat2(n64_distort.xy, n64_distort.zw) * clip.xy;
	clip.z = clip.w * 1e-9;
	POSITION = clip;
}

void fragment() {
	float t = texture(frames, UV).r;
	ALBEDO = mix(vec3(0.0, 1.0, 1.0), vec3(1.0), t);
	ALPHA = t * 128.0 / 255.0;
}
