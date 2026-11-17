// Affine shading (N64): vertex colours, baked light and fog interpolated in screen space,
// not perspective-corrected (textures still are, as on the N64). `varying N64_SHADE vec3 x;`
// - noperspective on our patched Godot (engine/patches/0003), plain varyings elsewhere.
#if defined(M3D3_NOPERSPECTIVE)
#define N64_SHADE noperspective
#else
#define N64_SHADE
#endif

// Display-space mixing (N64_GAMMA_MIX 1): the N64 filtered textures, shaded between vertices
// and blended fog on its display values (no linear light); Godot mixes in linear, which turns
// every in-between colour lighter and greyer (fog reads heavier, filtered texels paler). With
// it on, those mixes happen on display values (gamma 2.2) here.
#define N64_GAMMA_MIX 0
vec3 n64_enc(vec3 c) {
	return pow(max(c, vec3(0.0)), vec3(1.0 / 2.2));
}
vec3 n64_dec(vec3 c) {
	return pow(max(c, vec3(0.0)), vec3(2.2));
}
vec4 n64_enc4(vec4 c) {
	return vec4(n64_enc(c.rgb), c.a);
}
vec4 n64_dec4(vec4 c) {
	return vec4(n64_dec(c.rgb), c.a);
}

// Shared N64-style texture sampling. `n64_three_point` is a project-wide shader global
// (Project Settings > Shader Globals), toggled from the level tools' Paint panel.
// Textures are expected to carry Godot-generated mipmaps (N64Texture adds them); use
// filter_nearest_mipmap samplers.
global uniform bool n64_three_point;
// Mip choice shape (project setting): x = bias in levels (negative: sharper), y = how far
// from the RDP's rule (0: the largest texel step) towards the footprint's area (1) - a cheap
// anisotropy: a roof seen at a slant keeps the detail along it instead of dropping to the
// level its steep axis needs.
global uniform vec2 n64_lod_shape;
// World colour multiplier for baked vertex lighting (time of day). Set by DayNightSun.
global uniform vec4 n64_world_tint;
// Time-of-day lighting keys: x = slot a, y = slot b, z = weight of b (set by GameState).
global uniform vec4 n64_light_blend;
// Outdoor weather multiplier on baked lighting (DynamicSky; white indoors).
global uniform vec4 n64_weather_tint;
// 1 = apply baked vertex AO (vertex colour alpha); the editor's AO toggle sets 0.
global uniform float n64_vertex_ao;
// N64 fog (set by the Zone from FogSettings / weather): colour (alpha = soft-grid cell
// size, m), and x = start (m), y = end (m), z = curve (0 N64 depth / 1 linear) + 2 x
// sampling (0 per pixel / 1 per vertex / 2 soft grid), w = amount (0 off).
global uniform vec4 n64_fog_color;
global uniform vec4 n64_fog;
// Where fog distances are measured from (the player, or the camera): fog lies in a
// circle around it, so turning the camera doesn't change it.
global uniform vec3 n64_fog_origin;
// Ground-hugging fog: x = the fog's floor (world y), y = how high it reaches above it (m,
// 0 = off), z = how much it thins up there (0..1). Measured halfway along the line of
// sight, so looking up out of the fog thins it too.
global uniform vec4 n64_fog_height;
// Drifting fog banks: x = how much they thin the fog between them (0 = off), y = their size
// (m), zw = how fast they drift (m/s, world x / z).
global uniform vec4 n64_fog_drift;
// Key light for shine glints: xyz = world direction towards the light, w = strength (set by
// the Zone: the sun outdoors, else the nearest light).
global uniform vec4 n64_key_light;
// Lights in the fog (set by the Zone): up to 4 nearby lights, pos = xyz position + w
// range, col = linear colour x strength. n64_fog_lights: x = tint (colours fog near the
// light), y = halos (glow along the view ray passing near the light), z = tint sampling
// (0 per pixel / 1 follow the fog's sampling).
global uniform vec4 n64_fog_light_pos0;
global uniform vec4 n64_fog_light_pos1;
global uniform vec4 n64_fog_light_pos2;
global uniform vec4 n64_fog_light_pos3;
global uniform vec4 n64_fog_light_col0;
global uniform vec4 n64_fog_light_col1;
global uniform vec4 n64_fog_light_col2;
global uniform vec4 n64_fog_light_col3;
global uniform vec4 n64_fog_lights;

// Tint: fog close to a light takes its colour (depends on the point only).
vec3 n64_fog_light_tint(vec4 pos, vec4 col, vec3 world) {
	if (pos.w <= 0.0) {
		return vec3(0.0);
	}
	float near = 1.0 - clamp(distance(world, pos.xyz) / pos.w, 0.0, 1.0);
	return col.rgb * near * near;
}

vec3 n64_fog_tint_at(vec3 world) {
	return n64_fog_light_tint(n64_fog_light_pos0, n64_fog_light_col0, world)
		+ n64_fog_light_tint(n64_fog_light_pos1, n64_fog_light_col1, world)
		+ n64_fog_light_tint(n64_fog_light_pos2, n64_fog_light_col2, world)
		+ n64_fog_light_tint(n64_fog_light_pos3, n64_fog_light_col3, world);
}

// Halo: how close the line from the eye (`cam`) to `world` passes a light; sized around
// the light itself, not its whole range (room lights reach far).
vec3 n64_fog_light_halo(vec4 pos, vec4 col, vec3 world, vec3 cam) {
	if (pos.w <= 0.0) {
		return vec3(0.0);
	}
	vec3 seg = world - cam;
	float t = clamp(dot(pos.xyz - cam, seg) / max(dot(seg, seg), 1e-4), 0.0, 1.0);
	// (n64_fog_lights.w: halo size, > 1 in thick fog where light hangs in the air)
	float size = clamp(pos.w * 0.3, 0.5, 3.0) * max(n64_fog_lights.w, 1.0);
	float pass = 1.0 - clamp(distance(cam + seg * t, pos.xyz) / size, 0.0, 1.0);
	return col.rgb * pass * pass * pass;
}

// Per-vertex light tint for the fog (store in a varying, pass to n64_fog_out()).
vec3 n64_fog_tint_vertex(vec3 world) {
	return n64_fog_lights.x > 0.0 ? n64_fog_tint_at(world) : vec3(0.0);
}

// Animated textures' clock in seconds (wraps hourly), advanced by script: GameState in the
// game, the level plugin in the editor only while something animated shows and Anim is on.
// Not TIME: any material reading TIME makes the editor redraw every frame, forever.
global uniform float n64_time;
// Water reflection pass (N64Water): xyz = the reflection camera's position, w = water
// height. Far away when no reflection renders.
global uniform vec4 n64_reflect_cam;

// In the reflection camera's pass only, vertices below the water are lifted onto it, so
// what's under the surface (legs in the water, wall bottoms, a basin) collapses out of the
// mirror image. Vertex-only and branch-free in the main pass (no discard).
vec3 n64_reflect_flatten(vec3 vertex, mat4 model, vec3 camera) {
	if (distance(camera, n64_reflect_cam.xyz) > 0.01) {
		return vertex;
	}
	vec3 world = (model * vec4(vertex, 1.0)).xyz;
	float lift = n64_reflect_cam.w - world.y;
	if (lift <= 0.0) {
		return vertex;
	}
	return vertex + inverse(mat3(model)) * vec3(0.0, lift, 0.0);
}

// Fog at a view depth (metres). N64 depth curve: the console ramped fog linearly in depth
// buffer value (z / w ~ 1 - near / distance), which in metres is linear in 1/distance:
// fog thickens quickly just past the start and closes in slowly towards the end (a long
// tail). Linear: even ramp from start to end.
float n64_fog_amount(float depth) {
	float s = max(n64_fog.x, 0.01);
	float e = max(n64_fog.y, s + 0.01);
	float f;
	if (mod(n64_fog.z, 2.0) < 0.5) {
		f = (1.0 / s - 1.0 / max(depth, 0.001)) / (1.0 / s - 1.0 / e);
	} else {
		f = (depth - s) / (e - s);
	}
	return clamp(f, 0.0, 1.0);
}

// Smooth value noise in 0..1 (the drifting banks).
float n64_fog_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = p - i;
	f = f * f * (3.0 - 2.0 * f);
	vec4 h = fract(sin(vec4(dot(i, vec2(127.1, 311.7)), dot(i + vec2(1.0, 0.0), vec2(127.1, 311.7)),
		dot(i + vec2(0.0, 1.0), vec2(127.1, 311.7)), dot(i + vec2(1.0), vec2(127.1, 311.7)))) * 43758.5453);
	return mix(mix(h.x, h.y, f.x), mix(h.z, h.w, f.x), f.y);
}

// How much of the fog's amount reaches `world` (1 = all of it): thinner up out of a
// ground-hugging fog, and between drifting banks.
float n64_fog_density(vec3 world) {
	float k = 1.0;
	if (n64_fog_height.y > 0.0) {
		float h = (world.y + n64_fog_origin.y) * 0.5 - n64_fog_height.x;
		k *= 1.0 - n64_fog_height.z * smoothstep(0.0, n64_fog_height.y, h);
	}
	if (n64_fog_drift.x > 0.0) {
		vec2 p = (world.xz - n64_fog_drift.zw * n64_time) / max(n64_fog_drift.y, 0.5);
		float n = n64_fog_noise(p) * 0.65 + n64_fog_noise(p * 2.3 + 17.0) * 0.35;
		k *= 1.0 - n64_fog_drift.x * smoothstep(0.35, 0.75, n);
	}
	return k;
}

// Fog amount at a world point (distance from the fog origin, then its density there).
float n64_fog_at(vec3 world) {
	return n64_fog_amount(distance(world, n64_fog_origin)) * n64_fog_density(world);
}

// Fog inputs from vertex(), from the vertex's world position: x = fog at this vertex
// (per-vertex sampling, like the RSP: big triangles show its gradients), y = distance.
// Store in a varying; read with n64_fog_pixel() and write
// FOG = vec4(n64_fog_color.rgb, that).
vec2 n64_fog_vertex(vec3 world) {
	float d = distance(world, n64_fog_origin);
	return vec2(n64_fog_at(world), d);
}

// Soft grid: fog at the corners of a world-space lattice, blended trilinearly, i.e. per-
// vertex fog as if the level were evenly cut into `cell` metre pieces. Soft like the N64's
// vertex fog, but independent of the real triangle sizes.
float n64_fog_grid(vec3 world, float cell) {
	vec3 g = world / cell;
	vec3 i = floor(g);
	vec3 f = g - i;
	float acc = 0.0;
	for (int k = 0; k < 8; k++) {
		vec3 o = vec3(float(k & 1), float((k >> 1) & 1), float((k >> 2) & 1));
		vec3 w3 = mix(1.0 - f, f, o);
		acc += w3.x * w3.y * w3.z * n64_fog_at((i + o) * cell);
	}
	return acc;
}

// `view_pos`: VERTEX in fragment(), `inv_view`: INV_VIEW_MATRIX.
float n64_fog_pixel(vec2 v, vec3 view_pos, mat4 inv_view) {
	float sampling = floor(n64_fog.z / 2.0);
	float f;
	if (sampling > 1.5) {
		f = n64_fog_grid((inv_view * vec4(view_pos, 1.0)).xyz, max(n64_fog_color.a, 0.25));
	} else if (sampling > 0.5) {
		f = v.x;
	} else {
		f = n64_fog_at((inv_view * vec4(view_pos, 1.0)).xyz);
	}
	return f * n64_fog.w;
}

// FOG output for N64 shaders: fog colour plus nearby lights' tint (sampled like the fog,
// or per pixel) and halos (per pixel), which scale with the fog amount since FOG blends by
// it. `tint_v`: n64_fog_tint_vertex() from the vertex.
vec4 n64_fog_out(vec2 v, vec3 tint_v, vec3 view_pos, mat4 inv_view) {
	float a = n64_fog_pixel(v, view_pos, inv_view);
	vec3 c = n64_fog_color.rgb;
	if (a > 0.001 && n64_fog_lights.x + n64_fog_lights.y > 0.0) {
		vec3 world = (inv_view * vec4(view_pos, 1.0)).xyz;
		if (n64_fog_lights.x > 0.0) {
			float sampling = floor(n64_fog.z / 2.0);
			vec3 tint;
			if (n64_fog_lights.z < 0.5 || sampling < 0.5) {
				tint = n64_fog_tint_at(world);
			} else if (sampling < 1.5) {
				tint = tint_v;
			} else {
				// Soft grid: tint at the lattice corners, blended like the fog.
				float cell = max(n64_fog_color.a, 0.25);
				vec3 g = world / cell;
				vec3 i = floor(g);
				vec3 f = g - i;
				tint = vec3(0.0);
				for (int k = 0; k < 8; k++) {
					vec3 o = vec3(float(k & 1), float((k >> 1) & 1), float((k >> 2) & 1));
					vec3 w3 = mix(1.0 - f, f, o);
					tint += w3.x * w3.y * w3.z * n64_fog_tint_at((i + o) * cell);
				}
			}
			c += tint * n64_fog_lights.x;
		}
		if (n64_fog_lights.y > 0.0) {
			vec3 cam = inv_view[3].xyz;
			c += (n64_fog_light_halo(n64_fog_light_pos0, n64_fog_light_col0, world, cam)
				+ n64_fog_light_halo(n64_fog_light_pos1, n64_fog_light_col1, world, cam)
				+ n64_fog_light_halo(n64_fog_light_pos2, n64_fog_light_col2, world, cam)
				+ n64_fog_light_halo(n64_fog_light_pos3, n64_fog_light_col3, world, cam)) * n64_fog_lights.y;
		}
	}
	return vec4(c, a);
}

// Mip level as the RDP chose it (angrylion's tclod): the largest single texel step per
// pixel (max of |ds/dx|, |dt/dx|, |ds/dy|, |dt/dy| - not the diagonal length), the level its
// power of two, and the blend to the next level linear within that octave (lod / 2^level - 1),
// not logarithmic. Computed by hand so it also works on the Compatibility renderer.
float n64_lod_grad(sampler2D t, vec2 duv_dx, vec2 duv_dy) {
	vec2 size = vec2(textureSize(t, 0));
	vec2 dx = abs(duv_dx * size);
	vec2 dy = abs(duv_dy * size);
	float lx = max(dx.x, dx.y);
	float ly = max(dy.x, dy.y);
	float rho = max(lx, ly);
	if (n64_lod_shape.y > 0.0) {
		// Slant rule: towards the footprint's area (the geometric mean of its two true
		// lengths). It depends only on how much texture a pixel covers, not on how the
		// texture's axes line up with the screen's - per-axis steps made the level shift as
		// the camera tilted, and mid-distance textures seemed to turn.
		vec2 ex = duv_dx * size;
		vec2 ey = duv_dy * size;
		rho = mix(rho, sqrt(abs(ex.x * ey.y - ex.y * ey.x)), clamp(n64_lod_shape.y, 0.0, 1.0));
	}
	rho *= exp2(n64_lod_shape.x);
	float max_level = floor(log2(max(size.x, size.y)));
	if (rho <= 1.0) {
		return 0.0;
	}
	float level = floor(log2(rho));
	float frac = rho / exp2(level) - 1.0;
	return clamp(level + frac, 0.0, max_level);
}

float n64_lod(sampler2D t, vec2 uv) {
	return n64_lod_grad(t, dFdx(uv), dFdy(uv));
}

// N64 3-point bilinear at one mip level: blends the 3 nearest texels of the triangle the
// sample falls in.
vec4 n64_sample_level(sampler2D t, vec2 uv, int level) {
	vec2 size = max(vec2(textureSize(t, 0) >> ivec2(level)), vec2(1.0));
	float l = float(level);
	vec2 p = uv * size - 0.5;
	vec2 f = fract(p);
	vec2 i = floor(p);
	vec4 a = textureLod(t, (i + vec2(0.5)) / size, l);
	vec4 b = textureLod(t, (i + vec2(1.5, 0.5)) / size, l);
	vec4 c = textureLod(t, (i + vec2(0.5, 1.5)) / size, l);
	vec4 d = textureLod(t, (i + vec2(1.5)) / size, l);
#if N64_GAMMA_MIX
	a = n64_enc4(a); b = n64_enc4(b); c = n64_enc4(c); d = n64_enc4(d);
	vec4 r = f.x + f.y <= 1.0 ? a + f.x * (b - a) + f.y * (c - a) : d + (1.0 - f.x) * (c - d) + (1.0 - f.y) * (b - d);
	return n64_dec4(r);
#else
	if (f.x + f.y <= 1.0) {
		return a + f.x * (b - a) + f.y * (c - a);
	}
	return d + (1.0 - f.x) * (c - d) + (1.0 - f.y) * (b - d);
#endif
}

// 3-point with "brilinear" mip blending: pixels near a mip level read only that level (4
// reads); only a band around each level change blends two (8 reads). Smooth transitions
// at a fraction of full trilinear cost, and the two-level path is spatially coherent, so
// it doesn't make neighbouring GPU pixels diverge.
const float N64_MIP_BAND = 0.3;

vec4 n64_sample_at_lod(sampler2D t, vec2 uv, float lod) {
	int l0 = int(floor(lod));
	float blend = clamp((lod - float(l0) - 0.5) / N64_MIP_BAND + 0.5, 0.0, 1.0);
	if (blend <= 0.0) {
		return n64_sample_level(t, uv, l0);
	}
	if (blend >= 1.0) {
		return n64_sample_level(t, uv, l0 + 1);
	}
#if N64_GAMMA_MIX
	return n64_dec4(mix(n64_enc4(n64_sample_level(t, uv, l0)), n64_enc4(n64_sample_level(t, uv, l0 + 1)), blend));
#else
	return mix(n64_sample_level(t, uv, l0), n64_sample_level(t, uv, l0 + 1), blend);
#endif
}

vec4 n64_sample(sampler2D t, vec2 uv) {
	return n64_sample_at_lod(t, uv, n64_lod(t, uv));
}

vec4 n64_texture(sampler2D t, vec2 uv) {
	return n64_three_point ? n64_sample(t, uv) : texture(t, uv);
}

// --- Colour combiner tint ------------------------------------------------------------
// mode 0: as-is. 1: texel x light. 2: gradient lerp(dark, light, t) — the classic N64
// combiner ENV + (PRIM - ENV) * TEXEL — where t is the texel's luminance within
// extra.yz. extra.x (amount) mixes the result with the texture's own colours.
vec3 n64_tint(vec3 c, float mode, vec3 dark, vec3 light, vec3 extra) {
	if (mode < 0.5) {
		return c;
	}
	vec3 tinted;
	if (mode < 1.5) {
		tinted = c * light;
	} else {
		float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
		float t = clamp((l - extra.y) / max(extra.z - extra.y, 0.01), 0.0, 1.0);
		tinted = mix(dark, light, t);
	}
	return mix(c, tinted, extra.x);
}

// --- Anti-tiling: hex tiling (Mikkelsen 2022, after Heitz & Neyret 2018) ---------------
// The plane is split into hexagonal cells; each cell samples the texture with its own
// random offset (and rotation). A pixel blends the 3 nearest cells with sharpened weights,
// so most pixels take 1 sample and only cell borders take 2-3. Every sample takes the same
// brilinear path (per-sample special cases made neighbouring pixels diverge and cost
// more). LOD and gradients come from the unrotated UV, so mips stay continuous across
// cells.

vec2 n64_hash2(vec2 p) {
	vec2 r = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(r) * 43758.5453);
}

vec4 n64_hex_tap(sampler2D t, vec2 uv, vec2 cell, float w, float mode, float lod, vec2 dx, vec2 dy) {
	if (w <= 0.0) {
		return vec4(0.0);
	}
	vec2 h = n64_hash2(cell);
	// mode 1..2: rotate by up to +-(mode - 1) x 180 degrees (1 = offset only, 2 = any angle).
	float a = (h.x * 2.0 - 1.0) * clamp(mode - 1.0, 0.0, 1.0) * 3.14159265;
	mat2 r = mat2(vec2(cos(a), sin(a)), vec2(-sin(a), cos(a)));
	vec2 u = r * uv + h * 7.31;
	if (!n64_three_point) {
		return textureGrad(t, u, r * dx, r * dy) * w;
	}
	return n64_sample_at_lod(t, u, lod) * w;
}

// anti.x: 0 off, 1 random offset, 1..2 offset + rotation (amount = anti.x - 1),
// 3 row shuffle. anti.y: hex size in repeats.
vec4 n64_texture_tiled(sampler2D t, vec2 uv, vec2 anti) {
	if (anti.x < 0.5) {
		return n64_texture(t, uv);
	}
	vec2 dx = dFdx(uv);
	vec2 dy = dFdy(uv);
	float lod = n64_lod_grad(t, dx, dy);
	if (anti.x > 2.5) {
		// Row shuffle (bricks, planks): each row of repeats slides sideways by a random
		// amount, so repeats stop stacking into columns while courses stay whole (the
		// importer puts repeat edges on mortar lines). Mip level from the unshifted UVs.
		vec2 u = uv + vec2(n64_hash2(vec2(floor(uv.y), 17.0)).x, 0.0);
		if (!n64_three_point) {
			return textureGrad(t, u, dx, dy);
		}
		return n64_sample_at_lod(t, u, lod);
	}
	// Triangle grid in skewed space; its vertices are the hex cell centres.
	vec2 st = uv / max(anti.y, 0.05) * 3.4641016;
	vec2 skewed = vec2(st.x - 0.57735027 * st.y, 1.15470054 * st.y);
	vec2 base = floor(skewed);
	vec3 f = vec3(fract(skewed), 0.0);
	f.z = 1.0 - f.x - f.y;
	float s = step(0.0, -f.z);
	float s2 = 2.0 * s - 1.0;
	vec3 w = vec3(-f.z * s2, s - f.y * s2, s - f.x * s2);
	// Sharpen and drop negligible weights: fewer taps, less contrast loss.
	w = pow(max(w, vec3(0.0)), vec3(8.0));
	w /= max(w.x + w.y + w.z, 1e-6);
	w *= step(vec3(0.05), w);
	w /= max(w.x + w.y + w.z, 1e-6);
	return n64_hex_tap(t, uv, base + vec2(s, s), w.x, anti.x, lod, dx, dy)
		+ n64_hex_tap(t, uv, base + vec2(s, 1.0 - s), w.y, anti.x, lod, dx, dy)
		+ n64_hex_tap(t, uv, base + vec2(1.0 - s, s), w.z, anti.x, lod, dx, dy);
}

// --- Animated textures -----------------------------------------------------------------
// Scroll: `flow` = world direction (xyz) and speed (w, m/s). The direction is projected onto
// the surface (water on a wall runs down; on a floor the horizontal part of the direction
// moves it), then turned into the face's own UV directions through screen derivatives, so
// per-face UV offset / rotation / scale are respected. Returns the UV (metres) offset to add.
// `view_pos` = VERTEX (view space), `view_flow` = the flow direction in view space.
vec2 n64_scroll_uv(vec4 flow, vec3 view_flow, vec3 view_pos, vec2 uv, float time) {
	if (abs(flow.w) < 0.0001) {
		return vec2(0.0);
	}
	// Derivatives first, while every pixel of the quad is still here.
	vec3 px = dFdx(view_pos);
	vec3 py = dFdy(view_pos);
	vec2 ux = dFdx(uv);
	vec2 uy = dFdy(uv);
	vec3 n = normalize(cross(px, py));
	vec3 f = view_flow - n * dot(view_flow, n);
	if (length(f) < 0.1) {
		return vec2(0.0);  // straight into the surface: nothing to slide along
	}
	f = normalize(f);
	// f = a * px + b * py (least squares in the face's plane), then the same in UV.
	float xx = dot(px, px);
	float xy = dot(px, py);
	float yy = dot(py, py);
	float det = xx * yy - xy * xy;
	if (abs(det) < 1e-12) {
		return vec2(0.0);
	}
	float fx = dot(f, px);
	float fy = dot(f, py);
	float a = (fx * yy - fy * xy) / det;
	float b = (fy * xx - fx * xy) / det;
	vec2 duv = a * ux + b * uy;
	// Content moves along the flow: sample from behind it.
	return -duv * flow.w * time;
}

// Flipbook: `flip` = (columns, rows, frames, frames per second); `uv` in texture repeats of
// one frame. Frames are read inside their cell (kept a texel in from its edges so filtering
// never reads the next frame); mip levels stop where a cell would be under 4 texels.
vec4 n64_texture_frame(sampler2D t, vec2 uv, vec4 flip, float time) {
	vec2 grid = max(flip.xy, vec2(1.0));
	float frame = mod(floor(time * flip.w), max(flip.z, 1.0));
	vec2 cell = vec2(mod(frame, grid.x), floor(frame / grid.x));
	vec2 cell_px = vec2(textureSize(t, 0)) / grid;
	vec2 f = clamp(fract(uv), 0.5 / cell_px, 1.0 - 1.5 / cell_px);
	vec2 u = (f + cell) / grid;
	vec2 dx = dFdx(uv) / grid;
	vec2 dy = dFdy(uv) / grid;
	if (!n64_three_point) {
		return textureGrad(t, u, dx, dy);
	}
	float lod = min(n64_lod_grad(t, dx, dy), max(log2(min(cell_px.x, cell_px.y)) - 2.0, 0.0));
	return n64_sample_at_lod(t, u, lod);
}


// --- Subpixel snap (the RDP's 10.2 fixed-point screen coordinates) ---------------------
// Screen positions land on a quarter-pixel grid of the render size: faint shimmer on far,
// thin geometry at low line counts, invisible at high ones. End vertex() with
// N64_SNAP_MODEL (VERTEX in model space) or N64_SNAP_VIEW (skip_vertex_transform).
// Screen distortion (ScreenDistortion: OoT / MM's hot rooms, water, warps): a 2 x 2 on the
// picture, columns (x, y) and (z, w); identity (1, 0, 0, 1) when off.
global uniform vec4 n64_distort;
vec4 n64_snap(vec4 clip, vec2 viewport) {
	clip.xy = mat2(n64_distort.xy, n64_distort.zw) * clip.xy;
	if (clip.w <= 0.0) {
		return clip;
	}
	vec2 px = (clip.xy / clip.w * 0.5 + 0.5) * viewport;
	px = round(px * 4.0) / 4.0;
	clip.xy = ((px / viewport) * 2.0 - 1.0) * clip.w;
	return clip;
}
#define N64_SNAP_MODEL POSITION = n64_snap(PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)), VIEWPORT_SIZE)
#define N64_SNAP_VIEW POSITION = n64_snap(PROJECTION_MATRIX * vec4(VERTEX, 1.0), VIEWPORT_SIZE)

// --- Tile wrap modes (the RDP's per-axis clamp / mirror / wrap) --------------------------
// Each axis of a texture tile wraps (repeats), mirrors (every other repeat flipped: a
// symmetric texture stored at half size) or clamps (the edge texel stretches on), applied
// to texel coordinates as the RDP did, so filtering across a mirror seam reads the mirrored
// neighbour, not the far edge. mode per axis: 0 wrap, 1 mirror, 2 clamp.
ivec2 n64_wrap_texel(ivec2 i, ivec2 size, ivec2 mode) {
	ivec2 r;
	for (int k = 0; k < 2; k++) {
		int n = size[k];
		int v = i[k];
		if (mode[k] == 2) {
			v = clamp(v, 0, n - 1);
		} else if (mode[k] == 1) {
			int m = ((v % (2 * n)) + 2 * n) % (2 * n);
			v = m >= n ? 2 * n - 1 - m : m;
		} else {
			v = ((v % n) + n) % n;
		}
		r[k] = v;
	}
	return r;
}

vec4 n64_sample_level_wrap(sampler2D t, vec2 uv, int level, ivec2 mode) {
	ivec2 size = max(textureSize(t, level), ivec2(1));
	vec2 p = uv * vec2(size) - 0.5;
	vec2 f = fract(p);
	ivec2 i = ivec2(floor(p));
	vec4 a = texelFetch(t, n64_wrap_texel(i, size, mode), level);
	if (!n64_three_point) {
		return texelFetch(t, n64_wrap_texel(ivec2(floor(uv * vec2(size))), size, mode), level);
	}
	vec4 b = texelFetch(t, n64_wrap_texel(i + ivec2(1, 0), size, mode), level);
	vec4 c = texelFetch(t, n64_wrap_texel(i + ivec2(0, 1), size, mode), level);
	vec4 d = texelFetch(t, n64_wrap_texel(i + ivec2(1, 1), size, mode), level);
	if (f.x + f.y <= 1.0) {
		return a + f.x * (b - a) + f.y * (c - a);
	}
	return d + (1.0 - f.x) * (c - d) + (1.0 - f.y) * (b - d);
}

// n64_texture with per-axis wrap modes (all wrap = the usual read).
vec4 n64_texture_wrap(sampler2D t, vec2 uv, ivec2 mode) {
	if (mode == ivec2(0)) {
		return n64_texture(t, uv);
	}
	float lod = n64_lod(t, uv);
	int l0 = int(floor(lod));
	float blend = clamp((lod - float(l0) - 0.5) / N64_MIP_BAND + 0.5, 0.0, 1.0);
	if (blend <= 0.0) {
		return n64_sample_level_wrap(t, uv, l0, mode);
	}
	if (blend >= 1.0) {
		return n64_sample_level_wrap(t, uv, l0 + 1, mode);
	}
	return mix(n64_sample_level_wrap(t, uv, l0, mode), n64_sample_level_wrap(t, uv, l0 + 1, mode), blend);
}

// --- Decal depth (the RDP's ZMODE_DEC) -------------------------------------------------
// Decals sit exactly on their surface and pass the depth test where the surface is: the
// view-space position slides `amount` (a fraction of its distance) towards the camera
// along its own view ray, so it lands on the same pixels and only its depth moves. Holds
// at any distance, unlike lifting the geometry off the surface.
#define N64_SNAP_DECAL(amount) POSITION = n64_snap(PROJECTION_MATRIX * vec4((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz * (1.0 - (amount)), 1.0), VIEWPORT_SIZE)

// --- Dithered alpha (the RDP's alpha compare against dither / noise, G_AC_DITHER) --------
// A see-through surface drawn solid with pixels dropped: `alpha` against the magic square
// (ordered, 8 steps) or per-frame noise, as the RDP compared alpha with its dither / random
// value. Keeps depth and coverage, sorts with nothing, costs nothing (Boos, vanish fades,
// actors fading out at a distance or in a cutscene). Returns true when the pixel is kept.
bool n64_alpha_dither(float alpha, vec2 frag, bool noise, float time) {
	if (alpha >= 1.0) {
		return true;
	}
	float h;
	if (noise) {
		h = fract(sin(dot(floor(frag) + floor(time * 60.0) * vec2(0.37, 0.71), vec2(12.9898, 78.233))) * 43758.5453);
	} else {
		ivec2 p = ivec2(frag) & ivec2(3);
		const float m[16] = float[16](0.0, 6.0, 1.0, 7.0, 4.0, 2.0, 5.0, 3.0, 1.0, 7.0, 0.0, 6.0, 5.0, 3.0, 4.0, 2.0);
		h = (m[p.x + p.y * 4] + 0.5) / 8.0;
	}
	return alpha > h;
}

// --- Palette textures (CI4 / CI8 with a TLUT: N64PaletteTexture) -------------------------
// `index`: palette indices (R8, index / 255, mip levels re-indexed); `lut`: palettes, a row
// each (row = the swap this draw uses). Looked up per texel, then filtered, as the RDP did.
vec4 n64_ci_texel(sampler2D index, sampler2D lut, ivec2 i, ivec2 size, int level, int row, ivec2 mode) {
	float v = texelFetch(index, n64_wrap_texel(i, size, mode), level).r;
	return texelFetch(lut, ivec2(int(v * 255.0 + 0.5), row), 0);
}

vec4 n64_ci_level(sampler2D index, sampler2D lut, vec2 uv, int level, int row, ivec2 mode) {
	ivec2 size = max(textureSize(index, level), ivec2(1));
	vec2 p = uv * vec2(size) - 0.5;
	if (!n64_three_point) {
		return n64_ci_texel(index, lut, ivec2(floor(uv * vec2(size))), size, level, row, mode);
	}
	vec2 f = fract(p);
	ivec2 i = ivec2(floor(p));
	vec4 a = n64_ci_texel(index, lut, i, size, level, row, mode);
	vec4 b = n64_ci_texel(index, lut, i + ivec2(1, 0), size, level, row, mode);
	vec4 c = n64_ci_texel(index, lut, i + ivec2(0, 1), size, level, row, mode);
	vec4 d = n64_ci_texel(index, lut, i + ivec2(1, 1), size, level, row, mode);
	if (f.x + f.y <= 1.0) {
		return a + f.x * (b - a) + f.y * (c - a);
	}
	return d + (1.0 - f.x) * (c - d) + (1.0 - f.y) * (b - d);
}

vec4 n64_texture_ci(sampler2D index, sampler2D lut, vec2 uv, int row, ivec2 mode) {
	float lod = n64_lod(index, uv);
	int l0 = int(floor(lod));
	float blend = clamp((lod - float(l0) - 0.5) / N64_MIP_BAND + 0.5, 0.0, 1.0);
	if (blend <= 0.0) {
		return n64_ci_level(index, lut, uv, l0, row, mode);
	}
	if (blend >= 1.0) {
		return n64_ci_level(index, lut, uv, l0 + 1, row, mode);
	}
	return mix(n64_ci_level(index, lut, uv, l0, row, mode), n64_ci_level(index, lut, uv, l0 + 1, row, mode), blend);
}

// --- Primitive depth (the RDP's G_ZS_PRIM) ------------------------------------------------
// A sprite drawn at one depth: its centre's (`center`, world), moved `toward` metres
// towards the camera, so a billboard isn't cut where it passes through a wall or the
// ground: it's in front or behind as a whole, as OoT's effects were. Position snapped too.
vec4 n64_prim_depth(vec4 clip, vec3 center, float toward, mat4 view, mat4 proj, vec2 viewport) {
	vec3 vc = (view * vec4(center, 1.0)).xyz;
	vc *= max(1.0 - toward / max(length(vc), 1e-3), 0.05);
	vec4 pc = proj * vec4(vc, 1.0);
	clip = n64_snap(clip, viewport);
	if (pc.w > 0.0 && clip.w > 0.0) {
		clip.z = pc.z / pc.w * clip.w;
	}
	return clip;
}

// --- Detail / sharpen texture LOD (the RDP's magnified modes) -----------------------------
// Close up, where a texel covers more than a pixel, the RDP could do more than blur:
//  1 Sharpen: extrapolate away from the next mip level (base + (base - mip 1) x magnification),
//    so a magnified texture keeps its edges.
//  2 Detail: a finer texture blended in as you get closer (OoT's Hyrule Field ground), here
//    multiplied in around its own average so it adds grain, not colour.
//  3 Hi-res: `detail` is a higher-resolution copy of this same texture (same UVs): close up,
//    the base is multiplied by how the copy varies around its own blur at the base's
//    resolution - the base keeps its colour and grade, the copy adds its finer structure.
// `rho`: texel steps per pixel (below 1 = magnified).
float n64_texel_step(sampler2D t, vec2 uv) {
	vec2 size = vec2(textureSize(t, 0));
	vec2 dx = abs(dFdx(uv) * size);
	vec2 dy = abs(dFdy(uv) * size);
	return max(max(dx.x, dx.y), max(dy.x, dy.y));
}

vec4 n64_lod_detail(vec4 base, sampler2D t, vec2 uv, int mode, sampler2D detail, vec2 detail_uv, float strength) {
	if (mode == 0 || strength <= 0.0) {
		return base;
	}
	float k = clamp(1.0 - n64_texel_step(t, uv), 0.0, 1.0) * strength;
	if (k <= 0.0) {
		return base;
	}
	if (mode == 1) {
		vec4 c1 = n64_sample_level(t, uv, 1);
		return clamp(base + (base - c1) * k, 0.0, 1.0);
	}
	if (mode == 3) {
		vec2 hs = vec2(textureSize(detail, 0));
		int lb = clamp(int(round(log2(hs.x / max(float(textureSize(t, 0).x), 1.0)))), 0, 8);
		// (the copy one level down from its full size - twice the base's resolution for a 4x
		// copy: finer grain on the base's soft 3-point texels, not a bare high-res photo)
		vec3 fine = n64_sample_level(detail, detail_uv, max(lb - 1, 0) > 0 ? 1 : 0).rgb;
		vec3 coarse = max(n64_sample_level(detail, detail_uv, lb).rgb, vec3(0.03));
		vec3 ratio = clamp(fine / coarse, vec3(0.25), vec3(3.0));
		return vec4(base.rgb * mix(vec3(1.0), ratio, k), base.a);
	}
	vec3 d = n64_texture(detail, detail_uv).rgb;
	vec3 mean = max(textureLod(detail, vec2(0.5), 16.0).rgb, vec3(0.05));
	return vec4(base.rgb * mix(vec3(1.0), d / mean, k), base.a);
}

// --- 8-bit shade (the RSP's vertex colour) ----------------------------------------------
// Vertex light and colour as the RSP handed them to the RDP: 8 bits a channel in display
// values, so slow gradients across dark scenes step slightly, as N64 night scenes did.
// N64_SHADE_BITS 0 = off.
#define N64_SHADE_BITS 8
vec3 n64_shade8(vec3 c) {
#if N64_SHADE_BITS > 0
	float n = exp2(float(N64_SHADE_BITS)) - 1.0;
	vec3 s = pow(max(c, vec3(0.0)), vec3(1.0 / 2.2));
	s = floor(s * n + 0.5) / n;
	return pow(s, vec3(2.2));
#else
	return c;
#endif
}


// Fog blended on display values, as the RDP's blender did: FOG's amount re-worked so Godot's
// linear mix lands where the N64's display-space mix would (by luminance), for colour `c`
// (the surface's colour before fog: ALBEDO + EMISSION). Use: N64_FOG_GAMMA; at the end of
// fragment(), after FOG and the colours are set.
vec4 n64_fog_gamma(vec3 c, vec4 fog) {
#if N64_GAMMA_MIX
	if (fog.a <= 0.0 || fog.a >= 1.0) {
		return fog;
	}
	const vec3 L = vec3(0.2126, 0.7152, 0.0722);
	float lc = dot(c, L);
	float lf = dot(fog.rgb, L);
	if (abs(lf - lc) < 1e-3) {
		return fog;
	}
	float want = pow(mix(pow(max(lc, 0.0), 1.0 / 2.2), pow(max(lf, 0.0), 1.0 / 2.2), fog.a), 2.2);
	return vec4(fog.rgb, clamp((want - lc) / (lf - lc), 0.0, 1.0));
#else
	return fog;
#endif
}
#define N64_FOG_GAMMA FOG = n64_fog_gamma(ALBEDO + EMISSION, FOG)


// Smooth value noise 0..1 (dissolves, effects without a texture).
float n64_value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = fract(sin(dot(i, vec2(127.1, 311.7))) * 43758.5453);
	float b = fract(sin(dot(i + vec2(1.0, 0.0), vec2(127.1, 311.7))) * 43758.5453);
	float c = fract(sin(dot(i + vec2(0.0, 1.0), vec2(127.1, 311.7))) * 43758.5453);
	float d = fract(sin(dot(i + vec2(1.0, 1.0), vec2(127.1, 311.7))) * 43758.5453);
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
