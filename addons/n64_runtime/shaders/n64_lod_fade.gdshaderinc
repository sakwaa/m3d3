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

// The RDP's alpha dither threshold in (0, 1): its 4x4 magic square (values 0..7, so a fade
// steps through 8 patterns, as the N64's did). (Name kept: it was a Bayer matrix.)
float n64_bayer4(vec2 frag) {
	ivec2 p = ivec2(frag) & ivec2(3);
	int i = p.x + p.y * 4;
	const float m[16] = float[16](0.0, 6.0, 1.0, 7.0, 4.0, 2.0, 5.0, 3.0, 1.0, 7.0, 0.0, 6.0, 5.0, 3.0, 4.0, 2.0);
	return (m[i] + 0.5) / 8.0;
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


// Camera see-through (CameraDirector sets it every frame): level and prop pixels right in
// front of the lens (closer than ~0.8 m: an awning, a banner, a house corner the camera has
// swung into), or inside a thin capsule from the camera to the player's chest (anything
// between them), are dithered out with the 4 x 4 Bayer pattern, as faded actors are.
// n64_see_through: player chest (xyz), capsule radius (w; 0 = off).
global uniform vec4 n64_see_through;

void n64_see_through_dither(vec3 world, vec3 camera, vec2 frag) {
	if (n64_see_through.w <= 0.0) {
		return;
	}
	float keep = smoothstep(0.3, 0.8, distance(world, camera));
	vec3 seg = n64_see_through.xyz - camera;
	float len = length(seg);
	vec3 dir = seg / max(len, 1e-3);
	float t = dot(world - camera, dir);
	if (t > 0.0 && t < len - 0.5) {
		float r = length(world - camera - dir * t);
		keep = min(keep, smoothstep(n64_see_through.w * 0.55, n64_see_through.w, r));
	}
	if (keep < 1.0 && n64_bayer4(frag) >= keep) {
		discard;
	}
}

