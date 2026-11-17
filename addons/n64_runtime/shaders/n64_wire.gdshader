shader_type spatial;
// Thin lines (wires, ropes, string-light cords, antennae) that never break into dashes:
// a camera-facing ribbon round the line's centre, at least `min_pixels` wide on screen;
// where the real line is thinner than that its coverage (real width / drawn width) becomes
// the alpha, so it fades out smoothly with distance instead of shimmering (the RDP's line
// coverage done properly; "phone-wire AA"). Blended, so the coverage tags behind survive
// (keep_coverage_alpha). Mesh: vertices on the centreline, CUSTOM0 = tangent xyz + side
// (-1 / 1). rescue off: drawn at its true width only (the breaking-up comparison).
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_never, skip_vertex_transform;

#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"

uniform vec4 line_color : source_color = vec4(0.12, 0.1, 0.09, 1.0);
/// Real thickness of the line (metres).
uniform float width = 0.03;
uniform float min_pixels = 1.0;
uniform bool rescue = true;
/// Lines the 3D picture is rendered at (VIEWPORT_SIZE is the window's, before 3D scaling;
/// RenderScale's target lines). 0: VIEWPORT_SIZE.
uniform float render_lines = 0.0;
/// Only where the line is thinner than ~2 pixels (a textured rope ribbon draws it nearer):
/// fades in from 3 px down to 1.5 px of real width.
uniform bool thin_only = false;

varying float cover;
varying float thin_k;
varying N64_SHADE vec2 n64_fogv;
varying N64_SHADE vec3 n64_fog_tintv;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 t = normalize((MODEL_MATRIX * vec4(CUSTOM0.xyz, 0.0)).xyz);
	vec3 to_cam = normalize(CAMERA_POSITION_WORLD - world);
	vec3 across = normalize(cross(t, to_cam));
	float z = max(-(VIEW_MATRIX * vec4(world, 1.0)).z, 1e-3);
	// One pixel at this distance (metres).
	float lines = render_lines > 0.0 ? render_lines : VIEWPORT_SIZE.y;
	float px = 2.0 * z / (abs(PROJECTION_MATRIX[1][1]) * lines);  // (y flipped on this renderer: abs)
	float half_w = width * 0.5;
	float drawn = rescue ? max(half_w, 0.5 * min_pixels * px) : half_w;
	cover = half_w / drawn;
	thin_k = thin_only ? 1.0 - smoothstep(1.5, 3.0, width / px) : 1.0;
	world += across * CUSTOM0.w * drawn;
	n64_fogv = n64_fog_vertex(world);
	n64_fog_tintv = n64_fog_tint_vertex(world);
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
}

void fragment() {
	ALBEDO = line_color.rgb * n64_world_tint.rgb;
	ALPHA = (rescue ? clamp(cover, 0.0, 1.0) : 1.0) * thin_k;
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
}
