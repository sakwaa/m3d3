@tool
class_name Signpost
extends Node3D
## A sign to read, OoT style: a board on a post (or on a wall) the player walks up to and
## reads with interact. `text` shows in the dialogue box in the small sign style
## (DialogueLine.Style.SIGN); a blank line starts a new page. Its face shows the words in
## the in-game script, in rows read left to right (a tall, narrow face stacks them one glyph
## per row: vertical lettering): the level tools write that texture in
## the editor (`face_texture`) whenever the words change; games only load it. Placed from
## the level tools' Props menu; its post, board, collision and Talkable are built here and
## aren't saved with the scene.

enum Kind { POST, WALL, CLOTH, HANGING, NOBORI }
## How the words are written: PRINT the syllabary as drawn, BRUSH painted with an angled
## brush (thick and thin strokes, ragged edges, dry streaks), HAND with a wobbly pen.
enum Lettering { PRINT, BRUSH, HAND }

## What reading it says. Markup as in dialogue ([red]…[/red], {player}); a blank line
## starts a new page. Translations use the key "sign_<sign_id>.text".
@export_multiline var text := "":
	set(value):
		text = value
		_update_dialogue()
		_queue_face()
		notify_property_list_changed()
## What the face shows, if not the same as `text` (a short heading for a long notice).
@export_multiline var face_text := "":
	set(value):
		face_text = value
		_queue_face()
		notify_property_list_changed()
## Unique across the game; the stem of its translation key. Empty = from the node name.
@export var sign_id := &""
## POST: a board on its own post. WALL: just the board, its back against a wall (a tall one
## is a kanban). The cloth banners (board_texture / board_color are the cloth, frame_color the
## wood) are the town's shop banners:
##  - CLOTH: flat on the wall from a rod (wide: a yokomaku across the front; tall: a hanging
##    scroll, weighted by a second rod), centred on the node;
##  - HANGING: out from the wall (+Z) on a bracket, edge-on to the wall so it reads from along
##    the street both ways; its top on the node; `notch` cuts a swallowtail;
##  - NOBORI: a tall flag on its own pole with an arm across the top, standing on the node,
##    centred board_height up; written on both sides.
@export var kind := Kind.POST:
	set(value):
		kind = value
		_rebuild()
@export_group("Look")
@export var board_size := Vector2(1.0, 0.6):
	set(value):
		board_size = value
		_rebuild()
		_queue_face()
## Height of the board's centre above the ground (POST).
@export_range(0.3, 3.0, 0.05, "suffix:m") var board_height := 1.15:
	set(value):
		board_height = value
		_rebuild()
@export var board_texture: Texture2D = preload("res://textures/wood/wood_6.res"):
	set(value):
		board_texture = value
		_rebuild()
		_queue_face()
@export var board_color := Color(0.95, 0.85, 0.7):
	set(value):
		board_color = value
		_rebuild()
		_queue_face()
@export var frame_color := Color(0.32, 0.22, 0.14):
	set(value):
		frame_color = value
		_rebuild()
@export var ink_color := Color(0.2, 0.11, 0.06):
	set(value):
		ink_color = value
		_queue_face()
## The script the face is written in; empty = the banners' default (the syllabary).
@export_file("*.tres") var alphabet_path := "":
	set(value):
		alphabet_path = value
		_queue_face()
		notify_property_list_changed()
## The written face: the writing painted into the board (made by the level tools in the
## editor; shown on the front instead of the plain board).
@export var lettering := Lettering.PRINT:
	set(value):
		lettering = value
		_queue_face()
## A swallowtail cut up into the cloth's foot (HANGING, NOBORI), metres.
@export_range(0.0, 1.0, 0.01, "suffix:m") var notch := 0.0:
	set(value):
		notch = value
		_rebuild()
## Words with a word symbol (drawn in the Script Builder) written out letter by letter on this
## sign instead; every other such word is written with its symbol. Set in the inspector's
## Word symbols group, a tick box per word of the face that has one.
@export_storage var spelled_out := PackedStringArray()
@export var face_texture: Texture2D:
	set(value):
		face_texture = value
		_rebuild()
@export_group("")

const POST_SIZE := 0.12
const BOARD_DEPTH := 0.08
const FRAME := 0.05
## Near detail / far stand-in distance (the level's, LevelRoot.LOD_SETTING).
const LOD_SETTING := "n64/build/lod_distance"
## Editor only (looked up by path: the level tools don't ship).
const FACE_GENERATOR := "res://addons/n64_level_tools/textures/sign_face_generator.gd"

var talkable: Talkable
var _parts: Node3D
var _face_queued := false


func _ready() -> void:
	_rebuild()
	if Engine.is_editor_hint() and face_texture == null:
		_queue_face()


func _rebuild() -> void:
	if not is_inside_tree():
		return
	if _parts:
		_parts.queue_free()
	_parts = Node3D.new()
	_parts.name = "Parts"
	add_child(_parts, false, INTERNAL_MODE_BACK)
	var centre_y := board_height if kind == Kind.POST or kind == Kind.NOBORI else 0.0
	# Wall signs hang their back on the node's origin; post signs stand on it.
	var back_z := 0.0 if kind == Kind.POST else -BOARD_DEPTH * 0.5
	# One mesh: frame + post, the planks on both faces, the writing (a surface each).
	var surfaces := {}
	var add := func(m: Material, prim: Mesh, xf: Transform3D) -> void:
		_append(surfaces.get_or_add(m, _new_surface()), prim, xf)
	var frame_m := N64Materials.textured(frame_color)
	if kind >= Kind.CLOTH:
		_build_cloth(add, frame_m, centre_y)
		var cloth_mesh := ArrayMesh.new()
		for m: Material in surfaces:
			_commit(surfaces[m], cloth_mesh)
			cloth_mesh.surface_set_material(cloth_mesh.get_surface_count() - 1, m)
		var cmi := MeshInstance3D.new()
		cmi.mesh = cloth_mesh  # a dozen triangles: drawn at every distance
		_parts.add_child(cmi)
		if kind == Kind.NOBORI:
			var pole := StaticBody3D.new()
			_parts.add_child(pole)
			var cs := CollisionShape3D.new()
			var pole_box := BoxShape3D.new()
			pole_box.size = Vector3(POST_SIZE * 1.5, centre_y + board_size.y * 0.5, POST_SIZE * 1.5)
			cs.shape = pole_box
			cs.position = Vector3(-board_size.x * 0.5 - POLE * 0.5, pole_box.size.y * 0.5, 0)
			pole.add_child(cs)
		_add_talkable(centre_y)
		PropBatch.add(_parts)
		return
	if kind == Kind.POST:
		var top := board_height + board_size.y * 0.5 - FRAME
		add.call(frame_m, _box_mesh(Vector3(POST_SIZE, top, POST_SIZE)),
			Transform3D(Basis(), Vector3(0, top * 0.5, -BOARD_DEPTH * 0.5 - POST_SIZE * 0.5)))
	# Board: a dark frame with the planks on both faces.
	var frame_size := Vector3(board_size.x + FRAME * 2.0, board_size.y + FRAME * 2.0, BOARD_DEPTH)
	add.call(frame_m, _box_mesh(frame_size), Transform3D(Basis(), Vector3(0, centre_y, -back_z)))
	var face_m := N64Materials.textured(board_color, board_texture)
	face_m.set_shader_parameter(&"uv_scale", board_size)
	var quad := QuadMesh.new()
	quad.size = board_size
	# The front (+Z) shows the written face when there is one.
	var written_m: Material = face_m
	if face_texture:
		written_m = N64Materials.textured(Color.WHITE, face_texture)
		written_m.set_meta(&"atlas", true)  # PropBatch packs every sign's face into one texture
	for side in [1.0, -1.0]:
		add.call(written_m if side > 0.0 else face_m, quad, Transform3D(Basis(Vector3.UP, 0.0 if side > 0.0 else PI),
			Vector3(0, centre_y, -back_z + side * (BOARD_DEPTH * 0.5 + 0.005))))
	var mesh := ArrayMesh.new()
	for m: Material in surfaces:
		_commit(surfaces[m], mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, m)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	_parts.add_child(mi)
	# Far: just the frame's box (and post), in the frame colour; the writing's unreadable there.
	var lod_at: float = ProjectSettings.get_setting(LOD_SETTING, 40.0)
	mi.visibility_range_end = lod_at
	var far_s := _new_surface()
	if kind == Kind.POST:
		var post_top := board_height + board_size.y * 0.5 - FRAME
		_append(far_s, _box_mesh(Vector3(POST_SIZE, post_top, POST_SIZE)),
			Transform3D(Basis(), Vector3(0, post_top * 0.5, -BOARD_DEPTH * 0.5 - POST_SIZE * 0.5)))
	_append(far_s, _box_mesh(frame_size), Transform3D(Basis(), Vector3(0, centre_y, -back_z)))
	var far_m := N64Materials.textured(frame_color.lerp(board_color, 0.6))
	var far := MeshInstance3D.new()
	var far_mesh := ArrayMesh.new()
	_commit(far_s, far_mesh)
	far.mesh = far_mesh
	far.material_override = far_m
	far.visibility_range_begin = lod_at
	_parts.add_child(far)
	# Something to bump into.
	var body := StaticBody3D.new()
	_parts.add_child(body)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	var bottom := 0.0 if kind == Kind.POST else centre_y - frame_size.y * 0.5
	var height := (centre_y + frame_size.y * 0.5) - bottom
	box.size = Vector3(frame_size.x, height, maxf(BOARD_DEPTH, POST_SIZE * 2.0))
	shape.shape = box
	shape.position = Vector3(0, bottom + height * 0.5, -back_z)
	body.add_child(shape)
	_add_talkable(centre_y)
	PropBatch.add(_parts)


## Reading it.
func _add_talkable(centre_y: float) -> void:
	talkable = Talkable.new()
	talkable.prompt = "Read"
	talkable.radius = maxf(1.4, board_size.x)
	talkable.target_kind = Targetable.Kind.POI
	talkable.target_height = centre_y
	_parts.add_child(talkable)
	_update_dialogue()


## Pole / rod thickness of the cloth banners.
const POLE := 0.05


## A cloth banner's cloth (written on its front, and on its back too where it's seen from
## both sides, mirrored back to read the right way) and its wood. `add` as in _rebuild.
func _build_cloth(add: Callable, wood: Material, centre_y: float) -> void:
	var w := board_size.x
	var h := board_size.y
	var plain := N64Materials.textured(board_color, board_texture)
	plain.set_shader_parameter(&"uv_scale", board_size)
	var written: Material = plain
	if face_texture:
		written = N64Materials.textured(Color.WHITE, face_texture)
		written.set_meta(&"atlas", true)
	# The cloth's outline in (u across, v down) 0..1, with the notch cut up from its foot.
	var outline: Array[Vector2] = [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1)]
	if notch > 0.0 and kind != Kind.CLOTH:
		outline.append(Vector2(0.5, 1.0 - clampf(notch / h, 0.0, 0.9)))
	outline.append(Vector2(0, 1))
	var top := centre_y + h * 0.5
	match kind:
		Kind.CLOTH:
			var z := 0.03
			add.call(written, _sheet(outline, Vector3(-w * 0.5, top, z), Vector3(w, 0, 0), Vector3(0, -h, 0), Vector3.BACK), Transform3D())
			add.call(wood, _box_mesh(Vector3(w + 0.16, POLE, POLE)), Transform3D(Basis(), Vector3(0, top + POLE * 0.4, z)))
			if h > w:
				add.call(wood, _box_mesh(Vector3(w + 0.08, POLE * 0.8, POLE * 0.8)), Transform3D(Basis(), Vector3(0, top - h, z)))
		Kind.HANGING:
			var z0 := 0.15
			var arm := w + z0 + 0.08
			add.call(wood, _box_mesh(Vector3(POLE, POLE, arm)), Transform3D(Basis(), Vector3(0, top + POLE * 0.5, arm * 0.5)))
			add.call(wood, _box_mesh(Vector3(0.12, 0.3, 0.04)), Transform3D(Basis(), Vector3(0, top - 0.1, 0.02)))
			add.call(wood, _box_mesh(Vector3(POLE * 0.6, 0.35, POLE * 0.6)), Transform3D(Basis(Vector3.RIGHT, -0.8),
				Vector3(0, top - 0.1, 0.13)))
			# Seen from +X the street's right is -Z, so that side reads from the far end in.
			add.call(written, _sheet(outline, Vector3(0.004, top, z0 + w), Vector3(0, 0, -w), Vector3(0, -h, 0), Vector3.RIGHT), Transform3D())
			add.call(written, _sheet(outline, Vector3(-0.004, top, z0), Vector3(0, 0, w), Vector3(0, -h, 0), Vector3.LEFT), Transform3D())
		Kind.NOBORI:
			var px := -w * 0.5 - POLE * 0.5
			add.call(wood, _box_mesh(Vector3(POLE, top + 0.12, POLE)), Transform3D(Basis(), Vector3(px, (top + 0.12) * 0.5, 0)))
			add.call(wood, _box_mesh(Vector3(w + POLE, POLE * 0.7, POLE * 0.7)), Transform3D(Basis(), Vector3(POLE * 0.5, top + POLE * 0.35, 0)))
			add.call(wood, _box_mesh(Vector3(0.3, 0.12, 0.3)), Transform3D(Basis(), Vector3(px, 0.06, 0)))
			add.call(written, _sheet(outline, Vector3(-w * 0.5, top, 0.004), Vector3(w, 0, 0), Vector3(0, -h, 0), Vector3.BACK), Transform3D())
			add.call(written, _sheet(outline, Vector3(w * 0.5, top, -0.004), Vector3(-w, 0, 0), Vector3(0, -h, 0), Vector3.FORWARD), Transform3D())


## A flat polygon `outline` (u, v in 0..1) laid out from `origin` along `across` (u) and
## `down` (v), facing `normal`, its UVs the outline itself (the face texture spans 0..1).
static func _sheet(outline: Array[Vector2], origin: Vector3, across: Vector3, down: Vector3, normal: Vector3) -> ArrayMesh:
	var pts: Array[Vector3] = []
	for o in outline:
		pts.append(origin + across * o.x + down * o.y)
	var order := range(outline.size())
	# Godot fronts are clockwise: flip the fan if it winds the other way.
	if (pts[1] - pts[0]).cross(pts[2] - pts[0]).dot(normal) > 0.0:
		order.reverse()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(1, order.size() - 1):
		for k in [order[0], order[i], order[i + 1]]:
			st.set_normal(normal)
			st.set_uv(outline[k])
			st.add_vertex(pts[k])
	var sheet := ArrayMesh.new()
	PropBatch.commit(st, sheet)
	return sheet


## A surface being built: whole arrays appended at once (_append), committed by _commit.
static func _new_surface() -> Dictionary:
	return {v = PackedVector3Array(), n = PackedVector3Array(), uv = PackedVector2Array(), ix = PackedInt32Array()}


## Unit box / quad arrays, made once: every sign's boxes and quads are these scaled.
static var _units := {}


static func _unit(prim: PrimitiveMesh) -> Array:
	var key := prim.get_class()
	if not _units.has(key):
		var unit: PrimitiveMesh = ClassDB.instantiate(key)
		_units[key] = unit.get_mesh_arrays()
	return _units[key]


## `mesh` (surface 0) into surface `s` through `xf`. Boxes and quads come from the unit
## arrays scaled to their size; anything else from the arrays PropBatch.commit kept. Whole
## arrays transform natively: per-vertex SurfaceTool calls (and append_from, which reads
## the surface back from the GPU) were most of a zone's sign setup.
static func _append(s: Dictionary, mesh: Mesh, xf: Transform3D) -> void:
	var arr: Array
	var size := Vector3.ONE
	if mesh is BoxMesh:
		arr = _unit(mesh)
		size = (mesh as BoxMesh).size
	elif mesh is QuadMesh:
		arr = _unit(mesh)
		size = Vector3((mesh as QuadMesh).size.x, (mesh as QuadMesh).size.y, 1.0)
	else:
		var kept: Array = mesh.get_meta(PropBatch.ARRAYS_META, [])
		arr = kept[0] if not kept.is_empty() else mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var base: int = s.v.size()
	s.v.append_array((xf * Transform3D(Basis.from_scale(size), Vector3.ZERO)) * verts)
	# Box / quad / sheet normals run along the scaling axes: rotation alone turns them.
	var nrms = arr[Mesh.ARRAY_NORMAL]
	if nrms != null:
		s.n.append_array(Transform3D(xf.basis.orthonormalized(), Vector3.ZERO) * (nrms as PackedVector3Array))
	else:
		var up := PackedVector3Array()
		up.resize(verts.size())
		up.fill(Vector3.UP)
		s.n.append_array(up)
	var uvs = arr[Mesh.ARRAY_TEX_UV]
	if uvs != null:
		s.uv.append_array(uvs)
	else:
		var zero := PackedVector2Array()
		zero.resize(verts.size())
		s.uv.append_array(zero)
	var ix = arr[Mesh.ARRAY_INDEX]
	if ix != null and not (ix as PackedInt32Array).is_empty():
		for i: int in ix:
			s.ix.append(base + i)
	else:
		for i in verts.size():
			s.ix.append(base + i)


## Surface `s` (from _new_surface) as a new surface of `mesh`.
static func _commit(s: Dictionary, mesh: ArrayMesh) -> void:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = s.v
	arr[Mesh.ARRAY_NORMAL] = s.n
	arr[Mesh.ARRAY_TEX_UV] = s.uv
	arr[Mesh.ARRAY_INDEX] = s.ix
	PropBatch.commit_arrays(arr, mesh)


static func _box_mesh(size: Vector3) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = size
	return mesh


## Rewrites the face a moment after the words stop changing (editor).
func _queue_face() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree() or _face_queued:
		return
	_face_queued = true
	get_tree().create_timer(0.5).timeout.connect(_write_face)


func _write_face() -> void:
	_face_queued = false
	if not is_inside_tree() or not ResourceLoader.exists(FACE_GENERATOR):
		return
	var words := face_text if face_text.strip_edges() != "" else text
	var tex: Texture2D = load(FACE_GENERATOR).face_for(words, alphabet_path, board_size, ink_color, board_texture, board_color, lettering,
		symbols_used())
	if tex != face_texture:
		face_texture = tex
		# Built from a prop brush: the brush keeps it (this node is rebuilt from it).
		if has_meta(&"prop_spec"):
			get_meta(&"prop_spec").store_from(self, &"face_texture")


## The face's words that have a word symbol (editor only: the alphabet doesn't ship).
func _symbol_words() -> PackedStringArray:
	if not Engine.is_editor_hint() or not ResourceLoader.exists(FACE_GENERATOR):
		return PackedStringArray()
	return load(FACE_GENERATOR).symbol_words_in(face_text if face_text.strip_edges() != "" else text, alphabet_path)


## The words this sign writes with their symbol (the rest of _symbol_words is spelled out).
func symbols_used() -> PackedStringArray:
	var out := PackedStringArray()
	for w in _symbol_words():
		if not w in spelled_out:
			out.append(w)
	return out


func _get_property_list() -> Array[Dictionary]:
	var words := _symbol_words()
	if words.is_empty():
		return []
	var out: Array[Dictionary] = [{name = "Word symbols", type = TYPE_NIL, usage = PROPERTY_USAGE_GROUP, hint_string = "symbol_"}]
	for w in words:
		out.append({name = "symbol_" + w, type = TYPE_BOOL, usage = PROPERTY_USAGE_EDITOR})
	return out


func _get(property: StringName) -> Variant:
	var p := String(property)
	if p.begins_with("symbol_"):
		return not p.trim_prefix("symbol_") in spelled_out
	return null


func _set(property: StringName, value: Variant) -> bool:
	var p := String(property)
	if not p.begins_with("symbol_"):
		return false
	var w := p.trim_prefix("symbol_")
	var s := spelled_out.duplicate()
	if value:
		s.erase(w)
	elif not w in s:
		s.append(w)
	spelled_out = s
	_queue_face()
	return true


## The one-line dialogue reading the sign plays.
func _update_dialogue() -> void:
	if talkable == null:
		return
	var id := sign_id if sign_id != &"" else StringName(String(name).to_snake_case())
	var d := Dialogue.new()
	d.id = StringName("sign_%s" % id)
	d.start = "text"
	var line := DialogueLine.new()
	line.id = "text"
	line.style = DialogueLine.Style.SIGN
	line.text = text
	d.nodes.append(line)
	talkable.dialogue = d
	talkable.enabled = text.strip_edges() != ""
