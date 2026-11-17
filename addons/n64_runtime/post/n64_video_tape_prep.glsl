#[compute]
#version 450
// N64VideoOut, video tape's prep: the picture into display values once (rgb) with its
// brightness in alpha, so the tape pass's neighbour taps are plain loads.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D src;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D dst;
layout(push_constant, std430) uniform Params {
	vec2 size;
	float pad0;
	float pad1;
	float pad2;
	float pad3;
	float pad4;
	float pad5;
} p;

vec3 to_srgb(vec3 c) {
	c = clamp(c, 0.0, 1.0);
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

void main() {
	ivec2 xy = ivec2(gl_GlobalInvocationID.xy);
	if (xy.x >= int(p.size.x) || xy.y >= int(p.size.y)) {
		return;
	}
	vec3 c = to_srgb(imageLoad(src, xy).rgb);
	imageStore(dst, xy, vec4(c, dot(c, vec3(0.299, 0.587, 0.114))));
}
