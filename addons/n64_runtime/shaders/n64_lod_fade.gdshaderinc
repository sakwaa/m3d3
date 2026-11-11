// LOD cross-fade: a near / far pair dissolves into each other with one ordered dither, so
// every pixel shows exactly one of them (no see-through gaps mid-fade, no z-fighting where
// they overlap). Set per instance (LevelRoot.apply_lod_range, PropBatch):
//   n64_lod_fade.xyz = the point distance is measured to (the pair's shared bounds' centre, in
//   the mesh's own space),
//   n64_lod_fade.w = swap distance, positive on the near version (drawn inside it), negative
//   on the far one (drawn beyond it); 0 = no fade,
//   n64_lod_fade_band = metres the dissolve takes, centred on the swap distance.
// A version with no partner (a prop with no far stand-in) simply dissolves away.
// Call n64_lod_dither(CAMERA_POSITION_WORLD, MODEL_MATRIX, FRAGCOORD.xy) first thing in fragment().

instance uniform vec4 n64_lod_fade = vec4(0.0);
instance uniform float n64_lod_fade_band = 0.0;

// 4x4 Bayer threshold in (0, 1).
float n64_bayer4(vec2 frag) {
	ivec2 p = ivec2(frag) & ivec2(3);
	int i = p.x + p.y * 4;
	const float m[16] = float[16](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
	return (m[i] + 0.5) / 16.0;
}

void n64_lod_dither(vec3 camera, mat4 model, vec2 frag) {
	if (n64_lod_fade.w == 0.0 || n64_lod_fade_band <= 0.0) {
		return;
	}
	// 0 = fully the near version, 1 = fully the far one.
	float t = clamp((distance(camera, (model * vec4(n64_lod_fade.xyz, 1.0)).xyz) - abs(n64_lod_fade.w)) / n64_lod_fade_band + 0.5, 0.0, 1.0);
	float h = n64_bayer4(frag);
	if (n64_lod_fade.w > 0.0 ? h < t : h >= t) {
		discard;
	}
}
