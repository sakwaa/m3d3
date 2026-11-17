shader_type spatial;
// Ground mist, blended, for a slab the camera usually stands in (GroundMist made as dust):
// inside, one screen-filling pass marches from the camera (screen_floor); outside, the lid
// starts the march. No depth test: depth-tested, the lid behind a wall left the wall below it
// with no fragment to march - a hard line of dust across it; the march stops at the scene's
// depth itself (and the lid behind the scene gives up). Code: n64_ground_mist.gdshaderinc.
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled;
#include "res://addons/n64_runtime/shaders/n64_ground_mist.gdshaderinc"

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

void fragment() {
	vec3 c;
	float a;
	mist_fragment(FRAGCOORD.xy, SCREEN_UV, VERTEX, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX, depth_tex, CAMERA_POSITION_WORLD, n64_time, c, a);
	if (a <= 0.002) {
		discard;
	}
	ALBEDO = c;
	ALPHA = a;
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
}
