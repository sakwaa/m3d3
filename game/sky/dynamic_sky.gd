@tool
class_name DynamicSky
extends WorldEnvironment
## Outdoor sky, fog and ambient driven by GameState's weather and time of day (in the
## editor, by the preview settings below). Also sets the `n64_weather_tint` shader
## global that darkens baked level lighting in bad weather; it is reset to white when
## this node leaves the tree, so indoor zones without a DynamicSky are unaffected.
## Rain too: the weather's `rain` drives the Rain streaks and the `n64_rain` / `n64_wetness`
## shader globals (surfaces soak in over WET_IN seconds and dry over WET_OUT), cleared again
## when this node leaves (no rain or wet ground indoors).

const SHADER := preload("res://game/sky/n64_sky.gdshader")
const WEATHER_PARAM := &"n64_weather_tint"
const WIND_PARAM := &"n64_wind"
const RAIN_PARAM := &"n64_rain"
const WET_PARAM := &"n64_wetness"
## Seconds for the ground to soak through in a downpour, and to dry out after it.
const WET_IN := 25.0
const WET_OUT := 120.0

@export var cloud_texture: Texture2D = preload("res://textures/sky/clouds.res")
## Cloud texture repeats per unit of the cloud plane (higher = smaller clouds).
@export var cloud_scale := 0.25
## Star look: cells per cube face, share of cells with a star, angular radius (radians;
## ~0.002 = about one N64 pixel), edge softness and twinkle amount.
@export var star_density := 36.0
@export_range(0.0, 1.0, 0.05) var star_fill := 0.4
@export_range(0.0005, 0.02, 0.0001) var star_size := 0.002
@export_range(0.0, 1.0, 0.05) var star_softness := 0.35
@export_range(0.0, 1.0, 0.05) var star_twinkle := 0.3
## RGBA16-style banding with an ordered dither, like N64 framebuffers.
@export var dither := true
## Wind slanting the rain (metres per second, world X / Z) at full rain; lighter rain gets less.
@export var rain_wind := Vector2(1.5, 0.6)
@export_group("Editor Preview")
@export var preview_weather := &"sunny"
@export_range(0.0, 24.0, 0.25) var preview_hour := 12.0

var _mat: ShaderMaterial
var _offset := Vector2.ZERO
var _flash := 0.0
var _flicker := -1.0
var _next_flash := 4.0
var _table: WeatherTable
var _schedule: LightingSchedule
var _rain: Rain
var _wetness := 0.0
var _wet_started := false


func _ready() -> void:
	if environment == null:
		environment = Environment.new()
	var env := environment
	_mat = env.sky.sky_material as ShaderMaterial if env.sky else null
	if _mat == null or _mat.shader != SHADER:
		_mat = ShaderMaterial.new()
		_mat.shader = SHADER
		env.sky = Sky.new()
		env.sky.sky_material = _mat
	env.background_mode = Environment.BG_SKY
	env.sky.radiance_size = Sky.RADIANCE_SIZE_32
	# Levels are lit by baked vertex colour; actors by the sun + a flat ambient. The sky
	# itself never lights anything, so its radiance map is never needed.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	# Fog: the Zone drives it (N64 fog from the weather, see Zone.fog_target()).
	_table = WeatherTable.load_project()
	_schedule = LightingSchedule.load_project()
	_rain = Rain.new()
	add_child(_rain, false, INTERNAL_MODE_BACK)


func _exit_tree() -> void:
	RenderingServer.global_shader_parameter_set(WEATHER_PARAM, Color.WHITE)
	RenderingServer.global_shader_parameter_set(RAIN_PARAM, Vector4.ZERO)
	RenderingServer.global_shader_parameter_set(WET_PARAM, 0.0)


func _process(delta: float) -> void:
	if _mat == null:
		return
	var hour := preview_hour
	var w: Dictionary
	if Engine.is_editor_hint():
		if _table == null or _table.presets.is_empty():
			return
		w = WeatherTable.sample(_table.find(preview_weather), _schedule, hour)
	else:
		hour = GameState.time_of_day
		w = GameState.weather_now
		if w.is_empty():
			return
	_update_lightning(delta, w.lightning > 0.5 and not Engine.is_editor_hint())
	_offset += Vector2(1.0, 0.35) * w.cloud_speed * delta
	_offset = _offset.posmod(1.0)

	var sun := get_parent().get_node_or_null(^"Sun") as Node3D
	var dir := LightingSchedule.sun_direction(hour, sun.rotation.y if sun else 0.0)
	var t := fposmod(hour, 24.0) / 24.0
	var day := sin((t - 0.25) * TAU) >= 0.0

	_mat.set_shader_parameter(&"zenith", w.zenith)
	_mat.set_shader_parameter(&"horizon", w.horizon)
	_mat.set_shader_parameter(&"cloud_light", w.cloud_light)
	_mat.set_shader_parameter(&"cloud_dark", w.cloud_dark)
	_mat.set_shader_parameter(&"stars", w.stars * (1.0 - w.cloud_cover * 0.6))
	_mat.set_shader_parameter(&"cloud_cover", w.cloud_cover)
	_mat.set_shader_parameter(&"cloud_softness", w.cloud_softness)
	_mat.set_shader_parameter(&"cloud_offset", _offset)
	_mat.set_shader_parameter(&"cloud_scale", cloud_scale)
	_mat.set_shader_parameter(&"cloud_tex", cloud_texture)
	_mat.set_shader_parameter(&"star_density", star_density)
	_mat.set_shader_parameter(&"star_fill", star_fill)
	_mat.set_shader_parameter(&"star_size", star_size)
	_mat.set_shader_parameter(&"star_softness", star_softness)
	_mat.set_shader_parameter(&"star_twinkle", star_twinkle)
	_mat.set_shader_parameter(&"star_angle", t * TAU)
	_mat.set_shader_parameter(&"disc_dir", dir)
	_mat.set_shader_parameter(&"disc_color", Color(1.0, 0.92, 0.75) if day else Color(0.8, 0.85, 1.0))
	_mat.set_shader_parameter(&"disc_size", 0.9993 if day else 0.9997)
	_mat.set_shader_parameter(&"disc_glow", 0.35 if day else 0.12)
	_mat.set_shader_parameter(&"flash", _flash)
	_mat.set_shader_parameter(&"dither", dither)

	var env := environment
	var ambient: Color = w.zenith.lerp(w.horizon, 0.5)
	env.ambient_light_color = ambient.lerp(Color.WHITE, _flash * 0.5)
	env.ambient_light_energy = 0.6

	# Preset tints are on-screen colours; the shader multiplies linear light.
	var tint: Color = w.world_tint.srgb_to_linear()
	RenderingServer.global_shader_parameter_set(WEATHER_PARAM, tint.lerp(Color(1.4, 1.4, 1.5), _flash * 0.5))
	_update_rain(delta, float(w.get("rain", 0.0)))
	_update_wind(float(w.get("wind", 1.0)), float(w.get("gusts", 0.5)))


## The shared wind (n64_wind: direction x / z, strength, gustiness) from the zone's wind
## scaled by the weather's; grass, trees and anything else swaying read it.
func _update_wind(weather_wind: float, gusts: float) -> void:
	var zone := get_parent()
	var deg: float = zone.get(&"wind_direction") if zone and zone.get(&"wind_direction") != null else 30.0
	var strength: float = zone.get(&"wind_strength") if zone and zone.get(&"wind_strength") != null else 0.35
	var a := deg_to_rad(deg)
	RenderingServer.global_shader_parameter_set(WIND_PARAM, Vector4(cos(a), -sin(a), strength * weather_wind, gusts))


## Rain amount and wind for the streaks; the wetness follows the rain (at once in the editor).
func _update_rain(delta: float, rain: float) -> void:
	var wind := rain_wind * rain
	RenderingServer.global_shader_parameter_set(RAIN_PARAM, Vector4(rain, wind.x, wind.y, 0.0))
	var target := clampf(rain * 1.5, 0.0, 1.0)
	if Engine.is_editor_hint() or not _wet_started:
		# Arriving in rain: already wet.
		_wetness = target
		_wet_started = true
	elif target > _wetness:
		_wetness = minf(_wetness + delta / WET_IN, target)
	else:
		_wetness = maxf(_wetness - delta / WET_OUT, target)
	RenderingServer.global_shader_parameter_set(WET_PARAM, _wetness)
	if _rain:
		_rain.visible = rain > 0.0


## Storm flashes: a bright strike, a short flicker after it, then a random wait.
func _update_lightning(delta: float, active: bool) -> void:
	_flash = maxf(_flash - delta * 5.0, 0.0)
	if not active:
		_flicker = -1.0
		return
	if _flicker >= 0.0:
		_flicker -= delta
		if _flicker < 0.0:
			_flash = 0.8
	_next_flash -= delta
	if _next_flash <= 0.0:
		_flash = 1.0
		_flicker = randf_range(0.08, 0.2)
		_next_flash = randf_range(5.0, 14.0)


## Strike now (cutscenes, tests).
func strike() -> void:
	_flash = 1.0
	_flicker = 0.12
