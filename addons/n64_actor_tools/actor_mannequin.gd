@tool
class_name ActorMannequin
extends RefCounted
## Builds a character's skinned mesh from its pieces (or, before modelling starts, from
## the body plan's starter shapes): flat shaded, each piece rigid on its bone. Stitched
## joints (the default) weight a piece's base (a tube's first ring, or a free mesh's
## lowest vertices near the joint) half to the parent bone, so the joint bends with both
## bones; rigid joints keep pieces whole. Left-side pieces with `mirror` also build the
## right side. Left is tinted blue, right red.

const COLORS := {-1: Color(0.62, 0.68, 0.82), 0: Color(0.75, 0.75, 0.75), 1: Color(0.82, 0.64, 0.62)}


## Starter pieces from the body plan (centre + left; the right side mirrors).
static func starters(model: ActorModel) -> Array[ActorPiece]:
	var out: Array[ActorPiece] = []
	for b: BodyPlan.Bone in model.bones:
		if b.side == 1:
			continue
		var p: ActorPiece
		match b.shape:
			&"tube":
				p = ActorPiece.tube(b.name, b.length(), b.radius.x, b.radius.y, maxi(b.sides, 3))
				p.cap_start = b.parent == &"" or model.data.rigid_joints.get(b.name, false)
				p.rebuild_tube_faces()
			&"box":
				p = ActorPiece.box(b.name, b.length(), b.box.x, b.box.y)
		if p:
			out.append(p)
	return out


## Pieces to build: the data's, or the starters before modelling began.
static func pieces_of(model: ActorModel) -> Array:
	return model.data.pieces if not model.data.pieces.is_empty() else starters(model)


## [piece, source index, mirrored] for every piece that builds, right-side twins included.
static func expanded(model: ActorModel, pieces: Array) -> Array:
	var out := []
	for i in pieces.size():
		var p: ActorPiece = pieces[i]
		if model.bone_index(p.bone) < 0:
			continue
		p.ensure_id()
		out.append([p, i, false])
		if p.mirror and String(p.bone).ends_with("_L"):
			var r := BodyPlan.mirror_name(p.bone)
			if model.bone_index(r) >= 0:
				out.append([p.mirrored(r), i, true])
	return out


## Bone frame (rest, model space) of a piece, scaled along the bone for its current length.
static func piece_transform(model: ActorModel, p: ActorPiece) -> Transform3D:
	var i := model.bone_index(p.bone)
	var b: BodyPlan.Bone = model.bones[i]
	var stretch := b.length() / maxf(p.bone_length, 1e-4)
	var xf := model.rest_global(i)
	return xf * Transform3D(Basis.from_scale(Vector3(1.0, stretch, 1.0)), Vector3.ZERO)


const ACTOR_SHADER := preload("res://addons/n64_runtime/shaders/n64_actor.gdshader")
## Untextured faces in the editor: light grey (tinted by side while modelling).
const UNTEXTURED := Color(0.78, 0.78, 0.78)


## {mesh: ArrayMesh, picks: Array of {a, b, c, piece, face, mirrored}, slots: {name:
## {surface, frames}}} (model space, rest). `tint`: colour untextured pieces by side
## (editor modelling aid).
static func build(model: ActorModel, tint := false) -> Dictionary:
	var entries := world_entries(model, pieces_of(model))
	# Pass 3: triangles, one surface per texture / overlay / swap slot.
	var surfaces := {}
	var picks := []
	var tris := 0
	for e in entries:
		var p: ActorPiece = e.piece
		var pts: PackedVector3Array = e.pts
		var f := p.faces()
		for fi in f.size():
			var poly := f[fi]
			var slot: StringName = p.face_slots.get(fi, &"")
			var tex := _texture(model, p.face_textures[fi]) if slot == &"" else _slot_frame(model, slot)
			var overlay := _texture(model, p.face_overlays[fi])
			var key := "%s|%s|%s" % [tex.get_instance_id() if tex else 0, overlay.get_instance_id() if overlay else 0, slot]
			if not surfaces.has(key):
				var st := SurfaceTool.new()
				st.set_skin_weight_count(SurfaceTool.SKIN_4_WEIGHTS)
				st.begin(Mesh.PRIMITIVE_TRIANGLES)
				surfaces[key] = {st = st, tex = tex, overlay = overlay, slot = slot}
			var st: SurfaceTool = surfaces[key].st
			var uvs := face_uvs(p, fi, poly, tex)
			for k in range(1, poly.size() - 1):
				var tri := [0, k, k + 1]
				var a := pts[poly[0]]
				var bb := pts[poly[k]]
				var c := pts[poly[k + 1]]
				var n := (bb - a).cross(c - a)
				if n.length_squared() < 1e-14:
					continue
				n = n.normalized()
				# Faces are CCW around their outward normal; Godot's front faces are
				# clockwise, so emit in reverse.
				for t: int in [0, 2, 1]:
					var vi: int = poly[tri[t]]
					var col := p.colors[vi]
					if tint and tex == null:
						var side_tint: Color = COLORS[e.side]
						col = Color(side_tint.r * col.r, side_tint.g * col.g, side_tint.b * col.b, col.a)
					st.set_color(col)
					st.set_normal(n)
					st.set_uv(uvs[tri[t]])
					st.set_bones(e.weights[vi][0])
					st.set_weights(e.weights[vi][1])
					st.add_vertex(pts[vi])
				picks.append({a = a, b = bb, c = c, piece = e.source, face = fi, mirrored = e.mirrored})
				tris += 1
	var mesh := ArrayMesh.new()
	var slots := {}
	for key in surfaces:
		var s: Dictionary = surfaces[key]
		var st: SurfaceTool = s.st
		st.set_material(material(s.tex, s.overlay))
		st.commit(mesh)
		var si := mesh.get_surface_count() - 1
		if s.slot != &"":
			mesh.surface_set_name(si, "slot:%s" % s.slot)
			slots[s.slot] = {surface = si, frames = model.data.swap_slots.get(s.slot, [])}
	return {mesh = mesh, picks = picks, slots = slots, tris = tris}


## Every built piece (right-side twins included) with its rest positions (model space,
## pins applied) and skin weights: [{piece, source, mirrored, bone, side, pts, weights}].
static func world_entries(model: ActorModel, pieces: Array) -> Array:
	# Pass 1: every built piece's rest positions (model space) and skin weights.
	var entries := []
	for entry in expanded(model, pieces):
		var p: ActorPiece = entry[0]
		p.ensure_attributes()
		var bone := model.bone_index(p.bone)
		var b: BodyPlan.Bone = model.bones[bone]
		var parent := model.bone_index(p.stitch_to if p.stitch_to != &"" else b.parent)
		var stitched: bool = parent >= 0 and not model.data.rigid_joints.get(b.name, false)
		var xf := piece_transform(model, p)
		var shared := _joint_vertices(p) if stitched else {}
		var sw := clampf(p.stitch_weight, 0.0, 1.0)
		var pts := PackedVector3Array()
		var weights := []  # per vertex: [PackedInt32Array, PackedFloat32Array]
		for vi in p.vertices.size():
			pts.append(xf * p.vertices[vi])
			if shared.has(vi):
				var w: float = sw * shared[vi]
				weights.append([PackedInt32Array([bone, parent, 0, 0]), PackedFloat32Array([1.0 - w, w, 0, 0])])
			else:
				weights.append([PackedInt32Array([bone, 0, 0, 0]), PackedFloat32Array([1.0, 0, 0, 0])])
		entries.append({piece = p, source = entry[1], mirrored = entry[2], bone = bone, side = b.side, pts = pts, weights = weights})
	# Pass 2: vertex pins take their target's position and weights (twice, for chains).
	var by_id := by_id_of(entries)
	for _pass in 2:
		for e in entries:
			var p: ActorPiece = e.piece
			for v in p.pins:
				var target := pin_target(model, e, p.pins[v], by_id, entries)
				if target.is_empty() or v >= e.pts.size():
					continue
				var te: Dictionary = entries[target.entry]
				e.pts[v] = te.pts[target.vertex]
				e.weights[v] = te.weights[target.vertex]
	return entries


## Piece id -> index into world_entries().
static func by_id_of(entries: Array) -> Dictionary:
	var out := {}
	for i in entries.size():
		out[entries[i].piece.id] = i
	return out


## Where a pin of built piece `e` lands: {entry, vertex} or {}. Mirrored (right-side)
## pieces pin to the mirror of the target: a left piece's right copy, or a centre piece's
## twin vertex.
static func pin_target(model: ActorModel, e: Dictionary, pin: Array, by_id: Dictionary, entries: Array) -> Dictionary:
	var tid: String = pin[0]
	var tv: int = pin[1]
	if not by_id.has(tid):
		return {}
	var ti: int = by_id[tid]
	if e.mirrored:
		var mirror_id := tid + "~R"
		if by_id.has(mirror_id):
			ti = by_id[mirror_id]
		else:
			var tp: ActorPiece = entries[ti].piece
			var twin := tp.twin(tv)
			if twin >= 0:
				tv = twin
	var te: Dictionary = entries[ti]
	if tv >= te.pts.size():
		return {}
	return {entry = ti, vertex = tv}


## N64 actor material: texture (white when none) x vertex colour, overlay through the
## vertex mask (colour alpha).
static func material(tex: Texture2D, overlay: Texture2D) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = ACTOR_SHADER
	m.set_shader_parameter(&"albedo_color", Color.WHITE if tex else UNTEXTURED)
	if tex:
		m.set_shader_parameter(&"albedo_texture", tex)
	m.set_shader_parameter(&"use_vertex_color", true)
	if overlay:
		m.set_shader_parameter(&"overlay_texture", overlay)
		m.set_shader_parameter(&"has_overlay", true)
	return m


static func _texture(model: ActorModel, i: int) -> Texture2D:
	return model.data.textures[i] if i >= 0 and i < model.data.textures.size() else null


static func _slot_frame(model: ActorModel, slot: StringName) -> Texture2D:
	var frames: Array = model.data.swap_slots.get(slot, [])
	return frames[0] if not frames.is_empty() else null


## Metres one texture repeat covers (width, height) on characters: the project's texel
## density, like levels.
static func repeat_size(tex: Texture2D) -> Vector2:
	if tex is N64Texture:
		var n := tex as N64Texture
		var w := n.metres_per_repeat()
		return Vector2(w, w * float(n.texture_size.y) / maxf(n.texture_size.x, 1))
	if tex:
		var tpm := N64Texture.texels_per_metre()
		return Vector2(tex.get_width() / tpm, tex.get_height() / tpm)
	return Vector2.ONE


## UVs for one face's corners (bone frame): tubes (and `wrap_uv` pieces) wrap around the
## bone, other pieces project along the face's main axis, at the texture's texel density;
## fitted faces stretch the texture over the face. Then the face's nudges (offset, scale,
## turns).
static func face_uvs(p: ActorPiece, fi: int, poly: PackedInt32Array, tex: Texture2D) -> PackedVector2Array:
	var out := PackedVector2Array()
	var rep := repeat_size(tex)
	var n := ActorPieceOps.face_normal(p, poly)
	if p.face_fit.get(fi, 0) == 1 or p.face_slots.has(fi):
		# Face plane axes: v down the bone's up (projected), u across.
		var up := Vector3.UP - n * n.dot(Vector3.UP)
		if up.length() < 0.1:
			up = Vector3.BACK - n * n.dot(Vector3.BACK)
		up = up.normalized()
		var across := up.cross(n).normalized()
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		var raw := PackedVector2Array()
		for v in poly:
			var q := Vector2(p.vertices[v].dot(across), -p.vertices[v].dot(up))
			raw.append(q)
			lo = lo.min(q)
			hi = hi.max(q)
		var size := (hi - lo).max(Vector2(1e-4, 1e-4))
		for q in raw:
			out.append((q - lo) / size)
	elif p.is_tube() or p.wrap_uv:
		var first := -INF
		for v in poly:
			var pos := p.vertices[v]
			var ang := atan2(pos.z, pos.x)
			if first == -INF:
				first = ang
			# Unwrap around the seam relative to the face's first corner.
			ang = first + wrapf(ang - first, -PI, PI)
			var radius := Vector2(pos.x, pos.z).length()
			out.append(Vector2(ang * maxf(radius, 0.02) / rep.x, -pos.y / rep.y))
	else:
		var a := n.abs()
		for v in poly:
			var pos := p.vertices[v]
			var q: Vector2
			if a.y >= a.x and a.y >= a.z:
				q = Vector2(pos.x, pos.z)
			elif a.x >= a.z:
				q = Vector2(pos.z * signf(n.x), -pos.y)
			else:
				q = Vector2(-pos.x * signf(n.z), -pos.y)
			out.append(q / rep)
	var tw: Vector4 = p.face_uv.get(fi, Vector4(0, 0, 1, 0))
	if tw != Vector4(0, 0, 1, 0):
		var turns := int(tw.w) % 4
		for i in out.size():
			var q := out[i] - Vector2(0.5, 0.5)
			for _t in turns:
				q = Vector2(-q.y, q.x)
			out[i] = q / maxf(tw.z, 0.01) + Vector2(0.5, 0.5) + Vector2(tw.x, tw.y)
	return out


## Vertices that bend with the parent at a stitched joint: a tube's first ring, or a free
## mesh's vertices at the joint end (near y = 0).
## Values: how much of the stitch weight applies (1 at the joint, fading over
## `stitch_rings` rings on tubes).
static func _joint_vertices(p: ActorPiece) -> Dictionary:
	var out := {}
	if p.is_tube():
		var n := clampi(p.stitch_rings, 1, p.rings.size())
		for i in n:
			for v in p.rings[i]:
				out[v] = 1.0 - float(i) / n
		return out
	var lowest := INF
	for v in p.vertices:
		lowest = minf(lowest, v.y)
	if lowest > p.bone_length * 0.15:
		return out  # piece doesn't reach the joint
	for i in p.vertices.size():
		if p.vertices[i].y <= lowest + 0.01:
			out[i] = 1.0
	return out
