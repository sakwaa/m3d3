class_name LocoAir
extends ActorState
## Locomotion in the air: a jump (launches upwards on enter) or a fall. Keeps horizontal
## momentum (speed < 0) unless `speed` says otherwise; lands on touching the floor.

## Upward speed given on enter (0 = just falling).
@export var launch_velocity := 0.0
## Rising states hand over to this once the actor starts coming down.
@export var fall_state: StringName = &"Fall"
@export var land_state: StringName = &"Land"
## Soft landings (any but a fall from `hard_landing` metres or more) skip `land_state` and go
## straight on into these by the stick, keeping momentum (empty = always `land_state`).
@export var idle_state: StringName
@export var walk_state: StringName
@export var run_state: StringName
@export_range(0.0, 1.0) var run_above := 0.7
## Drop (m) that makes a hard landing (`land_state`: a stop); 0 = the actor's fall damage height.
@export var hard_landing := 0.0
## Holds within reach in the air are grabbed (LocoClimb.try_catch: falling, any round about
## the stick doesn't push away from): climbable walls, ledges, climbable ceilings. A LocoClimb state; empty =
## can't climb.
@export var climb_state: StringName


func enter(_previous: ActorState) -> void:
	if launch_velocity > 0.0:
		actor.velocity.y = launch_velocity


func can_enter() -> bool:
	return super.can_enter() and (launch_velocity <= 0.0 or actor.is_on_floor())


func update(_delta: float) -> void:
	if climb_state != &"":
		var climb := machine.states.get(climb_state) as LocoClimb
		if climb and climb.try_catch():
			return
	if launch_velocity > 0.0 and actor.velocity.y < 0.0 and fall_state != &"":
		go(fall_state)
	elif actor.is_on_floor() and time > 0.05 and land_state != &"":
		var into := _landing()
		if not go(into) and into != land_state:
			go(land_state)  # (another machine won't allow running on, e.g. mid jump slash)


func _landing() -> StringName:
	var hard := hard_landing if hard_landing > 0.0 else actor.fall_damage_height
	if idle_state == &"" or (hard > 0.0 and actor.last_drop >= hard):
		return land_state
	var m := actor.intent.move.length()
	if m > run_above and run_state != &"":
		return run_state
	if m > 0.1 and walk_state != &"":
		return walk_state
	return idle_state
