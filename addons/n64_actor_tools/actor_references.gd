@tool
extends Node3D
## Reference images for the orthographic views (like Blender's background images): one
## per view (front, back, left, right, top, bottom), shown only in that view, a little
## behind the model. Each has an image, position (metres, in the view plane), height
## (metres), stretch (width / the image's own aspect), angle (radians, counter-clockwise
## in the view), opacity, a show toggle and a lock (locked: taps don't select it). Saved with the model
## (node metadata). Shared by the phone app and the editor's character tools. Images
## live in `dir`: user://references on the phone (the app's folder in the Files app),
## res://references in the editor (ignored by Godot, never exported); a saved path that
## doesn't exist on this side is looked up by file name in `dir`.

const IMAGE_TYPES := ["png", "jpg", "jpeg", "webp", "bmp", "tga"]
const META := &"n64_references"
## Per view: forward (into the screen) and up, matching OrbitCamera's views; right =
## forward x up.
const VIEW_AXES := {
	1: [Vector3(0, 0, 1), Vector3.UP], 2: [Vector3(0, 0, -1), Vector3.UP],
	3: [Vector3(1, 0, 0), Vector3.UP], 4: [Vector3(-1, 0, 0), Vector3.UP],
	5: [Vector3(0, -1, 0), Vector3(0, 0, 1)], 6: [Vector3(0, 1, 0), Vector3(0, 0, 1)],
}
## How far behind the model's far side the image sits.
const GAP := 0.3

## view -> {path, offset: Vector2, height, stretch, angle, opacity, visible, locked}
var refs := {}
## Folder images are listed from and imported into (set before adding the node).
var dir := "user://references"
var view := 0
var _quads := {}  # view -> MeshInstance3D
var _textures := {}  # path -> Texture2D
var _model_box := AABB(Vector3(-0.5, 0, -0.5), Vector3(1, 1.7, 1))


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(dir)


## Image files in the references folder (newest first).
func images() -> PackedStringArray:
	var out := []
	var d := DirAccess.open(dir)
	if d:
		for f in d.get_files():
			if f.get_extension().to_lower() in IMAGE_TYPES:
				out.append(dir.path_join(f))
	out.sort_custom(func(a, b): return FileAccess.get_modified_time(a) > FileAccess.get_modified_time(b))
	return PackedStringArray(out)


## Copies an image file from anywhere into `dir` (a numbered name if one with that name
## but different contents is there); returns its path there, or "" on failure.
func import_image(source: String) -> String:
	var bytes := FileAccess.get_file_as_bytes(source)
	if bytes.is_empty():
		return ""
	DirAccess.make_dir_recursive_absolute(dir)
	var base := source.get_file().get_basename().validate_filename()
	var ext := source.get_extension().to_lower()
	var path := dir.path_join("%s.%s" % [base, ext])
	var n := 2
	while FileAccess.file_exists(path) and FileAccess.get_file_as_bytes(path) != bytes:
		path = dir.path_join("%s_%d.%s" % [base, n, ext])
		n += 1
	if not FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			return ""
		f.store_buffer(bytes)
		f.close()
	return path


func get_ref(v: int) -> Dictionary:
	return refs.get(v, {})


## Sets view `v`'s image (new references start centred on the model, its height).
func set_image(v: int, path: String) -> bool:
	if _texture(path) == null:
		return false
	var r: Dictionary = refs.get(v, {})
	if r.is_empty():
		r = {offset = Vector2.ZERO, height = 1.0, opacity = 0.55, visible = true}
		refs[v] = r
		r.path = path
		fit(v)
	r.path = path
	r.visible = true
	_update(v)
	return true


func set_value(v: int, key: String, value: Variant) -> void:
	if refs.has(v):
		refs[v][key] = value
		_update(v)


func clear(v: int) -> void:
	refs.erase(v)
	if _quads.has(v):
		_quads[v].queue_free()
		_quads.erase(v)


## Sizes view `v`'s image to the model's height in that view and centres it on it.
func fit(v: int) -> void:
	if not refs.has(v) or not VIEW_AXES.has(v):
		return
	var axes := _axes(v)
	var c := _model_box.get_center()
	var h := 0.0
	for i in 8:
		h = maxf(h, absf((_model_box.get_endpoint(i) - c).dot(axes[1])) * 2.0)
	refs[v].height = maxf(h, 0.05)
	refs[v].offset = Vector2(c.dot(axes[0]), c.dot(axes[1]))
	_update(v)


## Plane coordinates (metres: right, up in view `v`) of a world point.
func to_plane(v: int, world: Vector3) -> Vector2:
	var axes := _axes(v)
	return Vector2(world.dot(axes[0]), world.dot(axes[1]))


## World point of plane coordinates `p` in view `v` (at the image's depth).
func to_world(v: int, p: Vector2) -> Vector3:
	var axes := _axes(v)
	return axes[0] * p.x + axes[1] * p.y + axes[2] * _depth(v)


## View `v`'s image frame in plane coordinates: {centre, half (half width, height),
## angle}, or {}.
func frame(v: int) -> Dictionary:
	if not refs.has(v) or not VIEW_AXES.has(v):
		return {}
	var r: Dictionary = refs[v]
	var tex := _texture(r.get("path", ""))
	if tex == null:
		return {}
	var aspect := float(tex.get_width()) / maxf(tex.get_height(), 1)
	return {centre = r.offset, half = Vector2(r.height * aspect * r.get("stretch", 1.0), r.height) * 0.5,
		angle = r.get("angle", 0.0), aspect = aspect}


## Plane point `p` inside view `v`'s image?
func contains(v: int, p: Vector2) -> bool:
	var f := frame(v)
	if f.is_empty():
		return false
	var q: Vector2 = (p - f.centre).rotated(-f.angle)
	return absf(q.x) <= f.half.x and absf(q.y) <= f.half.y


## Sets view `v`'s image frame (centre, full size in metres, angle).
func set_frame(v: int, centre: Vector2, full: Vector2, angle: float) -> void:
	var f := frame(v)
	if f.is_empty():
		return
	var r: Dictionary = refs[v]
	r.offset = centre
	r.height = clampf(full.y, 0.02, 20.0)
	r.stretch = clampf(full.x / (r.height * f.aspect), 0.05, 20.0)
	r.angle = wrapf(angle, -PI, PI)
	_update(v)


## Moves view `v`'s image by `delta` metres (right, up in the view).
func nudge(v: int, delta: Vector2) -> void:
	if refs.has(v):
		refs[v].offset += delta
		_update(v)


## Scales view `v`'s image by `factor` about the view-plane point `pivot` (metres).
func scale_about(v: int, factor: float, pivot: Vector2) -> void:
	if not refs.has(v):
		return
	var r: Dictionary = refs[v]
	r.height = clampf(r.height * factor, 0.02, 20.0)
	r.offset = pivot + (r.offset - pivot) * factor
	_update(v)


## Shows only the reference of the current view (none in perspective).
func show_view(v: int) -> void:
	view = v
	for k in _quads:
		_quads[k].visible = k == v and refs.has(k) and refs[k].visible


func set_model_box(box: AABB) -> void:
	_model_box = box
	for v in refs:
		_update(v)


# --- Saving with the model -----------------------------------------------------------------

func save_to(model: Node) -> void:
	if refs.is_empty():
		if model.has_meta(META):
			model.remove_meta(META)
	else:
		model.set_meta(META, refs.duplicate(true))


func load_from(model: Node) -> void:
	for v in _quads:
		_quads[v].queue_free()
	_quads.clear()
	refs = (model.get_meta(META, {}) as Dictionary).duplicate(true)
	for v in refs:
		_update(v)
	show_view(view)


# --- Display -------------------------------------------------------------------------------

## [right, up, forward] (world) for view `v`.
func _axes(v: int) -> Array:
	var f: Vector3 = VIEW_AXES[v][0]
	var u: Vector3 = VIEW_AXES[v][1]
	return [f.cross(u), u, f]


func _update(v: int) -> void:
	if not refs.has(v) or not VIEW_AXES.has(v):
		return
	var r: Dictionary = refs[v]
	var tex := _texture(r.get("path", ""))
	if tex == null:
		return
	var mi: MeshInstance3D = _quads.get(v)
	if mi == null:
		mi = MeshInstance3D.new()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
		mat.render_priority = -3
		mi.material_override = mat
		mi.mesh = QuadMesh.new()
		add_child(mi)
		_quads[v] = mi
	var axes := _axes(v)
	var aspect := float(tex.get_width()) / maxf(tex.get_height(), 1)
	(mi.mesh as QuadMesh).size = Vector2(r.height * aspect * r.get("stretch", 1.0), r.height)
	var mat: StandardMaterial3D = mi.material_override
	mat.albedo_texture = tex
	mat.albedo_color = Color(1, 1, 1, r.opacity)
	# Behind the model's far side, facing the camera, turned in the view plane.
	var a: float = r.get("angle", 0.0)
	var right: Vector3 = axes[0] * cos(a) + axes[1] * sin(a)
	var up: Vector3 = -axes[0] * sin(a) + axes[1] * cos(a)
	mi.transform = Transform3D(Basis(right, up, -axes[2]), to_world(v, r.offset))
	mi.visible = v == view and r.visible


## Behind the model's far side along view `v`.
func _depth(v: int) -> float:
	var axes := _axes(v)
	var far := -INF
	for i in 8:
		far = maxf(far, _model_box.get_endpoint(i).dot(axes[2]))
	return far + GAP


func _texture(path: String) -> Texture2D:
	if path == "":
		return null
	if not FileAccess.file_exists(path):
		path = dir.path_join(path.get_file())
		if not FileAccess.file_exists(path):
			return null
	if not _textures.has(path):
		var img := Image.load_from_file(path)
		if img == null or img.is_empty():
			return null
		# Phones: keep big photos manageable.
		if maxi(img.get_width(), img.get_height()) > 2048:
			var k := 2048.0 / maxi(img.get_width(), img.get_height())
			img.resize(int(img.get_width() * k), int(img.get_height() * k), Image.INTERPOLATE_BILINEAR)
		_textures[path] = ImageTexture.create_from_image(img)
	return _textures[path]
