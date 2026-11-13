extends SceneTree
# Builds animation specs into a character model scene, as the actor tools' "From spec..."
# does, without the editor (replacing animations of the same name). Don't run it while the
# editor has the model open.
#   godot --headless --path . -s tests/tools/import_specs.gd -- res://characters/player_model.tscn a.json b.json ...

var _model: ActorModel
var _path := ""
var _specs: PackedStringArray


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		push_error("usage: -- MODEL_SCENE SPEC.json [SPEC.json ...]")
		quit(1)
		return
	_path = args[0]
	_specs = args.slice(1)
	var root: Node = (load(_path) as PackedScene).instantiate()
	_model = root as ActorModel
	if _model == null:
		push_error("%s isn't an ActorModel scene" % _path)
		quit(1)
		return
	_model.authoring = true
	get_root().add_child(_model)


func _process(_delta: float) -> bool:
	var anims := _model.data.animations.duplicate()
	for p in _specs:
		var spec := ActorAnimSpec.load_spec(p)
		if spec.is_empty():
			push_error("not a spec: " + p)
			continue
		var a := ActorAnimSpec.build(_model, spec)
		var at := -1
		for i in anims.size():
			if anims[i].name == a.name:
				at = i
		if at >= 0:
			anims[at] = a
		else:
			anims.append(a)
		print("%s %s (%d frames)" % ["replaced" if at >= 0 else "added", a.name, a.length])
	_model.data.animations = anims
	var packed := PackedScene.new()
	packed.pack(_model)
	print("saved %s: %s" % [_path, error_string(ResourceSaver.save(packed, _path))])
	quit()
	return true
