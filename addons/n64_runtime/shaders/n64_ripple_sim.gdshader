shader_type canvas_item;
render_mode unshaded, blend_disabled;
// Water ripples on the ground round the camera (GroundSim): a wave on a 2D grid - r = the
// surface's height now, g = a frame ago. Each frame: the wave equation (a ring spreads out
// from every disturbance), damped so rings die out in about a second. Fed by the drips off
// eaves (`drips`: lines where roof drips land, impulses along them at random as it rains),
// actors walking (a wake at their feet, stronger the faster) and landing (a splash). The
// ground and water shaders read r as rings (where wet / on the water).

uniform sampler2D prev : filter_nearest, repeat_disable, hint_default_black;
uniform vec2 shift = vec2(0.0);
uniform float dt = 0.016;
uniform float size = 12.0;
// Wave speed (texels per frame, squared; < 0.5 stays stable) and damping per frame.
uniform float speed2 = 0.12;
uniform float damping = 0.965;
uniform float time = 0.0;
uniform float rain = 0.0;
// Roof drips: each line's ends (uv: x0, y0, x1, y1); how many lines.
uniform vec4 drips[16];
uniform int drip_count = 0;
// Drops per second per metre of drip line, at full rain.
uniform float drip_rate = 14.0;
uniform vec4 actors[8];
uniform vec4 actor_vel[8];
uniform int actor_count = 0;

vec2 at(vec2 uv) {
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
		return vec2(0.0);
	}
	return texture(prev, uv).rg;
}

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

void fragment() {
	vec2 uv = UV + shift;
	vec2 px = 1.0 / vec2(textureSize(prev, 0));
	vec2 h = at(uv);
	float lap = at(uv + vec2(px.x, 0.0)).r + at(uv - vec2(px.x, 0.0)).r + at(uv + vec2(0.0, px.y)).r + at(uv - vec2(0.0, px.y)).r - 4.0 * h.r;
	float next = (2.0 * h.r - h.g + speed2 * lap) * damping;
	// Drips: this texel near a drip line takes a drop now and then (a random time per texel).
	if (rain > 0.0) {
		float frame = floor(time * 60.0);
		vec2 m = UV * size;
		for (int i = 0; i < 16; i++) {
			if (i >= drip_count) {
				break;
			}
			vec2 a = drips[i].xy * size;
			vec2 b = drips[i].zw * size;
			vec2 ab = b - a;
			float t = clamp(dot(m - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
			if (distance(m, a + ab * t) < px.x * size * 0.75) {
				float chance = drip_rate * rain * dt * px.x * size;
				if (hash13(vec3(floor(UV / px), frame)) < chance) {
					next -= 0.6;
				}
			}
		}
	}
	// Actors: a wake at the feet (with the speed), a splash on landing.
	for (int i = 0; i < 8; i++) {
		if (i >= actor_count) {
			break;
		}
		vec4 ac = actors[i];
		float r = length((UV - ac.xy) * size);
		float speed = length(actor_vel[i].xy);
		float core = exp(-(r * r) / (ac.z * ac.z * 0.25));
		next -= core * clamp(speed / 4.0, 0.0, 1.0) * 0.015;
		next -= core * ac.w * (actor_vel[i].w > 1.5 ? 1.4 : 0.9);
	}
	COLOR = vec4(clamp(next, -2.0, 2.0), h.r, 0.0, 1.0);
}
