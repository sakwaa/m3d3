extends MeshInstance3D
## Demo actor: a spinning crystal that logs when its room spawns or frees it.

@export var color := Color(0.4, 0.8, 1.0)


func _ready() -> void:
	var prism := PrismMesh.new()
	prism.size = Vector3(0.5, 0.8, 0.5)
	mesh = prism
	material_override = N64Materials.actor(color, null, N64Materials.Shine.GLOSS, 0.6, 0.8)
	print("[actor] spawned %s" % get_path())


func _exit_tree() -> void:
	print("[actor] removed %s" % name)


func _process(delta: float) -> void:
	rotate_y(delta * 1.5)
