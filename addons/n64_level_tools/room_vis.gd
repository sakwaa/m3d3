@tool
class_name RoomVis
extends RefCounted
## Drawing rooms for the build (OoT-style): the level's Room prop brushes (VisRoom) split
## the baked meshes (each polygon goes with the room holding its middle), and each mesh
## learns which rooms it can be seen from: from eye points over each room's walkable ground
## (player and camera heights), a ray reaching any of its sample points through the opaque
## level. The answer rides on the mesh (meta "seen_from": room ids); LevelRoot draws a mesh
## only while the camera's room is one of them. Meshes outside every room, and a camera
## outside every room, draw as before. Visibility is sampled: a sliver seen only through
## a crack may be missed, so samples lean generous (several heights, ground-hugging eyes).

const META := &"seen_from"
const DEFAULT_SIZE := Vector3(20, 12, 20)
## Eye spacing over a room's ground (metres; widened for big rooms to cap the count).
const EYE_STEP := 3.0
const MAX_EYES := 80
## Above the ground: the player's eyes and a raised camera.
const EYE_HEIGHTS := [1.6, 4.5]
const MAX_TARGETS := 40


## The level's rooms: [{id, xf, inv, size}] from its Room prop brushes.
static func rooms(data: LevelData) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for b: LevelBrush in data.brushes:
		if b == null or not b.is_prop() or b.prop.kind != PropSpec.Kind.ROOM:
			continue
		var id: StringName = b.prop.settings.get(&"room_id", &"")
		if id == &"":
			id = StringName(b.prop.node_name if b.prop.node_name != "" else "room_%s" % b.tag)
		out.append({id = id, xf = b.transform, inv = b.transform.affine_inverse(),
			size = b.prop.settings.get(&"size", DEFAULT_SIZE)})
	return out


## Index of the room holding `p` (level space), or -1.
static func room_at(list: Array[Dictionary], p: Vector3) -> int:
	for i in list.size():
		if inside(list[i], p):
			return i
	return -1


static func inside(room: Dictionary, p: Vector3) -> bool:
	var l: Vector3 = room.inv * p
	var s: Vector3 = room.size
	return absf(l.x) <= s.x * 0.5 and absf(l.z) <= s.z * 0.5 and l.y >= -0.5 and l.y <= s.y


## Sets each mesh's "seen_from" (room ids it's visible from). `blockers`: opaque triangles
## (level space, 3 points each); `ground`: per blocker triangle, whether it's ground.
## Returns {rooms, eyes, meshes, hidden_pairs} for the build report.
static func mark(meshes: Array, list: Array[Dictionary], blockers: PackedVector3Array, ground: PackedByteArray) -> Dictionary:
	var tm := TriangleMesh.new()
	if blockers.is_empty() or not tm.create_from_faces(blockers):
		return {}
	var eyes := []  # per room: PackedVector3Array
	var eye_count := 0
	for room in list:
		var e := _eyes(room, tm, ground)
		eyes.append(e)
		eye_count += e.size()
	var hidden := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	for m: ArrayMesh in meshes:
		var targets := _targets(m, rng)
		if targets.is_empty():
			continue
		var seen := PackedStringArray()
		for ri in list.size():
			if _sees(eyes[ri], targets, tm):
				seen.append(String(list[ri].id))
			else:
				hidden += 1
		m.set_meta(META, seen)
	return {rooms = list.size(), eyes = eye_count, meshes = meshes.size(), hidden_pairs = hidden}


## Eye points over the room's walkable ground (a ray down from its top must land on ground,
## not a roof or a wall top).
static func _eyes(room: Dictionary, tm: TriangleMesh, ground: PackedByteArray) -> PackedVector3Array:
	var s: Vector3 = room.size
	var step := maxf(EYE_STEP, sqrt(s.x * s.z / MAX_EYES))
	var nx := maxi(ceili(s.x / step), 1)
	var nz := maxi(ceili(s.z / step), 1)
	var out := PackedVector3Array()
	for ix in nx:
		for iz in nz:
			var l := Vector3(-s.x * 0.5 + (ix + 0.5) * s.x / nx, s.y, -s.z * 0.5 + (iz + 0.5) * s.z / nz)
			var top: Vector3 = room.xf * l
			var hit := tm.intersect_segment(top, top + Vector3.DOWN * (s.y + 1.0))
			if hit.is_empty() or not ground[int(hit.face_index)]:
				continue
			for h: float in EYE_HEIGHTS:
				out.append(hit.position + Vector3.UP * h)
	return out


## Sample points of a mesh: its triangles' middles (a random pick when there are many),
## nudged off the surface along its face.
static func _targets(m: ArrayMesh, rng: RandomNumberGenerator) -> PackedVector3Array:
	var tris := []
	for si in m.get_surface_count():
		var a := m.surface_get_arrays(si)
		var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
		for t in range(0, idx.size(), 3):
			tris.append([v[idx[t]], v[idx[t + 1]], v[idx[t + 2]]])
	if tris.size() > MAX_TARGETS:
		# (Every triangle a fair chance; big ones stand out more, so they come first.)
		tris.sort_custom(func(x, y): return _area(x) > _area(y))
		var big := tris.slice(0, MAX_TARGETS / 2)
		var rest := tris.slice(MAX_TARGETS / 2)
		for i in MAX_TARGETS / 2:
			big.append(rest[rng.randi_range(0, rest.size() - 1)])
		tris = big
	var out := PackedVector3Array()
	for t in tris:
		var c: Vector3 = (t[0] + t[1] + t[2]) / 3.0
		var n: Vector3 = (t[1] - t[0]).cross(t[2] - t[0])
		if n.length_squared() < 1e-10:
			continue
		# Both sides: the side facing the eye is the one drawn.
		out.append(c + n.normalized() * 0.05)
		out.append(c - n.normalized() * 0.05)
	return out


static func _area(t: Array) -> float:
	return ((t[1] - t[0]) as Vector3).cross(t[2] - t[0]).length()


static func _sees(eyes: PackedVector3Array, targets: PackedVector3Array, tm: TriangleMesh) -> bool:
	for e in eyes:
		for t in targets:
			if tm.intersect_segment(e, t).is_empty():
				return true
	return false
