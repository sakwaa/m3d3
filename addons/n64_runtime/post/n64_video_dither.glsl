#[compute]
#version 450
// N64VideoOut pass 1: the RDP's 16-bit framebuffer and the VI's dither filter, as the
// emulators document them (angrylion / ParaLLEl-RDP). RDP: each 8-bit channel keeps its top
// 5 bits and rounds up by one when its low 3 bits exceed the dither value at the pixel
// (magic square, Bayer, or per-frame noise; none). VI: the 5 bits shifted back up (low bits
// zero), then the dither filter restores them: +1 for each of the 8 neighbours whose 5-bit
// value is higher, -1 for each lower (flat areas smooth back out, edges stay put). Each
// neighbour's value is recomputed from the source, so no extra buffer. Works in display
// (sRGB) values, as the N64 had no linear light.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D src;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D dst;
layout(push_constant, std430) uniform Params {
	vec2 size;
	float dither;    // 0..1: the magic square's offsets (1 = the N64's)
	float dedither;  // 0..1: the VI filter's restore
	float quantize;  // 1: 16-bit colour, 0: pass through
	float mode;      // 0 magic square, 1 Bayer, 2 noise (changes each frame), 3 none
	float frame;     // (noise: a new pattern each frame)
	float crt;       // > 0: the picture through a CRT's gamma (display values ^ crt: ~1.14 = 2.5 / 2.2)
} p;

const int MAGIC[16] = int[](0, 6, 1, 7, 4, 2, 5, 3, 1, 7, 0, 6, 5, 3, 4, 2);
const int BAYER[16] = int[](0, 4, 1, 5, 4, 0, 5, 1, 3, 7, 2, 6, 7, 3, 6, 2);

// The RDP's dither value (0..7) at `c`.
float dither_at(ivec2 c) {
	int m = int(p.mode + 0.5);
	if (m == 3) {
		return 7.0;  // (none: never rounds up = truncation)
	}
	if (m == 2) {
		uint h = uint(c.x) * 73856093u ^ uint(c.y) * 19349663u ^ uint(p.frame) * 83492791u;
		h = (h ^ (h >> 13u)) * 1274126177u;
		return float((h >> 16u) & 7u);
	}
	int i = (c.y & 3) * 4 + (c.x & 3);
	return float(m == 1 ? BAYER[i] : MAGIC[i]);
}

vec3 to_srgb(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

vec3 to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

// The 5-bit colour the framebuffer holds at `xy`: top 5 bits, +1 where the low 3 bits are
// above the dither value (`dither` < 1 eases towards plain rounding at 3.5).
vec3 q5(ivec2 xy) {
	ivec2 c = clamp(xy, ivec2(0), ivec2(p.size) - 1);
	vec3 v = floor(clamp(to_srgb(imageLoad(src, c).rgb), 0.0, 1.0) * 255.0 + 0.5);
	float d = mix(3.5, dither_at(c), p.dither);
	vec3 hi = floor(v / 8.0);
	vec3 lo = v - hi * 8.0;
	return clamp(hi + step(vec3(d + 0.01), lo), 0.0, 31.0);
}

void main() {
	ivec2 xy = ivec2(gl_GlobalInvocationID.xy);
	if (xy.x >= int(p.size.x) || xy.y >= int(p.size.y)) {
		return;
	}
	vec4 here = imageLoad(src, xy);
	if (p.quantize < 0.5) {
		if (p.crt > 0.0) {
			here.rgb = to_linear(pow(clamp(to_srgb(here.rgb), 0.0, 1.0), vec3(p.crt)));
		}
		imageStore(dst, xy, here);
		return;
	}
	vec3 c5 = q5(xy);
	// The VI reads 5 bits as 8 by shifting them up (the low bits zero); its dither filter
	// below puts back what the dither spread out.
	vec3 v8 = c5 * 8.0;
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
	vec3 disp = clamp(v8 / 255.0, 0.0, 1.0);
	if (p.crt > 0.0) {
		disp = pow(disp, vec3(p.crt));
	}
	imageStore(dst, xy, vec4(to_linear(disp), here.a));
}
