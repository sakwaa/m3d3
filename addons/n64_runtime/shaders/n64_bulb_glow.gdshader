shader_type spatial;
render_mode unshaded, cull_disabled, skip_vertex_transform, blend_add, depth_draw_never, shadows_disabled, fog_disabled;
// The soft glow round each string light bulb (StringLights): an additive billboard (VERTEX =
// the bulb's centre, UV = the corner, -1..1, UV2.x = the bulb's own random), in a few flat
// steps (N64: no smooth gradients), as strong as `glow` (0 by day); `flicker` 1: each bulb
// wavers a little on its own.
uniform vec4 color : source_color = vec4(1.0, 0.75, 0.4, 1.0);
uniform float radius = 0.25;
uniform float glow = 0.0;
uniform float flicker = 0.0;
uniform float strength = 0.75;
global uniform float n64_time;

varying float seed;

void vertex() {
	seed = UV2.x;
	vec4 c = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	VERTEX = c.xyz + vec3(UV * radius, 0.0);
	NORMAL = vec3(0.0, 0.0, 1.0);
}

void fragment() {
	float f = clamp(1.0 - length(UV), 0.0, 1.0);
	f = f * f;
	f = floor(f * 6.0 + 0.5) / 6.0;
	float w = 1.0 - flicker * 0.3 * (0.5 + 0.5 * sin(n64_time * (9.0 + seed * 7.0) + seed * 40.0));
	ALBEDO = color.rgb * f * glow * strength * w;
}
