shader_type sky;
// N64-style textured sky: zenith/horizon gradient, two scrolling layers of an I4 cloud
// texture thresholded by cloud cover, Majora's Mask style point stars turning with the hour, a sun /
// moon disc and lightning flashes, quantised to RGBA16 with a 2x2 ordered dither.
// Colours come from DynamicSky (weather preset x time of day).

uniform vec3 zenith : source_color = vec3(0.2, 0.45, 0.9);
uniform vec3 horizon : source_color = vec3(0.65, 0.8, 0.95);
uniform vec3 cloud_light : source_color = vec3(1.0);
uniform vec3 cloud_dark : source_color = vec3(0.6, 0.65, 0.75);
uniform float stars = 0.0;
uniform float cloud_cover = 0.3;
uniform float cloud_softness = 0.35;
// Accumulated drift (texture repeats), so speed changes never jump.
uniform vec2 cloud_offset = vec2(0.0);
// Texture repeats per unit of the cloud plane.
uniform float cloud_scale = 0.35;
uniform sampler2D cloud_tex : filter_linear_mipmap, repeat_enable, hint_default_black;
uniform float star_angle = 0.0;
// Stars are individual soft points (like MM's star primitives at 240p), not a texture:
// one candidate per cell of a cube-map grid, `star_fill` of cells lit.
uniform float star_density = 36.0;
uniform float star_fill = 0.4;
// Angular radius in radians (~0.002 is about one N64 pixel), and the share of the radius
// that fades out (0 = hard disc, 1 = soft from the centre).
uniform float star_size = 0.002;
uniform float star_softness = 0.35;
uniform float star_twinkle = 0.3;
// Direction towards the sun (day) or moon (night), its colour and size (cosine of radius).
uniform vec3 disc_dir = vec3(0.0, 1.0, 0.0);
uniform vec3 disc_color : source_color = vec3(1.0, 0.95, 0.8);
uniform float disc_size = 0.9994;
uniform float disc_glow = 0.35;
uniform float flash = 0.0;
uniform bool dither = true;

vec3 star_hash(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.xxy + p.yxx) * p.zyx);
}

// Direction for a point (-1..1) on cube face `f` (0/1 = +-X, 2/3 = +-Y, 4/5 = +-Z).
vec3 face_dir(float f, vec2 uv) {
	float s = mod(f, 2.0) < 0.5 ? 1.0 : -1.0;
	if (f < 1.5) {
		return vec3(s, uv);
	} else if (f < 3.5) {
		return vec3(uv.x, s, uv.y);
	}
	return vec3(uv, s);
}

vec3 star_field(vec3 d, float time) {
	vec3 a = abs(d);
	float f;
	vec2 uv;
	if (a.x >= a.y && a.x >= a.z) {
		f = d.x > 0.0 ? 0.0 : 1.0;
		uv = d.yz / a.x;
	} else if (a.y >= a.z) {
		f = d.y > 0.0 ? 2.0 : 3.0;
		uv = d.xz / a.y;
	} else {
		f = d.z > 0.0 ? 4.0 : 5.0;
		uv = d.xy / a.z;
	}
	vec2 g = (uv * 0.5 + 0.5) * star_density;
	vec2 base = floor(g);
	vec3 col = vec3(0.0);
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 cell = base + vec2(float(i), float(j));
			vec3 h = star_hash(vec3(cell, f * 17.0 + 3.0));
			if (h.z > star_fill) {
				continue;
			}
			vec3 h2 = star_hash(vec3(cell.yx, f * 31.0 + 11.0));
			vec2 p = (cell + 0.15 + 0.7 * h.xy) / star_density * 2.0 - 1.0;
			float ang = length(cross(d, normalize(face_dir(f, p))));
			// Mostly faint, a few bright (and slightly bigger) ones.
			float bright = 0.25 + 0.75 * pow(h2.x, 3.0);
			float r = star_size * mix(0.75, 1.5, h2.x * h2.x);
			// Solid core, short filtered rim.
			float k = clamp((1.0 - ang / r) / max(star_softness, 0.01), 0.0, 1.0);
			if (k <= 0.0) {
				continue;
			}
			// Pale white / blue / yellow / orange, like MM's star colours.
			vec3 tint = h2.y < 0.55 ? vec3(1.0) : h2.y < 0.75 ? vec3(0.78, 0.87, 1.0)
				: h2.y < 0.92 ? vec3(1.0, 0.96, 0.78) : vec3(1.0, 0.82, 0.68);
			float tw = 1.0 - star_twinkle * (0.5 + 0.5 * sin(time * (1.3 + 2.5 * h2.z) + h2.z * 40.0));
			col += tint * k * bright * tw;
		}
	}
	return col;
}

void sky() {
	vec3 d = EYEDIR;
	if (AT_CUBEMAP_PASS) {
		COLOR = mix(horizon, zenith, clamp(d.y, 0.0, 1.0));
	} else {
		float up = clamp(d.y, 0.0, 1.0);
		vec3 col = mix(horizon, zenith, sqrt(up));
		// Below the horizon: darker horizon colour (fog hides the seam with the ground).
		col = mix(col, horizon * 0.6, smoothstep(0.0, -0.25, d.y));

		// Clouds: planar projection, two layers at different scales and drift.
		vec2 plane = d.xz / (max(d.y, 0.0) + 0.12);
		vec2 p = plane * cloud_scale;
		float n = texture(cloud_tex, p + cloud_offset).r * 0.65
			+ texture(cloud_tex, p * 1.7 + vec2(0.37, 0.11) + cloud_offset * 0.6).r * 0.35;
		float edge = 1.0 - cloud_cover;
		float density = smoothstep(edge - cloud_softness * 0.5, edge + cloud_softness * 0.5, n);
		// The projected texture compresses into streaks at the horizon: fade it out there and
		// let a flat band of average cloud colour (stronger with more cover) take over.
		float near_horizon = smoothstep(0.02, 0.2, d.y);
		density *= near_horizon;
		vec3 cloud_band = mix(cloud_dark, cloud_light, 0.55);
		col = mix(col, cloud_band, cloud_cover * 0.85 * (1.0 - near_horizon) * smoothstep(-0.15, 0.0, d.y));
		float lit = clamp(n * 1.4 - 0.25 + 0.3 * dot(d, disc_dir) * step(0.0, disc_dir.y), 0.0, 1.0);
		vec3 cloud = mix(cloud_dark, cloud_light, lit);

		// Stars, turning about the zenith with the hour; faded near the horizon.
		float sa = sin(star_angle);
		float ca = cos(star_angle);
		vec3 sd = vec3(ca * d.x - sa * d.z, d.y, sa * d.x + ca * d.z);
		if (stars > 0.001 && d.y > 0.0) {
			col += star_field(sd, TIME) * stars * smoothstep(0.03, 0.3, d.y) * (1.0 - density);
		}

		// Sun / moon disc and glow, hidden by clouds.
		float s = dot(d, normalize(disc_dir));
		float disc = smoothstep(disc_size - 0.0004, disc_size, s);
		float glow = pow(max(s, 0.0), 48.0) * disc_glow;
		col += disc_color * (disc + glow) * (1.0 - density * 0.9) * step(-0.05, disc_dir.y);

		col = mix(col, cloud, density);
		col = mix(col, vec3(0.85, 0.88, 1.0), flash * 0.55);

		if (dither) {
			vec2 f = mod(floor(FRAGCOORD.xy), 2.0);
			// 2x2 Bayer: 0, 2, 3, 1 (/4), centred.
			float b = mod(f.x * 2.0 + f.y * 3.0, 4.0) / 4.0 - 0.375;
			// Quantise in display (sRGB) space, like a real 5-bit framebuffer; in linear space
			// dark night tones would get huge steps.
			vec3 g = pow(clamp(col, 0.0, 1.0), vec3(1.0 / 2.2));
			g = floor(g * 31.0 + 0.5 + b) / 31.0;
			col = pow(g, vec3(2.2));
		}
		COLOR = col;
	}
}
