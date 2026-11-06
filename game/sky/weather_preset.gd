@tool
class_name WeatherPreset
extends Resource
## One weather (sunny, cloudy, stormy, ...). `keys` line up with the project
## LightingSchedule's keys sorted by hour, so each weather has its own time-of-day variants.

@export var id := &"sunny"
@export var display_name := "Sunny"
@export var keys: Array[SkyKey] = []
@export_group("Clouds")
## Share of the sky covered (drives the cloud texture threshold).
@export_range(0.0, 1.0, 0.05) var cloud_cover := 0.3
## Edge softness of the cloud threshold.
@export_range(0.02, 1.0, 0.02) var cloud_softness := 0.35
## Drift in texture repeats per second.
@export var cloud_speed := 0.008
@export_group("World")
## Multiplies baked level lighting as seen on screen (outdoor zones only).
@export var world_tint := Color.WHITE
## Multiplies the sun / moon light energy.
@export_range(0.0, 2.0, 0.05) var sun_strength := 1.0
## Fog start / end in metres and how opaque it gets, fading to the horizon colour (N64
## per-vertex fog; the zone's FogSettings picks the curve).
@export var fog_begin := 40.0
@export var fog_end := 160.0
@export_range(0.0, 1.0, 0.05) var fog_amount := 0.6
@export_group("Effects")
@export var lightning := false
## Rain intensity 0..1, for the rain system (not rendered yet).
@export_range(0.0, 1.0, 0.05) var rain := 0.0


func get_key(index: int) -> SkyKey:
	if keys.is_empty():
		return SkyKey.new()
	return keys[clampi(index, 0, keys.size() - 1)]
