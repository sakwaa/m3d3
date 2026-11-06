extends Node
## Conversations. Autoloaded as `Talk`. Runs a Dialogue through a DialogueRunner into the
## DialogueBox; while one is open the clock is held (GameState.hold_clock) and the player
## doesn't move. Talkables register here while the player is near: the interact button
## talks to the best one (the Z-targeted one, else the nearest one in front), and the box
## shows its "E  Talk" prompt.

signal conversation_started(with: Node3D)
signal conversation_ended(with: Node3D)

var box: DialogueBox
var runner: DialogueRunner
## Who the open conversation is with (a Talkable, or null).
var partner: Node3D
var active := false

var _nearby: Array[Node3D] = []
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
	conversation_ended.emit(with)


func register(t: Node3D) -> void:
	if not _nearby.has(t):
		_nearby.append(t)


func unregister(t: Node3D) -> void:
	_nearby.erase(t)


## The Talkable the interact button would talk to now.
func best_talkable() -> Node3D:
	var player := _player()
	if player == null:
		return null
	var locked = player.lock.target if "lock" in player and player.lock else null
	var best: Node3D = null
	var best_score := INF
	for t in _nearby:
		if not is_instance_valid(t) or not t.can_talk():
			continue
		if locked and locked.get_parent() == t:
			return t
		var to: Vector3 = t.global_position - player.global_position
		to.y = 0.0
		var ahead: float = player.facing.dot(to.normalized()) if to.length() > 0.01 else 1.0
		if ahead < -0.2:
			continue
		var score := to.length() - ahead
		if score < best_score:
			best_score = score
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
