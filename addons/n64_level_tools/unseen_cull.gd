@tool
class_name UnseenCull
extends RefCounted
## The build's never-seen pass (as OoT / MM were modelled: nothing the camera can't reach):
## from eye points over the level's walkable ground, at the player's and the camera's
## heights, the opaque bake is drawn all round with each triangle in its own flat colour;
## triangles that never show in any of those images are dropped from the drawn meshes
## (the backs of roofs against the town wall, the wall's outer side, faces pressed into the
## ground). Back faces don't count (the level's shaders cull them), cutouts and overrides
## neither block nor go, far stand-ins are left alone, collision is untouched.
## Needs a renderer (skipped headless).

## Project setting: n64/build/unseen_cull (on / off; on by default).
const SETTING := "n64/build/unseen_cull"
## Eye spacing over the ground (metres) within NEAR_WALL of a wall (steep blocking
## triangles: where the views change), OPEN_STEP elsewhere (open ground looks the same from
## nearby eyes; an open hillside would otherwise take tens of thousands).
const EYE_STEP := 4.0
const OPEN_STEP := 16.0
const NEAR_WALL := 8.0
## Eyes rendered per frame drawn (each frame has a fixed cost on top of its views).
const EYES_PER_DRAW := 8
## Eye heights above the ground: the player's eyes, the camera behind and above, a high camera.
const EYE_HEIGHTS := [1.6, 5.0, 8.0]
## A wall top has no eyes (no one stands there): ground that drops away (more than DROP,
## PROBE out) on two sides or more. Alleys between houses keep theirs.
const PROBE := 0.6
const DROP := 1.0
## Image size of each of an eye's six views.
const RES := 128

## Each triangle's id rides in UV.x (exact as a float; 0 = blocks, never counted) and
## becomes 6 bits a channel; the views render to linear HDR targets, so the colour comes back
## exactly as written. Distance bands swap as in game: CUSTOM0 = the mesh cell's middle and
## the band's start, UV2.x its end (LevelRoot's visibility ranges).
const BuildCache := preload("res://addons/n64_level_tools/export/build_cache.gd")
const ID_SHADER := """
shader_type spatial;
render_mode unshaded, cull_back, fog_disabled, shadows_disabled;
varying flat float idv;
varying flat float shown;
void vertex() {
	idv = UV.x;
	float d = distance(CAMERA_POSITION_WORLD, CUSTOM0.xyz);
	shown = (UV2.x <= 0.0 || d < UV2.x) && (CUSTOM0.w <= 0.0 || d >= CUSTOM0.w) ? 1.0 : 0.0;
}
void fragment() {
	if (shown < 0.5) {
		discard;
	}
	int id = int(idv + 0.5);
	ALBEDO = vec3(float(id & 63), float((id >> 6) & 63), float((id >> 12) & 63)) / 63.0;
}
"""


static func enabled() -> bool:
	return bool(ProjectSettings.get_setting(SETTING, true)) and DisplayServer.get_name() != "headless"


## `entries`: [[surface arrays (edited in place), removable (bool), blocks (bool), visibility
## range (Vector2: begin, end; zero = always), its mesh cell's middle (Vector3)], ...];
## `ground`: walkable triangles (level space, 3 points each). Returns stats.
static func cull(entries: Array, ground: PackedVector3Array) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	if ground.is_empty():
		return {}
	# Every blocking triangle, in its own colour.
	var pos := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var custom := PackedFloat32Array()
	var owner := PackedInt32Array()  # id -> entry
	var index_at := PackedInt32Array()  # id -> first index of the triangle in the entry
	for ei in entries.size():
		var e: Array = entries[ei]
		if not e[2]:
			continue
		var v: PackedVector3Array = e[0][Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = e[0][Mesh.ARRAY_INDEX]
		var r: Vector2 = e[3]
		var mid: Vector3 = e[4]
		for t in range(0, idx.size(), 3):
			var id := Vector2(owner.size() + 1 if e[1] else 0, 0.0)
			for k in 3:
				pos.append(v[idx[t + k]])
				uv.append(id)
				uv2.append(Vector2(r.y, 0.0))
				custom.append_array([mid.x, mid.y, mid.z, r.x])
			if e[1]:
				owner.append(ei)
				index_at.append(t)
	if owner.is_empty():
		return {}
	# The same geometry culled before (Build & Play): its result from the cache.
	var key := BuildCache.key([pos, uv, uv2, custom, ground, EYE_STEP, OPEN_STEP, NEAR_WALL, EYE_HEIGHTS, RES, PROBE, DROP, ID_SHADER])
	var seen = BuildCache.read("unseen", key) if BuildCache.active else null
	var eye_count := -1
	if not seen is PackedByteArray or (seen as PackedByteArray).size() != owner.size() + 1:
		var r := _render_seen(pos, uv, uv2, custom, ground, owner.size())
		seen = r[0]
		eye_count = r[1]
		if BuildCache.active:
			BuildCache.write("unseen", key, seen)

	# Unseen triangles out of their surfaces.
	var drop := {}  # entry -> {first index: true}
	var removed := 0
	for id in owner.size():
		if seen[id + 1] == 0 and entries[owner[id]][1]:
			drop.get_or_add(owner[id], {})[index_at[id]] = true
			removed += 1
	for ei: int in drop:
		var a: Array = entries[ei][0]
		var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
		var out := PackedInt32Array()
		var gone: Dictionary = drop[ei]
		for t in range(0, idx.size(), 3):
			if not gone.has(t):
				out.append_array([idx[t], idx[t + 1], idx[t + 2]])
		a[Mesh.ARRAY_INDEX] = out
	var stats := {triangles = owner.size(), removed = removed, eyes = eye_count, cached = eye_count < 0, ms = Time.get_ticks_msec() - t0}
	print("[UnseenCull] %d of %d triangles never seen (%s, %d ms)" % [removed, owner.size(),
		"cached" if eye_count < 0 else "%d eyes" % eye_count, stats.ms])
	return stats


## Renders the eyes' views: [per id (1-based) 1 where it showed, how many eyes].
## The GPU's half of the job ("microcode" for it): reads every view where it was drawn and
## marks the ids it shows in a buffer, so nothing comes back to the CPU until the end (the
## images read back and decoded one by one took ~94% of the pass). Ids as in ID_SHADER.
const COLLECT_SHADER := """
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D view;
layout(set = 0, binding = 1, std430) restrict buffer Seen { uint seen[]; };
layout(push_constant, std430) uniform Params { uint count; uint size; uint pad0; uint pad1; } params;
void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= int(params.size) || p.y >= int(params.size)) {
		return;
	}
	vec4 c = texelFetch(view, p, 0);
	if (c.a < 0.5) {
		return;
	}
	uint id = uint(round(c.r * 63.0)) | (uint(round(c.g * 63.0)) << 6) | (uint(round(c.b * 63.0)) << 12);
	if (id > 0u && id < params.count) {
		seen[id] = 1u;
	}
}
"""


## The views' ids marked on the GPU (COLLECT_SHADER): {run: Callable(view count), read:
## Callable() -> PackedByteArray, free: Callable()}; {} without a RenderingDevice.
static func _gpu_collector(views: Array, count: int) -> Dictionary:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return {}
	var src := RDShaderSource.new()
	src.source_compute = COLLECT_SHADER
	var spirv := rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		push_warning("[UnseenCull] GPU collect unavailable (%s): reading the views back instead." % spirv.compile_error_compute)
		return {}
	var shader := rd.shader_create_from_spirv(spirv)
	var pipeline := rd.compute_pipeline_create(shader)
	var zeros := PackedByteArray()
	zeros.resize((count + 1) * 4)
	var buf := rd.storage_buffer_create(zeros.size(), zeros)
	var sampler := rd.sampler_create(RDSamplerState.new())
	var sets := []
	for vp in views:
		var tex := RenderingServer.texture_get_rd_texture(RenderingServer.viewport_get_texture(vp))
		var u_view := RDUniform.new()
		u_view.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u_view.binding = 0
		u_view.add_id(sampler)
		u_view.add_id(tex)
		var u_buf := RDUniform.new()
		u_buf.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u_buf.binding = 1
		u_buf.add_id(buf)
		sets.append(rd.uniform_set_create([u_view, u_buf], shader, 0))
	var push := PackedInt32Array([count + 1, RES, 0, 0]).to_byte_array()
	var groups := ceili(RES / 8.0)
	var run := func(n: int) -> void:
		var cl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, pipeline)
		rd.compute_list_set_push_constant(cl, push, push.size())
		for i in n:
			rd.compute_list_bind_uniform_set(cl, sets[i], 0)
			rd.compute_list_dispatch(cl, groups, groups, 1)
		rd.compute_list_end()
	var read := func() -> PackedByteArray:
		var words := rd.buffer_get_data(buf).to_int32_array()
		var out := PackedByteArray()
		out.resize(count + 1)
		for i in out.size():
			out[i] = 1 if words[i] != 0 else 0
		return out
	var free := func() -> void:
		for u in sets:
			if rd.uniform_set_is_valid(u):
				rd.free_rid(u)
		for r in [buf, sampler, pipeline, shader]:
			rd.free_rid(r)
	return {run = run, read = read, free = free}


static func _render_seen(pos: PackedVector3Array, uv: PackedVector2Array, uv2: PackedVector2Array, custom: PackedFloat32Array,
		ground: PackedVector3Array, count: int) -> Array:
	var tm := TriangleMesh.new()
	tm.create_from_faces(pos)
	var eyes := _eyes(ground, tm, pos)
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_CUSTOM0] = custom
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
		Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = ID_SHADER
	mesh.surface_set_material(0, mat)
	# Straight on the rendering server (no nodes: the bake may run while the tree is busy).
	var rs := RenderingServer
	var scenario := rs.scenario_create()
	var inst := rs.instance_create2(mesh.get_rid(), scenario)
	var views := []
	var cams := []
	for i in 6 * EYES_PER_DRAW:
		var vp := rs.viewport_create()
		rs.viewport_set_size(vp, RES, RES)
		rs.viewport_set_scenario(vp, scenario)
		rs.viewport_set_transparent_background(vp, true)
		rs.viewport_set_use_hdr_2d(vp, true)
		rs.viewport_set_msaa_3d(vp, RenderingServer.VIEWPORT_MSAA_DISABLED)
		rs.viewport_set_screen_space_aa(vp, RenderingServer.VIEWPORT_SCREEN_SPACE_AA_DISABLED)
		rs.viewport_set_use_debanding(vp, false)
		rs.viewport_set_positional_shadow_atlas_size(vp, 0)
		var cam := rs.camera_create()
		rs.camera_set_perspective(cam, 90.0, 0.05, 500.0)
		rs.viewport_attach_camera(vp, cam)
		rs.viewport_set_active(vp, true)
		views.append(vp)
		cams.append(cam)

	var seen := PackedByteArray()
	seen.resize(count + 1)
	var gpu := _gpu_collector(views, count)
	var faces := [[Vector3.FORWARD, Vector3.UP], [Vector3.BACK, Vector3.UP], [Vector3.LEFT, Vector3.UP],
		[Vector3.RIGHT, Vector3.UP], [Vector3.UP, Vector3.BACK], [Vector3.DOWN, Vector3.FORWARD]]
	for first in range(0, eyes.size(), EYES_PER_DRAW):
		var n := mini(EYES_PER_DRAW, eyes.size() - first)
		for e in n:
			for i in 6:
				rs.camera_set_transform(cams[e * 6 + i], Transform3D(Basis.looking_at(faces[i][0], faces[i][1]), eyes[first + e]))
				rs.viewport_set_update_mode(views[e * 6 + i], RenderingServer.VIEWPORT_UPDATE_ONCE)
		rs.force_draw(false)
		if gpu:
			RenderingServer.call_on_render_thread(gpu.run.bind(n * 6))
		else:
			for i in n * 6:
				_collect(rs.texture_2d_get(rs.viewport_get_texture(views[i])), seen)
	if gpu:
		var done := [PackedByteArray()]
		RenderingServer.call_on_render_thread(func(): done[0] = gpu.read.call(); gpu.free.call())
		RenderingServer.force_sync()
		seen = done[0]
	for r in views + cams + [inst, scenario]:
		rs.free_rid(r)
	return [seen, eyes.size()]


## Marks the ids an image shows.
static func _collect(img: Image, seen: PackedByteArray) -> void:
	# (Half floats to bytes: k / 63 becomes round(k * 255 / 63), which maps back exactly.)
	img.convert(Image.FORMAT_RGBA8)
	var px := img.get_data().to_int32_array()
	px.sort()
	var last := 0
	for v in px:
		if v == last:
			continue
		last = v
		if (v >> 24) & 0xFF < 128:
			continue  # clear
		var id := roundi((v & 0xFF) * 63.0 / 255.0) | roundi(((v >> 8) & 0xFF) * 63.0 / 255.0) << 6 \
			| roundi(((v >> 16) & 0xFF) * 63.0 / 255.0) << 12
		if id > 0 and id < seen.size():
			seen[id] = 1


## Eye points: a grid over the walkable ground (every level of it; fine near walls, coarse in
## the open), not on wall tops, at each height with headroom. `blocks`: the blocking triangles.
static func _eyes(ground: PackedVector3Array, tm: TriangleMesh, blocks: PackedVector3Array) -> PackedVector3Array:
	var gtm := TriangleMesh.new()
	gtm.create_from_faces(ground)
	var box := AABB(ground[0], Vector3.ZERO)
	for p in ground:
		box = box.expand(p)
	# Grid cells near a wall (its footprint, grown by NEAR_WALL).
	var near := {}
	var grow := ceili(NEAR_WALL / EYE_STEP)
	for t in range(0, blocks.size(), 3):
		var a := blocks[t]
		var b := blocks[t + 1]
		var c := blocks[t + 2]
		var n := (b - a).cross(c - a)
		if n.length_squared() < 1e-10 or absf(n.normalized().y) > 0.7:
			continue
		var lo := Vector2(minf(a.x, minf(b.x, c.x)), minf(a.z, minf(b.z, c.z)))
		var hi := Vector2(maxf(a.x, maxf(b.x, c.x)), maxf(a.z, maxf(b.z, c.z)))
		for cx in range(floori(lo.x / EYE_STEP) - grow, floori(hi.x / EYE_STEP) + grow + 1):
			for cz in range(floori(lo.y / EYE_STEP) - grow, floori(hi.y / EYE_STEP) + grow + 1):
				near[Vector2i(cx, cz)] = true
	var out := PackedVector3Array()
	var top := box.end.y + 5.0
	var bottom := box.position.y - 1.0
	var every := roundi(OPEN_STEP / EYE_STEP)
	var x := box.position.x + EYE_STEP * 0.5
	var ix := 0
	while x < box.end.x:
		var z := box.position.z + EYE_STEP * 0.5
		var iz := 0
		while z < box.end.z:
			var keep := (ix % every == 0 and iz % every == 0) or near.has(Vector2i(floori(x / EYE_STEP), floori(z / EYE_STEP)))
			var from := Vector3(x, top if keep else bottom, z)
			while from.y > bottom:
				var hit := gtm.intersect_segment(from, Vector3(x, bottom, z))
				if hit.is_empty():
					break
				var p: Vector3 = hit.position
				from = p + Vector3.DOWN * 0.05
				if not _standable(tm, p):
					continue
				for h: float in EYE_HEIGHTS:
					var eye := p + Vector3.UP * h
					if not tm.intersect_segment(p + Vector3.UP * 0.2, eye).is_empty():
						break  # a roof or a ceiling above
					out.append(eye)
			z += EYE_STEP
			iz += 1
		x += EYE_STEP
		ix += 1
	return out


## Whether `p` is somewhere to stand: the level doesn't drop away on two sides or more
## (a wall top, a beam).
static func _standable(tm: TriangleMesh, p: Vector3) -> bool:
	var drops := 0
	for d in [Vector3(PROBE, 0, 0), Vector3(-PROBE, 0, 0), Vector3(0, 0, PROBE), Vector3(0, 0, -PROBE)]:
		var hit := tm.intersect_segment(p + d + Vector3.UP * 0.5, p + d + Vector3.DOWN * DROP)
		if hit.is_empty():
			drops += 1
	return drops <= 1
