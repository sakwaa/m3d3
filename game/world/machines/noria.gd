@tool
class_name Noria
extends Node3D
## A noria (a machine part prop): a great undershot water wheel, Hama style. Water flowing
## under it pushes its paddles round; buckets on its rim fill at the bottom, rise, and tip at
## the crest into a trough that runs off to the side (the start of an aqueduct). It turns only
## once `input` (the water under it: a MachineWater's output) reaches `threshold` - shallower
## water doesn't reach the paddles - spinning up and down slowly (it's heavy). Writes how fast
## it's running (0..1) to `output`: what the machine past the aqueduct runs on.
## Origin: the ground under the axle's middle; the axle along local X; the water under it flows
## along -Z (the crest moves towards +Z, where the trough is).

@export var input := &""
@export var output := &""
## Input this full before the water reaches the paddles.
@export_range(0.0, 1.0, 0.01) var threshold := 0.98
@export_range(1.0, 30.0, 0.1, "suffix:m") var radius := 6.0:
	set(v):
		radius = v
		_rebuild()
@export_range(0.5, 6.0, 0.1, "suffix:m") var width := 1.8:
	set(v):
		width = v
		_rebuild()
## How far the wheel's foot dips below the origin (into its channel).
@export_range(0.0, 5.0, 0.05, "suffix:m") var dip := 0.6:
	set(v):
		dip = v
		_rebuild()
@export_range(6, 48) var buckets := 16:
	set(v):
		buckets = v
		_rebuild()
## Turns a minute at full power.
@export_range(0.1, 10.0, 0.1) var rpm := 2.0
## Seconds to spin up to full (and down again).
@export_range(0.5, 30.0, 0.5, "suffix:s") var spin_up := 6.0
## The trough at the crest: how far it runs off to the side (+X).
@export_range(0.0, 30.0, 0.1, "suffix:m") var trough_length := 4.0:
	set(v):
		trough_length = v
		_rebuild()
## The trough runs off along -X instead (the wheel's other side).
@export var trough_flip := false:
	set(v):
		trough_flip = v
		_rebuild()
@export var stone_texture: Texture2D = preload("res://textures/rock/granite_1.res"):
	set(v):
		stone_texture = v
		_rebuild()
@export var wood_texture: Texture2D = preload("res://textures/wood/wood_2.res"):
	set(v):
		wood_texture = v
		_rebuild()

const POUR_SHADER := preload("res://game/world/machines/n64_pour.gdshader")

## Running 0..1 (its speed, of full).
var running := 0.0
var _rotor: Node3D
var _pour: Array[MeshInstance3D] = []
var _creak := 0.0


func _ready() -> void:
	_rebuild()


func axle_height() -> float:
	return radius - dip


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or _rotor == null:
		return
	var powered := input == &"" or MachineBus.value(input) >= threshold
	running = move_toward(running, 1.0 if powered else 0.0, delta / spin_up)
	var w := running * running * (3.0 - 2.0 * running) * rpm * TAU / 60.0  # (eased: heavy)
	_rotor.rotation.x += w * delta
	for p in _pour:
		var m := p.material_override as ShaderMaterial
		m.set_shader_parameter(&"amount", clampf(running * 1.5 - 0.3, 0.0, 1.0))
		p.visible = running > 0.2
	# A creak each eighth of a turn while it moves.
	if w > 0.01:
		_creak += w * delta
		if _creak > TAU / 8.0:
			_creak = 0.0
			Sfx.play(&"block_slide", global_position + Vector3.UP * axle_height(), 0.35 + running * 0.1, -8.0)
	MachineBus.set_value(output, running)


func _rebuild() -> void:
	if not is_inside_tree():
		return
	for c in get_children(true):
		if c.has_meta(&"noria_part"):
			c.queue_free()
	_pour.clear()
	var stone := N64Materials.textured(Color(0.6, 0.57, 0.52), stone_texture)
	var wood := N64Materials.textured(Color(0.5, 0.4, 0.3), wood_texture)
	var dark := N64Materials.textured(Color(0.36, 0.29, 0.22), wood_texture)
	var ah := axle_height()
	# Piers either side, up to the axle, and the axle.
	for sx in [-1.0, 1.0]:
		var pier := _box(Vector3(0.9, ah + 0.6, 1.6), Vector3(sx * (width * 0.5 + 0.7), (ah + 0.6) * 0.5 - 0.3, 0.0), stone, self, true)
		pier.set_meta(&"noria_part", true)
	_rotor = Node3D.new()
	_rotor.set_meta(&"noria_part", true)
	add_child(_rotor, false, INTERNAL_MODE_BACK)
	_rotor.position = Vector3.UP * ah
	var axle := MeshInstance3D.new()
	var am := CylinderMesh.new()
	am.top_radius = 0.35
	am.bottom_radius = 0.35
	am.height = width + 2.2
	am.radial_segments = 8
	axle.mesh = am
	axle.material_override = dark
	axle.rotation.z = PI * 0.5
	_rotor.add_child(axle)
	# Rims (two polygon rings), spokes, paddles and buckets.
	var n := buckets
	for side in [-1.0, 1.0]:
		var x: float = side * width * 0.5
		for k in n:
			var a0 := TAU * k / n
			var a1 := TAU * (k + 1) / n
			var p0 := Vector3(x, sin(a0) * radius, cos(a0) * radius)
			var p1 := Vector3(x, sin(a1) * radius, cos(a1) * radius)
			_beam(p0, p1, 0.22, wood, _rotor)
		for k in 8:
			var a := TAU * k / 8.0 + 0.2
			_beam(Vector3(x, 0, 0), Vector3(x, sin(a) * radius, cos(a) * radius), 0.18, wood, _rotor)
	for k in n:
		var a := TAU * (k + 0.5) / n
		var out := Vector3(0, sin(a), cos(a))
		var tan := Vector3(0, cos(a), -sin(a))
		# A paddle sticking out past the rim (what the water pushes) and a bucket inside it.
		var paddle := _box(Vector3(width, 0.06, 0.55), out * (radius + 0.2), dark, _rotor, false)
		paddle.basis = Basis.looking_at(tan, out)
		var bucket := _box(Vector3(width * 0.9, 0.45, 0.6), out * (radius - 0.35) - tan * 0.15, wood, _rotor, false)
		bucket.basis = Basis.looking_at(tan, out)
	# Trough at the crest, on the +Z side, running off along +X; the pour into it.
	var crest := Vector3(0, ah + radius - 0.9, 0.9)
	var tl := trough_length + width * 0.5 + 0.6
	var ts := -1.0 if trough_flip else 1.0
	var trough := _box(Vector3(tl, 0.35, 1.0), crest + Vector3(ts * (tl * 0.5 - width * 0.5 - 0.3), -0.2, 0.0), stone, self, true)
	trough.set_meta(&"noria_part", true)
	for k in 3:
		var p := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(width * 0.28, 1.0)
		p.mesh = q
		var m := ShaderMaterial.new()
		m.shader = POUR_SHADER
		m.set_shader_parameter(&"seed", float(k) * 1.7)
		p.material_override = m
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		p.set_meta(&"noria_part", true)
		add_child(p, false, INTERNAL_MODE_BACK)
		p.position = crest + Vector3((k - 1) * width * 0.3, 0.55, -0.1)
		p.visible = false
		_pour.append(p)


func _box(size: Vector3, at: Vector3, mat: Material, parent: Node, solid: bool) -> Node3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	if solid:
		var body := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		cs.shape = shape
		body.add_child(cs)
		body.add_child(mi)
		body.position = at
		if parent == self:
			add_child(body, false, INTERNAL_MODE_BACK)
		else:
			parent.add_child(body)
		return body
	mi.position = at
	if parent == self:
		mi.set_meta(&"noria_part", true)
		add_child(mi, false, INTERNAL_MODE_BACK)
	else:
		parent.add_child(mi)
	return mi


## A beam from a to b (in `parent`'s space).
func _beam(a: Vector3, b: Vector3, thick: float, mat: Material, parent: Node3D) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(thick, thick, a.distance_to(b) + thick)
	mi.mesh = bm
	mi.material_override = mat
	parent.add_child(mi)
	var mid := (a + b) * 0.5
	var up := Vector3.RIGHT if absf((b - a).normalized().dot(Vector3.RIGHT)) < 0.9 else Vector3.UP
	mi.position = mid
	mi.basis = Basis.looking_at(b - a, up)


func prop_bounds() -> AABB:
	var r := radius + 0.6
	var x0 := -width * 0.5 - 1.2 - (trough_length if trough_flip else 0.0)
	return AABB(Vector3(x0, -dip, -r), Vector3(width + 2.4 + trough_length, radius * 2.0 + 0.6, r * 2.0))
