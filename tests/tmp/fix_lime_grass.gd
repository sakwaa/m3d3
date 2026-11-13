@tool
extends EditorScript
## One-off: the market courtyard's grass has lime vertex paint (g = 1, red / blue cut down)
## that crushes the grass's blue into lime. Sets those grass corners to the near-white the
## rest of the level's grass uses (0.95), undoable. Run with the market scene open: File >
## Run (Cmd+Shift+X), then save and Build & Play.

const LEVEL := "res://zones/town1/town_1_market_square_level.res"
const GRASS := "157_green_grass.res"
const PLAIN := Color(0.949, 0.949, 0.949)


func _run() -> void:
	var data: LevelData = load(LEVEL)
	var grass := -1
	for i in data.textures.size():
		if data.textures[i] and data.textures[i].resource_path.get_file() == GRASS:
			grass = i
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Clear lime grass paint", UndoRedo.MERGE_DISABLE, data)
	var n := 0
	for b: LevelBrush in data.brushes:
		if b == null or not b.has_corner_colors():
			continue
		var cc := b.full_corner_colors()
		var c := 0
		var changed := false
		for f in b.get_face_count():
			var ids := b.get_face_vertex_ids(f)
			for k in ids.size():
				var col := cc[c]
				if b.get_face_texture(f) == grass and col.g > 0.98 and col.r < 0.95 and col.b < col.r + 0.05:
					cc[c] = Color(PLAIN, col.a)
					changed = true
					n += 1
				c += 1
		if changed:
			ur.add_do_property(b, &"corner_colors", cc)
			ur.add_undo_property(b, &"corner_colors", b.corner_colors)
	ur.commit_action()
	print("[lime grass] %d corners reset, saved: %s" % [n, error_string(ResourceSaver.save(data, LEVEL))])
