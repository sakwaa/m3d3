#[compute]
#version 450
// N64VideoOut, video tape (VideoTape): a 90s studio recording's chain over the picture, in
// display values (0..1). Lens: far things defocus smoothly (the BLUR pyramid by depth, not
// pixels). Camera: highlight bloom trailing along the line, aperture correction (halos round
// edges, brighter on the light side). Tape: luma / chroma split (YIQ), chroma low-passed along
// the line and late, saturation, a highlight knee, pedestal, warmth, faint noise.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D src;  // the picture: display rgb, luma in a
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D dst;
layout(set = 0, binding = 2) uniform sampler2D blur0;  // half (display values)
layout(set = 0, binding = 3) uniform sampler2D blur1;  // quarter
layout(set = 0, binding = 4) uniform sampler2D blur2;  // eighth
layout(set = 0, binding = 5) uniform sampler2D depth;
layout(push_constant, std430) uniform Params {
	vec2 size;
	float frame;
	float proj_z;
	float proj_w;
	float has_depth;
	float strength;
	float defocus;
	float focus_near;
	float focus_far;
	float bloom;
	float threshold;
	float smear;
	float sharpen;
	float sharpen_px;
	float chroma_px;
	float chroma_shift;
	float saturation;
	float knee;
	float black;
	float warmth;
	float luma_noise;
	float chroma_noise;
	float tint_r;
	float tint_g;
	float tint_b;
	float pad0;
	float pad1;
} p;

const vec3 LUMA = vec3(0.299, 0.587, 0.114);
const mat3 TO_YIQ = mat3(0.299, 0.596, 0.211, 0.587, -0.274, -0.523, 0.114, -0.322, 0.312);
const mat3 TO_RGB = mat3(1.0, 1.0, 1.0, 0.956, -0.272, -1.106, 0.621, -0.647, 1.703);

vec3 to_srgb(vec3 c) {
	c = clamp(c, 0.0, 1.0);
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

vec3 to_linear(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

float hash(vec2 q) {
	return fract(sin(dot(q, vec2(12.9898, 78.233))) * 43758.5453);
}

vec4 tap(ivec2 xy) {
	return imageLoad(src, clamp(xy, ivec2(0), ivec2(p.size) - 1));
}

vec3 at(ivec2 xy) {
	return tap(xy).rgb;
}

float luma(ivec2 xy) {
	return tap(xy).a;
}

void main() {
	ivec2 xy = ivec2(gl_GlobalInvocationID.xy);
	if (xy.x >= int(p.size.x) || xy.y >= int(p.size.y)) {
		return;
	}
	vec2 px = 1.0 / p.size;
	vec2 uv = (vec2(xy) + 0.5) * px;
	vec3 here = at(xy);

	// Lens: how out of focus this pixel is (sky: as far as it gets).
	float f = 0.0;
	if (p.defocus > 0.0) {
		float dist = 1e9;
		if (p.has_depth > 0.5) {
			float raw = textureLod(depth, uv, 0.0).r;
			dist = raw > 0.0 ? p.proj_w / (raw + p.proj_z) : 1e9;
		}
		f = p.defocus * smoothstep(p.focus_near, p.focus_far, dist);
	}
	vec3 c = here;
	if (f > 0.0) {
		vec3 b0 = textureLod(blur0, uv, 0.0).rgb;
		// (the quarter level read four times half a texel apart: round, not bilinear diamonds)
		vec2 q = px * 2.0;
		vec3 b1 = 0.25 * (textureLod(blur1, uv + vec2(-q.x, -q.y), 0.0).rgb + textureLod(blur1, uv + vec2(q.x, -q.y), 0.0).rgb
			+ textureLod(blur1, uv + vec2(-q.x, q.y), 0.0).rgb + textureLod(blur1, uv + vec2(q.x, q.y), 0.0).rgb);
		c = mix(c, b0, clamp(f * 2.0, 0.0, 1.0));
		c = mix(c, b1, clamp(f * 2.0 - 1.0, 0.0, 1.0));
	}

	// Camera: aperture correction on brightness (in focus only: there's no edge to ring on
	// a defocused one). Halos on the light side show; the dark side's are clipped shallower.
	if (p.sharpen > 0.0) {
		int r = max(int(round(p.sharpen_px)), 1);
		float y = luma(xy);
		float ring = 0.0;
		ring += luma(xy + ivec2(1, 0)) + luma(xy - ivec2(1, 0));
		ring += luma(xy + ivec2(0, 1)) + luma(xy - ivec2(0, 1));
		ring += luma(xy + ivec2(r, 0)) + luma(xy - ivec2(r, 0));
		ring += 0.5 * (luma(xy + ivec2(0, r)) + luma(xy - ivec2(0, r)));
		float detail = y - ring / 7.0;
		detail = detail > 0.0 ? detail : detail * 0.55;
		c += vec3(detail * p.sharpen * (1.0 - clamp(f * 2.0, 0.0, 1.0)));
	}

	// Camera: bloom - bright parts of the soft levels, trailing along the line to the right.
	if (p.bloom > 0.0) {
		vec3 g = vec3(0.0);
		float wsum = 0.0;
		for (int k = 0; k < 5; k++) {
			float o = float(k) / 4.0 * p.smear;
			float w = 1.0 - float(k) * 0.18;
			vec2 at_uv = uv - vec2(o * px.x, 0.0);
			g += w * (0.6 * textureLod(blur1, at_uv, 0.0).rgb + 0.4 * textureLod(blur2, at_uv, 0.0).rgb);
			wsum += w;
		}
		g /= wsum;
		float lum = dot(g, LUMA);
		float over = max(lum - p.threshold, 0.0) / max(1.0 - p.threshold, 0.01);
		c += g * over * p.bloom * vec3(p.tint_r, p.tint_g, p.tint_b);
	}

	// Tape: brightness kept, colour smeared along the line (and late), from the picture
	// before the camera stages, softened like the lens did.
	vec3 yiq = TO_YIQ * c;
	if (p.chroma_px > 0.0) {
		vec2 iq = vec2(0.0);
		float wsum = 0.0;
		for (int k = -3; k <= 3; k++) {
			float o = float(k) / 3.0 * p.chroma_px * 0.5 - p.chroma_shift;
			float w = 1.0 - abs(float(k)) / 4.0;
			iq += w * (TO_YIQ * at(xy + ivec2(int(round(o)), 0))).yz;
			wsum += w;
		}
		iq /= wsum;
		if (f > 0.0) {
			iq = mix(iq, (TO_YIQ * c).yz, clamp(f * 2.0, 0.0, 1.0));
		}
		yiq.yz = iq;
	}
	yiq.yz *= p.saturation;
	// Noise: brightness per pixel per frame; colour in short streaks along the line.
	float t = mod(p.frame, 977.0);
	yiq.x += (hash(vec2(xy) + t * 13.1) - 0.5) * p.luma_noise;
	vec2 streak = vec2(floor(float(xy.x) / 4.0), float(xy.y));
	yiq.yz += (vec2(hash(streak + t * 7.7), hash(streak + t * 3.3 + 91.0)) - 0.5) * p.chroma_noise;
	// Highlights roll off into the knee; blacks sit on the pedestal.
	if (yiq.x > p.knee) {
		float room = max(1.0 - p.knee, 0.001);
		yiq.x = p.knee + room * (1.0 - exp(-(yiq.x - p.knee) / room));
	}
	yiq.x = p.black + yiq.x * (1.0 - p.black);
	vec3 out_c = TO_RGB * yiq;
	out_c += vec3(p.warmth, 0.0, -p.warmth) * (0.5 + 0.5 * yiq.x);
	out_c = mix(here, clamp(out_c, 0.0, 1.0), p.strength);
	imageStore(dst, xy, vec4(to_linear(out_c), 1.0));
}
