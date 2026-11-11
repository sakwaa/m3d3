shader_type canvas_item;
// UI text (and anything else drawn by the item) with the N64's 3-point filter: glyphs
// magnified by whole pixels come out softened the way the console's text textures did,
// instead of hard-edged squares. Follows the n64_three_point shader global (off = nearest).
// `softness` mixes the filtered look back towards the hard pixels (1 = full 3-point).
// (As n64_sample_level, inline: canvas shaders can't hand TEXTURE to a function.)

global uniform bool n64_three_point;

uniform float softness : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	if (n64_three_point && softness > 0.0) {
		vec2 size = vec2(textureSize(TEXTURE, 0));
		vec2 p = UV * size - 0.5;
		vec2 f = fract(p);
		vec2 i = floor(p);
		vec4 a = textureLod(TEXTURE, (i + vec2(0.5)) / size, 0.0);
		vec4 b = textureLod(TEXTURE, (i + vec2(1.5, 0.5)) / size, 0.0);
		vec4 cc = textureLod(TEXTURE, (i + vec2(0.5, 1.5)) / size, 0.0);
		vec4 d = textureLod(TEXTURE, (i + vec2(1.5)) / size, 0.0);
		vec4 tri = f.x + f.y <= 1.0 ? a + f.x * (b - a) + f.y * (cc - a) : d + (1.0 - f.x) * (cc - d) + (1.0 - f.y) * (b - d);
		c = mix(c, tri, softness);
	}
	COLOR = c * COLOR;
}
