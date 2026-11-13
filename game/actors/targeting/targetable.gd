class_name Targetable
extends Node3D
## Something Z-targeting can lock onto: enemies, NPCs, points of interest (signs, doors,
## switches...). Place it where the lock should aim (head / chest height: the "focus") as
## a child of the thing; distances are measured from the thing's origin (its feet). Rules
## live in TargetLock and only use what's declared here, so any node can be targetable.
## Rules and numbers are Majora's Mask's (references/targeting/z_targeting_spec.md).

enum Kind {
	ENEMY,  ## Hostile tier: picked over anything in the other tier; yellow.
	NPC,    ## Someone to talk to; blue.
	POI,    ## Point of interest: signs, switches, chests, doors; green.
	BOSS,   ## Hostile tier, like ENEMY; yellow.
}

## MM's attention range types: [acquire, release] in metres (1 MM unit = 4 cm). Release is
## sqrt(range * leash) from MM's table (that's how its leash really works).
enum Reach {
	SIGN,      ## 0: 2.8 / 4.0 m (signs, chests, small NPCs).
	SHORT,     ## 1: 6.8 / 8.3 m.
	CLINGY,    ## 2: 11.2 / 50 m (Keese-like: hard to shake off).
	DEFAULT,   ## 3: 14 / 17.1 m (most enemies).
	FAR,       ## 4: 28 / 34.3 m.
	BOSS,      ## 5: 40 / 49 m.
	TOWNSFOLK, ## 6: 4.0 / 4.1 m (most town NPCs).
	CLOSE,     ## 7: 5.6 / 6.0 m.
	MEDIUM,    ## 8: 9.6 / 14.9 m.
	STICKY,    ## 9: 11.2 m / never.
	HUGE,      ## 10: 100 / 122 m.
	KIND,      ## The kind's default (ENEMY DEFAULT, NPC TOWNSFOLK, POI SIGN, BOSS BOSS).
}

const UNIT := 0.04  # metres per MM unit (human Link 40 units tall, our player 1.6 m)
const RANGES := [[70, 140], [170, 255], [280, 5600], [350, 525], [700, 1050], [1000, 1500],
	[100, 105.36842], [140, 163.33333], [240, 576], [280, 280000], [2500, 3750]]
const KIND_RANGE := {Kind.ENEMY: Reach.DEFAULT, Kind.NPC: Reach.TOWNSFOLK, Kind.POI: Reach.SIGN, Kind.BOSS: Reach.BOSS}
## Arrow / reticle colours (MM): NPC blue, enemies yellow, the rest green.
const COLORS := {Kind.ENEMY: Color8(255, 255, 0), Kind.BOSS: Color8(255, 255, 0), Kind.NPC: Color8(150, 150, 255),
	Kind.POI: Color8(0, 255, 0)}

const GROUP := &"targetable"

@export var kind := Kind.POI
@export var range_type := Reach.KIND
@export var enabled := true
## Hovered (looked at) but never locked and no arrow (MM's lock-on disabled).
@export var lock_disabled := false
## Hostile: battle stance and camera when locked, counts for battle music. Off = friendly
## even as an enemy (a sparring partner).
@export var hostile := true
## 0 = normal. Non-zero targets are only picked when no normal one is; lower wins.
@export var priority := 0
## Shown with the reticle (NPC name, "Read", "Look"...). Optional.
@export var label := ""

## Order of appearance (MM ties go to the actor spawned first).
var order := 0
static var _next_order := 0


func _enter_tree() -> void:
	add_to_group(GROUP)
	_next_order += 1
	order = _next_order


func _range() -> Array:
	return RANGES[KIND_RANGE[kind] if range_type == Reach.KIND else range_type]


## Metres within which it can be locked.
func acquire_range() -> float:
	return _range()[0] * UNIT


## Metres beyond which a lock on it lets go.
func release_range() -> float:
	var r: Array = _range()
	return sqrt(float(r[0]) * float(r[1])) * UNIT


## Boss / enemy tier: searched first, and wins over anything else.
func is_hostile_tier() -> bool:
	return kind == Kind.ENEMY or kind == Kind.BOSS


## Locked on, the player fights it (battle stance and camera, battle music).
func is_hostile() -> bool:
	return is_hostile_tier() and hostile


func color() -> Color:
	return COLORS[kind]


## Where distances are measured from: the owner's origin (its feet).
func origin() -> Vector3:
	var a := actor()
	if a:
		return a.global_position
	var p := get_parent() as Node3D
	return p.global_position if p else global_position


## The Actor this belongs to (parent chain), if any.
func actor() -> Actor:
	var n := get_parent()
	while n:
		if n is Actor:
			return n
		n = n.get_parent()
	return null
