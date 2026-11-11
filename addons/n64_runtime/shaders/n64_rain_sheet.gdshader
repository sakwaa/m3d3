shader_type spatial;
// N64 rain, far off: a ring of tall cards round the camera (Rain.make_sheet_mesh) with
// streaks drawn on them, falling, so the rain still reads as thick beyond the streaks of
// n64_rain.gdshader (which stop at the edge of their box). Fainter than the near streaks, gone
// with the rain (n64_rain.x), slanted with its wind (n64_rain.yz), fogged like the level.
// Mesh: quads in local space (x / z round the camera, y up); UV.x round the ring, UV.y down.
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled, world_vertex_coords;

#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"
#include "res://addons/n64_runtime/shaders/n64_weather.gdshaderinc"

uniform vec4 rain_color : source_color = vec4(0.85, 0.88, 0.95, 0.22);
// Streaks per metre across, their length (metres), how far apart they come down one column
// (metres) and how fast they fall (m/s). The pattern is fixed in the world (only the cards
// follow the camera), so walking about doesn't drag the rain along.
uniform float columns = 6.0;
uniform float length = 0.8;
uniform float spacing = 5.0;
uniform float fall_speed = 15.0;

varying vec2 n64_fogv;
varying vec3 n64_fog_tintv;
varying vec3 wpos;
varying vec2 tangent;
varying float edge_v;

void vertex() {
	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 p = VERTEX + vec3(cam.x, cam.y, cam.z);
	// Slant with the wind: the bottom pushed downwind.
	p.xz += vec2(n64_rain.y, n64_rain.z) * 0.08 * (1.0 - UV.y) * -1.0;
	n64_fogv = n64_fog_vertex(p);
	n64_fog_tintv = n64_fog_tint_vertex(p);
	wpos = p;
	tangent = normalize(vec2(-VERTEX.z, VERTEX.x));  // along the ring at this card
	edge_v = smoothstep(0.0, 0.15, UV.y) * smoothstep(1.0, 0.85, UV.y);
	VERTEX = n64_rain.x > 0.01 ? p : cam - vec3(0.0, 1000.0, 0.0);
}

float hash(float n) {
	return fract(sin(n * 91.3458) * 47453.5453);
}

void fragment() {
	float u = dot(wpos.xz, tangent) * columns;
	// A thin line in each column (a few cm across), not the whole column.
	if (fract(u) > 0.35) {
		discard;
	}
	float col = floor(u);
	float r = hash(col);
	// Most columns carry streaks; how many grows with the rain.
	if (r > n64_rain.x * 0.9) {
		discard;
	}
	// Falling: world height plus time (a streak keeps its place in the world).
	float y = fract((wpos.y + TIME * fall_speed * (0.8 + r * 0.4)) / (spacing * (0.7 + r * 0.6)) + hash(col + 7.1));
	if (y > length / (spacing * (0.7 + r * 0.6))) {
		discard;
	}
	ALBEDO = rain_color.rgb * n64_world_tint.rgb * n64_weather_tint.rgb;
	ALPHA = rain_color.a * edge_v * n64_rain.x;
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
}
