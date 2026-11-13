extends Node
# Dresses a level with the textures from the 2026-11 stock-disc import: the doors get the
# new door textures (mixed, fixed seed), every house's plinth stacked stone, and the cement
# floors granite setts. Rebuilds the houses; relight afterwards (tests/zones/relight.tscn).
# (A scene, so the game's autoloads are there.)
#   godot --headless --path . tests/tools/apply_town_textures.tscn -- res://zones/.../x_level.res

const DOORS := ["door_brown_panel", "door_green_plank", "door_weathered_plank", "door_green_weathered_double",
	"door_wooden_arched", "door_green_boards"]
const FOUNDATION := "res://textures/rock/stone_wall_stacked.res"
const FLOOR_FROM := "cement_3.res"
const FLOOR_TO := "res://textures/rock/cobbles_granite_setts.res"


func _ready() -> void:
	var path: String = OS.get_cmdline_user_args()[0]
	var root := LevelRoot.new()
	root.data = load(path)
	add_child(root)
	await get_tree().process_frame
	var data := root.data
	var rng := RandomNumberGenerator.new()
	rng.seed = 2611
	var doors := 0
	for b in data.brushes:
		if b and b.is_door():
			b.door.panel_texture = load("res://textures/doors/%s.res" % DOORS[rng.randi() % DOORS.size()])
			doors += 1
	var houses := data.brushes.filter(func(b): return b and b.is_house())
	var stone: Texture2D = load(FOUNDATION)
	for h in houses:
		h.house.foundation_texture = stone
	for h in houses:
		root._generate_house(h, houses)
	var to := root._palette_index(load(FLOOR_TO))
	var faces := 0
	for b in data.brushes:
		if b == null or b.is_house() or b.is_prop() or b.opening_spec():
			continue
		var ft := b.face_textures.duplicate()
		var changed := false
		for f in b.get_face_count():
			var t := b.get_face_texture(f)
			if t >= 0 and t < data.textures.size() and data.textures[t] and data.textures[t].resource_path.get_file() == FLOOR_FROM \
					and b.get_face_normal(f).y > 0.7:
				ft[f] = to
				changed = true
				faces += 1
		if changed:
			b.face_textures = ft
	print("%s: %d doors, %d houses' plinths, %d cement floor faces -> setts, saved %s" % [path.get_file(), doors, houses.size(), faces,
		error_string(ResourceSaver.save(data, path))])
	get_tree().quit()
