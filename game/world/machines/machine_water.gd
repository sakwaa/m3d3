@tool
class_name MachineWater
extends Node3D
## A water surface whose level a machine channel sets (a machine part prop): a side channel
## filling behind a gate, a trough the wheel pours into. Rises from `low` to `high` (local Y)
## as `input` goes 0 -> 1, easing (water fills, it doesn't jump); invisible while dry. Flows
## along local -Z at `flow` m/s (the texture's two layers both drift that way). Writes how
## full it is now (0..1) to `output`.
## No `input`: always full (a stream).
## Origin: the surface's middle at `low`; `size` across (x) and along (z). Or a shaped surface
## following banks: `strip` rows (along z, from x, to x), in order along z (local).

@export var input := &""
@export var output := &""
@export var size := Vector2(3.0, 12.0):
	set(v):
		size = v
		_rebuild()
## Shaped surface (overrides `size`): rows of (local z, x from, x to), in order along z.
@export var strip := PackedVector3Array():
	set(v):
		strip = v
		_rebuild()
@export_range(-10.0, 0.0, 0.05, "suffix:m") var low := 0.0
@export_range(0.0, 30.0, 0.05, "suffix:m") var high := 1.5
## Metres a second the surface rises / falls at most.
@export_range(0.05, 5.0, 0.05, "suffix:m/s") var fill_speed := 0.35
## Flow speed along -Z (0: still).
@export_range(0.0, 5.0, 0.05, "suffix:m/s") var flow := 0.8:
	set(v):
		flow = v
		_rebuild()
@export var material: Material = preload("res://game/materials/water.tres"):
	set(v):
		material = v
		_rebuild()

## How full (0..1).
var full := 0.0
var _mesh: MeshInstance3D


func _ready() -> void:
	if input == &"":
		full = 1.0
	_rebuild()


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or _mesh == null:
		return
	var want := MachineBus.value(input) if input != &"" else 1.0
	if not is_equal_approx(full, want):
		full = move_toward(full, want, fill_speed / maxf(high - low, 0.05) * delta)
		_place()
	MachineBus.set_value(output, full)


func level() -> float:
	return lerpf(low, high, full)


func _place() -> void:
	_mesh.position.y = level()
	_mesh.visible = full > 0.005


func _rebuild() -> void:
	if not is_inside_tree():
		return
	if _mesh:
		_mesh.queue_free()
	_mesh = MeshInstance3D.new()
	if strip.size() >= 2:
		_mesh.mesh = _strip_mesh()
	else:
		var pm := PlaneMesh.new()
		pm.size = size
		pm.subdivide_width = maxi(int(size.x), 1)
		pm.subdivide_depth = maxi(int(size.y), 1)
		_mesh.mesh = pm
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if material:
		var m := material.duplicate() as Material
		if m is ShaderMaterial and flow > 0.0:
			var ws := (m as ShaderMaterial)
			var dir := -(global_basis.z if is_inside_tree() else Vector3.BACK)
			var f := Vector2(dir.x, dir.z).normalized() * flow
			ws.set_shader_parameter(&"scroll_a", f)
			ws.set_shader_parameter(&"scroll_b", f * 0.7 + Vector2(-f.y, f.x) * 0.15)
		_mesh.material_override = m
	add_child(_mesh, false, INTERNAL_MODE_BACK)
	_place()


## The strip's vertex spacing across (metres).
const STRIP_STEP := 2.5


## The `strip` surface: rows zipped into bands, each row split about every STRIP_STEP m.
func _strip_mesh() -> ArrayMesh:
	# Each row split by its own width (a vertex every STRIP_STEP m across), neighbouring rows
	# zipped together (a long thin river no longer carries the widest pool's split on every
	# row; no T-junctions: every triangle uses only the two rows' own vertices).
	var counts := PackedInt32Array()
	var starts := PackedInt32Array()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	var n := 0
	for r in strip:
		var across := maxi(ceili((r.z - r.y) / STRIP_STEP), 1)
		counts.append(across)
		starts.append(n)
		for k in across + 1:
			st.add_vertex(Vector3(lerpf(r.y, r.z, float(k) / across), 0.0, r.x))
		n += across + 1
	for i in strip.size() - 1:
		var na := counts[i]
		var nb := counts[i + 1]
		var a0 := starts[i]
		var b0 := starts[i + 1]
		var ia := 0
		var ib := 0
		while ia < na or ib < nb:
			# (advance along whichever row is behind; counter-clockwise seen from above)
			if ib >= nb or (ia < na and float(ia + 1) / na <= float(ib + 1) / nb):
				st.add_index(a0 + ia); st.add_index(a0 + ia + 1); st.add_index(b0 + ib)
				ia += 1
			else:
				st.add_index(a0 + ia); st.add_index(b0 + ib + 1); st.add_index(b0 + ib)
				ib += 1
	return st.commit()


func prop_bounds() -> AABB:
	if strip.size() >= 2:
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for r in strip:
			lo = Vector2(minf(lo.x, r.y), minf(lo.y, r.x))
			hi = Vector2(maxf(hi.x, r.z), maxf(hi.y, r.x))
		return AABB(Vector3(lo.x, low, lo.y), Vector3(hi.x - lo.x, maxf(high - low, 0.2), hi.y - lo.y))
	return AABB(Vector3(-size.x * 0.5, low, -size.y * 0.5), Vector3(size.x, maxf(high - low, 0.2), size.y))
