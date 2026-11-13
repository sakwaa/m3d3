extends Node
## Test copy of a level with drawing rooms (Room prop brushes) on a grid of boxes: x / z
## split lines (level space), every box ROOM_H tall. Saves to OUT; never touches LEVEL.
##   LEVEL=res://... XS=-75,-35,33,75 ZS=-75,-35,35,75 OUT=/path.res godot --path . tests/zones/add_rooms.tscn


func _ready() -> void:
	var data: LevelData = (load(OS.get_environment("LEVEL")) as LevelData).duplicate(true)
	var xs := Array(OS.get_environment("XS").split(",")).map(func(v): return float(v))
	var zs := Array(OS.get_environment("ZS").split(",")).map(func(v): return float(v))
	var brushes := data.brushes.duplicate()
	for i in xs.size() - 1:
		for k in zs.size() - 1:
			var b := LevelBrush.new()
			var p := PropSpec.new()
			p.kind = PropSpec.Kind.ROOM
			p.settings = {room_id = StringName("r%d_%d" % [i, k]), size = Vector3(xs[i + 1] - xs[i], 30.0, zs[k + 1] - zs[k])}
			b.prop = p
			b.transform = Transform3D(Basis(), Vector3((xs[i] + xs[i + 1]) * 0.5, -1.0, (zs[k] + zs[k + 1]) * 0.5))
			b.ensure_geometry()
			# (As LevelRoot._generate_prop leaves a prop's pick box: never drawn or collided.)
			var fb := PackedByteArray()
			fb.resize(b.get_face_count())
			fb.fill(3)
			b.face_bake = fb
			if i == 0 and k == 0:
				print("room brush faces: %d" % b.get_face_count())
			brushes.append(b)
	data.brushes = brushes
	print("rooms: ", RoomVis.rooms(data).map(func(r): return String(r.id)))
	print("saved ", error_string(ResourceSaver.save(data, OS.get_environment("OUT"), ResourceSaver.FLAG_COMPRESS)))
	get_tree().quit()
