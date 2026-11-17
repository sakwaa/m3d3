@tool
class_name N64Lod
extends Node
## Low-poly stand-ins at a distance, as N64 games swapped models (OoT's NPCs, MM's
## townsfolk): every mesh under this node's parent gets a reduced copy shown beyond
## `distance`, the full one inside it - an instant pop, not a blend. The copy keeps the
## mesh's vertices (skinning, colours, UVs) and drops triangles (meshoptimizer, the same
## simplifier as Godot's mesh LODs), so it animates with the same skeleton.
## Reduced meshes are made once per mesh and shared (ten of the same NPC: one copy). Set
## `lod_mesh` on a single-mesh model to use a hand-made one instead.

## Metres from the camera where the reduced model takes over (0 = off).
@export_range(0.0, 200.0, 0.5, "suffix:m") var distance := 14.0:
	set(v):
		distance = v
		_apply_ranges()
## Share of the triangles the reduced model keeps (meshoptimizer gets as close as it can
## without tearing the shape).
@export_range(0.05, 0.95, 0.05) var ratio := 0.35
## A hand-made low-poly mesh (single-mesh models), instead of the generated one.
@export var lod_mesh: Mesh
## Shows only the reduced model, wherever the camera is (checking it).
@export var preview_lod := false:
	set(v):
		preview_lod = v
		_apply_ranges()

static var _cache := {}  # Mesh -> reduced ArrayMesh
var _pairs: Array = []  # [full MeshInstance3D, reduced MeshInstance3D]


func _ready() -> void:
	_setup.call_deferred()  # (models such as ActorModel build their mesh in their own _ready)


func _setup() -> void:
	for p in _pairs:
		if is_instance_valid(p[1]):
			p[1].queue_free()
	_pairs.clear()
	var parent := get_parent()
	if parent == null:
		return
	for mi: MeshInstance3D in parent.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null or mi.has_meta(&"n64_lod_copy"):
			continue
		var low: Mesh = lod_mesh if lod_mesh else reduced(mi.mesh, ratio)
		if low == null:
			continue
		var copy := MeshInstance3D.new()
		copy.name = mi.name + "Lod"
		copy.set_meta(&"n64_lod_copy", true)
		copy.mesh = low
		copy.skin = mi.skin
		copy.material_override = mi.material_override
		for s in mini(mi.get_surface_override_material_count(), low.get_surface_count()):
			copy.set_surface_override_material(s, mi.get_surface_override_material(s))
		copy.cast_shadow = mi.cast_shadow
		copy.layers = mi.layers
		copy.transform = mi.transform
		mi.add_sibling(copy)
		if not mi.skeleton.is_empty():
			copy.skeleton = copy.get_path_to(mi.get_node(mi.skeleton))
		_pairs.append([mi, copy])
	_apply_ranges()


func _apply_ranges() -> void:
	for p in _pairs:
		var full: MeshInstance3D = p[0]
		var low: MeshInstance3D = p[1]
		if not is_instance_valid(full) or not is_instance_valid(low):
			continue
		var d := 0.0001 if preview_lod else distance
		full.visibility_range_end = d if distance > 0.0 or preview_lod else 0.0
		low.visibility_range_begin = d
		low.visible = distance > 0.0 or preview_lod


## Triangle count of a mesh (all surfaces).
static func tris(mesh: Mesh) -> int:
	var n := 0
	for s in mesh.get_surface_count():
		var a := mesh.surface_get_arrays(s)
		n += (a[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3 if a[Mesh.ARRAY_INDEX] else (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return n


## `mesh` with about `keep` of its triangles (cached per mesh), or null if it can't shrink.
static func reduced(mesh: Mesh, keep: float) -> ArrayMesh:
	var key := [mesh, snappedf(keep, 0.05)]
	if _cache.has(key):
		return _cache[key]
	var im := ImporterMesh.new()
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		if arrays[Mesh.ARRAY_INDEX] == null:
			# (generate_lods needs an index buffer)
			var idx := PackedInt32Array()
			for i in (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size():
				idx.append(i)
			arrays[Mesh.ARRAY_INDEX] = idx
		im.add_surface(mesh.surface_get_primitive_type(s), arrays, [], {}, mesh.surface_get_material(s),
			mesh.surface_get_name(s), mesh.surface_get_format(s) & ~Mesh.ARRAY_FORMAT_INDEX & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS)
	im.generate_lods(25.0, 60.0, [])
	var out := ArrayMesh.new()
	var shrank := false
	for s in im.get_surface_count():
		var arrays := im.get_surface_arrays(s)
		var full: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var best := full
		var island := _islands(arrays[Mesh.ARRAY_VERTEX], full)
		var pieces := _pieces(island, full)
		for l in im.get_surface_lod_count(s):
			var li := im.get_surface_lod_indices(s, l)
			# A level that drops a whole piece (a hand, a box of a mannequin) isn't a lower
			# detail version of the model: skip it.
			if li.size() < 3 or _pieces(island, li) < pieces:
				continue
			if absf(float(li.size()) / full.size() - keep) < absf(float(best.size()) / full.size() - keep):
				best = li
		if best.size() < full.size():
			shrank = true
		arrays[Mesh.ARRAY_INDEX] = best
		out.add_surface_from_arrays(im.get_surface_primitive_type(s), arrays, [], {},
			mesh.surface_get_format(s) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS)
		out.surface_set_material(s, im.get_surface_material(s))
		out.surface_set_name(s, im.get_surface_name(s))
	var result: ArrayMesh = out if shrank else null
	_cache[key] = result
	return result


## Connected piece of each vertex (vertices at the same position count as joined: split
## normals and UV seams don't separate a piece).
static func _islands(verts: PackedVector3Array, idx: PackedInt32Array) -> PackedInt32Array:
	var parent := PackedInt32Array()
	parent.resize(verts.size())
	for i in verts.size():
		parent[i] = i
	var at := {}
	for i in verts.size():
		var k := verts[i].snappedf(1e-4)
		if at.has(k):
			_join(parent, i, at[k])
		else:
			at[k] = i
	for t in range(0, idx.size() - 2, 3):
		_join(parent, idx[t], idx[t + 1])
		_join(parent, idx[t], idx[t + 2])
	var out := PackedInt32Array()
	out.resize(verts.size())
	for i in verts.size():
		out[i] = _root(parent, i)
	return out


static func _root(parent: PackedInt32Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i


static func _join(parent: PackedInt32Array, a: int, b: int) -> void:
	var ra := _root(parent, a)
	var rb := _root(parent, b)
	if ra != rb:
		parent[ra] = rb


## How many pieces the triangles in `idx` touch.
static func _pieces(island: PackedInt32Array, idx: PackedInt32Array) -> int:
	var seen := {}
	for i in idx:
		seen[island[i]] = true
	return seen.size()
