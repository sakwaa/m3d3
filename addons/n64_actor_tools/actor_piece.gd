@tool
class_name ActorPiece
extends Resource
## One piece of a character's mesh, owned by one bone (N64 style: a separate simple mesh
## per limb). Vertices are in the bone's rest frame (metres; +Y runs along the bone), so
## pieces follow proportion changes: along-the-bone positions stretch with the bone.
## Faces are vertex loops wound counter-clockwise around their outward normal (like
## level brushes).
##
## Tube pieces keep their `rings` (vertex ids per ring, head to tail) and rebuild their
## faces from them, so rings can be added / scaled / moved; any free-form face edit turns
## the piece into a plain mesh (rings cleared).

@export var bone: StringName
## Stable id (vertex pins on other pieces refer to it). Mirrored right-side copies use
## id + "~R".
@export var id := ""
@export var vertices := PackedVector3Array()
@export var face_indices := PackedInt32Array()
@export var face_counts := PackedInt32Array()
## Tube pieces: vertex ids of each ring, head to tail. Empty = free-form mesh.
@export var rings: Array[PackedInt32Array] = []
## Tube pieces: close the first / last ring with a cap (centre vertex).
@export var cap_start := true
@export var cap_end := true
## Bone length when the piece was made: positions along the bone scale by the bone's
## current length / this.
@export var bone_length := 1.0
## Left-side pieces: build the right side from this one (mirrored). Centre pieces: edits
## apply symmetrically. Off = this piece stands alone (asymmetric details).
@export var mirror := true

@export_group("Joint")
## Bone the piece's joint end (a tube's first ring, a mesh's base) is stitched to: empty =
## the parent bone. An ancestor (e.g. the chest for an upper arm or a sleeve) skips bones
## without a piece of their own (clavicles).
@export var stitch_to: StringName
## How much of the joint end follows the stitch bone: 0 = rigid on its own bone (sleeves,
## pads: tuck their top into the body), 0.5 = soft (bends halfway), 1 = glued like N64
## limbs (the edge stays on the body, the faces stretch).
@export_range(0.0, 1.0, 0.05) var stitch_weight := 0.5
## Tubes: rings the stitch fades over (1 = only the first ring; 2+ = later rings share a
## decreasing part, so sleeves / skirts bend smoothly instead of folding).
@export_range(1, 4) var stitch_rings := 1

## Vertex pins: vertex -> [target piece id, target vertex]. A pinned vertex takes the
## target vertex's position and bone weights in every pose (seams that never open, the
## pieces stay separate).
@export var pins := {}

@export_group("Paint")
## Per face: index into the character's textures (-1 = untextured).
@export var face_textures := PackedInt32Array()
## Per face: overlay texture index (-1 = none), shown where the vertex mask (colour alpha)
## is painted.
@export var face_overlays := PackedInt32Array()
## Face -> 1: the texture is fitted to the face (eyes, emblems) instead of tiling at the
## project's texel density.
@export var face_fit := {}
## Face -> Vector4(offset u, offset v, scale, quarter turns): UV nudges.
@export var face_uv := {}
## Face -> swap slot name (eyes, mouth): the slot's current frame is its texture.
@export var face_slots := {}
## Per vertex: colour (rgb tints the textures, a = overlay mask).
@export var colors := PackedColorArray()

@export_group("Blender")
## Geometry edited in Blender (ActorModelData.blend_file): per face, the id stored on the
## face in the .blend (its `n64_face` attribute), so paint follows faces through edits
## there. 0 = none.
@export var face_ids := PackedInt32Array()
## Texture wraps around the bone like a tube's (pieces that were tubes before Blender
## edits turned them into plain meshes).
@export var wrap_uv := false


## Attribute arrays sized to the geometry (new entries: untextured, white, no mask).
func ensure_id() -> void:
	if id.is_empty():
		id = "%08x" % (randi() & 0x7fffffff)


func ensure_attributes() -> void:
	ensure_id()
	var nf := face_counts.size()
	for arr_name in [&"face_textures", &"face_overlays"]:
		var arr: PackedInt32Array = get(arr_name)
		var old := arr.size()
		arr.resize(nf)
		for i in range(old, nf):
			arr[i] = -1
		set(arr_name, arr)
	var old_c := colors.size()
	colors.resize(vertices.size())
	for i in range(old_c, vertices.size()):
		colors[i] = Color(1, 1, 1, 0)


func face_centre(poly: PackedInt32Array) -> Vector3:
	var c := Vector3.ZERO
	for v in poly:
		c += vertices[v]
	return c / maxf(poly.size(), 1)


## Snapshot of paint attributes by position, to carry over a topology change.
func paint_snapshot() -> Dictionary:
	ensure_attributes()
	var f := faces()
	var fc := PackedVector3Array()
	for poly in f:
		fc.append(face_centre(poly))
	return {face_centres = fc, face_textures = face_textures.duplicate(), face_overlays = face_overlays.duplicate(),
		face_fit = face_fit.duplicate(), face_uv = face_uv.duplicate(), face_slots = face_slots.duplicate(),
		verts = vertices.duplicate(), colors = colors.duplicate(), pins = pins.duplicate()}


## After a topology change: each new face takes the paint of the nearest old face, each
## new vertex the colour of the nearest old vertex.
func restore_paint(snap: Dictionary) -> void:
	var f := faces()
	var old_c: PackedVector3Array = snap.face_centres
	var tex := PackedInt32Array()
	var ovl := PackedInt32Array()
	var fit := {}
	var uv := {}
	var slots := {}
	for i in f.size():
		var c := face_centre(f[i])
		var best := -1
		var best_d := INF
		for j in old_c.size():
			var d := c.distance_squared_to(old_c[j])
			if d < best_d:
				best_d = d
				best = j
		tex.append(snap.face_textures[best] if best >= 0 and best < snap.face_textures.size() else -1)
		ovl.append(snap.face_overlays[best] if best >= 0 and best < snap.face_overlays.size() else -1)
		if best >= 0:
			if snap.face_fit.has(best):
				fit[i] = snap.face_fit[best]
			if snap.face_uv.has(best):
				uv[i] = snap.face_uv[best]
			if snap.face_slots.has(best):
				slots[i] = snap.face_slots[best]
	face_textures = tex
	face_overlays = ovl
	face_fit = fit
	face_uv = uv
	face_slots = slots
	var old_v: PackedVector3Array = snap.verts
	var old_col: PackedColorArray = snap.colors
	var cols := PackedColorArray()
	for v in vertices:
		var best := -1
		var best_d := INF
		for j in old_v.size():
			var d := v.distance_squared_to(old_v[j])
			if d < best_d:
				best_d = d
				best = j
		cols.append(old_col[best] if best >= 0 and best < old_col.size() else Color(1, 1, 1, 0))
	colors = cols
	# Pins stay on the vertex nearest to where the pinned one was.
	var old_pins: Dictionary = snap.get("pins", {})
	var new_pins := {}
	for ov in old_pins:
		if ov >= old_v.size():
			continue
		var best := -1
		var best_d := INF
		for i in vertices.size():
			var d := vertices[i].distance_squared_to(old_v[ov])
			if d < best_d:
				best_d = d
				best = i
		if best >= 0 and best_d < 1e-6 and not new_pins.has(best):
			new_pins[best] = old_pins[ov]
	pins = new_pins


func faces() -> Array[PackedInt32Array]:
	return BrushOps.unpack_faces(face_indices, face_counts)


func set_faces(f: Array[PackedInt32Array]) -> void:
	var packed := BrushOps.pack_faces(f)
	face_indices = packed[0]
	face_counts = packed[1]


func is_tube() -> bool:
	return not rings.is_empty()


func sides() -> int:
	return rings[0].size() if is_tube() else 0


## Tube faces from the rings (+ caps): ring vertices go around the bone so that quads
## (k, k+1 on ring i -> ring i+1) face outward.
func rebuild_tube_faces() -> void:
	if not is_tube():
		return
	var snap := paint_snapshot() if not face_counts.is_empty() else {}
	# Caps are the last vertices (start centre, end centre) when enabled; rebuild them.
	var ring_verts := PackedVector3Array()
	var new_rings: Array[PackedInt32Array] = []
	for r in rings:
		var nr := PackedInt32Array()
		for v in r:
			nr.append(ring_verts.size())
			ring_verts.append(vertices[v])
		new_rings.append(nr)
	rings = new_rings
	vertices = ring_verts
	var f: Array[PackedInt32Array] = []
	var n := sides()
	for i in rings.size() - 1:
		var a := rings[i]
		var b := rings[i + 1]
		for k in n:
			var k2 := (k + 1) % n
			f.append(PackedInt32Array([a[k], b[k], b[k2], a[k2]]))
	if cap_start:
		var c := vertices.size()
		vertices.append(_centre(rings[0]))
		for k in n:
			f.append(PackedInt32Array([c, rings[0][k], rings[0][(k + 1) % n]]))
	if cap_end:
		var c := vertices.size()
		vertices.append(_centre(rings[-1]))
		var last := rings[-1]
		for k in n:
			f.append(PackedInt32Array([c, last[(k + 1) % n], last[k]]))
	set_faces(f)
	if not snap.is_empty():
		restore_paint(snap)
	ensure_attributes()


func _centre(ring: PackedInt32Array) -> Vector3:
	var c := Vector3.ZERO
	for v in ring:
		c += vertices[v]
	return c / maxf(ring.size(), 1)


## The ring's centre and radii (x, z) in the bone frame.
func ring_centre(i: int) -> Vector3:
	return _centre(rings[i])


## Turns a tube into a free-form mesh (before face edits).
func make_free() -> void:
	rings.clear()


## A vertex's mirror twin within this piece (across the bone frame's X = 0), or -1.
func twin(v: int, eps := 0.002) -> int:
	var p := vertices[v]
	var m := Vector3(-p.x, p.y, p.z)
	if absf(p.x) <= eps:
		return v
	for i in vertices.size():
		if vertices[i].distance_to(m) <= eps:
			return i
	return -1


## Mirror copy across the bone frame's X = 0 (right side from left, or flipped).
func mirrored(to_bone: StringName) -> ActorPiece:
	var m := duplicate(true) as ActorPiece
	m.bone = to_bone
	m.id = id + "~R"
	m.stitch_to = BodyPlan.mirror_name(stitch_to) if stitch_to != &"" else &""
	var vs := PackedVector3Array()
	for p in vertices:
		vs.append(Vector3(-p.x, p.y, p.z))
	m.vertices = vs
	var f := faces()
	for i in f.size():
		var poly := f[i].duplicate()
		poly.reverse()
		f[i] = poly
	m.set_faces(f)
	# Ring order around the bone flips too, so rebuilt tube faces stay outward.
	var rs: Array[PackedInt32Array] = []
	for r in rings:
		var nr := r.duplicate()
		nr.reverse()
		rs.append(nr)
	m.rings = rs
	return m


# --- Starter shapes ---------------------------------------------------------------------------

## Tube along the bone from y = 0 to `length`: `sides` around, radius `r0` -> `r1`.
static func tube(bone_name: StringName, length: float, r0: float, r1: float, sides := 6, rings_count := 2) -> ActorPiece:
	var p := ActorPiece.new()
	p.bone = bone_name
	p.bone_length = length
	var rs: Array[PackedInt32Array] = []
	for i in rings_count:
		var t := float(i) / (rings_count - 1)
		var r := lerpf(r0, r1, t)
		var ring := PackedInt32Array()
		for k in sides:
			# Going x -> +z around the bone, so ring quads face outward.
			var a := TAU * (k + 0.5) / sides
			ring.append(p.vertices.size())
			p.vertices.append(Vector3(cos(a) * r, t * length, sin(a) * r))
		rs.append(ring)
	p.rings = rs
	p.rebuild_tube_faces()
	return p


## Box along the bone from y = 0 to `length`, `width` (x) by `depth` (z).
static func box(bone_name: StringName, length: float, width: float, depth: float) -> ActorPiece:
	var p := ActorPiece.new()
	p.bone = bone_name
	p.bone_length = length
	var hx := width * 0.5
	var hz := depth * 0.5
	for y in [0.0, length]:
		for c in [Vector2(-hx, -hz), Vector2(hx, -hz), Vector2(hx, hz), Vector2(-hx, hz)]:
			p.vertices.append(Vector3(c.x, y, c.y))
	# 0-3 bottom ring, 4-7 top ring (going -x-z, +x-z, +x+z, -x+z).
	var f: Array[PackedInt32Array] = [
		PackedInt32Array([0, 1, 2, 3]),  # bottom (-Y)
		PackedInt32Array([4, 7, 6, 5]),  # top (+Y)
	]
	for k in 4:
		var k2 := (k + 1) % 4
		f.append(PackedInt32Array([k, k + 4, k2 + 4, k2]))
	p.set_faces(f)
	p.ensure_attributes()
	return p
