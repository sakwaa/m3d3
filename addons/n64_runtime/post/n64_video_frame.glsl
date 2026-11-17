#[compute]
#version 450
// N64VideoOut pass 4 (only while in use): framebuffer copies, as OoT and MM drew them - the
// 3D picture (before the HUD) copied to a texture and drawn back over the live picture.
//  - take (mode 0): src = the live picture -> dst = the snapshot, softened `soften` pixels
//    (OoT's pause background, a pictograph photo).
//  - show (mode 1): src = the snapshot, dst = the live picture: the snapshot drawn over it
//    by `show`, dimmed, and warped: a spin-zoom carrying it away (MM's scene warps) or a
//    ripple (OoT's warp songs). Transitions take a snapshot, then run `amount` up while
//    `show` falls, so the old place melts into the new one.
// Point sampled, as the RDP read the copied picture.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D src;
layout(rgba16f, set = 0, binding = 1) uniform restrict image2D dst;
layout(push_constant, std430) uniform Params {
	vec2 size;
	float mode;    // 0 take, 1 show
	float show;    // show: 0..1 the snapshot's share. take: soften (pixels)
	float warp;    // 0 none, 1 spin-zoom, 2 ripple
	float amount;  // 0..1: how far the warp has run
	float dim;     // 0..1: the snapshot darkened (pause background)
	float time;    // seconds (ripple motion)
} p;

vec3 at(ivec2 xy) {
	return imageLoad(src, clamp(xy, ivec2(0), ivec2(p.size) - 1)).rgb;
}

void main() {
	ivec2 xy = ivec2(gl_GlobalInvocationID.xy);
	if (xy.x >= int(p.size.x) || xy.y >= int(p.size.y)) {
		return;
	}
	if (p.mode < 0.5) {
		int r = int(p.show);
		vec3 c = vec3(0.0);
		if (r <= 0) {
			c = at(xy);
		} else {
			// Box blur, 5 x 5 taps spread over the radius (cheap; taken once).
			for (int y = -2; y <= 2; y++) {
				for (int x = -2; x <= 2; x++) {
					c += at(xy + ivec2(x, y) * r / 2);
				}
			}
			c /= 25.0;
		}
		imageStore(dst, xy, vec4(c, 1.0));
		return;
	}
	vec4 live = imageLoad(dst, xy);
	vec2 uv = (vec2(xy) + 0.5) / p.size;
	vec2 aspect = vec2(p.size.x / p.size.y, 1.0);
	vec2 d = (uv - 0.5) * aspect;
	float a = p.amount;
	float keep = p.show;
	if (p.warp > 0.5 && p.warp < 1.5) {
		// Spin-zoom: the old picture turns and rushes outwards.
		float ang = a * a * 3.0;
		float zoom = 1.0 + a * a * 4.0;
		d = mat2(vec2(cos(ang), sin(ang)), vec2(-sin(ang), cos(ang))) * d / zoom;
	} else if (p.warp > 1.5) {
		// Ripple: rings running out from the centre, stronger as it runs.
		float r = length(d);
		d += (r > 1e-4 ? d / r : vec2(0.0)) * sin(r * 40.0 - p.time * 8.0) * 0.02 * a;
	}
	vec2 suv = d / aspect + 0.5;
	if (any(lessThan(suv, vec2(0.0))) || any(greaterThan(suv, vec2(1.0)))) {
		keep = 0.0;  // (zoomed past its edge: the live picture shows)
	}
	vec3 snap = at(ivec2(suv * p.size)) * (1.0 - p.dim);
	imageStore(dst, xy, vec4(mix(live.rgb, snap, keep), live.a));
}
