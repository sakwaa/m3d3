@tool
class_name LightingSchedule
extends Resource
## Project-wide time-of-day lighting keys (up to 4) for levels in Baked Timed lighting mode.
## Set the resource in Project Settings > n64/lighting/schedule. Levels bake one lighting
## pass per key; at runtime the two keys around the current hour are blended per vertex.

const SETTING := "n64/lighting/schedule"
const DEFAULT_PATH := "res://game/lighting_schedule.tres"
const MAX_KEYS := 4

## Keys in any order; they are used sorted by hour.
@export var keys: Array[LightingKey] = []


static func load_project() -> LightingSchedule:
	var path: String = ProjectSettings.get_setting(SETTING, DEFAULT_PATH)
	return load(path) as LightingSchedule if ResourceLoader.exists(path) else null


## Keys sorted by hour (the order of the baked lighting slots).
func sorted_keys() -> Array[LightingKey]:
	var out: Array[LightingKey] = []
	for k in keys:
		if k and out.size() < MAX_KEYS:
			out.append(k)
	out.sort_custom(func(a, b): return a.hour < b.hour)
	return out


## Vector3(slot a, slot b, weight of b) for an hour, wrapping around midnight.
func blend_for(hour: float) -> Vector3:
	var ks := sorted_keys()
	if ks.is_empty():
		return Vector3.ZERO
	if ks.size() == 1:
		return Vector3(0, 0, 0)
	hour = fposmod(hour, 24.0)
	for i in ks.size():
		var a := ks[i].hour
		var b := ks[(i + 1) % ks.size()].hour
		var span := fposmod(b - a, 24.0)
		var into := fposmod(hour - a, 24.0)
		if span > 0.0 and into <= span:
			return Vector3(i, (i + 1) % ks.size(), into / span)
	return Vector3(0, 0, 0)


## Sun / moon colour and energy at an hour (blended like the baked lighting).
func sun_at(hour: float) -> Array:
	var ks := sorted_keys()
	if ks.is_empty():
		return [Color.WHITE, 1.0]
	var b := blend_for(hour)
	var ka := ks[int(b.x)]
	var kb := ks[int(b.y)]
	return [ka.sun_color.lerp(kb.sun_color, b.z), lerpf(ka.sun_energy, kb.sun_energy, b.z)]


## Direction towards the sun (day) or moon (night) at an hour; `yaw` is the sun's
## compass rotation (DirectionalLight3D rotation.y). Matches DayNightSun.
static func sun_direction(hour: float, yaw: float) -> Vector3:
	var t := fposmod(hour, 24.0) / 24.0
	var height := sin((t - 0.25) * TAU)
	var pitch := -(t - 0.25) * TAU if height >= 0.0 else -(t - 0.75) * TAU
	return Basis.from_euler(Vector3(pitch, yaw, 0.0)).z.normalized()
