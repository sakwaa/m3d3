class_name EnemyProfile
extends Resource
## Tunables for an enemy type (balance without code changes). Behaviour lives in the
## type's brain states; they read these.

@export_group("Health")
@export var max_health := 6
## Condition machine: Wounded below this fraction of health, Critical below the next.
@export_range(0.0, 1.0) var wounded_below := 0.6
@export_range(0.0, 1.0) var critical_below := 0.25

@export_group("Senses")
@export var sight_range := 12.0
## Degrees in front.
@export var sight_angle := 120.0
## Hears the target moving fast (running) within this distance, whichever way it faces.
@export var hear_range := 4.0
## Seconds without seeing the target before giving up the chase (Lost).
@export var memory := 3.0

@export_group("Fighting")
## Starts squaring off within this distance.
@export var engage_range := 5.0
## Strikes from this distance.
@export var attack_range := 1.6
## Distance kept while circling (Wounded adds `wounded_distance`).
@export var circle_distance := 3.0
@export var wounded_distance := 1.0
## Chance per decision to attack, per condition (Healthy, Wounded, Critical).
@export var aggression := Vector3(0.6, 0.35, 0.2)
## Chance to guard (rather than back off) when the target swings, per condition.
@export var guard_chance := Vector3(0.5, 0.75, 0.9)
## Seconds between attack decisions while squaring off (random in this range).
@export var decision_time := Vector2(0.8, 1.8)
## Critical: run away instead of fighting on.
@export var flee_when_critical := false

@export_group("Movement")
@export var walk_speed := 2.0
@export var run_speed := 5.0
