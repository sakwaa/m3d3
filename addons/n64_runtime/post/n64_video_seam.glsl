#[compute]
#version 450
// N64VideoOut, contact shadow ("seam dirt"), cheap enough to leave on: run before the
// coverage pass in two stages.
//  stage 0 (full size): each pixel's front surface - its coverage tag's code (-1 untagged)
//    and depth - read once from the MSAA samples into `front`, so the shadow's samples read
//    one texel instead of every MSAA sample.
//  stage 1 (half size): the shadow itself, how much of the sky over each point another
//    surface touching it blocks (positions back from depth; samples within reach count by
//    how far above the point's plane they stand and how near they are, the highest per
//    direction, averaged over directions turned per pixel), into `ao` (shadow, depth). The
//    coverage pass reads it back blurred within each surface (depth-aware): soft, no bleed.
// Objects' contacts reach seam_metres; level against level (a wall's foot) level_metres with
// a squared falloff and level_gain of the gain - a long gentle spread.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2DMS color_ms;
layout(set = 0, binding = 1) uniform sampler2DMS depth_ms;
layout(rg32f, set = 0, binding = 2) uniform restrict image2D front;
layout(rg32f, set = 0, binding = 3) uniform restrict writeonly image2D ao;
layout(push_constant, std430) uniform Params {
	vec2 size;          // full size
	float stage;
	float radius;       // pixel cap of the reach (full-size pixels)
	float near_raw;     // only nearer than this (raw reversed-Z depth)
	float objects;      // 1: only contacts involving an object
	float metres;       // objects' reach
	float level_metres; // level joints' reach
	float gain;
	float level_gain;
	float pad0;
	float pad1;
	vec4 proj;          // |P00|, |P11|, P22, P32
} p;

bool tagged(float a) {
	return a > 0.5 && abs(a - round(a)) < 0.02;
}

bool same_surface(float a, float b) {
	if (a < 0.0 || b < 0.0) {
		return a == b;
	}
	if (a >= 64.0 || b >= 64.0) {
		return a == b;
	}
	return floor(a / 8.0) == floor(b / 8.0);
}

vec3 view_pos(vec2 xy, float raw) {
	float dist = p.proj.w / (raw + p.proj.z);
	vec2 ndc = (xy + 0.5) / p.size * 2.0 - 1.0;
	return vec3(ndc.x * dist / p.proj.x, -ndc.y * dist / p.proj.y, -dist);
}

vec2 front_at(ivec2 xy) {
	return imageLoad(front, clamp(xy, ivec2(0), ivec2(p.size) - 1)).xy;
}

float shadow_at(ivec2 xy) {
	vec2 here = front_at(xy);
	if (here.x < 0.0 || here.y < p.near_raw) {
		return 0.0;
	}
	float fade = smoothstep(p.near_raw, p.near_raw * 1.5, here.y);
	vec3 P = view_pos(vec2(xy), here.y);
	// (normal from this surface's own neighbours, two pixels out: half-size work)
	vec2 rx = front_at(xy + ivec2(2, 0)), lx = front_at(xy - ivec2(2, 0));
	vec2 dy = front_at(xy + ivec2(0, 2)), uy = front_at(xy - ivec2(0, 2));
	vec3 px = same_surface(rx.x, here.x) ? view_pos(vec2(xy + ivec2(2, 0)), rx.y) - P : P - view_pos(vec2(xy - ivec2(2, 0)), lx.y);
	vec3 py = same_surface(dy.x, here.x) ? view_pos(vec2(xy + ivec2(0, 2)), dy.y) - P : P - view_pos(vec2(xy - ivec2(0, 2)), uy.y);
	vec3 n = normalize(cross(py, px));
	if (dot(n, -P) < 0.0) {
		n = -n;
	}
	float R_obj = p.metres;
	float R_lvl = here.x < 64.0 ? max(p.level_metres, 0.0) : R_obj;
	float R = max(R_obj, R_lvl);
	float span = min(R * p.proj.y * p.size.y * 0.5 / max(-P.z, 1e-3), p.radius);
	if (span < 2.0) {
		return 0.0;
	}
	// Direction set turned per (half-size) pixel, 4 x 4 interleave: the coverage pass's
	// depth-aware blur evens it out.
	const float M[16] = float[16](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
	ivec2 hxy = xy / 2;
	float jitter = (M[(hxy.x & 3) + (hxy.y & 3) * 4] + 0.5) / 16.0;
	const int DIRS = 8;
	const int STEPS = 6;
	float occ = 0.0;
	float occ_lvl = 0.0;
	for (int d = 0; d < DIRS; d++) {
		float ang = (float(d) + jitter) * 6.2831853 / float(DIRS);
		vec2 dir = vec2(cos(ang), sin(ang));
		float best = 0.0;
		float best_lvl = 0.0;
		for (int k = 1; k <= STEPS; k++) {
			float t = (float(k) - 0.5 + jitter) / float(STEPS);
			ivec2 q = xy + ivec2(round(dir * t * span));
			if (q == xy) {
				continue;
			}
			vec2 fq = front_at(q);
			bool level_pair = here.x < 64.0 && fq.x < 64.0;
			if (fq.x < 0.0 || same_surface(fq.x, here.x) || (p.objects > 0.5 && level_pair)) {
				continue;
			}
			vec3 v = view_pos(vec2(q), fq.y) - P;
			float len = length(v);
			float Rq = level_pair ? R_lvl : R_obj;
			if (len >= Rq) {
				continue;
			}
			float rise = max(dot(n, v / len) - 0.05, 0.0);
			float near_f = 1.0 - len / Rq;
			if (level_pair) {
				best_lvl = max(best_lvl, rise * near_f * near_f);
			} else {
				best = max(best, rise * near_f);
			}
		}
		occ += best;
		occ_lvl += best_lvl;
	}
	return clamp((occ + occ_lvl * p.level_gain) / float(DIRS) * max(p.gain, 0.0), 0.0, 1.0) * fade;
}

void main() {
	ivec2 xy = ivec2(gl_GlobalInvocationID.xy);
	if (p.stage < 0.5) {
		if (any(greaterThanEqual(xy, ivec2(p.size)))) {
			return;
		}
		int n = min(textureSamples(color_ms), 8);
		float best = -1.0;
		float a = 0.0;
		for (int s = 0; s < n; s++) {
			float d = texelFetch(depth_ms, xy, s).r;
			if (d > best) {
				best = d;
				a = texelFetch(color_ms, xy, s).a;
			}
		}
		imageStore(front, xy, vec4(tagged(a) ? floor(a / 16.0) : -1.0, best, 0.0, 0.0));
		return;
	}
	ivec2 half_size = (ivec2(p.size) + 1) / 2;
	if (any(greaterThanEqual(xy, half_size))) {
		return;
	}
	ivec2 full = min(xy * 2, ivec2(p.size) - 1);
	imageStore(ao, xy, vec4(shadow_at(full), front_at(full).y, 0.0, 0.0));
}
