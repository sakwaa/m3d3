shader_type spatial;
render_mode unshaded, cull_disabled, skip_vertex_transform;
// The grass parted where an actor wades through a grass carpet (GrassWake), like a zipper:
// stamps laid along its path (MultiMesh instances, staying where they were put, local z
// along the way it was heading), each a row of blades rooted along the left and along the
// right of the path. INSTANCE_CUSTOM.x = how open (1 parted round the legs .. 0 closed).
// Opening, each row swings out (left to the left, right to the right); closing, they swing
// back past upright until the two sides cross, the blades keeping their length; only at the
// very end do the tips settle into the carpet. The carpet's own texture, tips cut ragged
// like leaves (1-bit alpha).
// Per vertex: CUSTOM0 = (pivot x, pivot y, side -1 / 1, front +1 / back -1);
// INSTANCE_CUSTOM.y = which quarters have carpet under them (bits); UV.y 0 at the tips;
// colour r = shade.
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"

uniform sampler2D tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform vec4 color : source_color = vec4(1.0);
// Texture repeats across a blade (match the carpet's scale).
uniform float tiling = 0.3;
// Lean (degrees from upright) fully open (out from the path) and closed (in over the path).
uniform float open_lean = 62.0;
uniform float closed_lean = 24.0;
// The legs (world x, z, radius): blades leave them clear (no grass across the shins).
uniform vec3 legs = vec3(0.0, 0.0, 0.0);

varying vec2 n64_fogv;
varying vec3 n64_fog_tintv;
varying float shade_v;
varying float show_v;
varying vec2 world_xz;

void vertex() {
	float open = INSTANCE_CUSTOM.x;
	vec3 local = VERTEX;
	float side = CUSTOM0.z;
	// Carpet under this quarter of the stamp (GrassWake._carpet_mask), else not drawn.
	int mask = int(INSTANCE_CUSTOM.y + 0.5);
	int bit = (side < 0.0 ? 1 : 4) * (CUSTOM0.w > 0.0 ? 2 : 1);
	show_v = (mask & bit) != 0 ? 1.0 : 0.0;
	// Swing about the blade's root (an axis along the path).
	float lean = mix(-closed_lean, open_lean, smoothstep(0.0, 1.0, open));
	float a = -side * radians(lean);
	vec2 pivot = CUSTOM0.xy;
	vec2 d = local.xy - pivot;
	d = vec2(d.x * cos(a) - d.y * sin(a), d.x * sin(a) + d.y * cos(a));
	local.xy = pivot + d;
	// The very end: the tips settle into the carpet (no pop when the stamp goes).
	local.y -= (1.0 - smoothstep(0.0, 0.12, open)) * 0.12 * (1.0 - UV.y);
	vec3 world = (MODEL_MATRIX * vec4(local, 1.0)).xyz;
	world_xz = world.xz;
	n64_fogv = n64_fog_vertex(world);
	n64_fog_tintv = n64_fog_tint_vertex(world);
	shade_v = COLOR.r;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	// Ragged leafy tips.
	vec2 cell = floor(UV * vec2(10.0, 8.0));
	float tip = 1.0 - UV.y;
	float h = hash(cell);
	float shade = shade_v;
	if (show_v < 0.5 || distance(world_xz, legs.xy) < legs.z) {
		discard;
	}
	if (h < pow(tip, 2.2) * 0.75 - 0.05) {
		discard;
	}
	vec4 c = n64_texture(tex, UV * tiling);
	ALBEDO = c.rgb * color.rgb * shade * n64_world_tint.rgb * n64_weather_tint.rgb;
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
}
