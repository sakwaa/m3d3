class_name StateMachine
extends Node
## A set of mutually exclusive ActorStates (its children); exactly one is current. An
## Actor runs several side by side (Locomotion, Action, ...), each for things that can't
## overlap. Switching honours the current state's exit mode, other machines' restrictions
## and priorities; refused requests are buffered briefly and retried, so a button pressed
## just before an animation's cancel window still counts.

signal state_changed(from: StringName, to: StringName)
## A named window of the current state opened / closed (hitboxes, openings...).
signal window_changed(window: StringName, open: bool)

## State entered on start (default: the first child state).
@export var initial_state: StringName
## Seconds a refused request is kept and retried.
@export var buffer_time := 0.25

var actor: Actor
var current: ActorState
var states := {}  # StringName -> ActorState

var _pending: StringName
var _pending_left := 0.0
var _open := {}  # window -> true


func _ready() -> void:
	actor = get_parent() as Actor
	for child in get_children():
		var s := child as ActorState
		if s:
			s.machine = self
			s.actor = actor
			states[s.name] = s
	if states.is_empty():
		push_error("StateMachine %s has no ActorState children." % name)
		return
	var first: ActorState = states.get(initial_state, get_child(0) as ActorState)
	_switch(first, null)


func state_name() -> StringName:
	return current.name if current else &""


## Buffered request waiting to be allowed (empty = none).
func pending() -> StringName:
	return _pending


func is_in(state: StringName) -> bool:
	return current != null and current.name == state


## Asks for `state`. Returns true if it's current now. A refused request is buffered for
## `buffer_time` (the latest one wins). `force` skips every check (cutscenes, resets).
func request(state: StringName, force := false) -> bool:
	var target: ActorState = states.get(state)
	if target == null:
		push_error("StateMachine %s: no state '%s'." % [name, state])
		return false
	if target == current:
		_pending = &""
		return true
	if not force and not _allowed(target):
		_pending = state
		_pending_left = buffer_time
		return false
	_pending = &""
	_switch(target, current)
	return true


## Can `target` be entered now?
func _allowed(target: ActorState) -> bool:
	if not target.can_enter():
		return false
	var outranks := current != null and target.priority > current.priority
	# Restrictions from the other machines' current states.
	for other: StateMachine in actor.machines:
		if other == self or other.current == null or not other.current.restrict.has(name):
			continue
		if target.priority > other.current.priority:
			continue
		var allowed: PackedStringArray = other.current.restrict[name]
		if not allowed.has(target.name):
			return false
	# What the target restricts: machines it would have to switch must be free to switch
	# (an attack waits for a landing to finish rather than cutting it).
	for machine_name in target.restrict:
		var other := actor.machine(machine_name)
		if other == null or other == self or other.current == null:
			continue
		var wanted: PackedStringArray = target.restrict[machine_name]
		if wanted.is_empty() or wanted.has(other.current.name):
			continue
		var into: ActorState = other.states.get(wanted[0])
		if into == null or not into.can_enter():
			return false
		if not other.current.can_leave() and target.priority <= other.current.priority:
			return false
	return outranks or current == null or current.can_leave()


func _switch(target: ActorState, previous: ActorState) -> void:
	if previous:
		previous.exit(target)
	for w in _open:
		window_changed.emit(w, false)
	_open.clear()
	var phase := previous.progress() if previous and previous.is_loop() else 0.0
	current = target
	target.time = 0.0
	if actor:
		# A bound animation's length and windows win over the placeholders.
		actor._bind_animation(target)
	if target.sync_phase and target.is_loop() and target.length > 0.0:
		target.time = phase * target.length
	target.enter(previous)
	# Pull other machines into what this state allows.
	for machine_name in target.restrict:
		var other := actor.machine(machine_name) if actor else null
		if other == null or other.current == null:
			continue
		var allowed: PackedStringArray = target.restrict[machine_name]
		if not allowed.is_empty() and not allowed.has(other.current.name):
			other.request(allowed[0], true)
	var from := previous.name if previous else &""
	state_changed.emit(from, target.name)
	if actor and actor.debug_log:
		print("[%s] %s: %s -> %s" % [actor.name, name, from, target.name])


## Called by the Actor every physics frame, before it moves.
func tick(delta: float) -> void:
	if current == null:
		return
	current.time += delta
	current.update(delta)
	# Windows opening / closing.
	for w in current.windows:
		var open := current.in_window(w)
		if open != _open.has(w):
			if open:
				_open[w] = true
			else:
				_open.erase(w)
			window_changed.emit(w, open)
	# Buffered request, then the state's own follow-up.
	if _pending != &"":
		_pending_left -= delta
		var p := _pending
		if _pending_left <= 0.0:
			_pending = &""
		else:
			request(p)
	if current.finished() and current.next_state != &"" and _pending == &"":
		request(current.next_state, true)
