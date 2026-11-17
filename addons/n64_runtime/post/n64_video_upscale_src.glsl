#[compute]
#version 450
// N64VideoOut, edge-aware upscale on screen: the finished picture (sRGB-encoded, 8 bits) and
// the coverage pass's edge info copied into textures that outlive the frame's render buffers,
// for the screen layer's shader (n64_upscale_layer.gdshader) to enlarge straight to the window.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D src;
layout(rgba16f, set = 0, binding = 1) uniform restrict readonly image2D info;
layout(rgba8, set = 0, binding = 2) uniform restrict writeonly image2D src_out;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image2D info_out;
layout(push_constant, std430) uniform Params {
	vec2 size;
	float copy_info;  // 0: the coverage pass wrote the info here already
	float pad1;
} p;

vec3 enc(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

void main() {
	ivec2 xy = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(xy, ivec2(p.size)))) {
		return;
	}
	imageStore(src_out, xy, vec4(enc(imageLoad(src, xy).rgb), 1.0));
	if (p.copy_info > 0.5) {
		imageStore(info_out, xy, imageLoad(info, xy));
	}
}
