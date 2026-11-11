@tool
class_name WeatherTable
extends Resource
## The game's weather presets (Project Settings > n64/weather/table). Also samples a
## preset at an hour into a flat dictionary of sky / fog / light values that can be
## blended between weathers.

const SETTING := "n64/weather/table"
const DEFAULT_PATH := "res://game/weather.tres"

@export var presets: Array[WeatherPreset] = []


static func load_project() -> WeatherTable:
	var path: String = ProjectSettings.get_setting(SETTING, DEFAULT_PATH)
	return load(path) as WeatherTable if ResourceLoader.exists(path) else null


## Preset by id; the first preset if not found.
func find(id: StringName) -> WeatherPreset:
	for p in presets:
		if p and p.id == id:
			return p
	return presets[0] if not presets.is_empty() else null


func ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for p in presets:
		if p:
			out.append(p.id)
	return out


## Values of a preset at an hour, its sky keys blended like the baked lighting keys.
static func sample(preset: WeatherPreset, schedule: LightingSchedule, hour: float) -> Dictionary:
	var b := schedule.blend_for(hour) if schedule else Vector3.ZERO
	var ka := preset.get_key(int(b.x))
	var kb := preset.get_key(int(b.y))
	var t := b.z
	return {
		zenith = ka.zenith.lerp(kb.zenith, t),
		horizon = ka.horizon.lerp(kb.horizon, t),
		cloud_light = ka.cloud_light.lerp(kb.cloud_light, t),
		cloud_dark = ka.cloud_dark.lerp(kb.cloud_dark, t),
		stars = lerpf(ka.stars, kb.stars, t),
		cloud_cover = preset.cloud_cover,
		cloud_softness = preset.cloud_softness,
		cloud_speed = preset.cloud_speed,
		world_tint = preset.world_tint,
		sun_strength = preset.sun_strength,
		fog_begin = preset.fog_begin,
		fog_end = preset.fog_end,
		fog_amount = preset.fog_amount,
		lightning = 1.0 if preset.lightning else 0.0,
		rain = preset.rain,
		wind = preset.wind,
		gusts = preset.gusts,
	}


## Blends two sample() dictionaries.
static func mix(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	if t <= 0.0:
		return a
	if t >= 1.0:
		return b
	var out := {}
	for k in a:
		out[k] = a[k].lerp(b[k], t) if a[k] is Color else lerpf(a[k], b[k], t)
	return out
