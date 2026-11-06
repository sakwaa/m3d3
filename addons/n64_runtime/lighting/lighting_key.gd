@tool
class_name LightingKey
extends Resource
## One time-of-day lighting state in a LightingSchedule. The sun's direction comes from
## `hour` (same path as DayNightSun); everything else is set here.

@export var name := "Noon"
@export_range(0.0, 24.0, 0.25) var hour := 12.0
@export var sun_color := Color(1.0, 0.96, 0.88)
@export_range(0.0, 4.0) var sun_energy := 1.0
## Ambient from above / below.
@export var sky := Color(0.52, 0.58, 0.72)
@export var ground := Color(0.32, 0.29, 0.25)
## Multiplier for local (omni) lights: torches off by day, full at night.
@export_range(0.0, 2.0) var local_lights := 1.0
