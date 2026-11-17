extends Node
func _ready() -> void:
	var zone: Zone = (load("res://zones/town1/town_1_market_square.tscn") as PackedScene).instantiate()
	add_child(zone)
	for h in [0.0, 6.5, 12.0, 18.0]:
		GameState.set_time(h)
		await get_tree().process_frame
		var a := zone.fog_target()
		var sky: Node = zone.get_children().filter(func(n): return n is DynamicSky)[0] if zone.get_children().any(func(n): return n is DynamicSky) else null
		var w := WeatherTable.sample(WeatherTable.load_project().find(GameState.weather), LightingSchedule.load_project(), h) if sky else {}
		var b := Zone.fog_for(zone.fog, false, sky != null, w, LightingSchedule.load_project(), h)
		print("[fm] %5.1fh game %s %.1f-%.1f amt %.2f | preview %s %.1f-%.1f amt %.2f" % [h, (a.color as Color).to_html(false), a.start, a.end, a.amount, (b.color as Color).to_html(false), b.start, b.end, b.amount])
	get_tree().quit()
