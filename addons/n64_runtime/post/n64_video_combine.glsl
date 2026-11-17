#[compute]
#version 450
// N64VideoOut, screen combiner (ScreenCombiner): the RDP's (A - B) * C + D over the whole
// picture, one or two cycles, up to two combiners crossfading (each at its weight). Works on
// framebuffer values (display encoding, 0..1), with the RDP's 9-bit overflow: -0.5..0 -> 0,
// 1..1.5 -> 1, past that wrapping round. Inputs: the picture (FRAME), its shrunk copy read
// back filtered (BLUR, n64_video_down.glsl), primitive / environment, noise, depth, the
// distance from the middle of the screen, 1 and 0.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color;
layout(set = 0, binding = 1) uniform sampler2D blur0;  // half
layout(set = 0, binding = 2) uniform sampler2D blur1;  // quarter
layout(set = 0, binding = 3) uniform sampler2D blur2;  // eighth
layout(set = 0, binding = 4) uniform sampler2D blur3;  // 30 rows
layout(set = 0, binding = 5) uniform sampler2D depth;
layout(set = 0, binding = 6, std140) uniform Slots {
	// per combiner: [0] cycle 1 colour a b c d, [1] cycle 1 alpha, [2] cycle 2 colour,
	// [3] cycle 2 alpha, [4] primitive, [5] environment, [6] wrap, weight, blur, depth_far, [7] -
	vec4 v[16];
} slots;
layout(push_constant, std430) uniform Params {
	vec2 size;
	float frame;    // frame counter (noise)
	float count;    // combiners in use (1 or 2)
	float proj_z;   // P22, P32: distance = P32 / (raw + P22)
	float proj_w;
	float pad0;
	float pad1;
} p;

const vec3 LUMA = vec3(0.299, 0.587, 0.114);

vec3 to_srgb(vec3 c) {
	c = clamp(c, 0.0, 1.0);
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

vec3 to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

float hash(vec2 q) {
	return fract(sin(dot(q, vec2(12.9898, 78.233))) * 43758.5453);
}

// Everything one pixel can read, gathered once.
vec3 g_frame;
vec3 g_blur;
float g_noise;
float g_depth;
float g_centre;
vec3 g_bands;
vec4 g_prim;
vec4 g_env;

vec3 rgb_in(int s, vec4 comb) {
	switch (s) {
		case 0: return comb.rgb;
		case 1: return vec3(comb.a);
		case 2: return g_frame;
		case 3: return vec3(dot(g_frame, LUMA));
		case 4: return g_blur;
		case 5: return vec3(dot(g_blur, LUMA));
		case 6: return g_prim.rgb;
		case 7: return vec3(g_prim.a);
		case 8: return g_env.rgb;
		case 9: return vec3(g_env.a);
		case 10: return vec3(g_noise);
		case 11: return vec3(g_depth);
		case 12: return vec3(g_centre);
		case 13: return vec3(1.0);
		case 15: return g_bands;
	}
	return vec3(0.0);
}

float a_in(int s, vec4 comb) {
	switch (s) {
		case 0: return comb.a;
		case 1: return comb.a;
		case 2: return dot(g_frame, LUMA);
		case 3: return dot(g_frame, LUMA);
		case 4: return dot(g_blur, LUMA);
		case 5: return dot(g_blur, LUMA);
		case 6: return g_prim.a;
		case 7: return g_prim.a;
		case 8: return g_env.a;
		case 9: return g_env.a;
		case 10: return g_noise;
		case 11: return g_depth;
		case 12: return g_centre;
		case 13: return 1.0;
		case 15: return dot(g_bands, LUMA);
	}
	return 0.0;
}

// The RDP's result: 9 bits, -0.5..1.5 clamps into 0..1, past that wraps.
vec4 overflow(vec4 v, bool wrap) {
	if (wrap) {
		v = mod(v + 0.5, 2.0) - 0.5;
	}
	return clamp(v, 0.0, 1.0);
}

vec4 cycle(vec4 sel_c, vec4 sel_a, vec4 comb, bool wrap) {
	ivec4 c = ivec4(sel_c + 0.5);
	ivec4 a = ivec4(sel_a + 0.5);
	vec3 rgb = (rgb_in(c.x, comb) - rgb_in(c.y, comb)) * rgb_in(c.z, comb) + rgb_in(c.w, comb);
	float al = (a_in(a.x, comb) - a_in(a.y, comb)) * a_in(a.z, comb) + a_in(a.w, comb);
	return overflow(vec4(rgb, al), wrap);
}

vec3 blur_at(int level, vec2 uv) {
	if (level == 0) return textureLod(blur0, uv, 0.0).rgb;
	if (level == 1) return textureLod(blur1, uv, 0.0).rgb;
	if (level == 2) return textureLod(blur2, uv, 0.0).rgb;
	return textureLod(blur3, uv, 0.0).rgb;
}

void main() {
	ivec2 xy = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(xy, ivec2(p.size)))) {
		return;
	}
	vec4 here = imageLoad(color, xy);
	vec3 frame = to_srgb(here.rgb);
	g_frame = frame;
	vec2 uv = (vec2(xy) + 0.5) / p.size;
	g_noise = hash(vec2(xy) + vec2(mod(p.frame, 251.0) * 17.0, mod(p.frame, 241.0) * 31.0));
	vec2 off = (uv - 0.5) * 2.0;
	g_centre = clamp(length(off * vec2(p.size.x / p.size.y, 1.0)) / length(vec2(p.size.x / p.size.y, 1.0)), 0.0, 1.0);
	float raw = textureLod(depth, uv, 0.0).r;
	float dist = raw > 0.0 ? p.proj_w / (raw + p.proj_z) : 1e9;
	// (MM's z_viszbuf RGBA mode: the depth's bits read as 5:5:5 colour - here the
	// non-linear depth's successive digits: bands that repeat faster with distance)
	float lz = log2(min(dist, 4096.0) + 1.0);
	g_bands = fract(vec3(lz * 0.5, lz * 2.0, lz * 8.0));
	vec3 out_c = frame;
	for (int k = 0; k < int(p.count); k++) {
		int o = k * 8;
		vec4 misc = slots.v[o + 6];
		if (misc.y <= 0.0) {
			continue;
		}
		g_prim = slots.v[o + 4];
		g_env = slots.v[o + 5];
		g_blur = blur_at(int(misc.z + 0.5), uv);
		g_depth = clamp(dist / max(misc.w, 0.01), 0.0, 1.0);
		bool wrap = misc.x > 0.5;
		vec4 comb = vec4(0.0);
		comb = cycle(slots.v[o], slots.v[o + 1], comb, wrap);
		comb = cycle(slots.v[o + 2], slots.v[o + 3], comb, wrap);
		out_c += (comb.rgb - frame) * misc.y;
	}
	imageStore(color, xy, vec4(to_linear(clamp(out_c, 0.0, 1.0)), here.a));
}
