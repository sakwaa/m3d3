@tool
extends Node
## Set pieces: level brushes whose geometry is made in Blender (an amphitheatre sunk into
## a hillside, anything too unique for the brush tools). One .blend per set piece
## (<zone>/blend/<name>.blend), one brush per Blender object, named like it. Godot keeps
## where they stand (brush transforms) and all paint, lighting and baking:
##  - create(): moves the selected brushes into a new .blend (in the first one's space)
##    and opens it in Blender, with the level around them shown there (Surroundings);
##  - saving the .blend, or any edit while it's open in Blender, brings the geometry
##    back: objects become brushes by name (new ones are added, deleted ones removed).
##    Paint follows faces by the id the .blend keeps on each face (`n64_face`), else the
##    nearest old face; vertex colours the nearest old vertex. Baked lighting / AO of a
##    reshaped brush is dropped (re-bake);
##  - linked brushes move, rotate, duplicate (a copy of the whole set piece follows the
##    file too) and paint here; reshaping them is Blender's.
## Shares the bridge and add-on with the character tools (n64_actor_tools/blender).

const ActorBlender := preload("res://addons/n64_actor_tools/actor_blender.gd")
const PassageBuilder := preload("res://addons/n64_level_tools/passage_builder.gd")
## Godot (Y up) <-> Blender (Z up): x stays, Godot's -Z is Blender's +Y. Inverses.
const TO_BLENDER := Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0))
const FROM_BLENDER := Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0))
## The level shown around a set piece in Blender: faces this far around it (metres).
const CONTEXT_MARGIN := 12.0
const CONTEXT_MAX_FACES := 20000
## Vertex colours carry to new vertices this close to a painted one (metres).
const COLOUR_REACH := 0.1

var plugin
## blend file (res://) -> the last pull's problems [{object, message}].
var issues := {}
var _job := {}
var _poll := 0.0
var _link_text := {}
var _geo_seq := {}
var _select := {}
var _select_seq := 0
## blend file -> surroundings version (Blender rebuilds them when it changes).
var _context_key := {}


func busy() -> bool:
	return not _job.is_empty()


func _process(delta: float) -> void:
	if not _job.is_empty():
		if not OS.is_process_running(_job.pid):
			var job := _job
			_job = {}
			job.done.call(ActorBlender._read_result(job.out))
		return
	_poll -= delta
	if _poll > 0.0:
		return
	_poll = 0.25
	var files := linked()
	for file: String in files:
		write_link(file)
		var path := ProjectSettings.globalize_path(file)
		if not FileAccess.file_exists(path):
			continue
		if FileAccess.get_modified_time(path) != files[file][0].brush.blend_stamp:
			pull(file)
			return
		# While the file is open in Blender, its geometry arrives after every edit.
		var geo := _paths(file, ".n64geo.json", ".n64geo.seq")
		if FileAccess.file_exists(geo[1]):
			var seq := FileAccess.get_file_as_string(geo[1])
			if seq != _geo_seq.get(file, ""):
				var first := not _geo_seq.has(file)
				_geo_seq[file] = seq
				if not first:
					_pulled(file, ActorBlender._read_result(geo[0]), true)


## Brushes in the edited scene made in a .blend: file -> [{root, brush}].
func linked() -> Dictionary:
	var out := {}
	for root: LevelRoot in plugin._scene_level_roots():
		if root.data == null:
			continue
		for b in root.data.brushes:
			if b.blend_file != "":
				out.get_or_add(b.blend_file, []).append({root = root, brush = b})
	return out


static func _paths(file: String, a: String, b: String) -> PackedStringArray:
	var base := ProjectSettings.globalize_path(file).get_basename()
	return PackedStringArray([base + a, base + b])


## The .blend is open in Blender (with the add-on).
static func is_live(file: String) -> bool:
	var live := _paths(file, ".n64link.json", ".n64live.json")[1]
	return FileAccess.file_exists(live) and Time.get_unix_time_from_system() - FileAccess.get_modified_time(live) < ActorBlender.LIVE_SECONDS


func _run(args: PackedStringArray, out: String, done: Callable, wait := false) -> void:
	var bin := ActorBlender.blender_binary()
	if bin == "":
		done.call({ok = false, error = "Blender not found (Editor Settings > FileSystem > Import > Blender > Blender Path)."})
		return
	DirAccess.remove_absolute(out)
	if wait:
		OS.execute(bin, args)
		done.call(ActorBlender._read_result(out))
		return
	var pid := OS.create_process(bin, args)
	if pid <= 0:
		done.call({ok = false, error = "Can't start Blender (%s)." % bin})
		return
	_job = {pid = pid, out = out, done = done}


# --- Create / open ---------------------------------------------------------------------------

## Moves `brushes` (of `root`, not linked yet) into a new .blend named `set_name` next to
## the scene and opens it in Blender (`open`). One undo step (the file stays). Returns the
## file (res://), "" when it failed (with a message).
func create(root: LevelRoot, brushes: Array[LevelBrush], set_name: String, open := true) -> String:
	if busy() or brushes.is_empty():
		return ""
	var scene_path := EditorInterface.get_edited_scene_root().scene_file_path
	var dir_res := (scene_path.get_base_dir() if scene_path != "" else "res://zones").path_join("blend")
	var dir := ProjectSettings.globalize_path(dir_res)
	DirAccess.make_dir_recursive_absolute(dir)
	if not FileAccess.file_exists(dir.path_join(".gdignore")):
		FileAccess.open(dir.path_join(".gdignore"), FileAccess.WRITE).store_string("")
	var base := N64TextureConverter.clean_name(set_name) if set_name.strip_edges() != "" else "set_piece"
	var res := dir_res.path_join(base + ".blend")
	var n := 2
	while FileAccess.file_exists(ProjectSettings.globalize_path(res)):
		res = dir_res.path_join("%s_%d.blend" % [base, n])
		n += 1
	var file := ProjectSettings.globalize_path(res)
	# The set piece's space is the first brush's: the others are placed in it. Ids on
	# every face, so the paint lands back on the same faces.
	var anchor: Transform3D = brushes[0].transform
	var inv := anchor.affine_inverse()
	var pool := []
	var objects := []
	var names := {}
	var next_id := 1
	for b in brushes:
		var obj_name := String(b.tag) if b.tag != &"" else (base.capitalize().replace(" ", "") if objects.is_empty() else "Piece")
		names[obj_name] = names.get(obj_name, 0) + 1
		if names[obj_name] > 1:
			obj_name += "_%d" % names[obj_name]
		var xf := inv * b.transform
		var verts := PackedVector3Array()
		var bverts := []
		for v in b.vertices:
			verts.append(xf * v)
			bverts.append(ActorBlender._a(TO_BLENDER * (xf * v)))
		var ids := PackedInt32Array()
		var faces := []
		for f in b.get_faces():
			faces.append(Array(f))
			ids.append(next_id)
			next_id += 1
		pool.append({brush = b, verts = verts, ids = ids, name = obj_name})
		objects.append({name = obj_name, verts = bverts, faces = faces, face_ids = Array(ids)})
	var context := _paths(res, ".n64context.json", "")[0]
	_write_surroundings(context, brushes, root.global_transform * anchor)
	var spec := {name = base, objects = objects, settings = _settings(), context = context}
	var spec_path := ActorBlender._temp("create_set.json")
	FileAccess.open(spec_path, FileAccess.WRITE).store_string(JSON.stringify(spec))
	var out := ActorBlender._temp("create_set_result.json")
	var made := {}
	_run(PackedStringArray(["-b", "--factory-startup", "--python", ActorBlender._script("bridge.py"), "--", "create_set", spec_path, file, out]), out,
		func(r): made.merge(r), true)
	if not made.get("ok", false):
		ActorBlender._toast("Couldn't make %s: %s" % [res, made.get("error", "")], true)
		return ""
	var dump := {}
	var dump_out := ActorBlender._temp("dump_set.json")
	_run(PackedStringArray(["-b", "--factory-startup", file, "--python", ActorBlender._script("bridge.py"), "--", "dump", dump_out]), dump_out,
		func(r): dump.merge(r), true)
	if not dump.get("ok", false):
		ActorBlender._toast("Made %s but couldn't read it back: %s" % [res, dump.get("error", "")], true)
		return ""
	issues[res] = dump.get("issues", [])
	var by_name := {}
	for obj: Dictionary in dump.get("objects", []):
		by_name[obj.name] = obj
	var stamp := FileAccess.get_modified_time(file)
	var ur: EditorUndoRedoManager = plugin.get_undo_redo()
	ur.create_action("Move Brushes to Blender", UndoRedo.MERGE_DISABLE, root)
	for e: Dictionary in pool:
		var b: LevelBrush = e.brush
		var obj: Dictionary = by_name.get(e.name, {})
		if obj.is_empty():
			continue
		var state := _state(obj, [e], b, true)
		state.transform = anchor
		state.blend_file = res
		state.blend_object = e.name
		state.blend_stamp = stamp
		for key: String in state:
			ur.add_do_property(b, key, state[key])
			ur.add_undo_property(b, key, b.get(key))
	ur.commit_action()
	if open:
		open_blender(res, pool[0].name)
	return res


## Opens a set piece's .blend in Blender with the link add-on (brings it forward when it's
## open already), selecting `object`; the level around it is refreshed there.
func open_blender(file: String, object := "") -> void:
	refresh_surroundings(file)
	_select_seq += 1
	_select[file] = {seq = _select_seq, object = object}
	_link_text.erase(file)
	write_link(file)
	var bin := ActorBlender.blender_binary()
	if bin == "":
		ActorBlender._toast("Blender not found: set Editor Settings > FileSystem > Import > Blender > Blender Path.", true)
		return
	if is_live(file):
		if OS.get_name() == "macOS":
			OS.create_process("open", ["-a", bin.get_base_dir().get_base_dir().get_base_dir()])
		return
	OS.create_process(bin, [ProjectSettings.globalize_path(file), "--python", ActorBlender._script("launch.py")])


## Rewrites what Blender shows around the set piece (the level, its door cuts); an open
## Blender picks it up.
func refresh_surroundings(file: String) -> void:
	var entries: Array = linked().get(file, [])
	if entries.is_empty():
		return
	var e: Dictionary = entries[0]
	var group: Array[LevelBrush] = []
	for x: Dictionary in entries:
		group.append(x.brush)
	_write_surroundings(_paths(file, ".n64context.json", "")[0], group, e.root.global_transform * e.brush.transform)


## Back to the brush tools for `brushes` (the .blend stays).
func unlink(root: LevelRoot, brushes: Array[LevelBrush]) -> void:
	var ur: EditorUndoRedoManager = plugin.get_undo_redo()
	ur.create_action("Unlink From Blender", UndoRedo.MERGE_DISABLE, root)
	for b in brushes:
		ur.add_do_property(b, &"blend_file", "")
		ur.add_undo_property(b, &"blend_file", b.blend_file)
	ur.commit_action()


## Of `files`, those no brush uses any more: none in the edited scene, none in the other
## levels and scenes under res://zones (as saved).
func orphaned(files: Array) -> PackedStringArray:
	var used := linked()
	var skip := {}
	var scene := EditorInterface.get_edited_scene_root()
	if scene:
		skip[scene.scene_file_path] = true
	for root: LevelRoot in plugin._scene_level_roots():
		if root.data:
			skip[root.data.resource_path] = true
	var texts: Array[String] = []
	_saved_texts("res://zones", skip, texts)
	var out := PackedStringArray()
	for file: String in files:
		if used.has(file) or out.has(file):
			continue
		var quoted := "\"%s\"" % file
		if not texts.any(func(t: String): return t.contains(quoted)):
			out.append(file)
	return out


static func _saved_texts(dir: String, skip: Dictionary, out: Array[String]) -> void:
	for sub in DirAccess.get_directories_at(dir):
		_saved_texts(dir.path_join(sub), skip, out)
	for f in DirAccess.get_files_at(dir):
		var path := dir.path_join(f)
		if (f.ends_with(".tres") or f.ends_with(".tscn")) and not skip.has(path):
			out.append(FileAccess.get_file_as_string(path))


## Moves a set piece's .blend (and Blender's .blend1 backup) to the Trash and removes the
## link files beside it. "" when done, else why not (open in Blender).
func trash(file: String) -> String:
	if is_live(file):
		return "%s is open in Blender: close it there first." % file.get_file()
	var base := ProjectSettings.globalize_path(file).get_basename()
	for ext in [".blend", ".blend1"]:
		if FileAccess.file_exists(base + ext):
			var err := OS.move_to_trash(base + ext)
			if err != OK:
				return "Can't move %s to the Trash (%s)." % [(base + ext).get_file(), error_string(err)]
	for ext in [".n64link.json", ".n64live.json", ".n64geo.json", ".n64geo.seq", ".n64context.json"]:
		DirAccess.remove_absolute(base + ext)
	issues.erase(file)
	_link_text.erase(file)
	_geo_seq.erase(file)
	_select.erase(file)
	_context_key.erase(file)
	return ""


# --- Pull ------------------------------------------------------------------------------------

## Reads a set piece's .blend into its brushes (in the background), one undo step.
func pull(file: String) -> void:
	if busy():
		return
	var path := ProjectSettings.globalize_path(file)
	var stamp := FileAccess.get_modified_time(path)
	for e: Dictionary in linked().get(file, []):
		e.brush.blend_stamp = stamp
	var out := ActorBlender._temp("dump_set.json")
	_run(PackedStringArray(["-b", "--factory-startup", path, "--python", ActorBlender._script("bridge.py"), "--", "dump", out]), out,
		func(r): _pulled(file, r))


## Geometry read from Blender (a saved .blend, or `live` after an edit there) into every
## copy of the set piece: brushes standing together (same level, same transform) are one
## copy. One undo step (live ones merge).
func _pulled(file: String, r: Dictionary, live := false) -> void:
	if not r.get("ok", false):
		if not live:
			ActorBlender._toast("Couldn't read %s: %s" % [file, r.get("error", "")], true)
		return
	issues[file] = r.get("issues", [])
	var entries: Array = linked().get(file, [])
	var objects: Array = r.get("objects", [])
	if entries.is_empty() or objects.is_empty():
		return
	var copies := []
	for e: Dictionary in entries:
		var copy: Dictionary = {}
		for c: Dictionary in copies:
			if c.root == e.root and c.transform.is_equal_approx(e.brush.transform):
				copy = c
		if copy.is_empty():
			copy = {root = e.root, transform = e.brush.transform, brushes = []}
			copies.append(copy)
		copy.brushes.append(e.brush)
	var names := {}
	for obj: Dictionary in objects:
		names[obj.name] = true
	var stamp := FileAccess.get_modified_time(ProjectSettings.globalize_path(file))
	var ur: EditorUndoRedoManager = plugin.get_undo_redo()
	var changed := 0
	var added := 0
	var removed := 0
	ur.create_action("Geometry from Blender" if live else "Pull Set Piece", UndoRedo.MERGE_ENDS if live else UndoRedo.MERGE_DISABLE, entries[0].root)
	for copy: Dictionary in copies:
		var data: LevelData = copy.root.data
		var pool := []
		var by_name := {}
		for b: LevelBrush in copy.brushes:
			pool.append({brush = b, verts = b.vertices, ids = b.face_ids})
			by_name[b.blend_object] = b
		var sibling: LevelBrush = copy.brushes[0]
		for obj: Dictionary in objects:
			var b: LevelBrush = by_name.get(obj.name)
			var state := _state(obj, pool, b)
			if b != null and not b.cuts.is_empty():
				state = _recut(state, b)
			if b == null:
				b = LevelBrush.new()
				b.hand_edited = true
				b.material = sibling.material
				b.bake_mode = sibling.bake_mode
				b.transform = copy.transform
				b.blend_file = file
				b.blend_object = obj.name
				b.blend_stamp = stamp
				for key: String in state:
					b.set(key, state[key])
				ur.add_do_method(data, &"add_brush", b)
				ur.add_do_reference(b)
				ur.add_undo_method(data, &"remove_brush", b)
				added += 1
				continue
			if b.vertices == state.vertices and b.face_indices == state.face_indices and b.face_counts == state.face_counts and b.face_ids == state.face_ids:
				continue
			for key: String in state:
				ur.add_do_property(b, key, state[key])
				ur.add_undo_property(b, key, b.get(key))
			changed += 1
		for b: LevelBrush in copy.brushes:
			if not names.has(b.blend_object):
				ur.add_do_method(data, &"remove_brush", b)
				ur.add_undo_method(data, &"add_brush", b, data.brushes.find(b))
				ur.add_undo_reference(b)
				removed += 1
	ur.commit_action()
	if live:
		return
	var text := "Pulled %s: %d changed, %d added, %d removed" % [file.get_file(), changed, added, removed]
	var found: Array = issues[file]
	if not found.is_empty():
		text += " · %d problem%s (Blender's N64 Set Piece panel)" % [found.size(), "" if found.size() == 1 else "s"]
	ActorBlender._toast(text, false)


## A brush's geometry and paint for one Blender object (set piece space): paint from the
## `pool` ([{brush, verts (set piece space), ids}]): each face takes its old face's (same
## id, nearest of those; else the nearest face's texture and UVs), painted masks only from
## a same-id face facing the same way (not onto sides extruded from it), each vertex
## the colour of a painted vertex within COLOUR_REACH. Baked lighting / AO stay when the
## shape is the same as `own`'s (`moved`: only its place changed, as when it's created).
static func _state(obj: Dictionary, pool: Array, own: LevelBrush, moved := false) -> Dictionary:
	var nb := LevelBrush.new()
	nb.hand_edited = true
	var verts := PackedVector3Array()
	for v in obj.verts:
		verts.append(FROM_BLENDER * ActorBlender._v(v))
	var faces: Array[PackedInt32Array] = []
	var ids := PackedInt32Array()
	for i in obj.faces.size():
		faces.append(PackedInt32Array(obj.faces[i]))
		ids.append(int(obj.face_ids[i]) if i < obj.face_ids.size() else 0)
	nb.vertices = verts
	nb.set_faces(faces)
	# Old faces: the brush's own first, then the rest of the set piece's (new objects).
	var old_faces := [[], []]
	var by_id := [{}, {}]
	var painted := []  # [position, colour]
	var corner_src := {}  # own's faces (shared space) with their painted corner colours
	for e: Dictionary in pool:
		var b: LevelBrush = e.brush
		var k := 0 if b == own else 1
		var vs: PackedVector3Array = e.verts
		var e_ids: PackedInt32Array = e.ids
		var bf := b.get_faces()
		for fi in bf.size():
			var rec := {c = ActorBlender._centre(vs, bf[fi]), n = _normal(vs, bf[fi]), brush = b, face = fi}
			old_faces[k].append(rec)
			var id := e_ids[fi] if fi < e_ids.size() else 0
			if id > 0:
				by_id[k].get_or_add(id, []).append(rec)
		for vi in mini(b.vertex_colors.size(), vs.size()):
			if b.vertex_colors[vi] != Color.WHITE:
				painted.append([vs[vi], b.vertex_colors[vi]])
		if b == own and b.has_corner_colors():
			corner_src = {verts = vs, indices = b.face_indices, counts = b.face_counts, colors = b.corner_colors}
	var tex := PackedInt32Array()
	var uv := PackedVector4Array()
	var surf := PackedInt32Array()
	var sets := PackedInt32Array()
	var masks := {}
	for fi in faces.size():
		var c := ActorBlender._centre(verts, faces[fi])
		var candidates: Array = by_id[0].get(ids[fi], by_id[1].get(ids[fi], old_faces[0] if not old_faces[0].is_empty() else old_faces[1]))
		var matched: bool = by_id[0].has(ids[fi]) or by_id[1].has(ids[fi])
		var best: Dictionary = {}
		var best_d := INF
		for rec: Dictionary in candidates:
			var d := c.distance_squared_to(rec.c)
			if d < best_d:
				best_d = d
				best = rec
		if best.is_empty():
			tex.append(-1)
			uv.append(LevelBrush.DEFAULT_UV)
			surf.append(0)
			sets.append(0)
			continue
		var src: LevelBrush = best.brush
		var sf: int = best.face
		tex.append(src.get_face_texture(sf))
		uv.append(src.get_face_uv(sf))
		surf.append(src.get_face_surface(sf))
		sets.append(src.get_face_layer_set(sf))
		if matched and _normal(verts, faces[fi]).dot(best.n) > 0.95:
			for key: Vector2i in src.face_masks:
				if key.x == sf:
					masks[Vector2i(fi, key.y)] = src.face_masks[key]
	var colours := PackedColorArray()
	if not painted.is_empty():
		colours.resize(verts.size())
		for vi in verts.size():
			colours[vi] = Color.WHITE
			var best_d := COLOUR_REACH * COLOUR_REACH
			for p: Array in painted:
				var d := verts[vi].distance_squared_to(p[0])
				if d <= best_d:
					best_d = d
					colours[vi] = p[1]
	# Hard colour edges stay where the faces still are; the rest blends like vertex colours.
	var corners := PackedColorArray()
	if not corner_src.is_empty():
		corners = LevelBrush.transfer_corner_colors(corner_src.verts, corner_src.indices, corner_src.counts,
			corner_src.colors, verts, nb.face_indices, nb.face_counts, colours)
	var same := own != null and own.face_indices == nb.face_indices and own.face_counts == nb.face_counts and (moved or own.vertices == verts)
	return {vertices = verts, face_indices = nb.face_indices, face_counts = nb.face_counts, face_ids = ids, hand_edited = true,
		face_textures = tex, face_uv = uv, face_masks = masks, face_surfaces = surf, face_layer_sets = sets, vertex_colors = colours,
		vertex_ao = own.vertex_ao if same else PackedFloat32Array(),
		corner_lighting = own.corner_lighting if same else PackedColorArray(),
		corner_lighting_keys = own.corner_lighting_keys if same else ([] as Array[PackedColorArray]),
		corner_colors = corners}


## `state` (from _state) with `own`'s door cuts made again: the .blend never has them.
## Baked lighting / AO stay when that gives `own`'s shape back.
static func _recut(state: Dictionary, own: LevelBrush) -> Dictionary:
	var nb := LevelBrush.new()
	for key: String in state:
		nb.set(key, state[key])
	for k: Dictionary in own.cuts:
		PassageBuilder.carve_brush(nb, Transform3D.IDENTITY, k.xf, k.width, k.height, k.depth, k.get("trim", Vector2.ZERO), k.get("shape", Vector2.ZERO))
	var out := nb.snapshot()
	if own.face_indices == nb.face_indices and own.face_counts == nb.face_counts and own.vertices == nb.vertices:
		out.vertex_ao = own.vertex_ao
		out.corner_lighting = own.corner_lighting
		out.corner_lighting_keys = own.corner_lighting_keys
	return out


## Newell normal of a polygon.
static func _normal(pts: PackedVector3Array, poly: PackedInt32Array) -> Vector3:
	var n := Vector3.ZERO
	for k in poly.size():
		var a := pts[poly[k]]
		var b := pts[poly[(k + 1) % poly.size()]]
		n += Vector3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
	return n.normalized()


# --- State for Blender -----------------------------------------------------------------------

## Writes the state file Blender's add-on follows (only when something changed).
func write_link(file: String) -> void:
	if not FileAccess.file_exists(ProjectSettings.globalize_path(file)):
		return
	var context := _paths(file, ".n64context.json", "")[0]
	var key: String = _context_key.get(file, str(FileAccess.get_modified_time(context)) if FileAccess.file_exists(context) else "")
	var text := JSON.stringify({settings = _settings(), report = issues.get(file, []), select = _select.get(file, {}),
		context = {path = context, key = key}})
	if text == _link_text.get(file, ""):
		return
	_link_text[file] = text
	var f := FileAccess.open(_paths(file, ".n64link.json", "")[0], FileAccess.WRITE)
	if f:
		f.store_string(text)


func _settings() -> Dictionary:
	return {grid = plugin.snap, angle = 7.5, budget = 0}


## The level's faces around `brushes` (not theirs, nor other set pieces of theirs) for
## Blender, in the set piece's space (`space`: its global transform).
func _write_surroundings(path: String, brushes: Array[LevelBrush], space: Transform3D) -> void:
	var files := {}
	for b in brushes:
		if b.blend_file != "":
			files[b.blend_file] = true
	var box := AABB()
	var first := true
	for root: LevelRoot in plugin._scene_level_roots():
		for b in brushes:
			if not root.has_brush(b):
				continue
			var xf := root.brush_global_transform(b)
			for v in b.vertices:
				if first:
					box = AABB(xf * v, Vector3.ZERO)
					first = false
				else:
					box = box.expand(xf * v)
	box = box.grow(CONTEXT_MARGIN)
	var to_set := Transform3D(TO_BLENDER, Vector3.ZERO) * space.affine_inverse()
	var verts := []
	var faces := []
	for root: LevelRoot in plugin._scene_level_roots():
		if root.data == null:
			continue
		for b in root.data.brushes:
			if b in brushes or files.has(b.blend_file) or faces.size() >= CONTEXT_MAX_FACES:
				continue
			var xf := root.brush_global_transform(b)
			var remap := {}
			for f in b.get_faces():
				if not box.has_point(xf * ActorBlender._centre(b.vertices, f)):
					continue
				var poly := []
				for v in f:
					if not remap.has(v):
						remap[v] = verts.size()
						verts.append(ActorBlender._a(to_set * (xf * b.vertices[v])))
					poly.append(remap[v])
				faces.append(poly)
	# Openings cut here (doors): boxes, so Blender shows where they are. One copy's only.
	var cuts := []
	for root: LevelRoot in plugin._scene_level_roots():
		for b in brushes:
			if not root.has_brush(b) or not root.brush_global_transform(b).is_equal_approx(space):
				continue
			for k: Dictionary in b.cuts:
				var xf: Transform3D = space * k.xf
				var hw: float = k.width * 0.5
				var corners := []
				for i in 8:
					var c := Vector3(hw * (-1.0 + 2.0 * (i & 1)), k.height * ((i >> 1) & 1), -k.depth * ((i >> 2) & 1))
					corners.append(ActorBlender._a(to_set * (xf * c)))
				cuts.append(corners)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({verts = verts, faces = faces, cuts = cuts}))
	for file: String in files:
		_context_key[file] = str(Time.get_ticks_usec())
