shader_type canvas_item;
render_mode unshaded, blend_disabled;
// GroundMist's disturbance field: a small ping-pong simulation over a square of ground round
// the camera (`size` metres, the texture's x = world x, y = world z). Each texel holds
//   rg: how far the mist is pushed (metres, world xz) - the mist shader reads its columns
//       from that far back, so the billows are dragged and streaked;
//   b:  thinning (the core an actor wades through);
//   a:  pile-up (mist heaped up beside the wake: it stands higher and catches the light).
// Every frame the field carries itself a little along its own push (a landing's outward burst
// travels out as a ring), blurs (spreads) and fades back to nothing (standing still, the mist
// fills back in). Actors add a tight push along their motion and out to their sides as they
// move, nothing while still; a landing adds one strong outward burst.

uniform sampler2D prev : filter_linear, repeat_disable, hint_default_black;
// The previous frame's field, offset to where this frame's square lies (uv units).
uniform vec2 shift = vec2(0.0);
uniform float dt = 0.016;
uniform float size = 16.0;
// Seconds for a disturbance to fade to a third (the mist 1.4, grass springing back ~3.5); how
// far the field carries itself per metre of push per second; how much it blurs per frame.
uniform float fill_time = 1.4;
// How hard a still-standing actor presses (grass: a soft dent under the feet; mist: none).
uniform float stand_press = 0.0;
uniform float carry = 1.6;
// Footprints (hold_time > 0): no fill-in; each print's r counts its life down over hold_time
// seconds, then it fades out (b and a) over fade_time.
uniform float hold_time = 0.0;
// Springing back at a steady rate as well (per second: 2 = a full press is back in half a
// second): brush snaps back rather than easing like jelly. 0: only fill_time's easing.
uniform float return_rate = 0.0;
// How much of a moving actor's press lands at once (0: built up over a few frames).
uniform float snap_press = 0.0;
// Grass (press_hold > 0): a stays pressed this many seconds after the actor leaves (a holds
// the time left, 1 -> 0: no pile-up in this mode), then springs back (fill_time, return_rate).
uniform float press_hold = 0.0;
uniform float fade_time = 3.0;
uniform float spread = 0.18;
// Per actor: xy = position (uv), z = radius (metres), w = landing burst this frame (0..1+);
// actor_vel: xy = velocity (metres / second, world xz).
uniform vec4 actors[8];
uniform vec4 actor_vel[8];
uniform int actor_count = 0;

vec4 at(vec2 uv) {
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
		return vec4(0.0);
	}
	return texture(prev, uv);
}

void fragment() {
	vec2 uv = UV + shift;
	vec2 px = 1.0 / vec2(textureSize(prev, 0));
	vec4 here = at(uv);
	// Carried along its own push (an outward burst moves out: a ring), then spread a little.
	vec4 s = at(uv - here.rg * carry * dt / size);
	vec4 n = (at(uv + vec2(px.x, 0.0)) + at(uv - vec2(px.x, 0.0)) + at(uv + vec2(0.0, px.y)) + at(uv - vec2(0.0, px.y))) * 0.25;
	s = mix(s, n, spread);
	if (hold_time > 0.0) {
		s = here;
		s.r = max(s.r - dt / hold_time, 0.0);
		if (s.r <= 0.0) {
			s.ba = max(s.ba - dt / max(fade_time, 0.05), vec2(0.0));
		}
	} else if (press_hold > 0.0) {
		float life = s.a;
		s.a = max(life - dt / press_hold, 0.0);
		if (life <= 0.0) {
			s.rgb *= exp(-dt / max(fill_time, 0.05));
			float k = dt * return_rate;
			s.b = max(s.b - k, 0.0);
			float l = length(s.rg);
			s.rg *= l > 1e-5 ? max(l - k, 0.0) / l : 0.0;
		}
	} else {
		s *= exp(-dt / max(fill_time, 0.05));
		if (return_rate > 0.0) {
			float k = dt * return_rate;
			s.ba = max(s.ba - k, vec2(0.0));
			float l = length(s.rg);
			s.rg *= l > 1e-5 ? max(l - k, 0.0) / l : 0.0;
		}
	}
	for (int i = 0; i < 8; i++) {
		if (i >= actor_count) {
			break;
		}
		vec4 a = actors[i];
		vec2 d = (UV - a.xy) * size;  // metres from the actor
		float r = length(d);
		float R = max(a.z, 0.05);
		vec2 outw = r > 1e-3 ? d / r : vec2(0.0);
		// A footprint (GroundSim.footprints): pressed in where the foot lands, nothing pushed.
		if (actor_vel[i].w > 0.5 && actor_vel[i].w < 1.5) {
			float foot = exp(-(r * r) / (R * R * 0.5));
			s.b = max(s.b, foot);
			s.a = max(s.a, exp(-pow((r - R * 1.1) / (R * 0.35), 2.0)) * 0.6);
			if (r < R * 1.6) {
				s.r = 1.0;  // (a fresh print: its life starts again)
			}
			continue;
		}
		vec2 v = actor_vel[i].xy;
		float speed = length(v);
		float moving = clamp(speed / 3.0, 0.0, 1.0);
		float core = exp(-(r * r) / (R * R));
		float rim = exp(-pow((r - R * 1.15) / (R * 0.4), 2.0));
		// Walking: dragged along a little, pushed out to the sides; thinned in the core,
		// heaped at the rim. Tight (R), and only while moving.
		vec2 vdir = speed > 1e-3 ? v / speed : vec2(0.0);
		vec2 side = outw - vdir * dot(outw, vdir);
		s.rg += (v * 0.16 + side * speed * 0.34) * core * dt * 6.0;
		s.b += core * moving * dt * 5.0;
		s.b = max(s.b, core * stand_press);
		s.b = max(s.b, core * moving * snap_press);
		if (press_hold > 0.0) {
			if (core * max(moving, stand_press) > 0.15) {
				s.a = 1.0;  // (pressed now: the hold starts again)
			}
		} else {
			s.a += rim * moving * dt * 3.5;
		}
		// Landing: one outward burst over a wider ring, cleared in the middle.
		float burst = a.w;
		if (burst > 0.0) {
			float wide = exp(-(r * r) / (R * R * 4.0));
			s.rg += outw * wide * burst * 1.2;
			s.b += wide * burst * 0.9;
			if (press_hold > 0.0) {
				s.a = max(s.a, step(0.15, wide * burst));
			} else {
				s.a += exp(-pow((r - R * 2.0) / (R * 0.6), 2.0)) * burst * 0.8;
			}
		}
	}
	float l = length(s.rg);
	if (l > 1.5) {
		s.rg *= 1.5 / l;
	}
	s.b = clamp(s.b, 0.0, 1.0);
	s.a = clamp(s.a, 0.0, 1.0);
	COLOR = s;
}
