class_name LocoAir
extends ActorState
## Locomotion in the air: a jump (launches upwards on enter) or a fall. Keeps horizontal
## momentum (speed < 0) unless `speed` says otherwise; lands on touching the floor.

## Upward speed given on enter (0 = just falling).
@export var launch_velocity := 0.0
## Rising states hand over to this once the actor starts coming down.
@export var fall_state: StringName = &"Fall"
@export var land_state: StringName = &"Land"


func enter(_previous: ActorState) -> void:
	if launch_velocity > 0.0:
		actor.velocity.y = launch_velocity


func can_enter() -> bool:
	return super.can_enter() and (launch_velocity <= 0.0 or actor.is_on_floor())


func update(_delta: float) -> void:
	if launch_velocity > 0.0 and actor.velocity.y < 0.0 and fall_state != &"":
		go(fall_state)
	elif actor.is_on_floor() and time > 0.05 and land_state != &"":
		go(land_state)
