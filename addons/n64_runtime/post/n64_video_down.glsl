#[compute]
#version 450
// N64VideoOut, screen combiner's BLUR: the picture shrunk (each output texel the average of
// the source texels it covers), a level at a time - Tharo's N64 bloom redraws the frame at
// half size three times. The first level also turns the linear picture into framebuffer
// values (display encoding, clamped 0..1) so the combiner reads what the RDP would.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D src;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D dst;
layout(push_constant, std430) uniform Params {
	vec2 src_size;
	vec2 dst_size;
	float encode;  // >= 1: src is the linear picture; 1 + n: multiplied by itself n times
	float pad0;
	float pad1;
	float pad2;
} p;

vec3 to_srgb(vec3 c) {
	c = clamp(c, 0.0, 1.0);
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

void main() {
	ivec2 xy = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(xy, ivec2(p.dst_size)))) {
		return;
	}
	vec2 s = p.src_size / p.dst_size;
	ivec2 lo = ivec2(floor(vec2(xy) * s));
	ivec2 hi = max(ivec2(ceil(vec2(xy + 1) * s)), lo + 1);
	hi = min(hi, ivec2(p.src_size));
	vec3 sum = vec3(0.0);
	float n = 0.0;
	for (int y = lo.y; y < hi.y; y++) {
		for (int x = lo.x; x < hi.x; x++) {
			vec3 c = imageLoad(src, ivec2(x, y)).rgb;
			if (p.encode > 0.5) {
				c = to_srgb(c);
				for (int i = 1; i < int(p.encode + 0.5); i++) {
					c *= c;  // (the bright pass: FRAME x FRAME)
				}
			}
			sum += c;
			n += 1.0;
		}
	}
	imageStore(dst, xy, vec4(sum / max(n, 1.0), 1.0));
}
