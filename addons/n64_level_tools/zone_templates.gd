@tool
extends RefCounted
## Starter zone scenes for Project > Tools > M3D World. Each gets a Zone root, a LevelRoot
## with a floor grid (LevelData saved next to the scene as <name>_level.res, binary: quick to load) and a
## `default` SpawnPoint, plus:
##  - outdoor: DynamicSky WorldEnvironment (weather + time of day) and a DayNightSun "Sun";
##  - indoor: a dark ambient WorldEnvironment (no weather), a ceiling light, clock paused.

const ZONE_SCRIPT := "res://game/world/zone.gd"
const SKY_SCRIPT := "res://game/sky/dynamic_sky.gd"
const SUN_SCRIPT := "res://game/world/day_night_sun.gd"
const SPAWN_SCRIPT := "res://game/world/spawn_point.gd"


## Builds and saves the zone scene at `path` (.tscn). Returns OK or an error.
static func create(path: String, outdoor: bool) -> Error:
	var zone_name := path.get_file().get_basename()
	var data_path := path.get_basename() + "_level.res"
	if FileAccess.file_exists(data_path):
		push_error("M3D World: %s already exists; pick another zone name." % data_path)
		return ERR_ALREADY_EXISTS

	var data := LevelData.new()
	var floor := LevelBrush.new()
	floor.shape = BrushShapes.Shape.GRID
	floor.size = Vector3(16, 0, 16) if outdoor else Vector3(8, 0, 8)
	floor.segments = 8
	floor.generate_from_shape()
	data.add_brush(floor)
	var err := ResourceSaver.save(data, data_path)
	if err != OK:
		push_error("M3D World: can't save %s (%s)." % [data_path, error_string(err)])
		return err
	data.take_over_path(data_path)

	var root := Node3D.new()
	root.name = zone_name.to_pascal_case()
	root.set_script(load(ZONE_SCRIPT))
	root.set(&"display_name", zone_name.capitalize())
	root.set(&"time_flows", outdoor)

	var world := WorldEnvironment.new()
	world.name = "WorldEnvironment"
	var env := Environment.new()
	if outdoor:
		env.background_mode = Environment.BG_SKY
		world.environment = env
		world.set_script(load(SKY_SCRIPT))
		root.add_child(world)
		var sun := DirectionalLight3D.new()
		sun.name = "Sun"
		sun.rotation_degrees = Vector3(-50, 30, 0)
		# No shadow maps: the player casts a ProjectedShadow decal, props are baked.
		sun.set_script(load(SUN_SCRIPT))
		root.add_child(sun)
	else:
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.02, 0.02, 0.03)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.35, 0.33, 0.3)
		env.ambient_light_energy = 0.5
		env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
		world.environment = env
		root.add_child(world)
		var light := OmniLight3D.new()
		light.name = "Light"
		light.position = Vector3(0, 3, 0)
		light.omni_range = 10.0
		light.light_energy = 1.5
		root.add_child(light)

	var level := LevelRoot.new()
	level.name = "Level"
	level.data = data
	root.add_child(level)

	var spawn := Marker3D.new()
	spawn.name = "Spawn_default"
	spawn.position = Vector3(0, 0, 2)
	spawn.set_script(load(SPAWN_SCRIPT))
	root.add_child(spawn)

	for child in root.get_children():
		child.owner = root
	var packed := PackedScene.new()
	err = packed.pack(root)
	root.free()
	if err != OK:
		return err
	return ResourceSaver.save(packed, path)
