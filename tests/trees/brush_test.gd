extends Node
## Tree prop brush check: LevelRoot builds the tree node, its pick box, a seed re-roll
## through the PropSpec inspector path, and the export bake (parts saved, species dropped).
##   godot --headless --path . tests/trees/brush_test.tscn
func _ready():
	await get_tree().process_frame
	var scene := Node3D.new()
	get_tree().root.add_child(scene)
	var data := LevelData.new()
	var root := LevelRoot.new()
	root.data = data
	scene.add_child(root)
	var spec := PropSpec.new()
	spec.kind = PropSpec.Kind.TREE
	spec.settings = {species = load("res://addons/n64_level_tools/trees/species/sycamore.tres"), seed = 7}
	var b := LevelBrush.new()
	b.tag = &"prop_test"
	b.hand_edited = true
	b.prop = spec
	data.add_brush(b)
	await get_tree().process_frame
	root._sync_props()
	await get_tree().process_frame
	var node = root._prop_nodes.get(b)
	print("node ", node, " parts ", node.get_child_count(true), " bounds ", node.prop_bounds())
	root._generate_prop(b)
	print("brush verts ", b.vertices.size())
	# template inspector path: tick new_seed through PropSpec
	spec.set(&"new_seed", true)
	print("seed after reroll ", spec.settings.get(&"seed"), " settings keys ", spec.settings.keys())
	root.make_prop_nodes_for_export(scene)
	var owned := 0
	for c in node.get_children():
		owned += int(c.owner == scene)
	print("baked ", node.baked, " species ", node.species, " saved children ", node.get_child_count(false), " owned ", owned)
	var ps := PackedScene.new()
	print("pack ", ps.pack(scene))
	get_tree().quit()
