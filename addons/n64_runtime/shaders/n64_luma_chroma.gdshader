shader_type spatial;
// Backdrop / sky painting stored as luma + chroma (the N64's YUV texture idea, split the
// modern way): brightness in a high-resolution intensity texture (I4 / I8), colour in a
// small texture a quarter the size (Cb, Cr) - the eye reads detail from brightness, so the
// same bytes buy a much sharper picture than an RGBA16 one. Unshaded, 3-point / nearest
// as the other N64 textures.
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;

#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"

uniform sampler2D luma_tex : filter_nearest, repeat_enable;
uniform sampler2D chroma_tex : filter_linear, repeat_enable;
/// Comparison: a plain RGBA texture instead (rgb_tex).
uniform bool rgb_mode = false;
uniform sampler2D rgb_tex : source_color, filter_nearest, repeat_enable;

void fragment() {
	if (rgb_mode) {
		ALBEDO = n64_three_point ? n64_sample_at_lod(rgb_tex, UV, 0.0).rgb : texture(rgb_tex, UV).rgb;
	} else {
		float y = n64_three_point ? n64_sample_at_lod(luma_tex, UV, 0.0).r : texture(luma_tex, UV).r;
		vec2 cbcr = texture(chroma_tex, UV).rg - 0.5;
		// (JPEG YCbCr, in the texture's sRGB values; out to linear)
		vec3 rgb = vec3(y + 1.402 * cbcr.y, y - 0.344136 * cbcr.x - 0.714136 * cbcr.y, y + 1.772 * cbcr.x);
		ALBEDO = pow(clamp(rgb, 0.0, 1.0), vec3(2.2));
	}
}
