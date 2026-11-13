#[compute]
#version 450
// N64VideoOut pass 1: the RDP's 16-bit framebuffer (5 bits a channel, its 4x4 "magic
// square" ordered dither) and the VI's dither filter, which partly restores the lost bits:
// each channel moves one 8-bit step towards each of its 8 neighbours that differ from it
// in 5 bits (so flat areas smooth back out, edges stay put). Each neighbour's dithered value
// is recomputed from the source, so no extra buffer. Works in display (sRGB) values.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D src;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D dst;
layout(push_constant, std430) uniform Params {
	vec2 size;
	float dither;    // 0..1: the magic square's offsets (1 = the N64's)
	float dedither;  // 0..1: the VI filter's restore
	float quantize;  // 1: 16-bit colour, 0: pass through
	float pad0;
	float pad1;
	float pad2;
} p;

const int MAGIC[16] = int[](0, 6, 1, 7, 4, 2, 5, 3, 1, 7, 0, 6, 5, 3, 4, 2);

vec3 to_srgb(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

vec3 to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

// The 5-bit colour the framebuffer holds at `xy`.
vec3 q5(ivec2 xy) {
	ivec2 c = clamp(xy, ivec2(0), ivec2(p.size) - 1);
	vec3 s = clamp(to_srgb(imageLoad(src, c).rgb), 0.0, 1.0);
	float d = float(MAGIC[(c.y & 3) * 4 + (c.x & 3)]) * p.dither + 3.5 * (1.0 - p.dither);
	return clamp(floor((s * 255.0 + d) / 8.0), 0.0, 31.0);
}

void main() {
	ivec2 xy = ivec2(gl_GlobalInvocationID.xy);
	if (xy.x >= int(p.size.x) || xy.y >= int(p.size.y)) {
		return;
	}
	vec4 here = imageLoad(src, xy);
	if (p.quantize < 0.5) {
		imageStore(dst, xy, here);
		return;
	}
	vec3 c5 = q5(xy);
	// The VI shows 5 bits as 8: the value shifted up, its top bits repeated below.
	vec3 v8 = c5 * 8.0 + floor(c5 / 4.0);
	if (p.dedither > 0.0) {
		vec3 sum = vec3(0.0);
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				if (x != 0 || y != 0) {
					sum += sign(q5(xy + ivec2(x, y)) - c5);
				}
			}
		}
		v8 += sum * p.dedither;
	}
	imageStore(dst, xy, vec4(to_linear(clamp(v8 / 255.0, 0.0, 1.0)), here.a));
}
