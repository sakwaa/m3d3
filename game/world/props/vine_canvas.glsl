#[compute]
#version 450
// VineCanvas: vines grown in a texture laid over a surface. Each thread moves one tendril
// tip a step: wander, seek the target, climb (up the surface), steer off holes (or, going
// down at one, drop and hang); it paints its stem (a ropey disc) and now and then a leaf
// into the canvas, and the distance from the source into the reach map (the display shader
// shows a texel once the growth front has passed it). Tips branch (a new tip off the side)
// and die when their length is spent.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

struct Tip {
	vec2 pos;    // texels
	vec2 dir;
	float life;  // texels of length left
	float width; // stem radius, texels
	float leaf;  // texels until the next leaf
	float state; // 0 dead, 1 crawling, 2 hanging
	float dist;  // texels from the source
	float side;  // next leaf's side (+1 / -1)
	float turn;  // current turn a step (drifts: sweeping curves, not jitter)
	float pad1;
};

layout(set = 0, binding = 0, std430) restrict buffer Tips { Tip t[]; } tips;
layout(set = 0, binding = 1, std430) restrict buffer Count { uint n; uint pad[3]; } count;
layout(rgba8, set = 0, binding = 2) uniform restrict image2D canvas;
layout(r32f, set = 0, binding = 3) uniform restrict image2D reach;
layout(r8, set = 0, binding = 4) uniform restrict readonly image2D surface;

layout(push_constant, std430) uniform Params {
	vec2 size;
	float frame;
	float wander;      // radians a step at most
	vec2 target;       // texels
	float seek;        // 0..1 a step
	float climb;       // pull up the surface (- = down)
	float branch;      // chance a texel of growth
	float leaf_every;  // texels between leaves
	float leaf_len;    // texels
	float hang;        // chance to drop off a hole's top edge
	float max_tips;
	float seed;
	float pad0;
	float pad1;
} p;

float hash(vec2 q) {
	return fract(sin(dot(q, vec2(12.9898, 78.233))) * 43758.5453);
}

vec2 rot(vec2 v, float a) {
	float c = cos(a), s = sin(a);
	return vec2(v.x * c - v.y * s, v.x * s + v.y * c);
}

bool inside(ivec2 q) {
	return q.x >= 0 && q.y >= 0 && q.x < int(p.size.x) && q.y < int(p.size.y);
}

void put(ivec2 q, vec3 c, float d) {
	if (!inside(q)) {
		return;
	}
	imageStore(canvas, q, vec4(c, 1.0));
	float had = imageLoad(reach, q).r;
	if (had <= 0.0 || d < had) {
		imageStore(reach, q, vec4(max(d, 0.001)));
	}
}

// The stem: a disc, darker at its edges, a twist of light strands along it.
void stem(vec2 pos, vec2 dir, float w, float d) {
	int r = int(ceil(w));
	vec2 side = vec2(-dir.y, dir.x);
	for (int y = -r; y <= r; y++) {
		for (int x = -r; x <= r; x++) {
			vec2 o = vec2(x, y);
			if (dot(o, o) > w * w + 0.25) {
				continue;
			}
			float across = dot(o, side) / max(w, 0.5);  // -1..1
			float twist = fract((dot(pos + o, dir) * 0.35 + across * 0.8));
			float light = 0.55 + 0.35 * (1.0 - abs(across)) + (twist < 0.3 ? 0.12 : 0.0) - (across > 0.4 ? 0.12 : 0.0);
			put(ivec2(floor(pos + o)), vec3(0.31, 0.32, 0.17) * light * 1.25, d);
		}
	}
}

// A leaf off the stem: pointed, lit on one half, a dark midrib.
void leaf(vec2 at, vec2 axis, float len, float d) {
	vec2 side = vec2(-axis.y, axis.x);
	int r = int(ceil(len)) + 1;
	for (int y = -r; y <= r; y++) {
		for (int x = -r; x <= r; x++) {
			vec2 o = vec2(x, y);
			float u = dot(o, axis) / len;
			float v = dot(o, side);
			if (u < 0.0 || u > 1.0) {
				continue;
			}
			float half_w = len * 0.42 * sin(3.14159 * pow(u, 0.8)) * pow(1.0 - u, 0.3);
			if (abs(v) > half_w) {
				continue;
			}
			vec3 c = v < 0.0 ? vec3(0.35, 0.58, 0.19) : vec3(0.21, 0.40, 0.13);
			if (abs(v) < 0.6 && u < 0.85) {
				c = vec3(0.14, 0.26, 0.09);
			}
			put(ivec2(floor(at + o)), c, d + u * len);
		}
	}
}

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= uint(p.max_tips) || i >= count.n) {
		return;
	}
	Tip a = tips.t[i];
	if (a.state < 0.5) {
		return;
	}
	vec2 h = vec2(float(i) * 1.37 + p.seed, p.frame * 0.731);
	float r1 = hash(h), r2 = hash(h + 17.3), r3 = hash(h + 41.9), r4 = hash(h + 73.1);
	if (a.state < 1.5) {
		a.turn = clamp(a.turn + (r1 - 0.5) * p.wander * 0.6, -p.wander, p.wander);
		a.dir = rot(a.dir, a.turn);
		vec2 to = p.target - a.pos;
		if (dot(to, to) > 4.0) {
			a.dir = normalize(mix(a.dir, normalize(to), p.seek));
		}
		a.dir = normalize(a.dir + vec2(0.0, -p.climb));  // (up the surface is -y)
	} else {
		a.dir = normalize(vec2((r1 - 0.5) * 0.25, 1.0));  // hanging: down, swaying a little
	}
	vec2 np = a.pos + a.dir;
	ivec2 nq = ivec2(floor(np));
	if (!inside(nq)) {
		a.state = 0.0;
		tips.t[i] = a;
		return;
	}
	if (a.state < 1.5 && imageLoad(surface, nq).r < 0.5) {
		// A hole ahead: going down over its top edge, maybe drop and hang; else turn away.
		if (a.dir.y > 0.3 && r2 < p.hang) {
			a.state = 2.0;
		} else {
			a.dir = rot(-a.dir, (r2 - 0.5) * 2.0);
			tips.t[i] = a;
			return;
		}
	}
	a.pos = np;
	a.dist += 1.0;
	a.life -= 1.0;
	stem(a.pos, a.dir, a.width, a.dist);
	a.leaf -= 1.0;
	if (a.leaf <= 0.0) {
		a.side = -a.side;
		vec2 axis = rot(a.dir, a.side * (0.9 + r3 * 0.5));
		leaf(a.pos + axis * a.width, axis, p.leaf_len * (0.75 + r4 * 0.5), a.dist);
		a.leaf = p.leaf_every * (0.6 + r3 * 0.8);
	}
	// Branch: a new tip off to one side, thinner, with some of the length left.
	if (r4 < p.branch && a.width > 0.9 && a.state < 1.5) {
		uint j = atomicAdd(count.n, 1u);
		if (j < uint(p.max_tips)) {
			Tip b = a;
			b.dir = rot(a.dir, (r1 < 0.5 ? -1.0 : 1.0) * (0.6 + r2 * 0.6));
			b.life = a.life * 0.6;
			b.width = a.width * 0.75;
			b.leaf = p.leaf_every * r3;
			tips.t[j] = b;
		}
	}
	if (a.life <= 0.0) {
		leaf(a.pos, a.dir, p.leaf_len, a.dist);
		a.state = 0.0;
	}
	tips.t[i] = a;
}
