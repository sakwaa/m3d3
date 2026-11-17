#[compute]
#version 450
// N64VideoOut pass 0: the VI's anti-aliasing. The N64 kept a 3-bit coverage per pixel (how
// much of it the polygon covered) and its video chip blended partly covered pixels with the
// background it estimated from the neighbours: per channel, the second-highest plus the
// second-lowest of the eight neighbours, less the pixel itself, mixed in by the uncovered
// share (the method emulators document: angrylion / ParaLLEl-RDP). No coverage here, so it
// is estimated from the depth buffer: a jump in depth (a silhouette) or a kink in it (a
// crease: on a flat surface the raw depth changes evenly across the screen, so where two
// surfaces meet - a wall on the ground, a roof on a wall - its second difference spikes).
// Textures stay as they are. Then the divot filter: an edge pixel that's the odd one out
// along the line (brighter or darker than both sides) takes their median.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D src;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D dst;
layout(set = 0, binding = 2) uniform sampler2D depth_tex;
layout(push_constant, std430) uniform Params {
	vec2 size;
	float amount;     // 0..1: how far an edge pixel goes to its neighbours' blend
	float threshold;  // relative depth jump that counts as an edge
	float divot;      // 1: the divot filter on
	float show;       // 1: edges shown in red (tuning)
	float crease;     // second-difference (relative) that counts as a crease; 0 = off
	float mode;       // 1: coverage mode - src's alpha is the front triangle's real coverage
} p;

vec3 at(ivec2 xy) {
	return imageLoad(src, clamp(xy, ivec2(0), ivec2(p.size) - 1)).rgb;
}

// Reversed-Z depth (1 near .. 0 far): its inverse grows with distance, so jumps compare
// fairly near and far.
float dist_at(ivec2 xy) {
	vec2 uv = (vec2(clamp(xy, ivec2(0), ivec2(p.size) - 1)) + 0.5) / p.size;
	return 1.0 / max(texture(depth_tex, uv).r, 1e-6);
}

float jump(float a, float b) {
	return abs(a - b) / min(a, b);
}

float raw_at(ivec2 xy) {
	vec2 uv = (vec2(clamp(xy, ivec2(0), ivec2(p.size) - 1)) + 0.5) / p.size;
	return texture(depth_tex, uv).r;
}

float edge_at(ivec2 xy) {
	float d = dist_at(xy);
	float e = max(max(jump(d, dist_at(xy + ivec2(1, 0))), jump(d, dist_at(xy - ivec2(1, 0)))),
		max(jump(d, dist_at(xy + ivec2(0, 1))), jump(d, dist_at(xy - ivec2(0, 1)))));
	float out_e = smoothstep(p.threshold, p.threshold * 3.0, e);
	if (p.crease > 0.0) {
		// Creases: the raw (screen-affine) depth's second difference, relative to it.
		float r = raw_at(xy);
		float cx = abs(raw_at(xy - ivec2(1, 0)) - 2.0 * r + raw_at(xy + ivec2(1, 0)));
		float cy = abs(raw_at(xy - ivec2(0, 1)) - 2.0 * r + raw_at(xy + ivec2(0, 1)));
		float k = max(cx, cy) / max(r, 1e-6);
		out_e = max(out_e, smoothstep(p.crease, p.crease * 3.0, k));
	}
	return out_e;
}

// Second-highest and second-lowest of eight values (per channel).
void pen_minmax(vec3 v[8], out vec3 pmax, out vec3 pmin) {
	vec3 m1 = vec3(-1e9), m2 = vec3(-1e9), n1 = vec3(1e9), n2 = vec3(1e9);
	for (int i = 0; i < 8; i++) {
		vec3 x = v[i];
		m2 = max(m2, min(m1, x));
		m1 = max(m1, x);
		n2 = min(n2, max(n1, x));
		n1 = min(n1, x);
	}
	pmax = m2;
	pmin = n2;
}

void main() {
	ivec2 xy = ivec2(gl_GlobalInvocationID.xy);
	if (xy.x >= int(p.size.x) || xy.y >= int(p.size.y)) {
		return;
	}
	vec4 here = imageLoad(src, xy);
	// Coverage mode: the uncovered share is known (the N64's way); else estimated from depth.
	float e = p.mode > 0.5 ? clamp((1.0 - here.a) * 2.0, 0.0, 1.0) : edge_at(xy);
	vec3 c = here.rgb;
	if (e > 0.0) {
		vec3 l = at(xy - ivec2(1, 0));
		vec3 r = at(xy + ivec2(1, 0));
		vec3 u = at(xy - ivec2(0, 1));
		vec3 d = at(xy + ivec2(0, 1));
		vec3 nb[8] = vec3[8](l, r, u, d, at(xy + ivec2(-1, -1)), at(xy + ivec2(1, -1)), at(xy + ivec2(-1, 1)), at(xy + ivec2(1, 1)));
		vec3 pmax, pmin;
		pen_minmax(nb, pmax, pmin);
		// The VI's background estimate; coverage from the edge strength (full edge ~ half
		// covered, as a pixel straddling a polygon's border).
		vec3 bg = clamp(pmax + pmin - c, pmin, pmax);
		float uncovered = 0.5 * e * p.amount;
		c = mix(c, bg, uncovered);
		if (p.divot > 0.5) {
			// Divot: the odd one out along the line takes the median of the three.
			float yl = dot(l, vec3(0.299, 0.587, 0.114));
			float yr = dot(r, vec3(0.299, 0.587, 0.114));
			float yc = dot(c, vec3(0.299, 0.587, 0.114));
			if ((yc > yl && yc > yr) || (yc < yl && yc < yr)) {
				vec3 med = abs(yl - yc) < abs(yr - yc) ? l : r;
				c = mix(c, med, 0.5 * e);
			}
		}
	}
	if (p.show > 0.5) {
		c = mix(c, vec3(1.0, 0.0, 0.0), e);
	}
	imageStore(dst, xy, vec4(c, p.mode > 0.5 ? 1.0 : here.a));
}
