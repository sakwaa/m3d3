// Shared N64-style texture sampling. `n64_three_point` is a project-wide shader global
// (Project Settings > Shader Globals), toggled from the level tools' Paint panel.
// Textures are expected to carry Godot-generated mipmaps (N64Texture adds them); use
// filter_nearest_mipmap samplers.
global uniform bool n64_three_point;
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
	float pass = 1.0 - clamp(distance(cam + seg * t, pos.xyz) / clamp(pos.w * 0.3, 0.5, 3.0), 0.0, 1.0);
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

// Fog inputs from vertex(), from the vertex's world position: x = fog at this vertex
// (per-vertex sampling, like the RSP: big triangles show its gradients), y = distance.
// Store in a varying; read with n64_fog_pixel() and write
// FOG = vec4(n64_fog_color.rgb, that).
vec2 n64_fog_vertex(vec3 world) {
	float d = distance(world, n64_fog_origin);
	return vec2(n64_fog_amount(d), d);
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
		acc += w3.x * w3.y * w3.z * n64_fog_amount(distance((i + o) * cell, n64_fog_origin));
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
		f = n64_fog_amount(distance((inv_view * vec4(view_pos, 1.0)).xyz, n64_fog_origin));
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

// Mip level from screen-space derivatives (texels per pixel). Computed by hand rather than
// textureQueryLod so it also works on the Compatibility renderer.
float n64_lod_grad(sampler2D t, vec2 duv_dx, vec2 duv_dy) {
	vec2 size = vec2(textureSize(t, 0));
	vec2 dx = duv_dx * size;
	vec2 dy = duv_dy * size;
	float rho = max(dot(dx, dx), dot(dy, dy));
	float max_level = floor(log2(max(size.x, size.y)));
	return clamp(0.5 * log2(max(rho, 1e-8)), 0.0, max_level);
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
	if (f.x + f.y <= 1.0) {
		return a + f.x * (b - a) + f.y * (c - a);
	}
	return d + (1.0 - f.x) * (c - d) + (1.0 - f.y) * (b - d);
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
	return mix(n64_sample_level(t, uv, l0), n64_sample_level(t, uv, l0 + 1), blend);
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
