// Shine for N64 materials (props, characters), the console's way: no specular lighting.
//  - Shine: environment mapping. Like the RSP's texture generation, each vertex looks up a
//    reflection texture by its normal as seen from the camera (chrome, gloss, water
//    sheen), so the reflection swims as the object turns.
//  - Hilite: a soft glint where the surface faces halfway between the key light
//    (n64_key_light: sun outdoors, nearest light indoors) and the camera, also per vertex.
// Include after n64_sampling.gdshaderinc; in vertex(): n64_shine_v = n64_shine_vertex(...),
// in fragment(): EMISSION = n64_shine(albedo, n64_shine_v).

uniform sampler2D shine_texture : source_color, filter_linear_mipmap, repeat_disable, hint_default_black;
uniform float shine_strength : hint_range(0.0, 2.0) = 0.0;
uniform vec4 shine_tint : source_color = vec4(1.0);
// Gloss: reflection added on top (unlit). Metal: reflection replaces the colour (lit).
uniform int shine_mode : hint_enum("Gloss", "Metal") = 0;
uniform float hilite_strength : hint_range(0.0, 2.0) = 0.0;
// Glint radius (bigger = broader, softer).
uniform float hilite_size : hint_range(0.02, 0.6) = 0.2;
uniform vec4 hilite_color : source_color = vec4(1.0);

// xy = shine lookup, zw = glint position (per vertex, like texgen).
varying vec4 n64_shine_v;

// `view_normal`, `view_pos`: the vertex in view space; `view`: VIEW_MATRIX.
vec4 n64_shine_vertex(vec3 view_normal, vec3 view_pos, mat4 view) {
	vec3 n = normalize(view_normal);
	vec3 l = normalize((view * vec4(n64_key_light.xyz, 0.0)).xyz);
	vec3 h = normalize(l + normalize(-view_pos));
	// Glint: offset of the normal from the half vector, in glint radii (0.5 = centre).
	vec2 g = dot(n, h) > 0.0 ? (n.xy - h.xy) / (2.0 * hilite_size) + 0.5 : vec2(-1.0);
	return vec4(n.xy * vec2(0.5, -0.5) + 0.5, g);
}

// Applies shine to `albedo` (Metal) and returns the unlit part (Gloss + hilite) for EMISSION.
vec3 n64_shine(inout vec3 albedo, vec4 sv) {
	vec3 glow = vec3(0.0);
	if (shine_strength > 0.0) {
		vec3 s = texture(shine_texture, sv.xy).rgb * shine_tint.rgb;
		if (shine_mode == 1) {
			albedo = mix(albedo, s, clamp(shine_strength, 0.0, 1.0));
		} else {
			glow += s * shine_strength;
		}
	}
	if (hilite_strength > 0.0 && n64_key_light.w > 0.0) {
		float r = length(sv.zw - 0.5) * 2.0;
		glow += hilite_color.rgb * (1.0 - smoothstep(0.5, 1.0, r)) * hilite_strength * n64_key_light.w;
	}
	return glow;
}
