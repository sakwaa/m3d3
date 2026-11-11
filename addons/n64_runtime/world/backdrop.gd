class_name Backdrop
extends RefCounted
## What's past a zone's walls, from the zones next door (baked by the level tools,
## NeighbourBackdrop): a low, flat-coloured copy of what's near enough to see over the
## walls, and a painted ring of what's further off. These build the nodes that draw them
## (LevelRoot in the editor and game, and the export).

const SHADER := preload("res://addons/n64_runtime/shaders/n64_backdrop.gdshader")
const RING_SHADER := preload("res://addons/n64_runtime/shaders/n64_backdrop_ring.gdshader")
## Ring cards' distance from the camera (any: it's drawn behind everything).
const RING_RADIUS := 40.0


## The nodes for a baked backdrop: `mesh` (the near zones, level space; may be null),
## `ring` (the painted strip, may be null) and `info` (segments, vertical fov°, pitch°,
## each segment's width / height).
static func build_nodes(mesh: Mesh, ring: Texture2D, info: Vector4) -> Array[Node3D]:
	var out: Array[Node3D] = []
	if mesh:
		var mi := MeshInstance3D.new()
		mi.name = "Backdrop"
		mi.mesh = mesh
		var m := ShaderMaterial.new()
		m.shader = SHADER
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Drawn past the camera's far plane too (its shader keeps it in the depth range).
		mi.extra_cull_margin = 2000.0
		out.append(mi)
	if ring and info.x >= 1.0:
		var ri := MeshInstance3D.new()
		ri.name = "BackdropRing"
		ri.mesh = ring_mesh(int(info.x), info.y, info.z, info.w)
		var rm := ShaderMaterial.new()
		rm.shader = RING_SHADER
		rm.set_shader_parameter(&"ring", ring)
		ri.material_override = rm
		ri.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		ri.extra_cull_margin = 16384.0  # wherever the camera is
		out.append(ri)
	return out


## The ring: one flat card per segment, exactly where the camera that painted it saw it
## (so it lines up from the middle of the zone), side by side in the strip's UVs.
static func ring_mesh(segments: int, fov: float, pitch: float, aspect: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tv := tan(deg_to_rad(fov) * 0.5)
	var th := tv * aspect
	for i in segments:
		var basis := segment_basis(i, segments, pitch)
		var corners := []
		for c in [Vector2(-1, 1), Vector2(1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			var p := basis * Vector3(c.x * th, c.y * tv, -1.0) * RING_RADIUS
			var uv := Vector2((i + (c.x + 1.0) * 0.5) / segments, (1.0 - c.y) * 0.5)
			corners.append([p, uv])
		for k in [0, 1, 2, 0, 2, 3]:
			st.set_uv(corners[k][1])
			st.add_vertex(corners[k][0])
	var mesh := st.commit()
	mesh.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))
	return mesh


## Which way segment `i` of `segments` looks (turned about the vertical, tipped up `pitch`°).
static func segment_basis(i: int, segments: int, pitch: float) -> Basis:
	return Basis(Vector3.UP, -TAU * i / segments) * Basis(Vector3.RIGHT, deg_to_rad(pitch))
