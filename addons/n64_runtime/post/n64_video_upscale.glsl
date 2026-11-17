#[compute]
#version 450
// N64VideoOut, edge-aware upscale: the finished low-resolution picture enlarged `factor`
// times, texels left as fat blocks, but every polygon edge redrawn where it really runs.
// The coverage pass leaves per pixel the front surface's coverage (the triangle's share of
// the pixel, from its analytic distance to the edge: coverage = distance + 0.5, in pixels)
// and its code. A partly covered pixel holds an edge: its direction from how the surface's
// coverage changes over the 3 x 3 round it (pointing into the surface), its offset from the
// coverage itself; each output pixel takes the surface's colour on its side of that line and
// the neighbour's beyond it, anti-aliased at the output resolution.
// mode 0: plain nearest (blocks, for comparison). Written sRGB-encoded (a picture to show).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D src;
layout(rgba16f, set = 0, binding = 1) uniform restrict readonly image2D info;
layout(rgba8, set = 0, binding = 2) uniform restrict writeonly image2D dst;
layout(push_constant, std430) uniform Params {
	vec2 size;     // source size
	float factor;  // output pixels per source pixel
	float mode;    // 0 nearest, 1 edge-aware
	float show;    // 1: edge pixels tinted (tuning)
	float pad0;
	float pad1;
	float pad2;
} p;

// Output is sRGB-encoded (shown / saved as a picture; the source is linear).
vec4 enc(vec3 c) {
	c = max(c, vec3(0.0));
	return vec4(mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c)), 1.0);
}

ivec2 clampi(ivec2 q) {
	return clamp(q, ivec2(0), ivec2(p.size) - 1);
}

bool same(float a, float b) {
	if (a < 0.0 || b < 0.0) {
		return a == b;
	}
	if (a >= 64.0 || b >= 64.0) {
		return a == b;
	}
	return floor(a / 8.0) == floor(b / 8.0);
}

// How much of the surface `code` is at q: its coverage there, 0 where another is in front.
float share(ivec2 q, float code) {
	vec4 i = imageLoad(info, clampi(q));
	return same(i.y, code) ? i.x : 0.0;
}

void main() {
	ivec2 xy = ivec2(gl_GlobalInvocationID.xy);
	ivec2 out_size = ivec2(p.size * p.factor);
	if (xy.x >= out_size.x || xy.y >= out_size.y) {
		return;
	}
	ivec2 sp = ivec2(vec2(xy) / p.factor);
	vec3 c = imageLoad(src, clampi(sp)).rgb;
	vec4 here = imageLoad(info, clampi(sp));
	if (p.mode < 0.5 || here.x >= 0.999 || here.y < 0.0) {
		imageStore(dst, xy, enc(c));
		return;
	}
	float code = here.y;
	// Sobel of the surface's share: points into it.
	float s00 = share(sp + ivec2(-1, -1), code), s10 = share(sp + ivec2(0, -1), code), s20 = share(sp + ivec2(1, -1), code);
	float s01 = share(sp + ivec2(-1, 0), code), s21 = share(sp + ivec2(1, 0), code);
	float s02 = share(sp + ivec2(-1, 1), code), s12 = share(sp + ivec2(0, 1), code), s22 = share(sp + ivec2(1, 1), code);
	vec2 g = vec2((s20 + 2.0 * s21 + s22) - (s00 + 2.0 * s01 + s02),
		(s02 + 2.0 * s12 + s22) - (s00 + 2.0 * s10 + s20));
	// (a clean straight edge gives |g| ~ 2-4; tiny corners and specks give a weak or
	// wandering direction - redrawing those makes shards, so they keep their block)
	if (length(g) < 1.5) {
		imageStore(dst, xy, enc(c));
		return;
	}
	vec2 n = normalize(g);
	// (coverage's distance is measured along the larger screen axis: |n.x| + |n.y| per pixel)
	vec2 o = (vec2(xy) + 0.5) / p.factor - vec2(sp) - 0.5;
	float s = dot(o, n) + (here.x - 0.5) / (abs(n.x) + abs(n.y));
	float k = clamp(s * p.factor + 0.5, 0.0, 1.0);
	// Beyond the edge: of the 8 neighbours showing another surface, the one lying most
	// along -n (none: the edge is too thin to tell - keep the pixel as it is).
	float best = 0.2;
	ivec2 q = sp;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			ivec2 d = ivec2(x, y);
			if (d == ivec2(0)) {
				continue;
			}
			float along = dot(normalize(vec2(d)), -n);
			if (along > best && !same(imageLoad(info, clampi(sp + d)).y, code)) {
				best = along;
				q = sp + d;
			}
		}
	}
	// Only a silhouette - what's beyond lies clearly farther (reversed Z: smaller) - is
	// redrawn: where two surfaces meet at the same depth (a post standing in the ground,
	// a wall's foot) the edge stays a block, as any redraw there makes shards.
	if (q == sp || !(imageLoad(info, clampi(q)).z < here.z * 0.985)) {
		imageStore(dst, xy, enc(c));
		return;
	}
	vec3 bg = imageLoad(src, clampi(q)).rgb;
	vec3 col = mix(bg, c, k);
	if (p.show > 0.5) {
		col = mix(col, vec3(1.0, 0.0, 0.0), 0.5);
	}
	imageStore(dst, xy, enc(col));
}
