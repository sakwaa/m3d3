@tool
class_name ActorPick
extends RefCounted
## Picking on an ActorModel for modelling tools (the desktop plugin and the iOS mesh
## builder): which vertex / edge / face is on screen where, through the mesh or not, and
## what a ray / finger hits. Every built piece counts, mirrored right-side copies too
## (their source piece index; same vertex ids).


## Is a model-space point unobstructed from the camera (always, seeing through)?
static func visible(model: ActorModel, camera: Camera3D, p: Vector3) -> bool:
	if model.sees_through():
		return true
	var world: Vector3 = model.global_transform * p
	var screen := camera.unproject_position(world)
	var inv := model.global_transform.affine_inverse()
	var origin: Vector3 = inv * camera.project_ray_origin(screen)
	var dir := (inv.basis * camera.project_ray_normal(screen)).normalized()
	var hit := model.pick(origin, dir)
	return hit.is_empty() or origin.distance_to(hit.point) >= origin.distance_to(p) - 0.01


## Screen-space elements of every built piece: [{piece, kind, id, pos (screen), at (model)}].
static func elements(model: ActorModel, camera: Camera3D, kind: int, only_piece := -1) -> Array:
	var out := []
	var to_world := model.global_transform
	for entry in ActorMannequin.expanded(model, model.data.pieces):
		var src: int = entry[1]
		if only_piece >= 0 and src != only_piece:
			continue
		var mirrored: bool = entry[2]
		var p: ActorPiece = entry[0]
		var xf := model.piece_transform(p)
		var pts := PackedVector3Array()
		for v in p.vertices:
			pts.append(xf * v)
		match kind:
			ActorModel.Select.VERTEX:
				for v in pts.size():
					out.append({piece = src, mirrored = mirrored, id = v, at = pts[v], a = pts[v], b = pts[v]})
			ActorModel.Select.EDGE:
				var seen := {}
				for poly in p.faces():
					for k in poly.size():
						var e := Vector2i(mini(poly[k], poly[(k + 1) % poly.size()]), maxi(poly[k], poly[(k + 1) % poly.size()]))
						if seen.has(e):
							continue
						seen[e] = true
						out.append({piece = src, mirrored = mirrored, id = e, at = (pts[e.x] + pts[e.y]) * 0.5, a = pts[e.x], b = pts[e.y]})
			ActorModel.Select.FACE:
				var f := p.faces()
				for fi in f.size():
					var c := Vector3.ZERO
					for v in f[fi]:
						c += pts[v]
					c /= f[fi].size()
					out.append({piece = src, mirrored = mirrored, id = fi, at = c, a = c, b = c})
	for e in out:
		e.screen = camera.unproject_position(to_world * e.at)
		e.sa = camera.unproject_position(to_world * e.a)
		e.sb = camera.unproject_position(to_world * e.b)
		e.behind = camera.is_position_behind(to_world * e.at)
	return out


## Model-space ray through a screen point: [origin, direction].
static func ray(model: ActorModel, camera: Camera3D, screen: Vector2) -> Array:
	var inv := model.global_transform.affine_inverse()
	return [inv * camera.project_ray_origin(screen), (inv.basis * camera.project_ray_normal(screen)).normalized()]


## The face under a screen point: {piece, face, mirrored, point} or {}.
static func face_at(model: ActorModel, camera: Camera3D, screen: Vector2) -> Dictionary:
	var r := ray(model, camera, screen)
	return model.pick(r[0], r[1])


## The visible element of `kind` nearest a screen point within `radius` pixels (vertices:
## to the point; edges: to the segment; faces: the face under the point), or {}.
static func nearest(model: ActorModel, camera: Camera3D, screen: Vector2, kind: int, radius: float, only_piece := -1) -> Dictionary:
	if kind == ActorModel.Select.FACE:
		var hit := face_at(model, camera, screen)
		if hit.is_empty() or (only_piece >= 0 and hit.piece != only_piece):
			return {}
		return {piece = hit.piece, id = hit.face, at = hit.point, mirrored = hit.mirrored}
	var best := radius
	var found := {}
	for e in elements(model, camera, kind, only_piece):
		if e.behind:
			continue
		var d: float = e.screen.distance_to(screen) if kind == ActorModel.Select.VERTEX \
			else screen.distance_to(Geometry2D.get_closest_point_to_segment(screen, e.sa, e.sb))
		if d < best and visible(model, camera, e.at):
			best = d
			found = e
	return found


## The built piece (source, or its mirrored right-side copy) an element came from:
## matched by where vertex `v` sits in model space. Null if none.
static func built_piece(model: ActorModel, piece: int, v: int, at: Vector3) -> ActorPiece:
	for entry in ActorMannequin.expanded(model, model.data.pieces):
		if entry[1] != piece:
			continue
		var cand: ActorPiece = entry[0]
		if v < cand.vertices.size() and (model.piece_transform(cand) * cand.vertices[v]).is_equal_approx(at):
			return cand
	return null
