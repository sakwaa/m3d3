shader_type spatial;
// True sight: a mesh's triangles drawn as glowing wire (BARYCENTRIC, engine patch 0002),
// through walls - for hidden passages, spirit paths, secrets inside a fog bank. Added on top
// (a next_pass, or an overlay MeshInstance); `reveal` 0..1 fades it, a bright band sweeps
// up through it. Without the patch nothing draws.
render_mode unshaded, blend_add, cull_back, depth_draw_never, depth_test_disabled, shadows_disabled, fog_disabled;

uniform vec4 wire_color : source_color = vec4(0.45, 0.9, 1.0, 1.0);
uniform float reveal : hint_range(0.0, 1.0) = 1.0;
/// Line width (pixels).
uniform float line_px = 1.0;
/// Fill between the lines (a faint ghost of the faces).
uniform float fill = 0.06;
uniform float sweep_speed = 0.8;

varying vec3 world_v;

void vertex() {
	world_v = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
#if defined(M3D3_BARYCENTRIC)
	vec3 d = BARYCENTRIC / max(fwidth(BARYCENTRIC), vec3(1e-6));
	float e = min(min(d.x, d.y), d.z);
	float line = 1.0 - smoothstep(line_px * 0.5, line_px * 0.5 + 1.0, e);
	float band = 1.0 - smoothstep(0.0, 0.6, abs(fract(world_v.y * 0.35 - TIME * sweep_speed) - 0.5) * 2.0 - 0.4);
	float a = (line * (0.75 + 0.6 * band) + fill) * reveal;
	if (a < 0.003) {
		discard;
	}
	ALBEDO = wire_color.rgb;
	ALPHA = clamp(a, 0.0, 1.0);
#else
	discard;
#endif
}
