extends SceneTree
## Tree importer, step 2: writes a TreeSpecies preset per photo analysed by
## tools/tree_import/tree_import.py (run everything with tools/tree_import/import.sh).
##   Godot --headless --path . -s res://addons/n64_level_tools/trees/tree_import.gd -- <analysis.json>
## Each species starts from its archetype's branching (broadleaf, spreading, columnar,
## conifer, weeping) and takes from the photo: the crown's outline, how wide it is, the
## bare trunk, trunk thickness, bark colour, its leaf cut-out and far card
## (textures/plants/leaves_<name>.res, tree_card_<name>.res, imported before this runs).
## Real heights are scaled to the game (GAME_SCALE). Palms aren't generated (no archetype
## yet): listed and skipped. Existing presets are overwritten (edit them after importing,
## or rename them).

const OUT := "res://addons/n64_level_tools/trees/species/"
const BARK := "res://textures/wood/tree_bark.res"
## Real height -> game height, and the range kept.
const GAME_SCALE := 0.6
const MIN_HEIGHT := 4.0
const MAX_HEIGHT := 18.0
## Average brightness of the bark texture (the photo's bark colour is a tint over it).
const BARK_LEVEL := 0.62


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("usage: -- <analysis.json>")
		quit(1)
		return
	var list: Array = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	for a: Dictionary in list:
		if a.archetype == "palm":
			print("SKIP %s (palm: no archetype yet)" % a.name)
			continue
		var sp := _species(a)
		var path := OUT + String(a.name) + ".tres"
		var err := ResourceSaver.save(sp, path)
		print("%s %s -> %s" % ["OK" if err == OK else "ERR %d" % err, a.name, path])
	quit()


func _level(props: Dictionary) -> TreeLevel:
	var l := TreeLevel.new()
	for k in props:
		l.set(k, props[k])
	return l


func _species(a: Dictionary) -> TreeSpecies:
	var sp := TreeSpecies.new()
	var name: String = a.name
	sp.display_name = name.capitalize()
	sp.latin = a.get("latin", "")
	var h := clampf(float(a.height) * GAME_SCALE, MIN_HEIGHT, MAX_HEIGHT)
	sp.height = h
	sp.reference = "Imported from %s (%s, archetype %s, real height ~%d m): crown %.2fx the height, bare trunk %.0f%%, widest at %.0f%% of the crown." % [
		a.source, sp.latin, a.archetype, int(a.height), a.crown_width, a.clear * 100.0, a.widest * 100.0]
	sp.crown = TreeSpecies.Crown.PROFILE
	sp.crown_profile = PackedFloat32Array(a.profile)
	sp.clear = clampf(float(a.clear) - 0.04, 0.0, 0.6)
	sp.trunk_radius = clampf(float(a.trunk_width) * 0.5 * h, 0.08, 0.9)
	var bark: Array = a.bark_rgb
	sp.bark_color = Color(minf(bark[0] / BARK_LEVEL, 1.0), minf(bark[1] / BARK_LEVEL, 1.0), minf(bark[2] / BARK_LEVEL, 1.0))
	sp.card_size = clampf(h * 0.24, 1.2, 3.8)
	var half := float(a.crown_width) * 0.5 * h  # metres from the trunk to the crown's edge
	var reach := maxf(half - sp.card_size * 0.4, 0.3)
	match String(a.archetype):
		"spreading":
			sp.trunk_top = 0.45
			sp.wander = 8.0
			var ang := 65.0
			sp.levels = [
				_level({count = 7, angle = ang, angle_var = 12.0, length = _len(reach, ang, h), curve = 25.0, curve_power = 1.5, wander = 10.0, radius = 0.6, sides = 4, segments = 3}),
				_level({count = 4, start = 0.3, angle = 50.0, angle_var = 15.0, length = 0.5, curve = -10.0, wander = 15.0, radius = 0.5, bark = false, segments = 1}),
			]
			sp.clumps = 3
			sp.inner_clumps = 2
			sp.leaf_start = 0.3
		"columnar":
			sp.trunk_top = 1.0
			sp.lean = 1.0
			var ang := 22.0
			sp.levels = [
				_level({count = 14, angle = ang, angle_var = 8.0, length = _len(reach + sp.card_size * 0.3, ang, h), curve = 5.0, wander = 5.0, radius = 0.4, bark = false, segments = 1}),
			]
			sp.card_size = clampf(half * 1.6, 1.0, 3.0)
			sp.clumps = 2
			sp.leaf_start = 0.1
		"conifer":
			sp.trunk_top = 1.0
			sp.lean = 1.0
			sp.wander = 1.5
			sp.trunk_taper = 0.1
			var ang := 78.0
			sp.levels = [
				_level({count = 4, whorls = 9, end = 0.97, angle = ang, angle_var = 8.0, length = _len(reach, ang, h), length_var = 0.2, curve = -12.0, wander = 6.0, radius = 0.35, bark = false, segments = 2}),
			]
			sp.clumps = 3
			sp.leaf_start = 0.15
			sp.crown_ao = 0.4
		"weeping":
			sp.trunk_top = 0.4
			var ang := 22.0
			sp.levels = [
				_level({count = 7, angle = ang, angle_var = 12.0, length = _len(reach, 55.0, h), curve = -115.0, curve_power = 3.5, wander = 6.0, radius = 0.6, sides = 4, segments = 4}),
				_level({count = 3, start = 0.4, angle = 40.0, angle_var = 15.0, length = 0.4, curve = -40.0, curve_power = 2.0, wander = 6.0, radius = 0.45, bark = false, segments = 2}),
			]
			sp.cards = TreeSpecies.Cards.HANGING
			sp.card_size = clampf(h * 0.14, 1.0, 1.8)
			sp.hang_length = h * 0.75
			sp.clumps = 3
			sp.inner_clumps = 3
			sp.leaf_start = 0.3
			sp.crown_ao = 0.35
		_:  # broadleaf
			sp.trunk_top = 0.65
			var ang := 58.0
			sp.levels = [
				_level({count = 9, angle = ang, angle_var = 12.0, length = _len(reach, ang, h), curve = 20.0, wander = 7.0, radius = 0.55, sides = 4, segments = 2}),
				_level({count = 3, start = 0.3, angle = 50.0, angle_var = 15.0, length = 0.55, curve = -5.0, wander = 10.0, radius = 0.5, bark = false, segments = 1}),
			]
			sp.clumps = 2
			sp.inner_clumps = 2
			sp.leaf_start = 0.3
	sp.bark_texture = load(BARK)
	sp.leaf_texture = _tex("res://textures/plants/leaves_%s.res" % name)
	var card := _tex("res://textures/plants/tree_card_%s.res" % name)
	sp.card_aspect = float(a.aspect)
	if card:
		sp.card_textures = [card] as Array[Texture2D]
		sp.card_aspects = PackedFloat32Array([sp.card_aspect])
	return sp


## Level-1 length (fraction of the height) for limbs at `angle` to reach `reach` metres out.
func _len(reach: float, angle: float, h: float) -> float:
	return clampf(reach / maxf(sin(deg_to_rad(angle)), 0.2) / h, 0.08, 1.0)


func _tex(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path)
	push_warning("missing texture " + path)
	return null
