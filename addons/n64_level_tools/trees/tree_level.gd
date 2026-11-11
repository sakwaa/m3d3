@tool
class_name TreeLevel
extends Resource
## One level of branching in a TreeSpecies (Weber & Penn style): the limbs off the trunk,
## the branches off those, ... Angles are degrees, lengths fractions of the parent's.

## Children per parent stem (all of them along start..end), or per whorl if `whorls` > 0.
@export var count := 6
## Whorls (firs): rings of `count` children at even steps along the parent; 0 = a spiral.
@export var whorls := 0
## Where along the parent children grow (0 base .. 1 tip).
@export_range(0.0, 1.0) var start := 0.3
@export_range(0.0, 1.0) var end := 1.0
## Angle from the parent's direction (0 = straight on, 90 = out sideways), and random spread.
@export_range(0.0, 150.0) var angle := 45.0
@export_range(0.0, 60.0) var angle_var := 10.0
## Length as a fraction of the parent's (level 1: of the tree's height), and random spread.
@export var length := 0.5
@export_range(0.0, 1.0) var length_var := 0.15
## Bend over the stem's length (degrees, + up towards the sky, - drooping down), and how
## much the bend comes at the end (1 even, 2+ mostly at the tip: a willow's arch).
@export var curve := 0.0
@export var curve_power := 1.0
## Random wander per segment (degrees): crooked oak limbs.
@export var wander := 6.0
## Base radius as a fraction of the parent's radius where it grows.
@export_range(0.05, 1.0) var radius := 0.5
## Draw the stems (off: twigs hidden in the leaves cost nothing; they still carry leaves).
@export var bark := true
## Low-poly tube: sides round, segments along.
@export_range(3, 8) var sides := 4
@export_range(1, 8) var segments := 3
