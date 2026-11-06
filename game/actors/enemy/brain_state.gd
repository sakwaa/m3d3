class_name BrainState
extends ActorState
## A state of an enemy's Brain machine: decides what the enemy wants (fills its intent the
## way the player's controller does) from its senses, condition and the fight. Each enemy
## type writes its own (Idle, Notice, Chase, Lost, SquareOff, Attack, Defend, Death...).

var enemy: Enemy:
	get:
		return actor as Enemy


func profile() -> EnemyProfile:
	return enemy.profile


func target() -> Actor:
	return enemy.target


func dist() -> float:
	return enemy.distance_to_target()


## The body's Action state is back to its resting state (not attacking / reeling).
func body_ready(rest := &"Ready") -> bool:
	var a := actor.state_of(Actor.ACTION)
	return a != null and a.name == rest


func body_reeling() -> bool:
	return actor.has_tag(&"reeling") or actor.has_tag(&"dead")
