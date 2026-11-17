shader_type canvas_item;
render_mode unshaded, blend_disabled;
// RenderScale's screen layer: N64VideoOut's picture enlarged to the window, drawn straight
// over it (no blending: it covers everything under it, so reading the screen back is waste).
// mode -1: TEXTURE is an already upscaled picture, copied as it is. 0: TEXTURE is the picture
// at render size (sRGB-encoded), enlarged as nearest blocks; 1: edge-aware, done right here in
// one pass at window resolution (n64_video_upscale.glsl's logic: texels as blocks,
// silhouettes redrawn from the coverage).

uniform int mode = -1;
uniform sampler2D info_tex : filter_nearest;  // coverage share, code, depth (render size)
uniform vec2 src_size = vec2(1.0);
uniform float factor = 1.0;
uniform bool show_edges = false;

vec3 dec(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}

vec3 enc(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

ivec2 clampi(ivec2 q) {
	return clamp(q, ivec2(0), ivec2(src_size) - 1);
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

float share(ivec2 q, float code) {
	vec4 i = texelFetch(info_tex, clampi(q), 0);
	return same(i.y, code) ? i.x : 0.0;
}

void fragment() {
	if (mode < 0) {
		COLOR = vec4(texelFetch(TEXTURE, ivec2(FRAGCOORD.xy), 0).rgb, 1.0);
	} else {
		vec2 pos = UV * src_size;  // in render pixels
		ivec2 sp = clampi(ivec2(floor(pos)));
		vec3 c = texelFetch(TEXTURE, sp, 0).rgb;
		vec4 here = texelFetch(info_tex, sp, 0);
		vec3 col = c;
		if (mode == 1 && here.x < 0.999 && here.y >= 0.0) {
			float code = here.y;
			float s00 = share(sp + ivec2(-1, -1), code), s10 = share(sp + ivec2(0, -1), code), s20 = share(sp + ivec2(1, -1), code);
			float s01 = share(sp + ivec2(-1, 0), code), s21 = share(sp + ivec2(1, 0), code);
			float s02 = share(sp + ivec2(-1, 1), code), s12 = share(sp + ivec2(0, 1), code), s22 = share(sp + ivec2(1, 1), code);
			vec2 g = vec2((s20 + 2.0 * s21 + s22) - (s00 + 2.0 * s01 + s02),
				(s02 + 2.0 * s12 + s22) - (s00 + 2.0 * s10 + s20));
			if (length(g) >= 1.5) {
				vec2 n = normalize(g);
				vec2 o = pos - vec2(sp) - 0.5;
				float s = dot(o, n) + (here.x - 0.5) / (abs(n.x) + abs(n.y));
				float k = clamp(s * factor + 0.5, 0.0, 1.0);
				float best = 0.2;
				ivec2 q = sp;
				for (int y = -1; y <= 1; y++) {
					for (int x = -1; x <= 1; x++) {
						ivec2 d = ivec2(x, y);
						if (d == ivec2(0)) {
							continue;
						}
						float along = dot(normalize(vec2(d)), -n);
						if (along > best && !same(texelFetch(info_tex, clampi(sp + d), 0).y, code)) {
							best = along;
							q = sp + d;
						}
					}
				}
				if (q != sp && texelFetch(info_tex, clampi(q), 0).z < here.z * 0.985) {
					vec3 bg = texelFetch(TEXTURE, clampi(q), 0).rgb;
					col = enc(mix(dec(bg), dec(c), k));
					if (show_edges) {
						col = mix(col, vec3(1.0, 0.0, 0.0), 0.5);
					}
				}
			}
		}
		COLOR = vec4(col, 1.0);
	}
}
