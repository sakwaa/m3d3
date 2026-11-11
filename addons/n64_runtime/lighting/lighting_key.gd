@tool
class_name LightingKey
extends Resource
## One time-of-day lighting state in a LightingSchedule. The sun's direction comes from
## `hour` (same path as DayNightSun); everything else is set here.

@export var name := "Noon"
@export_range(0.0, 24.0, 0.25) var hour := 12.0
## Hours this key stays fully on, centred on `hour` (e.g. Night at 0:00 with 7 holds from
## 20:30 to 3:30); the blends to the keys around it happen in what's left.
@export_range(0.0, 12.0, 0.25, "suffix:h") var hold := 0.0
@export var sun_color := Color(1.0, 0.96, 0.88)
@export_range(0.0, 4.0) var sun_energy := 1.0
## Ambient from above / below.
@export var sky := Color(0.52, 0.58, 0.72)
@export var ground := Color(0.32, 0.29, 0.25)
## Outdoor fog distance (start and end) multiplier: below 1 pulls the fog in (night hides
## the distance). Blended between keys like the rest.
@export_range(0.1, 2.0, 0.05) var fog_distance := 1.0
## Outdoor fog colour multiplier on top of this key's light (below 1: murkier).
@export_range(0.0, 2.0, 0.05) var fog_brightness := 1.0
## Multiplier for local (omni) lights: torches off by day, full at night.
@export_range(0.0, 2.0) var local_lights := 1.0
