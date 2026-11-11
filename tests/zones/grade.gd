extends RefCounted
## A colour grade to try (GRADE=1 in shot / relight runners), in memory only: the project's
## lighting schedule and weather table as loaded are changed (never saved), and a level's
## own light settings on its copy. Kakariko-like noon: warm strong ambient, warmer sun,
## lifted shadows, a deeper sky, yellower grass.

# Noon key (LightingSchedule): ambient sky / ground and the sun.
const NOON_SKY := Color(0.66, 0.66, 0.6)
const NOON_GROUND := Color(0.42, 0.4, 0.33)
const NOON_SUN := Color(1.0, 0.96, 0.86)
# Sunny day sky (WeatherTable): deeper, more saturated; a faint warm world tint.
const DAY_ZENITH := Color(0.2, 0.28, 0.78)
const DAY_HORIZON := Color(0.55, 0.62, 0.95)
const SUNNY_TINT := Color(1.0, 0.98, 0.94)
# Level: lifted floor, softer contrast, yellower grass carpet.
const FLOOR := 0.35
const CONTRAST := 0.7
const INTENSITY := 1.2
const GRASS_TINT := Color(1.08, 1.0, 0.8)


static func apply_globals() -> void:
	var keep := []
	var s := LightingSchedule.load_project()
	for k in s.keys:
		if k.name == "Noon":
			k.sky = NOON_SKY
			k.ground = NOON_GROUND
			k.sun_color = NOON_SUN
	keep.append(s)
	var w := WeatherTable.load_project()
	var sunny := w.find(&"sunny")
	if sunny:
		sunny.world_tint = SUNNY_TINT
		var day = sunny.get_key(2)
		day.zenith = DAY_ZENITH
		day.horizon = DAY_HORIZON
	keep.append(w)
	# (Held so the cache keeps the changed copies for the rest of the run.)
	Engine.set_meta(&"grade_keep", keep)


static func apply_level(data: LevelData) -> void:
	data.light_floor = FLOOR
	data.light_contrast = CONTRAST
	data.light_intensity = INTENSITY
	if data.grass:
		var c: Color = data.grass.color
		data.grass.color = Color(c.r * GRASS_TINT.r, c.g * GRASS_TINT.g, c.b * GRASS_TINT.b)


## TEXWS="res://a.res=8;res://b.res=12": textures' metres per repeat (world_size), in memory.
## CARPET_TILE=4: the grass carpet's texture repeat (metres), on the level given.
static func apply_textures() -> void:
	var keep: Array = Engine.get_meta(&"grade_keep", [])
	for pair in OS.get_environment("TEXWS").split(";", false):
		var kv := pair.split("=")
		var t: Resource = load(kv[0])
		t.set(&"world_size", float(kv[1]))
		keep.append(t)
	Engine.set_meta(&"grade_keep", keep)


static func apply_carpet(data: LevelData) -> void:
	if OS.get_environment("CARPET_TILE") != "" and data.grass:
		data.grass.tile = float(OS.get_environment("CARPET_TILE"))
