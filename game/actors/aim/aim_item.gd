class_name AimItem
extends Resource
## Something aimed and shot from AimState (the bow first; a slingshot or hookshot later):
## its timings, what it fires and how hard. The camera, reticle and body pose are AimState /
## CameraDirector / AimRig's and the same for every item.
## Timings measured off Tears of the Kingdom (references/aiming/totk_aim_reference.md):
## button to aimed ~0.5 s, the follow-through after a shot ~0.3 s.

@export var display_name := "Bow"
## Seconds from the button to the bow up on the aim line (AimRig blends the pose over it).
@export var raise_time := 0.35
## Seconds pulling the string back once raised (and again after each shot).
@export var draw_time := 0.25
## Seconds after a shot before the next arrow is nocked (the follow-through).
@export var reload_time := 0.35
## Least of a full draw that fires (a quick tap still shoots, a weaker one).
@export_range(0.0, 1.0) var min_draw := 0.5
## Projectile speed (m/s at a full draw) and how far it flies straight before dropping.
@export var speed := 45.0
@export var straight_range := 60.0
@export var damage := 1
@export var knockback := 2.0
## How far the reticle ray looks for what's being aimed at (m).
@export var reach := 80.0


## The projectile for one shot (an Arrow by default).
func make_projectile() -> Node3D:
	return Arrow.new()


static func bow() -> AimItem:
	return AimItem.new()
