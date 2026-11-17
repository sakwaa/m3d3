shader_type spatial;
// Ground mist, dithered (GroundMist.dither): drawn solid with pixels dropped by the RDP's
// magic square (G_AC_DITHER) - no sorting; the VI's de-dither softens it as on the N64.
// MIST_NOISE 1: per-frame noise instead (the RDP's random alpha compare; gritty, shimmers). Code: n64_ground_mist.gdshaderinc.
// (Reads the scene depth, so it still draws in the transparent pass, fully opaque.)
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;
#define MIST_NOISE false
#include "res://addons/n64_runtime/shaders/n64_ground_mist.gdshaderinc"

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
/// Debug: drawn pixels in flat magenta (which pixels the dither keeps; render checks).
uniform bool mask_view = false;

void fragment() {
	vec3 c;
	float a;
	mist_fragment(FRAGCOORD.xy, SCREEN_UV, VERTEX, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX, depth_tex, CAMERA_POSITION_WORLD, n64_time, c, a);
	// The march's opacity against the RDP's magic square (or per-frame noise).
	if (!n64_alpha_dither(a, FRAGCOORD.xy, MIST_NOISE, n64_time)) {
		discard;
	}
	ALBEDO = c;
	ALPHA = 1.0;
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
	if (mask_view) {
		ALBEDO = vec3(1.0, 0.0, 1.0);
		FOG = vec4(0.0);
	}
}
