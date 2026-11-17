// Coverage AA (N64VideoOut edge_aa with MSAA on, our patched Godot: engine/README.md):
// N64 shaders end their fragment() with `N64_COVERAGE;` (level geometry), `N64_COVERAGE_OBJECT;`
// (actors, trees, props: one surface each), or the `_CUTOUT` forms for alpha-tested ones
// (statements: Godot's preprocessor has no empty-argument macros).
// They write a tag into the colour's alpha, read back per MSAA sample by the video output
// (see n64_coverage_tag: coverage level + 16 x face direction or object code).
// The level is analytic (BARYCENTRIC, patch 0002): how much of the pixel this triangle
// covers, from the pixel's distance to its edges - 8 levels whatever the GPU's sample
// count. Cut-outs also take the texture alpha's edge (where the alpha test cuts the shape
// inside the triangle). The direction lets the resolve treat neighbouring triangles of
// one surface - a wall, a rounded actor's facets - as one (their coverage adds up across
// the shared edge, as on the N64), while silhouettes and creases are softened.
// On a stock Godot (or the Mobile / Compatibility renderers) they do nothing.
// Opaque and alpha-scissor shaders only: blended shaders need their alpha.
#if defined(M3D3_COVERAGE) && CURRENT_RENDERER == RENDERER_FORWARD_PLUS

// Octahedral direction bucket (8 x 8) of the face at view position `view_pos`.
float n64_coverage_dir(vec3 view_pos) {
	vec3 n = normalize(cross(dFdx(view_pos), dFdy(view_pos)));
	vec2 o = n.xy / (abs(n.x) + abs(n.y) + abs(n.z));
	if (n.z < 0.0) {
		o = (1.0 - abs(o.yx)) * vec2(o.x >= 0.0 ? 1.0 : -1.0, o.y >= 0.0 ? 1.0 : -1.0);
	}
	ivec2 q = clamp(ivec2((o * 0.5 + 0.5) * 8.0), ivec2(0), ivec2(7));
	return float(q.x + q.y * 8);
}

#if defined(M3D3_BARYCENTRIC)
// The triangle's share of the pixel: its nearest edge's distance in pixels, + 0.5.
float n64_coverage_tri(vec3 bary) {
	vec3 e = clamp(bary / max(fwidth(bary), vec3(1e-6)) + 0.5, 0.0, 1.0);
	return min(min(e.x, e.y), e.z);
}
#else
float n64_coverage_tri(vec3 bary) {
	return 1.0;
}
#endif

// Tag: level + 16 x code. Level 0..8 = the triangle's analytic coverage (eighths); 9..15 =
// limited by the texture's alpha edge instead (sixths, 9 = none): it counts even where
// the cut-out covers every sample. Code 0..63 = face direction (level geometry: a wall
// and the ground meet at an edge that's smoothed); 64 = an object (actor, tree, prop):
// all its triangles are one surface, as the N64's adjacent triangles summed their coverage.
// Level geometry's code (0..47): the facing axis (0..5: the normal's largest component, by
// sign) x 8 + the brush's ID (0..6, from the bake; 7 = none: carpets, mountains, unkeyed). The resolve counts one
// brush as one surface, and different brushes facing the same way at the same depth too.
float n64_coverage_axis(vec3 view_pos) {
	vec3 n = normalize(cross(dFdx(view_pos), dFdy(view_pos)));
	vec3 a = abs(n);
	if (a.x >= a.y && a.x >= a.z) {
		return n.x >= 0.0 ? 0.0 : 1.0;
	}
	if (a.y >= a.z) {
		return n.y >= 0.0 ? 2.0 : 3.0;
	}
	return n.z >= 0.0 ? 4.0 : 5.0;
}

float n64_coverage_tag(float tri, float alpha, float code) {
	float l = alpha < tri - 0.01 ? 9.0 + floor(clamp(alpha, 0.0, 1.0) * 6.0 + 0.5)
		: floor(clamp(tri, 0.0, 1.0) * 8.0 + 0.5);
	return l + 16.0 * code;
}

// Where the alpha test cuts (threshold 0.5): the texture's edge's share of the pixel.
// An object's ID code (64..127: the object flag + 6 bits hashed from where it is this frame):
// every pixel of one object shares it, so its own triangles count as one surface (their
// coverage sums, as the RDP's did within a mesh) and only its outline - against anything
// else, another actor included - is anti-aliased.
float n64_object_code(mat4 model) {
	vec3 p = floor(model[3].xyz * 4.0);
	float h = fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
	return 64.0 + floor(h * 62.99);
}

// An object's code with an explicit ID (instance `object_id` 1..62: stable, so the video
// output can count or outline that object), or 127 while it's dither-faded (N64VideoOut's
// dither resolve blends the pattern back into see-through), else the position hash.
float n64_object_code_id(mat4 model, int id, float fade_amount) {
	if (fade_amount < 0.999) {
		return 127.0;
	}
	return id > 0 ? 64.0 + float(clamp(id, 1, 62)) : n64_object_code(model);
}

float n64_coverage_alpha(float a) {
	return clamp((a - 0.5) / max(fwidth(a), 1e-4) + 0.5, 0.0, 1.0);
}

#if defined(M3D3_BARYCENTRIC)
#define N64_TRI n64_coverage_tri(BARYCENTRIC)
#else
#define N64_TRI (float(bitCount(SAMPLE_MASK_IN)) / 4.0)
#endif
// Level geometry (opaque / alpha-tested) and objects (opaque / alpha-tested). A shader can
// define N64_OBJECT_CODE before including this (n64_actor / n64_textured: object_id, fade).
#ifndef N64_OBJECT_CODE
#define N64_OBJECT_CODE n64_object_code(MODEL_MATRIX)
#endif
#define N64_COVERAGE COVERAGE = n64_coverage_tag(N64_TRI, 1.0, n64_coverage_axis(VERTEX) * 8.0 + 7.0)
#define N64_COVERAGE_BRUSH(id) COVERAGE = n64_coverage_tag(N64_TRI, 1.0, n64_coverage_axis(VERTEX) * 8.0 + (id))
#define N64_COVERAGE_BRUSH_CUTOUT(id) COVERAGE = n64_coverage_tag(N64_TRI, n64_coverage_alpha(ALPHA), n64_coverage_axis(VERTEX) * 8.0 + (id))
#define N64_COVERAGE_CUTOUT COVERAGE = n64_coverage_tag(N64_TRI, n64_coverage_alpha(ALPHA), n64_coverage_axis(VERTEX) * 8.0 + 7.0)
#define N64_COVERAGE_OBJECT COVERAGE = n64_coverage_tag(N64_TRI, 1.0, N64_OBJECT_CODE)
#define N64_COVERAGE_OBJECT_CUTOUT COVERAGE = n64_coverage_tag(N64_TRI, n64_coverage_alpha(ALPHA), N64_OBJECT_CODE)
// Texture edge for cut-outs that discard by alpha (no ALPHA output): a local `c` holds the texel.
#define COVERAGE_TEXEDGE COVERAGE = n64_coverage_tag(N64_TRI, n64_coverage_alpha(c.a), N64_OBJECT_CODE)

#else
#define N64_COVERAGE
#define N64_COVERAGE_CUTOUT
#define N64_COVERAGE_OBJECT
#define N64_COVERAGE_OBJECT_CUTOUT
#define N64_COVERAGE_BRUSH(id)
#define N64_COVERAGE_BRUSH_CUTOUT(id)
#define COVERAGE_TEXEDGE
#endif
