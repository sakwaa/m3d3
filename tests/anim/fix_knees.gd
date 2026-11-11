extends Node
## Fixes backwards knees in the player model's clips: where a key bends a knee the wrong way
## (the shin's local bend about X the wrong sign), mirrors that bend so the knee folds
## forwards. Only the clips named in CLIPS. Then run tests/anim/knee_check.tscn.
##   godot --headless --path . tests/anim/fix_knees.tscn   (editor closed: rewrites the model)

const MODEL := "res://characters/player_model.tscn"
const CLIPS := [&"Jump", &"Fall"]


func _ready() -> void:
	var packed: PackedScene = load(MODEL)
	var root := packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	var data = root.get(&"data")
	var fixed := 0
	for anim: ActorAnimation in data.animations:
		if anim == null or not anim.name in CLIPS:
			continue
		for key in anim.keys:
			var pose: Dictionary = key.pose
			for bone in [&"shin_L", &"shin_R"]:
				if not pose.has(bone):
					continue
				var q: Quaternion = pose[bone]
				if q.x > 0.02:  # bent the wrong way (the clips that bend right have x < 0)
					pose[bone] = Quaternion(-q.x, q.y, q.z, q.w)
					fixed += 1
	var out := PackedScene.new()
	out.pack(root)
	var err := ResourceSaver.save(out, MODEL)
	print("fixed %d shin keys, saved: %s" % [fixed, error_string(err)])
	root.free()
	get_tree().quit()
