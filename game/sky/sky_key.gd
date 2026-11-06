@tool
class_name SkyKey
extends Resource
## Sky colours of one weather at one lighting key (time of day). A WeatherPreset holds
## one per LightingSchedule key, in the schedule's hour order.

@export var zenith := Color(0.2, 0.45, 0.9)
@export var horizon := Color(0.65, 0.8, 0.95)
## Sunlit and shadowed sides of the clouds.
@export var cloud_light := Color.WHITE
@export var cloud_dark := Color(0.6, 0.65, 0.75)
## Star visibility before cloud cover (0 = none, 1 = full night sky).
@export_range(0.0, 1.0, 0.05) var stars := 0.0
