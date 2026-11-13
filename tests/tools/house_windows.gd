extends Node
# Ties each house's doors / windows / signs to it (HouseFixtures.adopt) and fills every
# house's walls with windows (HouseFixtures.add_windows, the level tools' "House windows"),
# then saves the level data. Don't run it while the editor has the level open.
# (A scene, so the game's autoloads are there.)
#   godot --headless --path . tests/tools/house_windows.tscn -- res://zones/town1/x_level.res ...
# With "rebuild" first: every house rebuilt (walls fresh, openings cut again), nothing added.
# With "outside" first: no windows added; every window tied to a house is made cheap
# (HouseFixtures.make_cheap: outside only, flat frame) and rebuilt.

var _paths: PackedStringArray
var _roots := []


var _outside := false
var _rebuild := false


func _ready() -> void:
	_paths = OS.get_cmdline_user_args()
	if not _paths.is_empty() and _paths[0] == "outside":
		_outside = true
		_paths = _paths.slice(1)
	elif not _paths.is_empty() and _paths[0] == "rebuild":
		_rebuild = true
		_paths = _paths.slice(1)
	for p in _paths:
		var root := LevelRoot.new()
		root.data = load(p)
		add_child(root)
		_roots.append(root)
	await get_tree().process_frame
	_run()


func _run() -> void:
	for i in _paths.size():
		var root: LevelRoot = _roots[i]
		if _rebuild:
			var houses := root.data.brushes.filter(func(b): return b and b.is_house())
			# (Openings record their cut again first: the rebuild re-cuts them as recorded.)
			for b in root.data.brushes:
				var o: OpeningSpec = b.opening_spec() if b else null
				if o and o.carved:
					o.mark_carved(o.carved_xf)
			for h in houses:
				h.passage_built = 0
				root._generate_house(h, houses)
			print("%s: %d houses rebuilt, saved %s" % [_paths[i].get_file(), houses.size(), error_string(ResourceSaver.save(root.data, _paths[i]))])
			continue
		if _outside:
			var made := 0
			for b in root.data.brushes:
				if b and b.is_window() and b.host != &"":
					HouseFixtures.make_cheap(b.window)
					b.passage_built = 0  # (rebuilt even when its settings didn't change)
					root._generate_window(b)
					made += 1
			print("%s: %d windows made outside-only, saved %s" % [_paths[i].get_file(), made, error_string(ResourceSaver.save(root.data, _paths[i]))])
			continue
		var before := root.data.brushes.size()
		var tied := HouseFixtures.adopt(root.data)
		var added := 0
		var houses := root.data.brushes.filter(func(b): return b and b.is_house())
		for h in houses:
			added += HouseFixtures.add_windows(root, h).size()
		var err := ResourceSaver.save(root.data, _paths[i])
		print("%s: %d houses, tied %d fixtures, added %d windows, brushes %d -> %d, saved %s" % [_paths[i].get_file(),
			houses.size(), tied, added, before, root.data.brushes.size(), error_string(err)])
	get_tree().quit()
