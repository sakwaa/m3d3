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
			# Each key holds for half its `hold` on this side; blend across the rest.
			var hold_a := minf(ks[i].hold * 0.5, span)
			var hold_b := minf(ks[(i + 1) % ks.size()].hold * 0.5, span - hold_a)
			var blend := span - hold_a - hold_b
			var w := clampf((into - hold_a) / blend, 0.0, 1.0) if blend > 0.0 else (0.0 if into < span * 0.5 else 1.0)
			return Vector3(i, (i + 1) % ks.size(), w)
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


## How lit the world is at an hour, like the baked keys light it (sky ambient + sun / moon),
## relative to the brightest key (1 = that key; night is dark and blue). For things the bake
## doesn't reach: a fixed fog colour, effect sprites.
func light_at(hour: float) -> Color:
	var ks := sorted_keys()
	if ks.is_empty():
		return Color.WHITE
	var top := 0.0
	for k in ks:
		top = maxf(top, _key_light(k).get_luminance())
	var b := blend_for(hour)
	var c := _key_light(ks[int(b.x)]).lerp(_key_light(ks[int(b.y)]), b.z) / maxf(top, 0.001)
	c.a = 1.0
	return c


## Outdoor fog distance multiplier at an hour (LightingKey.fog_distance, blended).
func fog_distance_at(hour: float) -> float:
	var ks := sorted_keys()
	if ks.is_empty():
		return 1.0
	var b := blend_for(hour)
	return lerpf(ks[int(b.x)].fog_distance, ks[int(b.y)].fog_distance, b.z)


## Outdoor fog colour multiplier at an hour (LightingKey.fog_brightness, blended).
func fog_brightness_at(hour: float) -> float:
	var ks := sorted_keys()
	if ks.is_empty():
		return 1.0
	var b := blend_for(hour)
	return lerpf(ks[int(b.x)].fog_brightness, ks[int(b.y)].fog_brightness, b.z)


static func _key_light(k: LightingKey) -> Color:
	var c := k.sky + k.sun_color * k.sun_energy
	c.a = 1.0
	return c


## Direction towards the sun (day) or moon (night) at an hour; `yaw` is the sun's
## compass rotation (DirectionalLight3D rotation.y). Matches DayNightSun.
static func sun_direction(hour: float, yaw: float) -> Vector3:
	var t := fposmod(hour, 24.0) / 24.0
	var height := sin((t - 0.25) * TAU)
	var pitch := -(t - 0.25) * TAU if height >= 0.0 else -(t - 0.75) * TAU
	return Basis.from_euler(Vector3(pitch, yaw, 0.0)).z.normalized()
