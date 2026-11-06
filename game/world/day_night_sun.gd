class_name DayNightSun
extends DirectionalLight3D
## Drives a directional light from GameState.time_of_day: sun arc by day, dim moon by night.
## Also sets the `n64_world_tint` shader global, so levels with single-bake vertex
## lighting (which ignore scene lights) still warm up at dusk and cool down at night.
## With a project LightingSchedule, the sun's colour / energy follow its keys, so actors
## are lit to match Baked Timed levels.

@export var day_energy := 1.2
@export var night_energy := 0.15
@export var day_color := Color(1.0, 0.96, 0.88)
@export var dusk_color := Color(1.0, 0.6, 0.35)
@export var night_color := Color(0.45, 0.55, 0.9)
@export var world_day := Color.WHITE
@export var world_dusk := Color(1.0, 0.78, 0.6)
@export var world_night := Color(0.32, 0.38, 0.62)


func _process(_delta: float) -> void:
	var t: float = GameState.time_of_day / 24.0
	var height := sin((t - 0.25) * TAU)  # 1 at noon, -1 at midnight
	var world: Color
	if height >= 0.0:
		rotation.x = -(t - 0.25) * TAU
		light_energy = lerpf(night_energy, day_energy, clampf(height * 3.0, 0.0, 1.0))
		light_color = dusk_color.lerp(day_color, clampf(height * 2.5, 0.0, 1.0))
		world = world_dusk.lerp(world_day, clampf(height * 2.5, 0.0, 1.0))
	else:
		rotation.x = -(t - 0.75) * TAU
		light_energy = night_energy
		light_color = night_color
		world = world_dusk.lerp(world_night, clampf(-height * 4.0, 0.0, 1.0))
	if GameState.lighting_schedule:
		var sun: Array = GameState.lighting_schedule.sun_at(GameState.time_of_day)
		light_color = sun[0]
		light_energy = sun[1]
	# Weather (overcast, storm) dims the sun / moon.
	light_energy *= GameState.weather_now.get("sun_strength", 1.0)
	RenderingServer.global_shader_parameter_set(&"n64_world_tint", world)
