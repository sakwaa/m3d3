class_name Arrow
extends Node3D
## A shot arrow: flies straight at `speed` along `dir` for `straight_range` metres (so it
## lands on the reticle: AimState aims it from the nock at the point the reticle ray hit),
## then falls. Each physics tick it sweeps a ray from where it was to where it is: an actor
## takes the hit (Actor.take_hit, pushed along the flight); anything else, it sticks in and
## stays a while. Moved on physics ticks (drawn interpolated between them).

const GRAVITY := 9.8
const STUCK_TIME := 8.0
const MAX_TIME := 6.0
const LENGTH := 0.75

var shooter: Actor
var velocity := Vector3.ZERO
var damage := 1
var knockback := 2.0
var straight_range := 60.0
var _flown := 0.0
var _life := 0.0
var _stuck := false
var _exclude: Array[RID] = []


func _init() -> void:
	name = "Arrow"
	top_level = true
	_build_mesh()


## Sets it flying from `from` along `dir` (unit) at `speed`.
func launch(from: Vector3, dir: Vector3, speed: float, by: Actor, item: AimItem) -> void:
	shooter = by
	damage = item.damage
	knockback = item.knockback
	straight_range = item.straight_range
	velocity = dir * speed
	global_position = from
	_face(dir)
	if by is CollisionObject3D:
		_exclude.append((by as CollisionObject3D).get_rid())
	reset_physics_interpolation()


func _physics_process(delta: float) -> void:
	_life += delta
	if _stuck:
		if _life > STUCK_TIME:
			queue_free()
		return
	if _life > MAX_TIME:
		queue_free()
		return
	if _flown > straight_range:
		velocity.y -= GRAVITY * delta
	var from := global_position
	var to := from + velocity * delta
	var q := PhysicsRayQueryParameters3D.create(from, to + velocity.normalized() * LENGTH * 0.5)
	q.exclude = _exclude
	q.collide_with_areas = false
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		_hit(hit)
		return
	_flown += from.distance_to(to)
	global_position = to
	_face(velocity)


func _hit(hit: Dictionary) -> void:
	var at: Vector3 = hit.position
	var actor := _actor_of(hit.collider)
	if actor and actor != shooter and not actor.is_dead():
		var dir := velocity.normalized()
		actor.take_hit(damage, shooter, knockback, {dir = dir, at = at, strength = 0.6})
		queue_free()
		return
	# Stuck in: the tip a little way in, left there.
	_stuck = true
	_life = 0.0
	global_position = at - velocity.normalized() * (LENGTH * 0.5 - 0.06)
	_face(velocity)


static func _actor_of(n: Object) -> Actor:
	var node := n as Node
	while node:
		if node is Actor:
			return node
		node = node.get_parent()
	return null


func _face(dir: Vector3) -> void:
	if dir.length() < 0.001:
		return
	var up := Vector3.UP if absf(dir.normalized().y) < 0.98 else Vector3.RIGHT
	global_basis = Basis.looking_at(dir, up)


## A low-poly arrow along -Z (its local forward), centred: shaft, head, fletching.
func _build_mesh() -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = build_mesh()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


static func build_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var shaft := Color(0.55, 0.4, 0.24)
	var head := Color(0.62, 0.64, 0.68)
	var fletch := Color(0.85, 0.82, 0.74)
	var h := LENGTH * 0.5
	var w := 0.012
	# Shaft: a thin square tube.
	_box(st, Vector3(-w, -w, -h + 0.06), Vector3(w, w, h), shaft)
	# Head: a flat diamond each way.
	for side in [Vector3.RIGHT, Vector3.UP]:
		var s: Vector3 = side * 0.035
		_tri(st, Vector3(0, 0, -h - 0.07), Vector3(0, 0, -h + 0.06) + s, Vector3(0, 0, -h + 0.06) - s, head)
	# Fletching: two crossed vanes at the tail.
	for side in [Vector3.RIGHT, Vector3.UP]:
		var s: Vector3 = side * 0.045
		_quad(st, Vector3(0, 0, h - 0.16), Vector3(0, 0, h - 0.16) + s, Vector3(0, 0, h) + s, Vector3(0, 0, h), fletch)
		_quad(st, Vector3(0, 0, h - 0.16), Vector3(0, 0, h), Vector3(0, 0, h) - s, Vector3(0, 0, h - 0.16) - s, fletch)
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)
	return mesh


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	for v in [a, b, c]:
		st.set_color(col)
		st.add_vertex(v)


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	_tri(st, a, b, c, col)
	_tri(st, a, c, d, col)


static func _box(st: SurfaceTool, lo: Vector3, hi: Vector3, col: Color) -> void:
	var p := [Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(lo.x, hi.y, lo.z),
		Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z)]
	for f in [[0, 1, 2, 3], [5, 4, 7, 6], [4, 0, 3, 7], [1, 5, 6, 2], [3, 2, 6, 7], [4, 5, 1, 0]]:
		_quad(st, p[f[0]], p[f[1]], p[f[2]], p[f[3]], col.darkened(0.15 * (f[0] % 3)))
