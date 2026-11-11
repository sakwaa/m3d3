extends SceneTree
## Writes the tree species presets (addons/n64_level_tools/trees/species/*.tres) from the
## real-world measurements below. Run: godot --headless --path . -s tests/trees/make_species.gd
## (Edit the .tres files in the inspector afterwards; rerunning this overwrites them.)

const OUT := "res://addons/n64_level_tools/trees/species/"
const BARK := "res://textures/wood/tree_bark.res"


func _init() -> void:
	_save("sycamore", _sycamore())
	_save("oak", _oak())
	_save("fir", _fir())
	_save("willow", _willow())
	quit()


func _save(name: String, sp: TreeSpecies) -> void:
	sp.bark_texture = load(BARK)
	sp.leaf_texture = load("res://textures/plants/leaves_%s.res" % name)
	# (Far cards: tests/trees/make_cards.tscn + assign_cards.gd, see tools/tree_import/cards.sh.)
	print(name, ": ", ResourceSaver.save(sp, OUT + name + ".tres"))


func _level(props: Dictionary) -> TreeLevel:
	var l := TreeLevel.new()
	for k in props:
		l.set(k, props[k])
	return l


func _sycamore() -> TreeSpecies:
	var sp := TreeSpecies.new()
	sp.display_name = "Sycamore"
	sp.reference = "Acer pseudoplatanus (field sycamore, Yorkshire Dales photo + typical form): 20-35 m wild, crown broad and domed ~0.75x the height, clear trunk ~1/4-1/3, trunk runs to ~2/3 before dividing, limbs ascending 30-45 deg from vertical. Game scale 14 m."
	sp.height = 14.0
	sp.trunk_radius = 0.42
	sp.trunk_taper = 0.35
	sp.root_flare = 0.2
	sp.trunk_top = 0.65
	sp.clear = 0.22
	sp.crown = TreeSpecies.Crown.DOME
	sp.sides = 6
	sp.segments = 4
	sp.levels = [
		_level({count = 10, angle = 62.0, angle_var = 12.0, length = 0.5, curve = 25.0, wander = 6.0, radius = 0.55, sides = 4, segments = 2}),
		_level({count = 3, start = 0.3, angle = 50.0, angle_var = 15.0, length = 0.55, curve = -5.0, wander = 10.0, radius = 0.5, bark = false, segments = 1}),
	]
	sp.cards = TreeSpecies.Cards.CLUMPS
	sp.card_size = 3.2
	sp.clumps = 2
	sp.inner_clumps = 2
	sp.leaf_start = 0.3
	sp.bark_color = Color(0.58, 0.55, 0.5)
	return sp


func _oak() -> TreeSpecies:
	var sp := TreeSpecies.new()
	sp.display_name = "Oak"
	sp.reference = "Quercus robur (English oak, open-grown): 20-40 m, crown as wide as tall or wider, short bole 3-5 m, dividing low into heavy sinuous limbs spreading 50-70 deg from vertical, rising again at their ends. Game scale 12 m."
	sp.height = 12.0
	sp.trunk_radius = 0.6
	sp.trunk_taper = 0.4
	sp.root_flare = 0.3
	sp.trunk_top = 0.45
	sp.clear = 0.22
	sp.wander = 8.0
	sp.crown = TreeSpecies.Crown.SPREADING
	sp.sides = 6
	sp.segments = 3
	sp.levels = [
		_level({count = 8, angle = 62.0, angle_var = 7.0, length = 0.6, length_var = 0.07, curve = 25.0, curve_power = 1.5, wander = 8.0, radius = 0.6, sides = 4, segments = 3}),
		_level({count = 4, start = 0.3, angle = 50.0, angle_var = 12.0, length = 0.5, length_var = 0.1, curve = -10.0, wander = 12.0, radius = 0.5, bark = false, segments = 1}),
	]
	sp.cards = TreeSpecies.Cards.CLUMPS
	sp.card_size = 2.6
	sp.clumps = 2
	sp.inner_clumps = 2
	sp.leaf_start = 0.35
	sp.bark_color = Color(0.46, 0.42, 0.37)
	return sp


func _fir() -> TreeSpecies:
	var sp := TreeSpecies.new()
	sp.display_name = "Fir"
	sp.reference = "Abies alba (silver fir) / spruce form: narrow cone ~0.35x the height, straight leader to the top, branches in whorls nearly horizontal (75-90 deg from vertical), drooping slightly, crown down to ~10% of the height. Game scale 15 m."
	sp.height = 15.0
	sp.trunk_radius = 0.3
	sp.trunk_taper = 0.08
	sp.root_flare = 0.15
	sp.trunk_top = 1.0
	sp.clear = 0.1
	sp.lean = 1.0
	sp.wander = 1.5
	sp.crown = TreeSpecies.Crown.CONICAL
	sp.sides = 6
	sp.segments = 5
	sp.levels = [
		_level({count = 5, whorls = 13, end = 0.97, angle = 80.0, angle_var = 8.0, length = 0.36, length_var = 0.2, curve = -14.0, wander = 6.0, radius = 0.35, bark = false, segments = 2}),
	]
	sp.cards = TreeSpecies.Cards.SPRAYS
	sp.card_size = 3.0
	sp.leaf_start = 0.0
	sp.crown_ao = 0.4
	sp.bark_color = Color(0.48, 0.38, 0.32)
	return sp


func _willow() -> TreeSpecies:
	var sp := TreeSpecies.new()
	sp.display_name = "Weeping willow"
	sp.reference = "Salix babylonica / x sepulcralis: 10-20 m, crown broad and rounded, wider than tall (~1.2x), short trunk 1.5-3 m dividing into several ascending limbs that arch over; branchlets hang straight down, nearly to the ground. Game scale 10 m."
	sp.height = 11.0
	sp.trunk_radius = 0.45
	sp.trunk_taper = 0.45
	sp.root_flare = 0.25
	sp.trunk_top = 0.4
	sp.clear = 0.25
	sp.crown = TreeSpecies.Crown.CYLINDER
	sp.sides = 6
	sp.segments = 3
	sp.levels = [
		_level({count = 7, angle = 18.0, angle_var = 12.0, length = 0.85, curve = -115.0, curve_power = 3.5, wander = 6.0, radius = 0.6, sides = 4, segments = 4}),
		_level({count = 3, start = 0.4, angle = 40.0, angle_var = 15.0, length = 0.4, curve = -40.0, curve_power = 2.0, wander = 6.0, radius = 0.45, bark = false, segments = 2}),
	]
	sp.cards = TreeSpecies.Cards.HANGING
	sp.card_size = 1.6
	sp.hang_length = 8.0
	sp.clumps = 3
	sp.inner_clumps = 3
	sp.leaf_start = 0.3
	sp.crown_ao = 0.35
	sp.bark_color = Color(0.5, 0.45, 0.38)
	return sp
