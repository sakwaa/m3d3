class_name Npc
extends Actor
## A townsperson. Placed by hand (stands where it is, talks with `dialogue`) or spawned by
## Schedules from an NpcSchedule, which moves its `goal` along paths and between spots as
## the clock runs. Walks towards the goal (runs to catch up when it has fallen behind,
## jumps there when it's far off, e.g. after a time skip), turns to the spot's facing
## when it arrives, and nudges the player out of its way rather than waiting. Faces the
## player while talking; the clock (and so the schedule) is held meanwhile.

const BODY_RADIUS := 0.3
const BODY_HEIGHT := 1.6
## Further than this from the goal, it's put there instead of walking.
const SNAP_DISTANCE := 8.0
## Further than this behind, it runs.
const CATCH_UP := 1.2
const ARRIVED := 0.15
const PUSH := 2.6

## CharacterDef id: name, model, voice, walking speed.
@export var character := &""
## Hand-placed NPCs: what they say.
@export var dialogue: Dialogue
@export var dialogue_entry := ""

## Scheduled NPCs: set by Schedules.
var schedule: NpcSchedule
var entry: ScheduleEntry
var goal := Vector3.ZERO
var goal_facing := Vector3.ZERO
var walking := false

var talkable: Talkable
var _def: CharacterDef
var _talking := false
var _idle: LocoGround


func _ready() -> void:
	var db: StoryDatabase = get_node(^"/root/GameState").story if has_node(^"/root/GameState") else StoryDatabase.load_project()
	_def = db.find_character(character) if db else null
	if goal == Vector3.ZERO:
		goal = global_position
	floor_snap_length = 0.3
	var capsule := CapsuleShape3D.new()
	capsule.radius = BODY_RADIUS
	capsule.height = BODY_HEIGHT
	var shape := CollisionShape3D.new()
	shape.shape = capsule
	shape.position.y = BODY_HEIGHT * 0.5
	add_child(shape)
	body = Node3D.new()
	body.name = "Body"
	add_child(body)
	if _def and _def.model:
		body.add_child(_def.model.instantiate())
	else:
		body.add_child(_stand_in(_def.name_color if _def else Color(0.8, 0.7, 0.6)))
	_build_machines()
	talkable = Talkable.new()
	talkable.prompt = "Talk"
	talkable.radius = 1.6
	add_child(talkable)
	_update_dialogue()
	add_child(ProjectedShadow.new())
	var talk := get_node_or_null(^"/root/Talk")
	if talk:
		talk.conversation_started.connect(_on_talk_started)
		talk.conversation_ended.connect(_on_talk_ended)
	super._ready()
	if not goal_facing.is_zero_approx():
		facing = goal_facing


## Capsule in the character's colour with a nose, until there's a model.
static func _stand_in(color: Color) -> Node3D:
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = BODY_RADIUS
	mesh.height = BODY_HEIGHT
	mesh.radial_segments = 8
	mesh.rings = 2
	mi.mesh = mesh
	mi.position.y = BODY_HEIGHT * 0.5
	mi.material_override = N64Materials.actor(color, null, N64Materials.Shine.NONE, 0.7, 1.0)
	root.add_child(mi)
	var nose := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.12, 0.12, 0.2)
	nose.mesh = box
	nose.position = Vector3(0, BODY_HEIGHT * 0.8, -BODY_RADIUS)
	nose.material_override = N64Materials.actor(color.darkened(0.4), null, N64Materials.Shine.NONE, 0.7, 1.0)
	root.add_child(nose)
	return root


func _build_machines() -> void:
	var loco := StateMachine.new()
	loco.name = "Locomotion"
	var speed := _def.walk_speed if _def else 1.4
	_idle = LocoGround.new()
	_idle.name = "Idle"
	_idle.idle_state = &""
	_idle.move_state = &"Walk"
	_idle.jump_state = &""
	_idle.speed = 0.0
	var walk := LocoGround.new()
	walk.name = "Walk"
	walk.faster = &"Run"
	walk.jump_state = &""
	walk.speed = speed
	var run := LocoGround.new()
	run.name = "Run"
	run.slower = &"Walk"
	run.jump_state = &""
	run.speed = speed * 2.2
	var fall := LocoAir.new()
	fall.name = "Fall"
	fall.land_state = &"Idle"
	for s in [_idle, walk, run, fall]:
		loco.add_child(s)
	add_machine(loco)


## Moves the goal (Schedules, every frame). `snap` puts the NPC there at once.
func set_goal(at: Vector3, face: Vector3, is_walking: bool, snap := false) -> void:
	goal = at
	goal_facing = face
	walking = is_walking
	if snap and is_inside_tree():
		global_position = at
		velocity = Vector3.ZERO
		if not face.is_zero_approx():
			facing = face


## The schedule part changed (Schedules): its dialogue and animation.
func set_entry(e: ScheduleEntry) -> void:
	entry = e
	_update_dialogue()
	if _idle:
		var anim := e.animation if e and e.activity == ScheduleEntry.Activity.STAY else &""
		if _idle.animation != anim:
			_idle.animation = anim
			play_state_animation()


func _update_dialogue() -> void:
	if talkable == null:
		return
	if entry and entry.dialogue:
		talkable.dialogue = entry.dialogue
		talkable.entry = entry.dialogue_entry
	elif schedule and schedule.dialogue:
		talkable.dialogue = schedule.dialogue
		talkable.entry = ""
	else:
		talkable.dialogue = dialogue
		talkable.entry = dialogue_entry


func drive(delta: float) -> void:
	if scripted:
		return  # a cutscene sets intent
	intent.clear()
	if _talking:
		return
	var to := goal - global_position
	to.y = 0.0
	var d := to.length()
	if d > SNAP_DISTANCE:
		set_goal(goal, goal_facing, walking, true)
		return
	if d > ARRIVED:
		intent.move = to / d * (1.0 if d > CATCH_UP else 0.5)
		_push_player(to / d)
	elif not goal_facing.is_zero_approx():
		facing = facing.slerp(goal_facing.normalized(), clampf(6.0 * delta, 0.0, 1.0)).normalized()


## Walks through the player (no collision between them) and shoves them aside.
func _push_player(dir: Vector3) -> void:
	var player := get_tree().get_first_node_in_group(&"player") as Actor
	if player == null:
		return
	add_collision_exception_with(player)
	var to := player.global_position - global_position
	to.y = 0.0
	var d := to.length()
	if d > 0.9 or d < 0.001 or dir.dot(to / d) < 0.2:
		return
	# Out to the side they're already on.
	var side := dir.cross(Vector3.UP)
	side = side if side.dot(to) >= 0.0 else -side
	player.impulse = (side * 0.8 + dir * 0.4).normalized() * PUSH


func _on_talk_started(with: Node3D) -> void:
	if with == talkable:
		_talking = true
		face_target = get_tree().get_first_node_in_group(&"player") as Node3D


func _on_talk_ended(with: Node3D) -> void:
	if with == talkable:
		_talking = false
		face_target = null
