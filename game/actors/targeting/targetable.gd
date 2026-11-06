class_name Targetable
extends Node3D
## Something Z-targeting can lock onto: enemies, NPCs, points of interest (signs, doors,
## switches...). Place it where the lock should aim (head / chest height) as a child of
## the thing. Rules live in TargetLock and only use what's declared here, so any node can
## be targetable.

enum Kind {
	ENEMY,  ## Hostile: picked first, camera frames the fight.
	NPC,    ## Someone to talk to.
	POI,    ## Point of interest: signs, switches, items to look at.
}

const GROUP := &"targetable"
## Default lock ranges per kind (metres).
const RANGES := {Kind.ENEMY: 14.0, Kind.NPC: 7.0, Kind.POI: 9.0}

@export var kind := Kind.POI
@export var enabled := true
## Metres within which it can be locked (0 = the kind's default).
@export var max_distance := 0.0
## Higher wins when two candidates are about equally good.
@export var priority := 0
## Shown with the reticle (NPC name, "Read", "Look"...). Optional.
@export var label := ""


func _enter_tree() -> void:
	add_to_group(GROUP)


func lock_range() -> float:
	return max_distance if max_distance > 0.0 else RANGES[kind]


## The Actor this belongs to (parent chain), if any.
func actor() -> Actor:
	var n := get_parent()
	while n:
		if n is Actor:
			return n
		n = n.get_parent()
	return null
