shader_type spatial;
// LensFlare: Ocarina of Time's sun flare, as its decomp draws it (references/sun_flare/
// OOT_SUN_FLARE.md). Ten billboards placed in the world along the line from the sun back
// towards the middle of the view (so the later ones, nearer the camera, come out bigger),
// each a flat colour with the texture as its alpha (combiner: PRIM, alpha TEXEL0 x PRIM),
// blended normally (G_RM_CLD_SURF), no depth test; then a full-screen glare when looking
// near the sun. LensFlare (CPU) eases the visibility and the glare as OoT did.
// Mesh: one quad per element, VERTEX.xy = corner (-1..1), VERTEX.z = element index
// (0..9 sprites, 10 the glare).
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled, fog_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform sampler2D disc_tex : filter_linear, hint_default_white;
uniform sampler2D ring_tex : filter_linear, hint_default_white;
// World direction towards the sun.
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);
// x = colour intensity share (OoT's min(colorIntensity / 10, 1), x weather), y = eased
// visibility (lensFlareAlphaScale), z = glare alpha (0..1), w = glare tint t (0 dusk .. 1 noon).
uniform vec4 state = vec4(0.0);
// Where the billboards sit (metres from the camera to the sun's stand-in; any distance gives
// the same picture, kept inside the camera's far plane).
uniform float distance_m = 40.0;
// Pixels between the depth taps around the sun (a fallback for what the CPU's ray misses:
// trees, mountains - things without collision).
uniform float probe_spread = 3.0;

const int COUNT = 10;
const float SCALE[COUNT] = float[](23.0, 12.0, 7.0, 5.0, 3.0, 10.0, 6.0, 2.0, 3.0, 1.0);
const vec3 COL[COUNT] = vec3[](vec3(155.0, 205.0, 255.0), vec3(255.0, 255.0, 205.0), vec3(255.0, 255.0, 205.0),
	vec3(255.0, 255.0, 205.0), vec3(155.0, 255.0, 205.0), vec3(205.0, 255.0, 255.0), vec3(155.0, 155.0, 255.0),
	vec3(205.0, 175.0, 255.0), vec3(175.0, 255.0, 205.0), vec3(255.0, 155.0, 235.0));
const float F_ALPHA[COUNT] = float[](50.0, 10.0, 25.0, 40.0, 70.0, 30.0, 50.0, 70.0, 50.0, 40.0);
// OoT's sun sits ~3000 units from the eye; a sprite is a 64-unit quad.
const float SUN_UNITS = 3000.0;

varying flat vec4 element;  // rgb colour, a alpha
varying flat float kind;    // 0 disc, 1 ring, 2 glare
varying flat vec2 sun_uv;
varying vec2 corner;

void vertex() {
	int i = int(VERTEX.z + 0.5);
	corner = VERTEX.xy;
	vec3 look = -normalize(INV_VIEW_MATRIX[2].xyz);
	vec3 sun = normalize(sun_dir);
	vec3 half_pos = look * 0.5;
	vec3 pos_dir = normalize(sun - half_pos);
	float cos_a = dot(look, pos_dir);
	vec4 sc = PROJECTION_MATRIX * vec4((VIEW_MATRIX * vec4(sun, 0.0)).xyz, 0.0);
	sun_uv = sc.w > 1e-4 ? (sc.xy / sc.w) * 0.5 + 0.5 : vec2(-1.0);
	POSITION = vec4(0.0);
	if (i >= COUNT) {
		// The glare: a full-screen fill.
		kind = 2.0;
		float t = state.w;
		element = vec4(1.0, (180.0 + 75.0 * t) / 255.0, (100.0 + 155.0 * t) / 255.0, state.z);
		if (state.z > 0.0) {
			POSITION = vec4(VERTEX.xy, 0.0, 1.0);
		}
	} else if (cos_a >= 0.0 && state.x * state.y > 0.0) {
		kind = i == 0 ? 1.0 : 0.0;
		element = vec4(COL[i] / 255.0, state.x * F_ALPHA[i] / 255.0 * state.y);
		// FOV weight: 1 at 60 degrees (and wider), 0 at 15 (zoomed in).
		float fov = degrees(2.0 * atan(1.0 / PROJECTION_MATRIX[1][1]));
		float fov_w = min(1.0 - (60.0 - fov) / 45.0, 1.0);
		float half_size = 32.0 * SCALE[i] * cos_a * 0.001 * (370.0 + 630.0 * fov_w) / SUN_UNITS;
		vec3 centre = (sun - pos_dir * float(i) / 12.0) * distance_m;
		vec4 v = VIEW_MATRIX * vec4(CAMERA_POSITION_WORLD + centre, 1.0);
		v.xy += VERTEX.xy * half_size * distance_m;  // (billboard: facing the camera)
		POSITION = PROJECTION_MATRIX * v;
		POSITION.z = POSITION.w * 0.5;  // (never clipped by depth; drawn over everything)
	}
}

void fragment() {
	// Share of the sun's neighbourhood that's open sky (reversed Z: the sky is at 0).
	vec2 px = probe_spread / VIEWPORT_SIZE;
	float open = 0.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			open += texture(depth_tex, sun_uv + vec2(float(x), float(y)) * px).r <= 0.0 ? 1.0 : 0.0;
		}
	}
	open /= 9.0;
	if (kind > 1.5) {
		ALBEDO = element.rgb;
		ALPHA = element.a * open;
	} else {
		vec2 uv = corner * 0.5 + 0.5;
		float a = kind > 0.5 ? texture(ring_tex, uv).r : texture(disc_tex, uv).r;
		ALBEDO = element.rgb;
		ALPHA = element.a * a * open;
	}
}
