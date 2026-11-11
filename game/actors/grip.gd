class_name Grip
extends Node
## Climbing stamina (SotC's grip meter), a child of the Actor: holding on drains it (the
## climbing states' grip_cost(), more while moving), leaps take a chunk, solid ground
## refills it. Empty = the actor lets go, and can't grab again until it has refilled a
## little. Grip pieces (GameState item PIECE_ITEM) grow it a segment every
## `pieces_per_segment`, so climbs can be gated by how much grip they take.

signal emptied

const PIECE_ITEM := &"grip_piece"

## Grip to start with (about seconds of climbing while moving).
@export var base := 15.0
## Grip each upgrade segment adds.
@export var per_segment := 4.0
@export var pieces_per_segment := 4
## Grip per second regained standing on the ground.
@export var refill_rate := 8.0
## Grip needed before grabbing again.
@export var grab_minimum := 0.5

var value := 10.0
var actor: Actor
var _max := 10.0


func _ready() -> void:
	actor = get_parent() as Actor
	actor.grip = self
	_max = max_value()
	value = _max
	GameState.item_changed.connect(_on_item_changed)


## Upgrade segments collected (0 = base grip).
func segments() -> int:
	return GameState.item_count(PIECE_ITEM) / maxi(pieces_per_segment, 1)


func max_value() -> float:
	return base + per_segment * segments()


func ratio() -> float:
	return clampf(value / maxf(_max, 0.001), 0.0, 1.0)


func is_full() -> bool:
	return value >= _max


func is_empty() -> bool:
	return value <= 0.0


func can_grab() -> bool:
	return value >= grab_minimum


func spend(amount: float) -> void:
	var was := value
	value = maxf(value - amount, 0.0)
	if was > 0.0 and value <= 0.0:
		emptied.emit()


## Any of the actor's states using grip (climbing).
func in_use() -> bool:
	return _cost() > 0.0


func _physics_process(delta: float) -> void:
	var cost := _cost()
	if cost > 0.0:
		spend(cost * delta)
	elif actor.is_on_floor() and not actor.has_tag(&"climbing"):  # (is_on_floor is stale while holding on)
		value = minf(value + refill_rate * delta, _max)


func _cost() -> float:
	var cost := 0.0
	for m in actor.machines:
		if m.current and m.current.has_method(&"grip_cost"):
			cost += m.current.grip_cost()
	return cost


func _on_item_changed(id: StringName, _count: int) -> void:
	if id != PIECE_ITEM:
		return
	var grown := max_value() - _max
	_max = max_value()
	if grown > 0.0:
		value = _max  # a new segment comes full
