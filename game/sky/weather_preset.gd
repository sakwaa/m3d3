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
@export_group("Fog look")
## This weather's fog replaces outdoor zones' own fog while it lasts (thick mist rolling into
## a town that's normally clear). Off: only zones whose fog says From Weather use it. Rooms
## with a fog of their own keep it.
@export var fog_overrides_zone := false
## Fog colour as a share of the horizon's: below 1 the fog is darker than the sky, so
## buildings deep in it still read as dim silhouettes against it (thick mist, dusk haze).
@export_range(0.3, 1.5, 0.05) var fog_shade := 1.0
## The same once the sky is dark: night fog catches the town's lights and the moon, so it
## shows as a pale veil over darker shapes (above 1 = lighter than the night sky). Blends in
## as the horizon darkens.
@export_range(0.3, 3.0, 0.05) var fog_night_shade := 1.0
## Ground-hugging fog: how high it reaches above the zone's fog floor (m; 0 = even
## everywhere), and how much it thins above that (rooftops and chimneys rise out of it).
@export_range(0.0, 40.0, 0.5, "suffix:m") var fog_height := 0.0
@export_range(0.0, 1.0, 0.05) var fog_height_thin := 0.6
## Drifting fog banks: how much thinner the fog is between them (0 = none), and their size.
@export_range(0.0, 1.0, 0.05) var fog_drift := 0.0
@export_range(2.0, 60.0, 1.0, "suffix:m") var fog_drift_size := 14.0
## Light hanging in the fog: lamps and windows tint more of the air round them and glow
## wider and brighter (0 = the zone's own settings).
@export_range(0.0, 2.0, 0.05) var fog_glow := 0.0
## Screen look while this weather lasts outdoors (over the zone's; a room's wins).
@export var screen_look: ScreenLook
@export_group("Effects")
@export var lightning := false
## Rain intensity 0..1, for the rain system (not rendered yet).
@export_range(0.0, 1.0, 0.05) var rain := 0.0
## Wind: multiplies the zone's wind (Zone.wind_strength; 1 = as the zone has it, 0 = still,
## 2+ = a gale), and how gusty it is (0 steady .. 1 rolling gusts).
@export_range(0.0, 4.0, 0.05) var wind := 1.0
@export_range(0.0, 1.0, 0.05) var gusts := 0.5


func get_key(index: int) -> SkyKey:
	if keys.is_empty():
		return SkyKey.new()
	return keys[clampi(index, 0, keys.size() - 1)]
