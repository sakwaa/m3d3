@tool
extends Node
## Character editor v2: a character's geometry lives in a .blend and is edited in
## Blender; Godot keeps the skeleton, texturing and rigging (made by the editor plugin).
##  - create(): writes the .blend from the character's pieces (or the body plan's
##    starters), one object per piece on its bone, and opens it in Blender;
##  - while the character is open here, saving the .blend pulls its geometry back
##    (modifiers applied; a Mirror modifier's other half goes to the other side's bone).
##    Paint follows faces by the id the .blend keeps on each face (`n64_face`), else the
##    nearest old face; vertex colours the nearest old vertex; pins re-link by position;
##  - a state file next to the .blend tells Blender's add-on (blender/n64_actor_link)
##    the bones (proportion changes), snap settings, reference images and the last pull's
##    problems. Godot never writes the .blend itself once it exists.

const ActorEditor := preload("res://addons/n64_actor_tools/actor_editor.gd")
const BLEND_DIR := "res://characters/blend"
const SCRIPTS := "res://addons/n64_actor_tools/blender/"
## Godot (Y up, facing -Z, left -X) <-> Blender (Z up, facing -Y, left +X); its own inverse.
const TO_BLENDER := Basis(Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0))
## The add-on's heartbeat is fresh (the file is open in Blender).
const LIVE_SECONDS := 3
## Pins re-link to vertices within this distance of where they were (metres).
const PIN_REACH := 0.003

var plugin
## The last pull's problems: [{object, message}].
var issues: Array = []
var _job := {}
var _poll := 0.0
var _link_text := ""
var _select := ""
var _select_seq := 0
## Live geometry from Blender: the last sequence number read.
var _geo_seq := ""
## Bones (as sent) right after a fit: Blender moves them without the meshes.
var _fit_bones := ""


## The character being edited, when its geometry lives in a .blend.
func current() -> ActorModel:
	var root := EditorInterface.get_edited_scene_root() as ActorModel
	return root if root and root.data and root.data.blend_file != "" else null


func busy() -> bool:
	return not _job.is_empty()


func _process(delta: float) -> void:
	if not _job.is_empty():
		if not OS.is_process_running(_job.pid):
			var job := _job
			_job = {}
			job.done.call(_read_result(job.out))
		return
	_poll -= delta
	if _poll > 0.0:
		return
	_poll = 0.25
	var model := current()
	if model == null:
		return
	write_link(model)
	var path := blend_path(model)
	if FileAccess.file_exists(path) and FileAccess.get_modified_time(path) != model.data.blend_stamp:
		pull(model)
		return
	# While the file is open in Blender, its geometry arrives after every edit.
	var geo := geo_paths(model)
	if FileAccess.file_exists(geo[1]):
		var seq := FileAccess.get_file_as_string(geo[1])
		if seq != _geo_seq:
			var first := _geo_seq == ""
			_geo_seq = seq
			if not first:
				_pulled(model, _read_result(geo[0]), true)


# --- Blender ---------------------------------------------------------------------------------

## Blender's executable: Editor Settings > FileSystem > Import > Blender > Blender Path
## (an .app works too), else /Applications/Blender.app. Empty when missing.
static func blender_binary() -> String:
	var es := EditorInterface.get_editor_settings()
	var setting := "filesystem/import/blender/blender_path"
	var candidates := [String(es.get_setting(setting)) if es.has_setting(setting) else "", "/Applications/Blender.app"]
	for c: String in candidates:
		var bin := c.path_join("Contents/MacOS/Blender") if c.ends_with(".app") else c
		if bin != "" and FileAccess.file_exists(bin):
			return bin
	return ""


static func blend_path(model: ActorModel) -> String:
	return ProjectSettings.globalize_path(model.data.blend_file)


## (Godot -> Blender state, Blender heartbeat) files next to the .blend.
static func link_paths(model: ActorModel) -> PackedStringArray:
	var base := blend_path(model).get_basename()
	return PackedStringArray([base + ".n64link.json", base + ".n64live.json"])


## (live geometry, its sequence number) written by Blender's add-on after each edit.
static func geo_paths(model: ActorModel) -> PackedStringArray:
	var base := blend_path(model).get_basename()
	return PackedStringArray([base + ".n64geo.json", base + ".n64geo.seq"])


## The .blend is open in Blender (with the add-on).
static func is_live(model: ActorModel) -> bool:
	var live := link_paths(model)[1]
	return FileAccess.file_exists(live) and Time.get_unix_time_from_system() - FileAccess.get_modified_time(live) < LIVE_SECONDS


static func _script(file: String) -> String:
	return ProjectSettings.globalize_path(SCRIPTS + file)


static func _temp(file: String) -> String:
	var dir := ProjectSettings.globalize_path("user://n64_blender")
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(file)


## Runs headless Blender; `done` gets the bridge's result ({ok, ...}). Waits when `wait`.
func _run(args: PackedStringArray, out: String, done: Callable, wait := false) -> void:
	var bin := blender_binary()
	if bin == "":
		done.call({ok = false, error = "Blender not found (Editor Settings > FileSystem > Import > Blender > Blender Path)."})
		return
	DirAccess.remove_absolute(out)
	if wait:
		OS.execute(bin, args)
		done.call(_read_result(out))
		return
	var pid := OS.create_process(bin, args)
	if pid <= 0:
		done.call({ok = false, error = "Can't start Blender (%s)." % bin})
		return
	_job = {pid = pid, out = out, done = done}


static func _read_result(out: String) -> Dictionary:
	var r = JSON.parse_string(FileAccess.get_file_as_string(out)) if FileAccess.file_exists(out) else null
	return r if r is Dictionary else {ok = false, error = "Blender stopped without a result (run it from a terminal to see why)."}


static func _toast(text: String, error := false) -> void:
	EditorInterface.get_editor_toaster().push_toast(text, EditorToaster.SEVERITY_ERROR if error else EditorToaster.SEVERITY_INFO)


# --- Create / open ---------------------------------------------------------------------------

## Moves the character's geometry into a new .blend (characters/blend/<scene>.blend) and
## opens it in Blender. One undo step (the file stays).
func create(model: ActorModel) -> void:
	if make_blend(model):
		open_blender(model)


## create() without opening Blender. False when it failed (with a message).
func make_blend(model: ActorModel) -> bool:
	if model == null or model.data.blend_file != "":
		return false
	var dir := ProjectSettings.globalize_path(BLEND_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	if not FileAccess.file_exists(dir.path_join(".gdignore")):
		FileAccess.open(dir.path_join(".gdignore"), FileAccess.WRITE).store_string("")
	var base := model.scene_file_path.get_file().get_basename() if model.scene_file_path != "" else String(model.name).to_snake_case()
	var res := BLEND_DIR.path_join(base + ".blend")
	var n := 2
	while FileAccess.file_exists(ProjectSettings.globalize_path(res)):
		res = BLEND_DIR.path_join("%s_%d.blend" % [base, n])
		n += 1
	var file := ProjectSettings.globalize_path(res)
	# Ids on every face, so the pull right after keeps the paint where it was.
	var old: Array = model.pieces_copy() if not model.data.pieces.is_empty() else ActorMannequin.starters(model)
	var next_id := 1
	for p: ActorPiece in old:
		p.ensure_attributes()
		p.face_ids.resize(p.face_counts.size())
		for i in p.face_ids.size():
			p.face_ids[i] = next_id
			next_id += 1
	var names := {}
	var pieces := []
	for e in ActorMannequin.world_entries(model, old):
		var p: ActorPiece = e.piece
		var obj_name := String(p.bone)
		names[obj_name] = names.get(obj_name, 0) + 1
		if names[obj_name] > 1:
			obj_name += "_%d" % names[obj_name]
		var verts := []
		for v: Vector3 in e.pts:
			verts.append(_a(TO_BLENDER * v))
		var faces := []
		for f in p.faces():
			faces.append(Array(f))
		pieces.append({name = obj_name, bone = String(p.bone), verts = verts, faces = faces, face_ids = Array(p.face_ids)})
	var spec := {name = String(model.name), bones = _bones(model), pieces = pieces, settings = _settings(model), references = _references(model)}
	var spec_path := _temp("create.json")
	FileAccess.open(spec_path, FileAccess.WRITE).store_string(JSON.stringify(spec))
	var out := _temp("create_result.json")
	var made := {}
	_run(PackedStringArray(["-b", "--factory-startup", "--python", _script("bridge.py"), "--", "create", spec_path, file, out]), out,
		func(r): made.merge(r), true)
	if not made.get("ok", false):
		_toast("Couldn't make %s: %s" % [res, made.get("error", "")], true)
		return false
	var dump := {}
	_run(PackedStringArray(["-b", "--factory-startup", file, "--python", _script("bridge.py"), "--", "dump", _temp("dump.json")]), _temp("dump.json"),
		func(r): dump.merge(r), true)
	if not dump.get("ok", false):
		_toast("Made %s but couldn't read it back: %s" % [res, dump.get("error", "")], true)
		return false
	var built := _pieces_from(model, dump, old)
	issues = built.issues
	var ur = plugin.editor.undo_redo()
	ur.create_action("Move Geometry to Blender")
	ur.add_do_property(model.data, &"pieces", built.pieces)
	ur.add_do_property(model.data, &"blend_file", res)
	ur.add_do_property(model.data, &"blend_stamp", FileAccess.get_modified_time(file))
	ur.add_undo_property(model.data, &"pieces", model.data.pieces)
	ur.add_undo_property(model.data, &"blend_file", "")
	ur.commit_action()
	plugin.editor.set_tool(ActorEditor.Tool.PIECE)
	return true


## Opens the character's .blend in Blender with the link add-on (brings it forward when
## it's open already), selecting the piece selected here.
func open_blender(model: ActorModel) -> void:
	var p := model.selected_piece()
	_select = p.id.trim_suffix("~R") if p else ""
	_select_seq += 1
	write_link(model)
	var bin := blender_binary()
	if bin == "":
		_toast("Blender not found: set Editor Settings > FileSystem > Import > Blender > Blender Path.", true)
		return
	if is_live(model):
		if OS.get_name() == "macOS":
			OS.create_process("open", ["-a", bin.get_base_dir().get_base_dir().get_base_dir()])
		return
	OS.create_process(bin, [blend_path(model), "--python", _script("launch.py")])


## Back to the built-in modelling tools (the .blend stays; Move to Blender makes a new one).
func unlink(model: ActorModel) -> void:
	var ur = plugin.editor.undo_redo()
	ur.create_action("Unlink Blender File")
	ur.add_do_property(model.data, &"blend_file", "")
	ur.add_undo_property(model.data, &"blend_file", model.data.blend_file)
	ur.commit_action()


# --- Pull ------------------------------------------------------------------------------------

## Reads the .blend's geometry into the character (in the background), one undo step.
func pull(model: ActorModel) -> void:
	if busy():
		return
	var path := blend_path(model)
	if not FileAccess.file_exists(path):
		issues = [{object = "", message = "%s is missing." % model.data.blend_file}]
		return
	var stamp := FileAccess.get_modified_time(path)
	model.data.blend_stamp = stamp
	var out := _temp("dump.json")
	_run(PackedStringArray(["-b", "--factory-startup", path, "--python", _script("bridge.py"), "--", "dump", out]), out,
		func(r): _pulled(model, r))


## Geometry read from Blender (a saved .blend, or `live` after an edit there) into the
## character, one undo step (live ones merge). With ActorModelData.blend_fit, the skeleton
## then fits the meshes (BodyPlan.fit) and the pieces keep their places on it.
func _pulled(model: ActorModel, r: Dictionary, live := false) -> void:
	if not is_instance_valid(model):
		return
	if not r.get("ok", false):
		if not live:
			_toast("Couldn't read %s: %s" % [model.data.blend_file, r.get("error", "")], true)
		return
	# Made on other bones than Godot's: after a fit (Blender moves bones, not meshes) the
	# geometry stands where it is; after a proportion change here, Blender stretches it
	# along, so it's placed on the bones it was made on.
	var matches := _bones_match(model, r)
	var after_fit := JSON.stringify(_bones(model)) == _fit_bones
	var built := _pieces_from(model, r, model.pieces_copy(), matches or after_fit)
	issues = built.issues
	var before: Dictionary = model.data.proportions
	var fitted := model.data.blend_fit and matches and _fit(model, built)
	var ur = plugin.editor.undo_redo()
	ur.create_action("Geometry from Blender" if live else "Pull from Blender", UndoRedo.MERGE_ENDS if live else UndoRedo.MERGE_DISABLE)
	ur.add_do_property(model.data, &"pieces", built.pieces)
	ur.add_undo_property(model.data, &"pieces", model.data.pieces)
	if fitted:
		ur.add_do_property(model.data, &"proportions", model.data.proportions)
		ur.add_undo_property(model.data, &"proportions", before)
	ur.commit_action()
	plugin.editor.refreshed.emit()
	if fitted:
		_fit_bones = JSON.stringify(_bones(model))
		write_link(model)
		if not is_live(model):
			_store_bones(model)
	if live:
		return
	var text := "Pulled %s: %d pieces, %d tris" % [model.data.blend_file.get_file(), built.pieces.size(), built.tris]
	if not issues.is_empty():
		text += " · %d problem%s (Blender's N64 Actor panel)" % [issues.size(), "" if issues.size() == 1 else "s"]
	_toast(text, false)


## The .blend's objects as pieces, with paint, settings and pins carried over from `old`.
## Placed on the file's bones (geometry saved before a proportion change here still
## lands right), or on Godot's when `as_is` (world positions kept).
## {pieces: Array[ActorPiece], world, issues, tris}.
func _pieces_from(model: ActorModel, dump: Dictionary, old: Array, as_is := false) -> Dictionary:
	var found: Array = (dump.get("issues", []) as Array).duplicate()
	var frames := {}
	for bone_name: String in ({} if as_is else dump.get("bones", {})):
		var b: Dictionary = dump.bones[bone_name]
		frames[bone_name] = [Transform3D(TO_BLENDER * Basis(_v(b.x), _v(b.y), _v(b.z)), TO_BLENDER * _v(b.head)), float(b.length)]
	# What there was: faces (world centre, paint source), vertices (colour), piece settings.
	var old_entries := ActorMannequin.world_entries(model, old)
	var old_faces := []
	var by_face_id := {}
	var old_verts := {}  # bone index -> [[position, colour]]
	var all_verts := []
	var old_by_id := {}
	var old_by_bone := {}
	for e in old_entries:
		var p: ActorPiece = e.piece
		old_by_id[p.id] = p
		if not old_by_bone.has(p.bone):
			old_by_bone[p.bone] = p
		var f := p.faces()
		for fi in f.size():
			var rec := {c = _centre(e.pts, f[fi]), piece = p, face = fi}
			old_faces.append(rec)
			var fid := p.face_ids[fi] if fi < p.face_ids.size() else 0
			if fid > 0:
				by_face_id.get_or_add(fid, []).append(rec)
		for vi in e.pts.size():
			var v := [e.pts[vi], p.colors[vi]]
			old_verts.get_or_add(e.bone, []).append(v)
			all_verts.append(v)
	var out: Array[ActorPiece] = []
	var out_world: Array[PackedVector3Array] = []
	var tris := 0
	for obj: Dictionary in dump.get("objects", []):
		var bone := StringName(obj.bone)
		var bi := model.bone_index(bone)
		if bi < 0:
			found.append({object = obj.name, message = "Bone %s isn't in the %s skeleton; left out." % [bone, model.data.plan]})
			continue
		var world := PackedVector3Array()
		for v in obj.verts:
			world.append(TO_BLENDER * _v(v))
		var faces: Array[PackedInt32Array] = []
		for f: Array in obj.faces:
			faces.append(PackedInt32Array(f))
		# A Mirror modifier on a side piece: the half past the centre is the other side's.
		var side: int = model.bones[bi].side
		var other := BodyPlan.mirror_name(bone)
		var split: bool = obj.mirrored and side != 0 and model.bone_index(other) >= 0
		var groups := {bone: []}
		for fi in faces.size():
			var b := bone
			if split and _centre(world, faces[fi]).x * side < -1e-4:
				b = other
			groups.get_or_add(b, []).append(fi)
		for b: StringName in groups:
			if groups[b].is_empty():
				continue
			var fr: Array = frames.get(String(b), [])
			if fr.is_empty():
				var i := model.bone_index(b)
				fr = [model.rest_global(i), model.bones[i].length()]
			var inv: Transform3D = fr[0].affine_inverse()
			var p := ActorPiece.new()
			p.bone = b
			p.id = obj.name if b == bone else obj.name + "~R"
			p.bone_length = maxf(fr[1], 1e-4)
			p.mirror = false
			var remap := {}
			var pw := PackedVector3Array()
			var polys: Array[PackedInt32Array] = []
			var ids := PackedInt32Array()
			for fi: int in groups[b]:
				var poly := PackedInt32Array()
				for v in faces[fi]:
					if not remap.has(v):
						remap[v] = pw.size()
						pw.append(world[v])
						p.vertices.append(inv * world[v])
					poly.append(remap[v])
				polys.append(poly)
				ids.append(int(obj.face_ids[fi]) if fi < obj.face_ids.size() else 0)
				tris += poly.size() - 2
			p.set_faces(polys)
			p.face_ids = ids
			var src: ActorPiece = old_by_id.get(p.id, old_by_bone.get(b))
			if src:
				p.stitch_to = src.stitch_to
				p.stitch_weight = src.stitch_weight
				p.stitch_rings = src.stitch_rings
				p.wrap_uv = src.wrap_uv or src.is_tube()
			p.ensure_attributes()
			_carry_paint(p, pw, polys, by_face_id, old_faces, old_verts.get(model.bone_index(b), all_verts))
			out.append(p)
			out_world.append(pw)
	_relink_pins(model, old_entries, out, out_world)
	if tris > model.data.tri_budget:
		found.append({object = "", message = "%d triangles: over the %d budget." % [tris, model.data.tri_budget]})
	return {pieces = out, world = out_world, issues = found, tris = tris}


## The geometry was made on the skeleton Godot has now (not one from before a proportion
## change still on its way to Blender): only then may the skeleton fit it.
func _bones_match(model: ActorModel, dump: Dictionary) -> bool:
	var bones: Dictionary = dump.get("bones", {})
	for b: Dictionary in _bones(model):
		var d: Dictionary = bones.get(b.name, {})
		if d.is_empty() or _v(d.head).distance_to(_v(b.head)) > 1e-4:
			return false
		var tail := _v(d.head) + _v(d.y) * float(d.length)
		if tail.distance_to(_v(b.tail)) > 1e-4:
			return false
	return true


## Fits the proportions to the pieces' lengths along their bones (from where they start,
## overlap into the parent ignored) and re-expresses the pieces on the new bones so they
## stay put. False when nothing changed.
func _fit(model: ActorModel, built: Dictionary) -> bool:
	var measured := {}
	var pieces: Array = built.pieces
	for i in pieces.size():
		var bi := model.bone_index(pieces[i].bone)
		var xf := model.rest_global(bi)
		var lo := INF
		var hi := -INF
		for w: Vector3 in built.world[i]:
			var y := (w - xf.origin).dot(xf.basis.y.normalized())
			lo = minf(lo, y)
			hi = maxf(hi, y)
		if hi > lo:
			var length := hi - maxf(lo, 0.0)
			measured[model.bones[bi].name] = maxf(measured.get(model.bones[bi].name, 0.0), length)
	var start := model.plan.resolve(model.data.proportions)
	var fitted := model.plan.fit(measured, model.data.proportions)
	if fitted == start:
		return false
	model.data.proportions = fitted
	model.rebuild()
	for i in pieces.size():
		var p: ActorPiece = pieces[i]
		var bi := model.bone_index(p.bone)
		var inv := model.rest_global(bi).affine_inverse()
		var vs := PackedVector3Array()
		for w: Vector3 in built.world[i]:
			vs.append(inv * w)
		p.vertices = vs
		p.bone_length = maxf(model.bones[bi].length(), 1e-4)
	return true


## Blender is closed: moves the .blend's bones to the fitted skeleton (meshes stay).
func _store_bones(model: ActorModel) -> void:
	var spec := _temp("bones.json")
	FileAccess.open(spec, FileAccess.WRITE).store_string(_fit_bones)
	var out := _temp("bones_result.json")
	_run(PackedStringArray(["-b", "--factory-startup", blend_path(model), "--python", _script("bridge.py"), "--", "bones", spec, out]), out,
		func(_r): model.data.blend_stamp = FileAccess.get_modified_time(blend_path(model)), true)


## Each face takes the paint of its old face (same id, nearest of those; else the nearest
## old face), each vertex the colour of the nearest old vertex.
static func _carry_paint(p: ActorPiece, pw: PackedVector3Array, polys: Array[PackedInt32Array], by_face_id: Dictionary, old_faces: Array, old_verts: Array) -> void:
	if old_faces.is_empty():
		return
	for fi in polys.size():
		var c := _centre(pw, polys[fi])
		var best: Dictionary = {}
		var best_d := INF
		for rec: Dictionary in by_face_id.get(p.face_ids[fi], old_faces):
			var d := c.distance_squared_to(rec.c)
			if d < best_d:
				best_d = d
				best = rec
		var src: ActorPiece = best.piece
		var sf: int = best.face
		p.face_textures[fi] = src.face_textures[sf]
		p.face_overlays[fi] = src.face_overlays[sf]
		if src.face_fit.has(sf):
			p.face_fit[fi] = src.face_fit[sf]
		if src.face_uv.has(sf):
			p.face_uv[fi] = src.face_uv[sf]
		if src.face_slots.has(sf):
			p.face_slots[fi] = src.face_slots[sf]
	if old_verts.is_empty():
		return
	for vi in pw.size():
		var best_d := INF
		for v: Array in old_verts:
			var d := pw[vi].distance_squared_to(v[0])
			if d < best_d:
				best_d = d
				p.colors[vi] = v[1]


## Old pins (pinned vertex -> target vertex) onto the new pieces' vertices at the same
## places, on the same bones.
static func _relink_pins(model: ActorModel, old_entries: Array, out: Array[ActorPiece], out_world: Array[PackedVector3Array]) -> void:
	var by_id := ActorMannequin.by_id_of(old_entries)
	for e: Dictionary in old_entries:
		var p: ActorPiece = e.piece
		for v: int in p.pins:
			var t := ActorMannequin.pin_target(model, e, p.pins[v], by_id, old_entries)
			if t.is_empty() or v >= e.pts.size():
				continue
			var te: Dictionary = old_entries[t.entry]
			var a := _nearest(out, out_world, p.bone, e.pts[v])
			var b := _nearest(out, out_world, te.piece.bone, te.pts[t.vertex])
			if not a.is_empty() and not b.is_empty() and a.piece != b.piece:
				out[a.piece].pins[a.vertex] = [out[b.piece].id, b.vertex]


static func _nearest(out: Array[ActorPiece], out_world: Array[PackedVector3Array], bone: StringName, at: Vector3) -> Dictionary:
	var best := {}
	var best_d := PIN_REACH * PIN_REACH
	for i in out.size():
		if out[i].bone != bone:
			continue
		for vi in out_world[i].size():
			var d := out_world[i][vi].distance_squared_to(at)
			if d <= best_d:
				best_d = d
				best = {piece = i, vertex = vi}
	return best


# --- State for Blender -----------------------------------------------------------------------

## Writes the state file Blender's add-on follows (only when something changed).
func write_link(model: ActorModel) -> void:
	if not FileAccess.file_exists(blend_path(model)):
		return
	var bones := _bones(model)
	var mode := "fit" if JSON.stringify(bones) == _fit_bones else "stretch"
	var text := JSON.stringify({armature = bones, armature_mode = mode, settings = _settings(model), references = _references(model),
		report = issues, select = {seq = _select_seq, object = _select}})
	if text == _link_text:
		return
	_link_text = text
	var f := FileAccess.open(link_paths(model)[0], FileAccess.WRITE)
	if f:
		f.store_string(text)


static func _settings(model: ActorModel) -> Dictionary:
	return {grid = model.data.model_grid, angle = model.data.angle_step, budget = model.data.tri_budget}


## Rest bones in Blender space (Blender keeps its bones' roll on Godot's bone frames).
static func _bones(model: ActorModel) -> Array:
	var out := []
	for i in model.bones.size():
		var b: BodyPlan.Bone = model.bones[i]
		var xf := model.rest_global(i)
		out.append({name = String(b.name), parent = String(b.parent), head = _a(TO_BLENDER * xf.origin),
			tail = _a(TO_BLENDER * (xf * Vector3(0, maxf(b.length(), 0.001), 0))), z = _a(TO_BLENDER * xf.basis.z)})
	return out


## Reference images (the 3D view's, when they belong to this character) as Blender image
## empties: centre, axes, size.
func _references(model: ActorModel) -> Array:
	var aids = plugin.get(&"_aids") if plugin else null
	if aids == null or not is_instance_valid(aids) or aids.model != model:
		return []
	var refs = aids.refs
	var out := []
	for v: int in refs.refs:
		var f: Dictionary = refs.frame(v)
		if f.is_empty():
			continue
		var r: Dictionary = refs.refs[v]
		var path: String = r.get("path", "")
		if not FileAccess.file_exists(path):
			path = String(refs.dir).path_join(path.get_file())
		var axes: Array = refs._axes(v)
		var a: float = f.angle
		var right: Vector3 = axes[0] * cos(a) + axes[1] * sin(a)
		var up: Vector3 = -axes[0] * sin(a) + axes[1] * cos(a)
		out.append({view = v, path = ProjectSettings.globalize_path(path), centre = _a(TO_BLENDER * refs.to_world(v, f.centre)),
			right = _a(TO_BLENDER * right), up = _a(TO_BLENDER * up), toward = _a(TO_BLENDER * -(axes[2] as Vector3)),
			size = [f.half.x * 2.0, f.half.y * 2.0], opacity = r.get("opacity", 0.55), visible = r.get("visible", true)})
	return out


static func _centre(pts: PackedVector3Array, poly) -> Vector3:
	var c := Vector3.ZERO
	for v in poly:
		c += pts[v]
	return c / maxf(poly.size(), 1)


static func _a(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


static func _v(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])
