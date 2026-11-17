#[compute]
#version 450
// N64VideoOut, coverage AA (patched Godot + MSAA): the N64's own edge anti-aliasing from
// real per-triangle coverage, in one pass straight into the colour.
// Resolve: per pixel, the nearest MSAA sample is the front triangle; the front surface is
// every sample facing about the same way at about the same depth (n64_coverage.gdshaderinc
// tags each sample with its coverage level and face direction, or as an object): a wall's
// or an actor's neighbouring triangles count together, as the N64 summed the coverage of a
// mesh's adjacent triangles. Its colour is theirs (not averaged with what's behind, as the
// RDP drew it). Coverage: full where the surface fills every sample (an edge inside it),
// else its triangles' own analytic coverage (8 levels, the N64's 3 bits) - or a cut-out's
// alpha edge, or the share of samples it holds where another surface passes through it at
// the same depth (ZMODE_INTER: walls meeting the ground). Samples drawn over with blending afterwards (the passages' darkness,
// effects) carry no coverage: a plain MSAA resolve there.
// VI blend (edge pixels only, most of the screen stops at the resolve): the background
// estimated from the neighbours' resolved colours (per channel, second-highest +
// second-lowest less the pixel), mixed in by the uncovered share; then the divot filter.
// Extras from the same tags (N64VideoOut): seam dirt in hollows where surfaces meet, the
// dither resolve of faded objects, a 1-pixel outline on one object, per-object visible
// pixel counts, and per-pixel edge info for the edge-aware upscale (n64_video_upscale.glsl).

// BRUSH_IDS 0: level geometry by facing alone (as before brush IDs; comparisons).
#define BRUSH_IDS 1

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2DMS color_ms;
layout(set = 0, binding = 1) uniform sampler2DMS depth_ms;
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image2D dst;
// Objects' visible pixels this frame (front sample's code 64..127 -> [code - 64]).
layout(set = 0, binding = 3, std430) restrict buffer Counts {
	uint counts[64];
} vis;
// Per pixel for the edge-aware upscale: coverage, front code (-1 untagged), front depth.
layout(rgba16f, set = 0, binding = 4) uniform restrict writeonly image2D info;
// Contact shadow at half size (n64_video_seam.glsl stage 1): shadow, depth.
layout(rg32f, set = 0, binding = 5) uniform restrict readonly image2D ao;
layout(push_constant, std430) uniform Params {
	vec2 size;
	float amount;  // 0..1: the VI blend's strength
	float divot;   // 1: divot filter on
	float show;    // 1: partly covered pixels in red (tuning)
	float seam;    // seam dirt: darkening where different surfaces meet in a hollow (0 off)
	float seam_radius;  // its reach (pixels)
	float dither_resolve;  // 1: dither-faded objects (code 127) blended back (4 x 4)
	float outline_code;  // object code outlined (64..126; < 0 off)
	float outline_mix;
	float seam_near_raw;  // seam dirt only nearer than this (raw reversed-Z depth: near / distance)
	float seam_objects;  // 1: only contacts involving an object (the bake already darkened level seams)
	vec4 outline_color;  // rgb, a: 1 = tint the object's own colour, 0 = flat colour
	float count;   // 1: count visible pixels per object
	float write_info;  // 1: per-pixel edge info for the upscale
	float seam_metres;  // contact shadow reach (world metres)
	float seam_debug;  // 1: the contact shadow alone, as grey (white = none); 2: view depth
	vec4 proj;     // |P00|, |P11|, P22, P32: view position from raw depth
	vec4 seam2;    // x: reach between level surfaces (metres: a wall's foot, a step); y: gain; z: level joints' share of the gain
} p;

bool tagged(float a) {
	return a > 0.5 && abs(a - round(a)) < 0.02;
}

// The nearest sample's code (-1: untagged, e.g. sky / effects) and depth (reversed Z).
vec2 front_at(ivec2 xy) {
	xy = clamp(xy, ivec2(0), ivec2(p.size) - 1);
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
	return vec2(tagged(a) ? floor(a / 16.0) : -1.0, best);
}

// One surface for the seam / outline tests: objects by code, level geometry by facing.
bool same_surface(float a, float b) {
	if (a < 0.0 || b < 0.0) {
		return a == b;
	}
	if (a >= 64.0 || b >= 64.0) {
		return a == b;
	}
	return floor(a / 8.0) == floor(b / 8.0);
}

// View-space position of pixel `xy` at raw (reversed-Z) depth `raw`.
vec3 view_pos(vec2 xy, float raw) {
	float dist = p.proj.w / (raw + p.proj.z);  // linear depth (positive)
	vec2 ndc = (xy + 0.5) / p.size * 2.0 - 1.0;
	return vec3(ndc.x * dist / p.proj.x, -ndc.y * dist / p.proj.y, -dist);
}

// Contact shadow (n64_video_seam.glsl, half size) read back for this pixel: a 3 x 3 blur
// of the half-size results that lie on this surface (about this depth) - softens the
// directions' interleave and the half-size steps without bleeding across edges.
float seam_at(ivec2 xy, vec2 here) {
	if (here.x < 0.0) {
		return 0.0;
	}
	ivec2 hs = (ivec2(p.size) + 1) / 2;
	ivec2 hc = xy / 2;
	float sum = 0.0;
	float wsum = 0.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 v = imageLoad(ao, clamp(hc + ivec2(x, y), ivec2(0), hs - 1)).xy;
			float w = abs(v.y - here.y) <= here.y * 0.03 ? (x == 0 && y == 0 ? 2.0 : 1.0) : 0.0;
			sum += v.x * w;
			wsum += w;
		}
	}
	return wsum > 0.0 ? sum / wsum : imageLoad(ao, clamp(hc, ivec2(0), hs - 1)).x;
}

// Direction bucket -> unit normal (octahedral, bucket centre).
vec3 bucket_dir(float b) {
	vec2 q = vec2(mod(b, 8.0), floor(b / 8.0));
	vec2 o = (q + 0.5) / 8.0 * 2.0 - 1.0;
	vec3 n = vec3(o, 1.0 - abs(o.x) - abs(o.y));
	if (n.z < 0.0) {
		n.xy = (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
	}
	return normalize(n);
}

// The last resolve()'s coverage before the interpenetration share (the upscale wants
// silhouettes only: a post standing in the ground is no edge to redraw).
float g_cov_silhouette = 1.0;
// resolve()'s front sample: (code or -1, depth) - what front_at() would read again.
vec2 g_front = vec2(-1.0, 0.0);

// The front surface's colour (rgb) and coverage (a) at `xy`.
vec4 resolve(ivec2 xy) {
	g_cov_silhouette = 1.0;
	xy = clamp(xy, ivec2(0), ivec2(p.size) - 1);
	int n = min(textureSamples(color_ms), 8);
	vec4 cs[8];
	float ds[8];
	int front = 0;
	vec3 all_sum = vec3(0.0);
	bool uniform_px = true;
	for (int s = 0; s < n; s++) {
		cs[s] = texelFetch(color_ms, xy, s);
		ds[s] = texelFetch(depth_ms, xy, s).r;  // (reversed Z: larger is nearer)
		all_sum += cs[s].rgb;
		uniform_px = uniform_px && cs[s].a == cs[0].a && ds[s] == ds[0];
		if (ds[s] > ds[front]) {
			front = s;
		}
	}
	float fa = cs[front].a;
	g_front = vec2(tagged(fa) ? floor(fa / 16.0) : -1.0, ds[front]);
	if (!tagged(fa)) {
		return vec4(all_sum / float(n), 1.0);
	}
	float lv = mod(fa, 16.0);
	if (uniform_px && lv < 9.0) {
		// One triangle (or one tag) over every sample, no alpha edge: inside a surface.
		return vec4(all_sum / float(n), 1.0);
	}
	float near = ds[front];
	float fcode = floor(fa / 16.0);
	vec3 sum = vec3(0.0);
	int count = 0;
	float level = 0.0;
	float alpha_cut = 1.0;
	int crossing = 0;  // samples of another surface at the same depth (passing through this one)
	for (int s = 0; s < n; s++) {
		float a = cs[s].a;
		bool t = tagged(a);
		float code = floor(a / 16.0);
		// Objects (codes 64..127, one ID each): the same object; level geometry: by facing.
		// Level geometry (codes 0..47 = facing axis x 8 + brush ID): one brush is one surface
		// (its creases stay crisp: the RDP summed a mesh's coverage), and surfaces facing the
		// same way are one too (coplanar tiles: no seams).
#if BRUSH_IDS
		bool level_same = code < 64.0 && fcode < 64.0
			&& ((mod(code, 8.0) == mod(fcode, 8.0) && mod(fcode, 8.0) < 7.0)  // (7: no brush ID)
				|| floor(code / 8.0) == floor(fcode / 8.0));
		// (Same facing counts as one surface whatever the brush, as before brush IDs: a "same
		// depth" test for coplanar neighbours failed at grazing angles and marked the ground's
		// brush seams.)
#else
		bool level_same = code < 64.0 && fcode < 64.0 && floor(code / 8.0) == floor(fcode / 8.0);
#endif
		bool same = abs(ds[s] - near) <= near * 0.03
			&& (!t || (fcode >= 64.0 ? code == fcode : level_same));
		// (another object - a different ID - anywhere in the near band; level geometry only
		// when truly at the same depth)
		if (!same && t && abs(ds[s] - near) <= near * (fcode >= 64.0 || code >= 64.0 ? 0.03 : 0.004)) {
			crossing++;
		}
		if (same) {
			sum += cs[s].rgb;
			count++;
			if (t) {
				float l = mod(a, 16.0);
				if (l >= 9.0) {
					alpha_cut = min(alpha_cut, (l - 9.0) / 6.0);
					level = max(level, (l - 9.0) / 6.0);
				} else {
					level = max(level, l / 8.0);
				}
			}
		}
	}
	// Filling every sample: an edge inside the surface (full) - unless a cut-out's alpha
	// edge runs through the pixel.
	float cvg = count == n ? alpha_cut : clamp(level, 0.0, 1.0);
	// Interpenetration (the RDP's ZMODE_INTER): where another surface passes through this one
	// (a wall into the ground, a post into the floor) the pixel is shared at the same depth -
	// its coverage is the share of samples this surface holds, so the VI softens the seam.
	g_cov_silhouette = cvg;
	if (crossing > 0) {
		cvg = min(cvg, float(count) / float(n));
	}
	return vec4(sum / float(max(count, 1)), cvg);
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
	vec4 here = resolve(xy);
	float cov_sil = g_cov_silhouette;
	vec3 c = here.rgb;
	vec2 fr = g_front;  // (the same samples front_at(xy) reads: not read twice)
	// Dither resolve: a faded object's dropped pixels (magic square, period 4) show what's
	// behind; over a 4 x 4 window its share of pixels is the fade, so the window's two
	// averages mixed by that share give the see-through colour (no sorting, as the RDP's
	// dither, then smoothed back as the VI smoothed its 16-bit dither).
	bool door = false;
	if (p.dither_resolve > 0.5) {
		vec3 ds = vec3(0.0), os = vec3(0.0);
		float dn = 0.0, on = 0.0;
		for (int y = -2; y < 2; y++) {
			for (int x = -2; x < 2; x++) {
				ivec2 q = xy + ivec2(x, y);
				bool d = front_at(q).x == 127.0;
				vec3 qc = resolve(q).rgb;
				if (d) { ds += qc; dn += 1.0; } else { os += qc; on += 1.0; }
			}
		}
		if (dn > 0.0) {
			door = true;
			c = on > 0.0 ? mix(os / on, ds / dn, dn / 16.0) : ds / dn;
		}
	}
	float e = door ? 0.0 : clamp((1.0 - here.a) * 2.0, 0.0, 1.0);
	if (e > 0.0 && p.amount > 0.0) {
		vec3 l = resolve(xy - ivec2(1, 0)).rgb;
		vec3 r = resolve(xy + ivec2(1, 0)).rgb;
		vec3 nb[8] = vec3[8](l, r, resolve(xy - ivec2(0, 1)).rgb, resolve(xy + ivec2(0, 1)).rgb,
			resolve(xy + ivec2(-1, -1)).rgb, resolve(xy + ivec2(1, -1)).rgb,
			resolve(xy + ivec2(-1, 1)).rgb, resolve(xy + ivec2(1, 1)).rgb);
		vec3 pmax, pmin;
		pen_minmax(nb, pmax, pmin);
		vec3 bg = clamp(pmax + pmin - c, pmin, pmax);
		c = mix(c, bg, 0.5 * e * p.amount);
		if (p.divot > 0.5) {
			float yl = dot(l, vec3(0.299, 0.587, 0.114));
			float yr = dot(r, vec3(0.299, 0.587, 0.114));
			float yc = dot(c, vec3(0.299, 0.587, 0.114));
			if ((yc > yl && yc > yr) || (yc < yl && yc < yr)) {
				vec3 med = abs(yl - yc) < abs(yr - yc) ? l : r;
				c = mix(c, med, 0.5 * e);
			}
		}
	}
	if (p.seam > 0.0) {
		float sh = seam_at(xy, fr);
		c *= 1.0 - p.seam * sh;
		if (p.seam_debug > 2.5) {
			// 3: the tag - level geometry by facing axis (0..5 colours), objects grey, untagged magenta.
			const vec3 AX[6] = vec3[6](vec3(1, 0.2, 0.2), vec3(0.5, 0, 0), vec3(0.2, 1, 0.2), vec3(0, 0.5, 0), vec3(0.3, 0.3, 1), vec3(0, 0, 0.5));
			c = fr.x < 0.0 ? vec3(1, 0, 1) : fr.x >= 64.0 ? vec3(0.6) : AX[int(fr.x) / 8] * (0.6 + 0.4 * mod(fr.x, 8.0) / 7.0);
		} else if (p.seam_debug > 1.5) {
			c = vec3(fract(-view_pos(vec2(xy), fr.y).z / 4.0));
		} else if (p.seam_debug > 0.5) {
			c = vec3(1.0 - sh);
		}
	}
	// Outline: the outlined object's own pixels next to anything else (1 pixel, inside its
	// silhouette, so it never spills onto what's behind).
	if (p.outline_code >= 0.0 && fr.x == p.outline_code) {
		bool edge = front_at(xy + ivec2(1, 0)).x != p.outline_code || front_at(xy - ivec2(1, 0)).x != p.outline_code
			|| front_at(xy + ivec2(0, 1)).x != p.outline_code || front_at(xy - ivec2(0, 1)).x != p.outline_code;
		if (edge) {
			vec3 oc = p.outline_color.a > 0.5 ? c * p.outline_color.rgb : p.outline_color.rgb;
			c = mix(c, oc, p.outline_mix);
		}
	}
	if (p.count > 0.5 && fr.x >= 64.0) {
		atomicAdd(vis.counts[int(fr.x) - 64], 1u);
	}
	if (p.write_info > 0.5) {
		imageStore(info, xy, vec4(door ? 1.0 : cov_sil, fr.x, fr.y, 1.0));
	}
	if (p.show > 0.5) {
		c = mix(c, vec3(1.0, 0.0, 0.0), e);
	}
	imageStore(dst, xy, vec4(c, 1.0));
}
