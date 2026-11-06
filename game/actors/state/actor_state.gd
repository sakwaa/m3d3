class_name ActorState
extends Node
## One discrete state of a StateMachine (Idle, Run, Attack...). Only one state per machine
## is active; machines run side by side (Locomotion, Action...) and can restrict each
## other while a state is active (`restrict`).
##
## Timing: `length` seconds, or the bound animation's length; 0 = loops forever. Leaving is
## governed by `exit`; `next_state` follows when the time runs out. Named `windows`
## (fractions of the length) mark moments others can query: "cancel" (when WINDOW states
## may be left), and for combat e.g. "active" (hitbox live) or "opening" (vulnerable).
## Extend it for states with their own logic (update() / enter() / exit()).

enum Exit {
	ANYTIME,  ## Switch as soon as asked (idle, walk, run loops).
	FINISH,   ## Requests wait until the time runs out (landing, opening a chest).
	WINDOW,   ## Can only be left inside the "cancel" window (attacks, rolls: combos).
}

## Animation played on enter, if the actor has an AnimationPlayer with it.
@export var animation: StringName
## Seconds; 0 = loops until left. A bound animation's length wins over this.
@export var length := 0.0
@export var exit_mode := Exit.ANYTIME
## Entered when the time runs out (non-looping states). Empty = hold the last moment.
@export var next_state: StringName
## Requests for a state with higher priority interrupt anything lower, whatever its exit
## mode or restrictions (hurt, stagger, death).
@export var priority := 0
## Animation cross-fade into this state.
@export var blend_time := 0.1
## Looping states: start at the same point of the cycle as the looping state before
## (walk -> run keeps the feet in step).
@export var sync_phase := false
## Named windows, as fractions of the length (x = from, y = to).
@export var windows: Dictionary[StringName, Vector2] = {}
## Other machines -> the only states they may be in while this one is active (they're
## switched to the first if needed). An empty list freezes that machine.
@export var restrict: Dictionary[StringName, PackedStringArray] = {}
## Movement speed (m/s) while this state is active; < 0 = no opinion (keeps momentum).
@export var speed := -1.0
## Multiplies the actor's movement while active (0 = rooted).
@export var move_scale := 1.0
## Whether the actor may turn to face its movement while active.
@export var can_turn := true
## Free-form labels for other systems ("guarding", "airborne", "stunned"...).
@export var tags: PackedStringArray
## Can't be entered while any machine's current state has one of these tags (e.g. ground
## attacks: "airborne").
@export var blocked_by_tags: PackedStringArray

var machine: StateMachine
var actor: Actor
## Seconds since entered (wraps for loops only through progress()).
var time := 0.0


## 0..1 through the state (looping states wrap).
func progress() -> float:
	if length <= 0.0:
		return 0.0
	return fposmod(time, length) / length if is_loop() else clampf(time / length, 0.0, 1.0)


func is_loop() -> bool:
	return next_state == &"" and exit_mode == Exit.ANYTIME and animation_loops()


## Looping when it has no fixed end (length 0) or its animation loops.
func animation_loops() -> bool:
	return length <= 0.0 or (actor and actor.animation_loops(actor.state_animation(self)))


func finished() -> bool:
	return length > 0.0 and not is_loop() and time >= length


func in_window(window: StringName) -> bool:
	if not windows.has(window):
		return false
	var w: Vector2 = windows[window]
	var p := progress()
	return p >= w.x and p <= w.y


func has_tag(tag: StringName) -> bool:
	return tags.has(tag)


## Whether the machine may leave this state now (without priority).
func can_leave() -> bool:
	match exit_mode:
		Exit.FINISH:
			return finished()
		Exit.WINDOW:
			return finished() or in_window(&"cancel")
	return true


## Extra conditions for entering; extend with super.can_enter() when overriding.
func can_enter() -> bool:
	for tag in blocked_by_tags:
		if actor.has_tag(tag):
			return false
	return true


## Override hooks.
func enter(_previous: ActorState) -> void:
	pass


func exit(_next: ActorState) -> void:
	pass


func update(_delta: float) -> void:
	pass


## Shortcut for states: ask this state's machine to switch.
func go(state: StringName, force := false) -> bool:
	return machine.request(state, force)
