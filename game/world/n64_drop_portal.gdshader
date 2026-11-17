shader_type spatial;
// DropPortal's hole: the other zone's picture.
//  - seamless: its view from where the camera would be on the other side, by screen position
//    (a window: no fog or light of this zone on it);
//  - rdp: a small framebuffer copy laid on the hole like a texture (u along +x, v along +z),
//    stored as RGBA16 (5 bits a channel, the RDP's dithered colour copy) and read with the
//    RDP's three-point filter, rippling out from where the player crosses it (SM64's
//    paintings); shaded a touch darker towards its rim (the shaft's shadow).
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;

uniform sampler2D view : source_color, filter_nearest, repeat_disable;
uniform bool ready = false;
uniform bool rdp = false;
uniform vec2 rdp_size = vec2(64.0);
uniform float ripple = 0.0;
uniform vec2 ripple_at = vec2(0.5);

// The RDP's three-point filter: the nearest three texels of a 2 x 2 by which triangle the
// point is in.
vec3 three_point(vec2 uv) {
	vec2 p = uv * rdp_size - 0.5;
	vec2 f = fract(p);
	ivec2 i = ivec2(floor(p));
	ivec2 lim = ivec2(rdp_size) - 1;
	vec3 c00 = texelFetch(view, clamp(i, ivec2(0), lim), 0).rgb;
	vec3 c10 = texelFetch(view, clamp(i + ivec2(1, 0), ivec2(0), lim), 0).rgb;
	vec3 c01 = texelFetch(view, clamp(i + ivec2(0, 1), ivec2(0), lim), 0).rgb;
	vec3 c11 = texelFetch(view, clamp(i + ivec2(1, 1), ivec2(0), lim), 0).rgb;
	if (f.x + f.y <= 1.0) {
		return c00 + (c10 - c00) * f.x + (c01 - c00) * f.y;
	}
	return c11 + (c01 - c11) * (1.0 - f.x) + (c10 - c11) * (1.0 - f.y);
}

// 5 bits a channel with the RDP's 4 x 4 ordered dither (in texels: the copy was dithered as
// it was drawn).
vec3 rgba16(vec3 c, vec2 texel) {
	const float m[16] = float[16](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
	ivec2 q = ivec2(texel) & ivec2(3);
	float d = (m[q.x + q.y * 4] + 0.5) / 16.0 - 0.5;
	return floor(clamp(c, 0.0, 1.0) * 31.0 + 0.5 + d) / 31.0;
}

void fragment() {
	if (!ready) {
		ALBEDO = vec3(0.0);
	} else if (!rdp) {
		ALBEDO = texture(view, SCREEN_UV).rgb;
	} else {
		vec2 uv = UV;
		if (ripple > 0.001) {
			vec2 d = uv - ripple_at;
			float r = length(d);
			float w = sin(r * 40.0 - TIME * 9.0) * 0.018 * ripple * smoothstep(0.9, 0.0, r);
			uv += (r > 1e-4 ? d / r : vec2(0.0)) * w;
		}
		uv = clamp(uv, vec2(0.0), vec2(1.0));
		// (the copy is stored dithered at 5 bits; the filter reads the stored texels)
		vec3 c = three_point(uv);
		// (quantised in the stored, gamma-encoded values)
		c = pow(rgba16(pow(max(c, vec3(0.0)), vec3(1.0 / 2.2)), uv * rdp_size), vec3(2.2));
		vec2 e = min(UV, 1.0 - UV);
		ALBEDO = c * mix(0.55, 1.0, smoothstep(0.0, 0.12, min(e.x, e.y)));
	}
}
