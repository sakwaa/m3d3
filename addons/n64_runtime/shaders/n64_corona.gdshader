shader_type spatial;
// N64 light glow: a soft additive disc on each of the zone's four fog lights (the
// n64_fog_light_pos / col globals Zone picks), as strong as the fog's halos
// (n64_fog_lights.y, which rain raises) and stronger in the dark. Mesh: a quad per light,
// UV2.x = which light, UV = corner.
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, world_vertex_coords, fog_disabled;

#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"

uniform float size_per_range = 0.18;
uniform float min_size = 0.5;
uniform float max_size = 1.8;
uniform float strength = 0.55;

varying vec3 glow;

void vertex() {
	int i = int(UV2.x + 0.5);
	vec4 pos = i == 0 ? n64_fog_light_pos0 : i == 1 ? n64_fog_light_pos1 : i == 2 ? n64_fog_light_pos2 : n64_fog_light_pos3;
	vec4 col = i == 0 ? n64_fog_light_col0 : i == 1 ? n64_fog_light_col1 : i == 2 ? n64_fog_light_col2 : n64_fog_light_col3;
	vec3 cam = CAMERA_POSITION_WORLD;
	float halo = n64_fog_lights.y;
	bool shown = pos.w > 0.0 && halo > 0.0;
	// Brighter as the world darkens (night, storms).
	float dark = 1.0 - clamp(dot(n64_world_tint.rgb * n64_weather_tint.rgb, vec3(0.333)), 0.0, 1.0) * 0.7;
	glow = col.rgb * min(halo, 1.5) * strength * dark;
	vec3 c = pos.xyz + normalize(cam - pos.xyz) * 0.3;
	float s = clamp(pos.w * size_per_range, min_size, max_size) * (0.8 + 0.4 * min(halo, 1.0));
	vec2 q = UV * 2.0 - 1.0;
	vec3 p = c + INV_VIEW_MATRIX[0].xyz * q.x * s + INV_VIEW_MATRIX[1].xyz * q.y * s;
	VERTEX = shown ? p : cam - vec3(0.0, 1000.0, 0.0);
}

void fragment() {
	float d = length(UV * 2.0 - 1.0);
	float a = pow(max(1.0 - d, 0.0), 2.2);
	ALBEDO = glow * a;
}
