// How rain catches light (rain streaks, splashes, roof drips). Include after
// n64_sampling.gdshaderinc and n64_weather.gdshaderinc.
// Water is clear: a drop shows little of its own, mostly the light it bends towards the eye.
// So rain is dim against the world (ambient, from the sky's tint), lit only where a lamp's
// light reaches it (the level's rain light grid: baked with shadows, so rain under a roof
// or behind a wall from the lamp stays dark) and most when that lamp is behind the drop as
// seen from the eye (forward scatter), with a faint glint the same way from the key light
// (the sun, mostly hidden while it rains). Sheltered water (under eaves) gets no sky light.
// Cheap: meant per vertex; four texture reads and the four fog light slots.

// The rain light grid (RainCover; LevelLighting.bake_rain_light): XZ layers stacked by
// height in one texture (light / 2).
global uniform sampler2D n64_rain_light : filter_linear;
// xyz = world position of the first point, w = metres between points (0 = no grid).
global uniform vec4 n64_rain_light_area;
// x = points along X, y = height layers, z = points along Z.
global uniform vec4 n64_rain_light_dims;
// Lamp strength per lighting key (n64_light_blend slots; 1 when not timed).
global uniform vec4 n64_rain_light_keys;

float n64_rain_key(float slot) {
	return slot < 0.5 ? n64_rain_light_keys.x : slot < 1.5 ? n64_rain_light_keys.y
		: slot < 2.5 ? n64_rain_light_keys.z : n64_rain_light_keys.w;
}

// Lamp light at world `p` from the grid (0 outside it).
vec3 n64_rain_grid(vec3 p) {
	vec3 dims = n64_rain_light_dims.xyz;
	vec3 g = (p - n64_rain_light_area.xyz) / n64_rain_light_area.w;
	if (any(lessThan(g, vec3(-0.5))) || any(greaterThan(g, dims - 0.5))) {
		return vec3(0.0);
	}
	float y = clamp(g.y, 0.0, dims.y - 1.0);
	float j0 = floor(y);
	float j1 = min(j0 + 1.0, dims.y - 1.0);
	float u = (clamp(g.x, 0.0, dims.x - 1.0) + 0.5) / dims.x;
	float z = clamp(g.z, 0.0, dims.z - 1.0) + 0.5;
	float rows = dims.y * dims.z;
	vec3 a = textureLod(n64_rain_light, vec2(u, (j0 * dims.z + z) / rows), 0.0).rgb;
	vec3 b = textureLod(n64_rain_light, vec2(u, (j1 * dims.z + z) / rows), 0.0).rgb;
	float k = mix(n64_rain_key(n64_light_blend.x), n64_rain_key(n64_light_blend.y), n64_light_blend.z);
	return mix(a, b, y - j0) * 2.0 * k;
}

// One nearby light (fog light slot) at `p` seen along `view` (eye to drop): x = how near
// (unshadowed), y = how much it's behind the drop (forward scatter).
vec2 n64_rain_lamp(vec4 pos, vec4 col, vec3 p, vec3 view) {
	if (pos.w <= 0.0) {
		return vec2(0.0);
	}
	vec3 to = pos.xyz - p;
	float d = length(to);
	float near = 1.0 - clamp(d / pos.w, 0.0, 1.0);
	near *= near * dot(col.rgb, vec3(0.3, 0.59, 0.11));
	float fwd = max(dot(view, to / max(d, 1e-3)), 0.0);
	return vec2(near, near * fwd * fwd * fwd);
}

// Colour of rain at world `p` seen from `cam`; `seed` (0..1) varies drop to drop, `shelter`
// (0..1) for water out of the sky's light. w = how visible: lit drops show, dim ones fade.
vec4 n64_rain_lit(vec3 p, vec3 cam, float seed, float shelter) {
	vec3 view = normalize(p - cam);
	vec3 sky = n64_world_tint.rgb * n64_weather_tint.rgb;
	vec3 c = sky * vec3(0.5, 0.54, 0.6) * mix(0.65, 1.0, seed) * mix(1.0, 0.45, shelter);
	if (n64_key_light.w > 0.0) {
		float f = max(dot(view, n64_key_light.xyz), 0.0);
		f *= f;
		f *= f;
		c += sky * n64_key_light.w * f * f * 0.5 * (1.0 - 0.7 * n64_rain.x) * (1.0 - shelter) * seed;
	}
	// Which way the lamps around are (for the scatter), from the fog light slots.
	vec2 s = n64_rain_lamp(n64_fog_light_pos0, n64_fog_light_col0, p, view)
		+ n64_rain_lamp(n64_fog_light_pos1, n64_fog_light_col1, p, view)
		+ n64_rain_lamp(n64_fog_light_pos2, n64_fog_light_col2, p, view)
		+ n64_rain_lamp(n64_fog_light_pos3, n64_fog_light_col3, p, view);
	float scatter = s.x > 1e-4 ? s.y / s.x : 0.2;
	// How much lamp light: the grid's (shadowed); without one, the slots' (unshadowed).
	vec3 lamp;
	if (n64_rain_light_area.w > 0.0) {
		lamp = n64_rain_grid(p);
	} else {
		lamp = vec3(0.0);
		for (int i = 0; i < 4; i++) {
			vec4 lp = i == 0 ? n64_fog_light_pos0 : i == 1 ? n64_fog_light_pos1 : i == 2 ? n64_fog_light_pos2 : n64_fog_light_pos3;
			vec4 lc = i == 0 ? n64_fog_light_col0 : i == 1 ? n64_fog_light_col1 : i == 2 ? n64_fog_light_col2 : n64_fog_light_col3;
			if (lp.w > 0.0) {
				float near = 1.0 - clamp(distance(lp.xyz, p) / lp.w, 0.0, 1.0);
				lamp += lc.rgb * near * near;
			}
		}
	}
	c += lamp * (0.15 + 0.85 * scatter) * mix(0.5, 1.0, seed);
	float lum = dot(c, vec3(0.299, 0.587, 0.114));
	return vec4(min(c, vec3(1.0)), clamp(0.35 + lum * 1.2, 0.35, 1.0));
}
