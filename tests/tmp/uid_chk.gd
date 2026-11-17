extends SceneTree
func _init() -> void:
	var dir := OS.get_environment("DIR")
	for n in ["roof/shingles_3", "concrete/stucco_3", "grass/157_green_grass", "wood/wood_2"]:
		var now := ResourceLoader.get_resource_uid("res://textures/" + n + ".res")
		var head := ResourceLoader.get_resource_uid(dir + "/" + n.get_file() + ".res")
		print("%s now %s head %s %s" % [n, ResourceUID.id_to_text(now), ResourceUID.id_to_text(head), "OK" if now == head else "DIFFERENT"])
	quit()
