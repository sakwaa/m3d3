// The grass's baked light (GrassBuilder): the level's own lighting keys, sampled from the
// ground under each carpet vertex / tuft root at build time, so the grass darkens at night,
// sits in the same shadows and lamp pools, and matches the street round it. Keys blend with
// the time of day like the level's (n64_light_blend); through the same contrast curve and
// floor. Without keys (light_keys 0) the world tint, as before.
// Needs n64_sampling.gdshaderinc first (n64_light_blend, n64_world_tint, n64_shade8).

uniform int light_keys = 0;
uniform bool timed_bake = false;
uniform float light_contrast = 1.0;
uniform float light_floor = 0.0;

// The light now from up to four keys.
vec3 n64_grass_key_light(vec3 k0, vec3 k1, vec3 k2, vec3 k3) {
	if (light_keys <= 0) {
		return vec3(1.0);
	}
	vec3 k[4] = vec3[](k0, k1, k2, k3);
	int a = clamp(int(n64_light_blend.x + 0.5), 0, light_keys - 1);
	int b = clamp(int(n64_light_blend.y + 0.5), 0, light_keys - 1);
	return n64_shade8(mix(k[a], k[b], clamp(n64_light_blend.z, 0.0, 1.0)));
}

// A key packed in a float (r * 65536 + g * 256 + b, bytes): tufts' instance data.
vec3 n64_grass_unpack(float v) {
	// (bytes taken out as integers: floor(v + 0.5) rounds up past 2^23 and float division can
	// land on 256, so bright keys - white 0xFFFFFF - came out red)
	int x = int(round(v));
	return vec3(float(x >> 16), float((x >> 8) & 255), float(x & 255)) / 255.0;
}

// The light on screen: the level's contrast curve and floor (on the light alone: the grass's
// colours are tuned as they are), world tint when the keys don't carry the time of day.
vec3 n64_grass_light(vec3 key) {
	if (light_keys <= 0) {
		return n64_world_tint.rgb;
	}
	vec3 light = key * (timed_bake ? vec3(1.0) : n64_world_tint.rgb);
	vec3 s = mix(light, pow(light, vec3(2.2)), light_contrast);
	if (light_floor > 0.0) {
		float f = mix(light_floor, pow(light_floor, 2.2), light_contrast);
		vec3 hue = light / max(max(light.r, max(light.g, light.b)), 1e-4);
		vec3 fl = f * hue;
		vec3 kk = fl * 0.5;
		s = 0.5 * (s + fl + sqrt((s - fl) * (s - fl) + kk * kk));
	}
	return s;
}
