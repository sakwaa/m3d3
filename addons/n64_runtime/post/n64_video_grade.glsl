#[compute]
#version 450
// N64VideoOut pass 3 (only while in use): Majora's Mask's screen filters, on the 3D image
// before the HUD (so text stays sharp, as MM took care to do).
//  - Echo: an earlier picture drawn back over this one (MM's cutscene motion blur). The
//    picture is only taken a few times a second (`write`: this frame takes one), blurred a
//    little each time, so the trail is a few soft ghosts melting together, like MM at 20
//    fps, not a strobe of sharp copies. Two history buffers: read one, write the other.
//  - Grade: towards its luminance x a tint (white = grey, warm = sepia, red...).
//  - Screen looks (ScreenLook, four slots blended by weight: zone / room / weather x time
//    of day / cutscene, crossfading): gradient map,
//    palette snap with ordered dither, or a LUT. Worked in display (sRGB) values.
//  - A colour matrix (colour-blind correction; identity otherwise), last.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color;
layout(rgba16f, set = 0, binding = 1) uniform restrict readonly image2D hist_in;
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image2D hist_out;
layout(rgba8, set = 0, binding = 3) uniform restrict readonly image2D look_0;
layout(rgba8, set = 0, binding = 4) uniform restrict readonly image2D look_1;
layout(rgba8, set = 0, binding = 5) uniform restrict readonly image2D look_2;
layout(rgba8, set = 0, binding = 6) uniform restrict readonly image2D look_3;
// Per slot: mode (0 none, 1 gradient, 2 palette, 3 LUT), weight, n, dither.
layout(set = 0, binding = 7, std140) uniform Looks {
	vec4 slot[4];
} looks;
layout(push_constant, std430) uniform Params {
	vec2 size;
	float echo;      // 0..1: share of the earlier picture shown
	float grade;     // 0..1
	vec4 tint;       // rgb (linear); a = 1 when hist_in holds a picture
	vec4 m0;         // colour matrix rows (xyz); m0.w = 1: take a picture this frame
	vec4 m1;         // m1.w: soften (pixels the history spreads each time it's taken)
	vec4 m2;         // m2.w: value groups (0 off; 3 / 5: the picture's light posterised into that many greys)
} p;

const int MAGIC[16] = int[](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

vec3 to_srgb(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

vec3 to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

vec3 lk(int slot, ivec2 i) {
	if (slot == 0) {
		return imageLoad(look_0, i).rgb;
	} else if (slot == 1) {
		return imageLoad(look_1, i).rgb;
	} else if (slot == 2) {
		return imageLoad(look_2, i).rgb;
	}
	return imageLoad(look_3, i).rgb;
}

// One look applied to linear colour `lin` at pixel `xy`.
vec3 apply_look(int slot, vec4 L, vec3 lin, ivec2 xy) {
	int mode = int(L.x + 0.5);
	int n = int(L.z + 0.5);
	vec3 s = clamp(to_srgb(lin), 0.0, 1.0);
	vec3 o = s;
	if (mode == 1) {
		float x = dot(s, LUMA) * 255.0;
		int i0 = int(floor(x));
		o = mix(lk(slot, ivec2(i0, 0)), lk(slot, ivec2(min(i0 + 1, 255), 0)), x - float(i0));
	} else if (mode == 2) {
		// Ordered dither (a 4x4 Bayer square), spread about half a step between colours.
		float d = (float(MAGIC[(xy.y & 3) * 4 + (xy.x & 3)]) / 16.0 - 0.47) * L.w * 0.18;
		vec3 q = clamp(s + d, 0.0, 1.0);
		float best = 1e9;
		for (int i = 0; i < n; i++) {
			vec3 c = lk(slot, ivec2(i, 0));
			vec3 e = q - c;
			float dist = dot(e * e, vec3(0.3, 0.59, 0.11));
			if (dist < best) {
				best = dist;
				o = c;
			}
		}
	} else if (mode == 3) {
		vec3 g = s * float(n - 1);
		ivec3 i0 = ivec3(floor(g));
		ivec3 i1 = min(i0 + 1, ivec3(n - 1));
		vec3 f = g - vec3(i0);
		vec3 c00 = mix(lk(slot, ivec2(i0.b * n + i0.r, i0.g)), lk(slot, ivec2(i0.b * n + i1.r, i0.g)), f.r);
		vec3 c01 = mix(lk(slot, ivec2(i0.b * n + i0.r, i1.g)), lk(slot, ivec2(i0.b * n + i1.r, i1.g)), f.r);
		vec3 c10 = mix(lk(slot, ivec2(i1.b * n + i0.r, i0.g)), lk(slot, ivec2(i1.b * n + i1.r, i0.g)), f.r);
		vec3 c11 = mix(lk(slot, ivec2(i1.b * n + i0.r, i1.g)), lk(slot, ivec2(i1.b * n + i1.r, i1.g)), f.r);
		o = mix(mix(c00, c01, f.g), mix(c10, c11, f.g), f.b);
	}
	return to_linear(o);
}

vec3 hist(ivec2 xy) {
	return imageLoad(hist_in, clamp(xy, ivec2(0), ivec2(p.size) - 1)).rgb;
}

// The history around `xy`, blurred over `r` pixels (3x3 tent).
vec3 hist_soft(ivec2 xy, int r) {
	if (r <= 0) {
		return hist(xy);
	}
	vec3 s = hist(xy) * 4.0;
	s += (hist(xy + ivec2(r, 0)) + hist(xy - ivec2(r, 0)) + hist(xy + ivec2(0, r)) + hist(xy - ivec2(0, r))) * 2.0;
	s += hist(xy + ivec2(r, r)) + hist(xy + ivec2(-r, r)) + hist(xy + ivec2(r, -r)) + hist(xy - ivec2(r, r));
	return s / 16.0;
}

void main() {
	ivec2 xy = ivec2(gl_GlobalInvocationID.xy);
	if (xy.x >= int(p.size.x) || xy.y >= int(p.size.y)) {
		return;
	}
	vec4 here = imageLoad(color, xy);
	vec3 c = here.rgb;
	bool have = p.tint.a > 0.5;
	bool write = p.m0.w > 0.5;
	if (p.echo > 0.0 && have) {
		// Never a sharp copy: shown softened, and softened again as it's carried on.
		c = mix(c, hist_soft(xy, int(p.m1.w + 0.5)), p.echo);
	}
	if (write) {
		vec3 carried = have ? mix(here.rgb, hist_soft(xy, int(p.m1.w + 0.5)), p.echo) : here.rgb;
		imageStore(hist_out, xy, vec4(carried, 1.0));
	}
	if (p.grade > 0.0) {
		float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
		c = mix(c, l * p.tint.rgb, p.grade);
	}
	float total = 0.0;
	for (int i = 0; i < 4; i++) {
		total += looks.slot[i].x > 0.5 ? looks.slot[i].y : 0.0;
	}
	if (total > 0.0) {
		vec3 base = c;
		c = base * max(1.0 - total, 0.0);
		for (int i = 0; i < 4; i++) {
			vec4 L = looks.slot[i];
			if (L.x > 0.5 && L.y > 0.0) {
				c += apply_look(i, L, base, xy) * L.y;
			}
		}
	}
	c = max(vec3(dot(p.m0.xyz, c), dot(p.m1.xyz, c), dot(p.m2.xyz, c)), vec3(0.0));
	if (p.m2.w > 1.5) {
		// Value groups (the squint test): perceived lightness in n flat steps.
		float n = p.m2.w;
		float l = pow(max(dot(c, LUMA), 0.0), 1.0 / 2.2);
		float q = clamp(floor(l * n), 0.0, n - 1.0) / (n - 1.0);
		c = vec3(pow(q, 2.2));
	}
	imageStore(color, xy, vec4(c, here.a));
}
