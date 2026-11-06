shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

// Cell size of the checker, driven by the editor snap setting.
global uniform float level_grid_size;

uniform vec3 color_a : source_color = vec3(0.40);
uniform vec3 color_b : source_color = vec3(0.50);
uniform vec3 major_line_color : source_color = vec3(0.22);
uniform float major_spacing = 1.0;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 n = abs(world_normal);
	vec2 uv;
	if (n.y >= n.x && n.y >= n.z) {
		uv = world_pos.xz;
	} else if (n.x >= n.z) {
		uv = world_pos.zy;
	} else {
		uv = world_pos.xy;
	}

	float cell = max(level_grid_size, 0.001);
	vec2 c = floor(uv / cell + 1e-4);
	vec3 col = mix(color_a, color_b, mod(c.x + c.y, 2.0));

	// Darker lines every metre so scale reads at any snap size.
	vec2 g = uv / major_spacing;
	vec2 d = abs(fract(g - 0.5) - 0.5) / max(fwidth(g), vec2(1e-5));
	float line = 1.0 - min(min(d.x, d.y), 1.0);
	ALBEDO = mix(col, major_line_color, line);
}
