extends Node
## Conversations. Autoloaded as `Talk`. Runs a Dialogue through a DialogueRunner into the
## DialogueBox; while one is open the clock is held (GameState.hold_clock) and the player
## doesn't move. Talkables register here while the player is near: the interact button
## talks to the best one (the Z-targeted one, else the nearest offering), and the box
## shows its "E  Talk" prompt.

signal conversation_started(with: Node3D)
signal conversation_ended(with: Node3D)

var box: DialogueBox
var runner: DialogueRunner
## Who the open conversation is with (a Talkable, or null).
var partner: Node3D
var active := false

var _cooldown := 0.0


func _ready() -> void:
	box = DialogueBox.new()
	add_child(box)
	box.advanced.connect(func(): _show(runner.advance()))
	box.chosen.connect(func(i: int): _show(runner.choose(i)))
	runner = DialogueRunner.new(GameState)


## Starts a conversation (does nothing while one is open).
func start(dialogue: Dialogue, entry := "", with: Node3D = null) -> void:
	if active or dialogue == null:
		return
	active = true
	partner = with
	GameState.hold_clock(self)
	var player := _player()
	if player:
		player.set_controlled(false)
		if with:
			var to := with.global_position - player.global_position
			to.y = 0.0
			if to.length() > 0.01:
				player.face(to.normalized())
	conversation_started.emit(with)
	_show(runner.start(dialogue, entry))


func _show(event: Dictionary) -> void:
	match event.type:
		"line":
			box.show_line(event)
		"choice":
			box.show_choice(event)
		_:
			_end()


func _end() -> void:
	box.close()
	active = false
	_cooldown = 0.25
	GameState.release_clock(self)
	var player := _player()
	if player:
		player.set_controlled(true)
	var with := partner
	partner = null
	if with is Talkable:
		with.ready_at = Time.get_ticks_msec() * 0.001 + with.cooldown
	conversation_ended.emit(with)


## The Talkable the interact button would talk to now (MM): the Z-targeted one wherever it
## is (while locked onto anything else, nobody); else the nearest (flat distance) offering
## to the player - inside its cylinder and facing gate. Not in the air.
func best_talkable() -> Node3D:
	var player := _player()
	if player == null:
		return null
	if player is CharacterBody3D and not (player as CharacterBody3D).is_on_floor():
		return null
	var lock: TargetLock = player.lock if "lock" in player else null
	if lock and lock.target:
		var t := lock.target.get_parent() as Talkable
		return t if t and t.can_talk() and t.in_gate(player.global_position) else null
	var best: Node3D = null
	var best_d := INF
	for t: Talkable in get_tree().get_nodes_in_group(Talkable.GROUP):
		if not t.can_talk() or not t.offers_to(player.global_position):
			continue
		var to: Vector3 = t.global_position - player.global_position
		var d := Vector2(to.x, to.z).length()
		if d < best_d:
			best_d = d
			best = t
	return best


func _process(delta: float) -> void:
	_cooldown = maxf(_cooldown - delta, 0.0)
	var t: Node3D = best_talkable() if not active else null
	box.set_prompt(t.prompt if t else "")


func _unhandled_input(event: InputEvent) -> void:
	if active or _cooldown > 0.0 or not event.is_action_pressed(&"interact") or event.is_echo():
		return
	var t: Node3D = best_talkable()
	if t:
		get_viewport().set_input_as_handled()
		t.talk()


func _player() -> Node3D:
	return get_tree().get_first_node_in_group(&"player") as Node3D
