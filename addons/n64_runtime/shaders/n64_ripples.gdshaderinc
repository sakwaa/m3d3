// Ripples on wet ground and water (needs n64_sampling.gdshaderinc first):
//  - n64_rain_rings: raindrops landing - small rings on a jittered grid, each cell's drop at
//    its own moment of a short cycle, as many cells active as it rains (procedural: sharp,
//    everywhere, nothing stored). Faded with distance (they'd shimmer).
//  - n64_ripple_sim: the zone's ripple simulation (GroundSim, n64_ripple_sim.gdshader:
//    drips off eaves, actors' wakes and landings). Its square follows the camera exactly as
//    the simulation's does (snapped to its texels), so it's worked out here from the camera
//    and the material is set up once (ripple_map, ripple_dims = size, texels; 0 = none).
// Both return a ripple height about -1..1 (rings' crests and troughs).

uniform sampler2D ripple_map : filter_linear, repeat_disable, hint_default_black;
uniform vec2 ripple_dims = vec2(0.0, 128.0);
// The simulations' squares now (corner x, z, size), set by their GroundSim each frame with
// the very corner its texture was drawn for (deriving it from the camera here jittered by a
// texel: the sim reads the camera before it's placed for the frame).
global uniform vec4 n64_ripple_rect;
global uniform vec4 n64_print_rect;

vec2 n64_ripple_hash(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453);
}

float n64_rain_rings(vec2 xz, float time, float amount, float dist) {
	float fade = 1.0 - smoothstep(5.0, 13.0, dist);
	if (amount <= 0.0 || fade <= 0.0) {
		return 0.0;
	}
	float sum = 0.0;
	for (int s = 0; s < 2; s++) {
		float scale = s == 0 ? 0.7 : 0.5;
		vec2 g = xz / scale;
		vec2 base = floor(g);
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				vec2 c = base + vec2(float(x), float(y)) + float(s) * 17.0;
				vec2 h = n64_ripple_hash(c);
				if (fract(h.x * 91.7 + h.y * 13.3) > min(amount * 1.5, 1.0)) {
					continue;  // (not raining on this cell)
				}
				vec2 centre = (base + vec2(float(x), float(y)) + 0.2 + 0.6 * h) * scale;
				float phase = fract(time * 1.25 + h.x * 7.31 + h.y * 3.17);
				float rad = phase * 0.32 * scale;
				float d = distance(xz, centre);
				float w = 0.035;
				sum += sin((d - rad) / w * 1.6) * exp(-pow((d - rad) / w, 2.0)) * pow(1.0 - phase, 1.4);
			}
		}
	}
	return sum * fade;
}

float n64_ripple_sim(vec2 xz, vec3 cam) {
	if (ripple_dims.x <= 0.0) {
		return 0.0;
	}
	if (n64_ripple_rect.z <= 0.0) {
		return 0.0;
	}
	vec2 uv = (xz - n64_ripple_rect.xy) / n64_ripple_rect.z;
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
		return 0.0;
	}
	vec2 e = min(uv, 1.0 - uv);
	return textureLod(ripple_map, uv, 0.0).r * smoothstep(0.0, 0.08, min(e.x, e.y));
}

// --- Footprints (the zone's footprint simulation, GroundSim.footprints) ----------------------
// b = pressed (a print), a = the rim pushed up round it; each holds a few seconds, then fades
// (r: its time left). Square from n64_print_rect. Soft ground (sand, snow, dirt, mud: soft_ground > 0) shows them.
uniform sampler2D print_map : filter_linear, repeat_disable, hint_default_black;
uniform vec2 print_dims = vec2(0.0, 128.0);
uniform float soft_ground = 0.0;

vec4 n64_prints_at(vec2 xz, vec3 cam) {
	if (print_dims.x <= 0.0) {
		return vec4(0.0);
	}
	if (n64_print_rect.z <= 0.0) {
		return vec4(0.0);
	}
	vec2 uv = (xz - n64_print_rect.xy) / n64_print_rect.z;
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
		return vec4(0.0);
	}
	vec2 e = min(uv, 1.0 - uv);
	return textureLod(print_map, uv, 0.0) * smoothstep(0.0, 0.08, min(e.x, e.y));
}

// Footprints shading `c` at `xz`: pressed darker, rims lighter, lit from `light` (xz) as a
// slope (two more reads). `up` = how much the face points up.
vec3 n64_footprints(vec3 c, vec2 xz, vec3 cam, vec2 light, float up) {
	if (soft_ground <= 0.0 || print_dims.x <= 0.0 || up <= 0.0) {
		return c;
	}
	vec4 f = n64_prints_at(xz, cam);
	if (f.b + f.a <= 0.002) {
		return c;
	}
	float d = 0.06;
	float gx = n64_prints_at(xz + vec2(d, 0.0), cam).b - f.b;
	float gz = n64_prints_at(xz + vec2(0.0, d), cam).b - f.b;
	float slope = dot(vec2(gx, gz), normalize(light + vec2(1e-4))) * 4.0;
	float k = soft_ground * up;
	c *= 1.0 - 0.5 * clamp(f.b, 0.0, 1.0) * k;
	c *= 1.0 + clamp(slope, -0.6, 0.6) * 1.2 * k;
	c *= 1.0 + 0.2 * clamp(f.a, 0.0, 1.0) * k;
	return c;
}
