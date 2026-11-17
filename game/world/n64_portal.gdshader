shader_type spatial;
// A portal's surface (PortalChain): whichever camera draws it - the main view, or a level
// of the chain seeing the portal again through itself - shows the next level's picture,
// mapped by screen position (each level renders only the portal's rectangle on the level
// before). The level is found by the camera's position. Past the last level (too small, or
// another portal's chain looking at it) it shows `fallback`, faded with the fog colour.
// Tagged as an object for the coverage pass: its rim is anti-aliased like any silhouette,
// and N64VideoOut counts its visible pixels (object_id) to tell whether it's seen at all.
render_mode unshaded, cull_back, shadows_disabled, fog_disabled;

instance uniform int object_id = 0;
#define N64_OBJECT_CODE n64_object_code_id(MODEL_MATRIX, object_id, 1.0)
#include "res://addons/n64_runtime/shaders/n64_coverage.gdshaderinc"

const int MAX_LEVELS = 8;
uniform sampler2D views[MAX_LEVELS] : source_color, filter_nearest, repeat_disable;
// rects[k]: level k's window on the main screen (UV x, y, w, h); rects[0] = the whole screen.
uniform vec4 rects[MAX_LEVELS + 1];
uniform vec3 cam_pos[MAX_LEVELS + 1];
uniform int levels = 0;
uniform vec3 fallback : source_color = vec3(0.02, 0.02, 0.03);

void fragment() {
	int k = -1;
	for (int i = 0; i <= MAX_LEVELS; i++) {
		if (distance(CAMERA_POSITION_WORLD, cam_pos[i]) < 0.002) {
			k = i;
			break;
		}
	}
	vec3 c = fallback;
	if (k >= 0 && k < levels) {
		vec2 main_uv = rects[k].xy + SCREEN_UV * rects[k].zw;
		vec2 uv = (main_uv - rects[k + 1].xy) / rects[k + 1].zw;
		// (sampler arrays index by constant on some backends: unrolled)
		if (k == 0) c = texture(views[0], uv).rgb;
		else if (k == 1) c = texture(views[1], uv).rgb;
		else if (k == 2) c = texture(views[2], uv).rgb;
		else if (k == 3) c = texture(views[3], uv).rgb;
		else if (k == 4) c = texture(views[4], uv).rgb;
		else if (k == 5) c = texture(views[5], uv).rgb;
		else if (k == 6) c = texture(views[6], uv).rgb;
		else c = texture(views[7], uv).rgb;
	}
	ALBEDO = c;
	N64_COVERAGE_OBJECT;
}
