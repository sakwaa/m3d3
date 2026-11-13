@tool
class_name StrikePoint
extends Node3D
## A place on a body a sword can land: the head, the flank, a shield. Add it as a child of
## the character's model scene (Scene dock: Add Child Node > StrikePoint; it stays in exports)
## or of the actor, pick its `bone` from the skeleton's list, and set where it sits
## (`offset`, in the model's space: +X right, +Y up, -Z forward) and which way it faces out
## (`normal`; zero = every way). In the editor it shows as a sphere on its bone (green open,
## grey armour, blue guard) with a line out along its normal.
## Attackers aim their swings at the best OPEN point facing them (Combat.aim_swing: the head
## from the front, the flank from the side); the blade's sweep then decides what it meets
## first (Combat):
##   OPEN   takes the hit, `damage_scale` times the swing's damage;
##   ARMOR  turns blades no stronger than its `hardness` (ricochet: the attacker recoils,
##          sparks, the part flashes); a stronger blade cuts through it;
##   GUARD  like ARMOR, but only while its actor guards (a raised shield, claws up).
## Blade strength: the sword's BladeTrigger.power.

enum Kind { OPEN, ARMOR, GUARD }

## Hardness by kind when `hardness` is -1: flesh, a guard (wood, claws), armour.
const DEFAULT_HARDNESS := {Kind.OPEN: 0, Kind.GUARD: 1, Kind.ARMOR: 2}

@export var kind := Kind.OPEN:
	set(v):
		kind = v
		_redraw()
@export var bone: StringName:
	set(v):
		bone = v
		_bone = -1
@export var offset := Vector3.ZERO
@export var normal := Vector3.ZERO:
	set(v):
		normal = v
		_redraw()
@export_range(0.02, 1.5, 0.01, "suffix:m") var radius := 0.2:
	set(v):
		radius = v
		_redraw()
@export var damage_scale := 1.0
## Blades with power up to this are turned (ARMOR / GUARD); -1 = the kind's default
## (guard 1, armour 2). 3+ turns every blade we have.
@export_range(-1, 5) var hardness := -1
## The part's name (head, flank...), for logs and the sandbox.
@export var part := ""

## Draw every strike point while playing (the sandbox's P); always drawn in the editor.
static var show := false

var actor: Actor
var _debug: MeshInstance3D
var _skeleton: Skeleton3D
var _bone := -1


func _init(p_kind := Kind.OPEN, p_bone := &"", p_offset := Vector3.ZERO, p_normal := Vector3.ZERO, p_radius := 0.2,
		p_scale := 1.0, p_part := "") -> void:
	kind = p_kind
	bone = p_bone
	offset = p_offset
	normal = p_normal
	radius = p_radius
	damage_scale = p_scale
	part = p_part
	name = "Strike_" + (p_part if p_part != "" else String(p_bone))


func _enter_tree() -> void:
	top_level = true
	var n := get_parent()
	while n and not n is Actor:
		n = n.get_parent()
	actor = n as Actor
	if actor and not Engine.is_editor_hint():
		var list: Array = actor.get_meta(&"strike_points", [])
		list.append(self)
		actor.set_meta(&"strike_points", list)


func _exit_tree() -> void:
	if actor and actor.has_meta(&"strike_points"):
		(actor.get_meta(&"strike_points") as Array).erase(self)


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		place()
		_draw_debug()


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	place()
	if show or _debug:
		_draw_debug()


## The model / body it's placed against (the actor's body, else its parent).
func _frame() -> Node3D:
	if actor and actor.body:
		return actor.body
	var p := get_parent() as Node3D
	return p if p else self


## Moves onto its bone now (Combat calls this before testing a sweep).
func place() -> void:
	var frame := _frame()
	var at := frame.global_position
	if bone != &"":
		if _skeleton == null or not is_instance_valid(_skeleton):
			var root: Node = actor if actor else get_parent()
			var found: Array = root.find_children("*", "Skeleton3D", true, false) if root else []
			_skeleton = found[0] if not found.is_empty() else null
			_bone = -1
		if _skeleton and _bone < 0:
			_bone = _skeleton.find_bone(bone)
		if _skeleton and _bone >= 0:
			at = _skeleton.global_transform * _skeleton.get_bone_global_pose(_bone).origin
	global_position = at + frame.global_basis * offset


## Out of the body (world), or zero for every way.
func world_normal() -> Vector3:
	if normal == Vector3.ZERO:
		return Vector3.ZERO
	return (_frame().global_basis * normal).normalized()


## How much it faces someone at `from`: 1 straight at them, 0 side on, < 0 away.
func exposure(from: Vector3) -> float:
	var n := world_normal()
	if n == Vector3.ZERO:
		return 1.0
	var to := from - global_position
	to.y *= 0.3  # (height matters less than which side)
	return n.dot(to.normalized())


func hardness_value() -> int:
	return hardness if hardness >= 0 else DEFAULT_HARDNESS[kind]


## Up now: ARMOR always, GUARD while its actor guards.
func defends() -> bool:
	match kind:
		Kind.ARMOR:
			return true
		Kind.GUARD:
			return actor != null and actor.state_of(Actor.ACTION) is GuardState
	return false


## Turns a blade of `power` swung from `from`: up, facing that way (a shield covers its
## front, not its edge), and at least as hard as the blade is strong.
func defends_from(from: Vector3, power := 1) -> bool:
	return defends() and exposure(from) > 0.25 and hardness_value() >= power


## Can be struck by a blade of `power` from `from`: an open point on the near side of the
## body, or armour / a raised guard the blade is strong enough to cut through.
func takes_from(from: Vector3, power := 1) -> bool:
	if kind == Kind.OPEN:
		return exposure(from) >= -0.1
	return defends() and exposure(from) > 0.25 and power > hardness_value()


## Of `who` (all its points: on the actor and in its model).
static func of(who: Actor) -> Array[StrikePoint]:
	var out: Array[StrikePoint] = []
	if who:
		for p in who.get_meta(&"strike_points", []):
			if is_instance_valid(p):
				out.append(p)
	return out


# --- Editor ------------------------------------------------------------------------------------

func _validate_property(property: Dictionary) -> void:
	# The bone as a list of the skeleton's bones.
	if property.name == "bone" and Engine.is_editor_hint() and is_inside_tree():
		var root: Node = get_parent()
		var found: Array = root.find_children("*", "Skeleton3D", true, false) if root else []
		if not found.is_empty():
			var sk: Skeleton3D = found[0]
			var names := PackedStringArray([""])
			for i in sk.get_bone_count():
				names.append(sk.get_bone_name(i))
			property.hint = PROPERTY_HINT_ENUM_SUGGESTION
			property.hint_string = ",".join(names)


func _redraw() -> void:
	if _debug:
		_debug.queue_free()
		_debug = null


func _draw_debug() -> void:
	if _debug == null:
		_debug = MeshInstance3D.new()
		var m := SphereMesh.new()
		m.radius = radius
		m.height = radius * 2.0
		m.radial_segments = 12
		m.rings = 6
		_debug.mesh = m
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.no_depth_test = true
		_debug.material_override = mat
		add_child(_debug, false, INTERNAL_MODE_BACK)
		if normal != Vector3.ZERO:
			var line := MeshInstance3D.new()
			var im := ImmediateMesh.new()
			im.surface_begin(Mesh.PRIMITIVE_LINES)
			im.surface_add_vertex(Vector3.ZERO)
			im.surface_add_vertex(normal.normalized() * (radius + 0.25))
			im.surface_end()
			line.mesh = im
			line.material_override = mat
			_debug.add_child(line)
	_debug.visible = show or Engine.is_editor_hint()
	_debug.global_basis = _frame().global_basis
	var c := Color(0.2, 1.0, 0.3)
	match kind:
		Kind.ARMOR:
			c = Color(0.7, 0.7, 0.7)
		Kind.GUARD:
			c = Color(0.3, 0.5, 1.0) if defends() or Engine.is_editor_hint() else Color(0.2, 0.25, 0.45)
	(_debug.material_override as StandardMaterial3D).albedo_color = Color(c, 0.35)
