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
const ACTOR_LIFT_PARAM := &"n64_actor_lift"
const ACTOR_RIM_PARAM := &"n64_actor_rim"
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
## Majora's Mask's own stars instead: 1-pixel-tall dashes half a pixel to 2.5 wide, no
## twinkle, a lavender-to-pink palette (a few blue and one orange), fading in 19:00-21:00 and
## out 02:00-03:00.
@export var mm_stars := true
## Majora's Mask's sky tint: the weather's midday sky remapped each hour onto two colours
## (out = env + (prim - env) x sky: morning, day, sunset, night, pre-dawn; cloudy its own
## set) instead of the weather's per-time colours.
@export var mm_sky_tint := false
## RGBA16-style banding with an ordered dither, like N64 framebuffers.
@export var dither := true
## Ocarina of Time's sun flare (LensFlare): rings through the screen centre when the sun is
## in view, cut off by anything in front of it. Fades with cloud cover and rain.
@export var lens_flare := true
## Wind-blown dust (WindDust, from the weather's dust / dust_far): the far band's centre (x, z)
## and radius (metres: just outside the town, before the hills / backdrop behind it) and the
## ground it stands on. Defaults suit the market.
@export var dust_ring_center := Vector2(-3, 0)
@export var dust_ring_radius := 72.0
@export var dust_ground := 0.0
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
var _flare: LensFlare
var _bolts: LightningBolts
var _sand: Sandstorm
var _dust: WindDust
var _wind_xz := Vector2(1, 0)
# OoT lightning (20 Hz): 0 wait, 1 start, 2 end
var _l_state := 0
var _l_delay := 0.0
var _l_alpha := 0
var _l_amb := Vector3.ZERO
var _l_tick := 0.0
var _l_last := false
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
	_flare = LensFlare.new()
	add_child(_flare, false, INTERNAL_MODE_BACK)
	_bolts = LightningBolts.new()
	add_child(_bolts, false, INTERNAL_MODE_BACK)
	_sand = Sandstorm.new()
	add_child(_sand, false, INTERNAL_MODE_BACK)
	_dust = WindDust.new()
	add_child(_dust, false, INTERNAL_MODE_BACK)


func _exit_tree() -> void:
	_set_global(WEATHER_PARAM, Color.WHITE)
	_set_global(RAIN_PARAM, Vector4.ZERO)
	_set_global(WET_PARAM, 0.0)


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

	var sky := w
	if mm_sky_tint and _table:
		# (the weather's midday sky; the tint makes the time of day)
		var preset := _table.find(preview_weather if Engine.is_editor_hint() else GameState.weather)
		if preset:
			sky = WeatherTable.sample(preset, _schedule, 12.0)
	_mat.set_shader_parameter(&"zenith", sky.zenith)
	_mat.set_shader_parameter(&"horizon", sky.horizon)
	_mat.set_shader_parameter(&"cloud_light", sky.cloud_light)
	_mat.set_shader_parameter(&"cloud_dark", sky.cloud_dark)
	_mat.set_shader_parameter(&"sky_tint_on", mm_sky_tint)
	if mm_sky_tint:
		var tint := mm_sky_colours(hour, float(w.cloud_cover) > 0.6)
		_mat.set_shader_parameter(&"sky_prim", tint[0])
		_mat.set_shader_parameter(&"sky_env", tint[1])
	_mat.set_shader_parameter(&"star_mm", mm_stars)
	var star_amount: float = w.stars * (1.0 - w.cloud_cover * 0.6)
	if mm_stars:
		star_amount = mm_star_fade(hour) * (1.0 - float(w.cloud_cover))
		var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
		# (an N64 pixel: the view's height over 240 lines)
		var px := deg_to_rad(cam.fov if cam else 60.0) / 240.0
		_mat.set_shader_parameter(&"pixel_angle", px)
	_mat.set_shader_parameter(&"stars", star_amount)
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
	_mat.set_shader_parameter(&"flash", _l_alpha / 255.0)
	if _sand:
		_sand.hour = hour
		var storm := float(w.get("sandstorm", 0.0))
		_sand.haze = float(w.get("sandstorm_haze", 0.0)) > 0.5
		_sand.strength = clampf(storm, 0.0, 1.0)
		if _dust:
			_dust.hour = hour
			_dust.far = float(w.get("dust_far", 0.0))
			_dust.haze = _sand.haze
			_dust.wind = _wind_xz
			_dust.ring_radius = dust_ring_radius
			_dust.ring_center = dust_ring_center
			_dust.ring_base = dust_ground
		if storm > 0.01 and not Engine.is_editor_hint():
			_sand.state = Sandstorm.State.ACTIVE
		elif _sand.state != Sandstorm.State.OFF:
			_sand.state = Sandstorm.State.DISSIPATE
	if _flare:
		var clear := (1.0 - float(w.cloud_cover)) * (1.0 - clampf(float(w.get("rain", 0.0)) * 2.0, 0.0, 1.0))
		# (OoT: full strength most of the day - cos(time - noon) x 12, capped at 1 - fading only
		# as the sun nears the horizon; glare tint by cos(time - noon))
		var noon := cos((t - 0.5) * TAU)
		_flare.set_sun(dir, (clampf(noon * 12.0, 0.0, 1.0) * smoothstep(0.0, 0.05, dir.y) * clear) if lens_flare and day else 0.0,
			Color.WHITE, clampf(noon, 0.0, 1.0))
	_mat.set_shader_parameter(&"dither", dither)

	var env := environment
	var ambient: Color = w.zenith.lerp(w.horizon, 0.5)
	env.ambient_light_color = ambient.lerp(Color.WHITE, _flash * 0.5)
	env.ambient_light_energy = 0.6
	# Actors stay readable against the baked level: a floor of their own colour (most at
	# night, when sun + flat ambient leave them darker than the moonlit ground) and a sky rim.
	var daylight := smoothstep(-0.05, 0.3, dir.y)
	var sky_tint: Color = w.horizon.lerp(Color.WHITE, 0.5)
	_set_global(ACTOR_LIFT_PARAM, Color(sky_tint, lerpf(0.4, 0.06, daylight)))
	_set_global(ACTOR_RIM_PARAM, Color(w.horizon.lerp(Color.WHITE, 0.35), lerpf(0.55, 0.3, daylight)))

	# Preset tints are on-screen colours; the shader multiplies linear light.
	var tint: Color = w.world_tint.srgb_to_linear()
	_set_global(WEATHER_PARAM, tint.lerp(Color(1.4, 1.4, 1.5), _flash * 0.5))
	_update_rain(delta, float(w.get("rain", 0.0)))
	_update_wind(float(w.get("wind", 1.0)), float(w.get("gusts", 0.5)))


## The shared wind (n64_wind: direction x / z, strength, gustiness) from the zone's wind
## scaled by the weather's; grass, trees and anything else swaying read it.
func _update_wind(weather_wind: float, gusts: float) -> void:
	var zone := get_parent()
	var deg: float = zone.get(&"wind_direction") if zone and zone.get(&"wind_direction") != null else 30.0
	var strength: float = zone.get(&"wind_strength") if zone and zone.get(&"wind_strength") != null else 0.35
	var a := deg_to_rad(deg)
	_set_global(WIND_PARAM, Vector4(cos(a), -sin(a), strength * weather_wind, gusts))
	_wind_xz = Vector2(cos(a), -sin(a)) * maxf(strength * weather_wind, 0.05)


## Rain amount and wind for the streaks; the wetness follows the rain (at once in the editor).
func _update_rain(delta: float, rain: float) -> void:
	var wind := rain_wind * rain
	_set_global(RAIN_PARAM, Vector4(rain, wind.x, wind.y, 0.0))
	var target := clampf(rain * 1.5, 0.0, 1.0)
	if Engine.is_editor_hint() or not _wet_started:
		# Arriving in rain: already wet.
		_wetness = target
		_wet_started = true
	elif target > _wetness:
		_wetness = minf(_wetness + delta / WET_IN, target)
	else:
		_wetness = maxf(_wetness - delta / WET_OUT, target)
	_set_global(WET_PARAM, _wetness)
	if _rain:
		_rain.visible = rain > 0.0


## Ocarina of Time's storms (Environment_UpdateLightningStrike), at 20 Hz: while waiting, a
## counter gains a random 0..1 a tick plus 50 one tick in ten; past 500 a strike (about every
## 4.5 s): 1-3 bolts (LightningBolts) and a flash - the sky whitens towards (200, 200, 255) by
## 100 a tick to 200, the ambient light climbs (+80, +80, +100) a tick, then both fall back
## 10 a tick (about a second). Weather turning calm lets the current strike finish.
func _update_lightning(delta: float, active: bool) -> void:
	if not active and _l_state == 0:
		_l_amb = Vector3.ZERO
		_l_alpha = 0
		_flash = 0.0
		return
	_l_tick += delta * 20.0
	while _l_tick >= 1.0:
		_l_tick -= 1.0
		match _l_state:
			0:
				if randf() < 0.1:
					_l_delay += 50.0
				_l_delay += randf()
				if _l_delay > 500.0 and active:
					_l_delay = 0.0
					_begin_strike(int(randf() * 2.9) + 1)
			1:
				_l_alpha += 100
				_l_amb += Vector3(80, 80, 100)
				if _l_alpha >= 200:
					_l_alpha = 200
					_l_state = 2
			2:
				_l_alpha = maxi(_l_alpha - 10, 0)
				_l_amb = Vector3(maxf(_l_amb.x - 10, 0), maxf(_l_amb.y - 10, 0), maxf(_l_amb.z - 10, 0))
				if _l_alpha <= 0:
					_l_amb = Vector3.ZERO
					_l_state = 0
	# (the world brightening: the ambient boost, 0..1 of its peak)
	_flash = clampf(_l_amb.z / 200.0, 0.0, 1.0)


func _begin_strike(bolts: int) -> void:
	_l_state = 1
	_l_alpha = 0
	if _bolts:
		_bolts.strike(bolts)


## Majora's Mask's sky colours at `hour`: [prim, env] (config 0 clear, config 1 cloudy).
static func mm_sky_colours(hour: float, cloudy: bool) -> Array:
	# (start, end, colour from, colour to): colours below
	var c := [[Color8(181, 100, 72), Color8(102, 135, 99)], [Color8(255, 255, 255), Color8(0, 15, 69)],
		[Color8(255, 164, 63), Color8(110, 55, 110)], [Color8(70, 90, 100), Color8(0, 0, 100)],
		[Color8(180, 110, 70), Color8(70, 10, 10)], [Color8(140, 120, 90), Color8(40, 0, 10)],
		[Color8(186, 107, 70), Color8(40, 40, 40)], [Color8(50, 90, 120), Color8(20, 20, 30)],
		[Color8(160, 104, 125), Color8(60, 0, 10)]]
	var table := [[0, 4, 3, 3], [4, 5, 3, 4], [5, 6, 4, 4], [6, 8, 0, 1], [8, 16, 1, 1], [16, 17, 1, 2],
		[17, 18, 2, 2], [18, 19, 2, 3], [19, 24, 3, 3]]
	if cloudy:
		table = [[0, 4, 7, 7], [4, 5, 7, 4], [5, 6, 4, 4], [6, 8, 5, 6], [8, 16, 6, 6], [16, 17, 6, 8],
			[17, 18, 8, 8], [18, 19, 8, 7], [19, 24, 7, 7]]
	var h := fposmod(hour, 24.0)
	for e in table:
		if h >= e[0] and h < e[1]:
			var k: float = (h - e[0]) / float(e[1] - e[0])
			return [(c[e[2]][0] as Color).lerp(c[e[3]][0], k), (c[e[2]][1] as Color).lerp(c[e[3]][1], k)]
	return c[3]


## Majora's Mask's star fade: in 19:00 -> 21:00, full to 02:00, out by 03:00.
static func mm_star_fade(hour: float) -> float:
	var h := fposmod(hour, 24.0)
	if h >= 21.0 or h < 2.0:
		return 1.0
	if h >= 19.0:
		return (h - 19.0) / 2.0
	if h < 3.0:
		return 3.0 - h
	return 0.0


## Strike now (cutscenes, tests).
func strike() -> void:
	_begin_strike(int(randf() * 2.9) + 1)


## The shared shader globals - left alone by a copy of the zone drawn in a DropPortal's hole
## (its sky runs to show the hour, but the globals are the zone the player is in).
func _set_global(param: StringName, value: Variant) -> void:
	if not DropPortal.is_preview(self):
		RenderingServer.global_shader_parameter_set(param, value)
