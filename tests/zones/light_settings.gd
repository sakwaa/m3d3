extends Node
## A level's (LEVEL) lighting settings and the project schedule's keys.


func _ready() -> void:
	var d: LevelData = ResourceLoader.load(OS.get_environment("LEVEL"), "", ResourceLoader.CACHE_MODE_IGNORE)
	for p in ["lighting_mode", "light_sky", "light_ground", "light_ao_strength", "light_intensity", "light_contrast", "light_floor", "light_bake_strength", "light_min_sun_elevation"]:
		print("  %s = %s" % [p, d.get(p)])
	var s := LightingSchedule.load_project()
	if s:
		for prop in s.get_property_list():
			if prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
				print("schedule %s = %s" % [prop.name, str(s.get(prop.name)).left(600)])
	get_tree().quit()
