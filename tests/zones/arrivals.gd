extends Node
## Lists each zone's arrival ids (ZoneArrivals: what target_spawn offers in the inspector).
##   godot --headless --path . tests/zones/arrivals.tscn


func _ready() -> void:
	for z in ["res://zones/town1/town_1_market_square.tscn", "res://zones/town1/house_outside_town.tscn", "res://zones/town1/town_1_hillside.tscn"]:
		var t := Time.get_ticks_msec()
		var ids := ZoneArrivals.ids(z)
		var t2 := Time.get_ticks_msec()
		ZoneArrivals.ids(z)
		print("%s: %s (%d ms, cached %d ms)" % [z.get_file(), ids, t2 - t, Time.get_ticks_msec() - t2])
	var p := PassageSpec.new()
	p.target_zone = "res://zones/town1/house_outside_town.tscn"
	for prop in p.get_property_list():
		if prop.name == "target_spawn":
			print("inspector hint: ", prop.hint == PROPERTY_HINT_ENUM_SUGGESTION, " ", prop.hint_string)
	get_tree().quit()
