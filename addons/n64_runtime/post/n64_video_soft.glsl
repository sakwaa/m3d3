#[compute]
#version 450
// N64VideoOut pass 2: the VI stretching ~320-pixel lines across the screen (softer side to
// side than up and down: a 1-2-1 filter along the line), and optionally composite video's
// colour bleed (chroma smeared along the line, brightness kept sharp; chroma_px sets its
// width in render pixels - N64VideoOut.chroma_width in N64 pixels, so it holds at any size).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D src;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D dst;
layout(push_constant, std430) uniform Params {
	vec2 size;
	float soft;   // 0..1: the horizontal filter's share
	float bleed;  // 0..1: chroma blurred over 5 pixels
	float chroma_px;  // > 0: chroma blurred this wide instead (render pixels, triangle filter)
	float pad1;
	float pad2;
	float pad3;
} p;

vec3 at(ivec2 xy) {
	return imageLoad(src, clamp(xy, ivec2(0), ivec2(p.size) - 1)).rgb;
}

const mat3 TO_YIQ = mat3(0.299, 0.596, 0.211, 0.587, -0.274, -0.523, 0.114, -0.322, 0.312);
const mat3 TO_RGB = mat3(1.0, 1.0, 1.0, 0.956, -0.272, -1.106, 0.621, -0.647, 1.703);

void main() {
	ivec2 xy = ivec2(gl_GlobalInvocationID.xy);
	if (xy.x >= int(p.size.x) || xy.y >= int(p.size.y)) {
		return;
	}
	vec4 here = imageLoad(src, xy);
	vec3 l = at(xy - ivec2(1, 0));
	vec3 r = at(xy + ivec2(1, 0));
	vec3 c = mix(here.rgb, 0.25 * l + 0.5 * here.rgb + 0.25 * r, p.soft);
	if (p.bleed > 0.0) {
		vec3 wide = (at(xy - ivec2(2, 0)) + 2.0 * l + 3.0 * here.rgb + 2.0 * r + at(xy + ivec2(2, 0))) / 9.0;
		if (p.chroma_px > 0.0) {
			// Composite video's narrow colour band at any render size: chroma over
			// chroma_px pixels each side (triangle weights), luma untouched.
			int rad = clamp(int(ceil(p.chroma_px)), 1, 32);
			vec3 sum = vec3(0.0);
			float wsum = 0.0;
			for (int i = -rad; i <= rad; i++) {
				float w = 1.0 - abs(float(i)) / (float(rad) + 1.0);
				sum += at(xy + ivec2(i, 0)) * w;
				wsum += w;
			}
			wide = sum / wsum;
		}
		vec3 yiq = TO_YIQ * c;
		vec3 blur = TO_YIQ * wide;
		yiq.yz = mix(yiq.yz, blur.yz, p.bleed);
		c = max(TO_RGB * yiq, vec3(0.0));
	}
	imageStore(dst, xy, vec4(c, here.a));
}
