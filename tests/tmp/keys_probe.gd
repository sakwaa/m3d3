extends Node
func _ready() -> void:
	var d: LevelData = load("res://zones/town1/town_1_market_square_level.res")
	var n := 0
	var keyed := 0
	var lit := 0
	for b in d.brushes:
		if b == null:
			continue
		n += 1
		if b.corner_lighting_keys.size() > 0:
			keyed += 1
		if b.corner_lighting.size() > 0:
			lit += 1
	print("[kp] brushes %d lit %d keyed %d mode %s has_bake %s" % [n, lit, keyed, d.lighting_mode, d.has_bake()])
	get_tree().quit()
