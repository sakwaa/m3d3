@tool
class_name HouseFixtures
extends RefCounted
## Doors, windows and signs belonging to a house's walls (LevelBrush.host / mount): finding
## which wall each sits on (adopt), keeping them there when the house changes (place), sliding
## them along their wall (slide), and filling a house's walls with windows (add_windows).

const PassageBuilder := preload("res://addons/n64_level_tools/passage_builder.gd")
## A sign's board stands this far out of the wall's face.
const SIGN_OUT := 0.0


## Ties every door, window and sign standing in a house's wall to it (those not tied yet).
## Returns how many were tied.
static func adopt(data: LevelData) -> int:
	var n := 0
	var houses := data.brushes.filter(func(b): return b != null and b.is_house())
	for f: LevelBrush in data.brushes:
		if f == null or f.host != &"" or not _is_fixture(f):
			continue
		for h: LevelBrush in houses:
			var m := _mount_on(h, f)
			if m != Vector3.INF:
				f.host = h.tag
				f.mount = m
				n += 1
				break
	return n


static func _is_fixture(b: LevelBrush) -> bool:
	return b.opening_spec() != null and not b.is_passage() or (b.is_prop() and b.prop.kind == PropSpec.Kind.SIGN)


## Where `f` sits on one of `h`'s walls (mount), or INF if on none: in the wall's plane (within
## its thickness, or just out of its face for a sign), inside its length and height, facing out.
static func _mount_on(h: LevelBrush, f: LevelBrush) -> Vector3:
	var spec := h.house
	var local := h.transform.affine_inverse() * f.transform
	for side in 4:
		var w := spec.wall_xf(side, 0.0, 0.0)
		var p := w.affine_inverse() * local.origin
		var facing := (w.basis.inverse() * local.basis.z).normalized()
		if facing.z < 0.7:
			continue
		var half_len := spec.wall_length(side) * 0.5
		var inside := -_thickness(spec) - 0.15 <= p.z and p.z <= 0.6
		if inside and absf(p.x) <= half_len + 0.1 and p.y >= -spec.foundation - 0.2 and p.y <= spec.wall_height() + 1.5:
			return Vector3(p.x, p.y, side)
	return Vector3.INF


static func _thickness(spec: HouseSpec) -> float:
	return minf(spec.wall_thickness, minf(spec.width, spec.depth) * 0.5 - 0.05)


## `f`'s transform (level space) at `mount` on house `h`: openings on the wall's centre line,
## signs on its face.
static func transform_for(h: LevelBrush, f: LevelBrush, mount: Vector3) -> Transform3D:
	var spec := h.house
	var out := -_thickness(spec) * 0.5 if f.opening_spec() else SIGN_OUT
	return h.transform * spec.wall_xf(int(mount.z), mount.x, mount.y, out)


## `mount` kept on its wall: inside the wall's length (the opening's half width in from each
## corner) and between the ground floor and the wall top (an opening's height below it).
static func clamp_mount(h: LevelBrush, f: LevelBrush, mount: Vector3) -> Vector3:
	var spec := h.house
	var o := f.opening_spec()
	var half_w := o.opening_size().x * 0.5 + 0.1 if o else 0.2
	var high := o.opening_size().y if o else 0.0
	var half_len := spec.wall_length(int(mount.z)) * 0.5
	var lo_y := -spec.foundation if o == null else 0.0
	var top := spec.storeys * spec.storey_height - high - (0.1 if o else -1.2)
	return Vector3(clampf(mount.x, -half_len + half_w, maxf(half_len - half_w, -half_len + half_w)),
		clampf(mount.y, lo_y, maxf(top, lo_y)), mount.z)


## The fixtures tied to house `h`.
static func of(data: LevelData, h: LevelBrush) -> Array[LevelBrush]:
	var out: Array[LevelBrush] = []
	for f: LevelBrush in data.brushes:
		if f and f.host != &"" and f.host == h.tag:
			out.append(f)
	return out


## Puts house `h`'s fixtures back on its walls (after it moved, was resized or rebuilt):
## clamped onto the wall, at their mount; an opening's cut follows (it's re-cut in the new
## walls). Returns the fixtures that moved.
static func place(data: LevelData, h: LevelBrush) -> Array[LevelBrush]:
	var moved: Array[LevelBrush] = []
	for f in of(data, h):
		var m := clamp_mount(h, f, f.mount)
		var xf := transform_for(h, f, m)
		if m == f.mount and xf.is_equal_approx(f.transform):
			continue
		f.mount = m
		f.transform = xf
		var o := f.opening_spec()
		if o:
			o.mark_carved(o.opening_xf(xf))
		moved.append(f)
	return moved


## `f` slid along its wall to the spot nearest `level_point` (snapped to `step`): its new
## mount (the wall stays the same).
static func slide(h: LevelBrush, f: LevelBrush, level_point: Vector3, step: float) -> Vector3:
	var spec := h.house
	var side := int(f.mount.z)
	var w := h.transform * spec.wall_xf(side, 0.0, 0.0)
	var p := w.affine_inverse() * level_point
	var s := maxf(step, 0.05)
	return clamp_mount(h, f, Vector3(snappedf(p.x, s), snappedf(p.y, s), side))


## Window spots on house `h` the way the House tool lays them out: the front's right in every
## storey (a shop's open front none downstairs), over the door spot upstairs, the middle of
## each side wall per storey; [side, along, up]. Spots already taken by a fixture or the shop
## opening, and party walls in a terrace, are left out.
static func window_spots(data: LevelData, h: LevelBrush, size: Vector2) -> Array:
	var spec := h.house
	var hw := spec.width * 0.5
	var door_x := -minf(1.4, hw - 1.0)
	var spots := []
	for k in spec.storeys:
		var sill := k * spec.storey_height + 1.0
		if not (spec.shopfront and k == 0):
			spots.append([0, hw * 0.45, sill])
		if k > 0:
			spots.append([0, door_x, sill])
		spots.append([1, 0.0, sill])
		spots.append([3, 0.0, sill])
	var taken := of(data, h)
	# No windows in a party wall (a terrace neighbour stands against it).
	var joins := HouseTerrace.joins(h, data.brushes.filter(func(b): return b != null and b.is_house()))
	var out := []
	for s in spots:
		if joins.has(HouseSpec.SIDE_NAMES[s[0]]):
			continue
		if _free(spec, taken, s, size):
			out.append(s)
	return out


## No fixture on that wall overlaps a window of `size` at spot `s` (with a margin), and it's
## clear of the shop opening.
static func _free(spec: HouseSpec, taken: Array[LevelBrush], s: Array, size: Vector2) -> bool:
	var r := Rect2(s[1] - size.x * 0.5 - 0.3, s[2] - 0.3, size.x + 0.6, size.y + 0.6)
	if spec.shopfront and s[0] == 0:
		var span := spec.shop_span()
		if r.intersects(Rect2(span.x - span.y, 0.0, span.y * 2.0, spec.shop_height + 0.5)):
			return false
	for f in taken:
		if int(f.mount.z) != s[0]:
			continue
		var o := f.opening_spec()
		var fs := o.opening_size() if o else Vector2(1.6, 0.6)
		var fy: float = f.mount.y if o else f.mount.y - 0.3
		if r.intersects(Rect2(f.mount.x - fs.x * 0.5, fy, fs.x, fs.y)):
			return false
	return true


## A window for a house's wall, made cheap for a house with no interior: outside only, and a
## flat frame (no edges standing off the wall; the cut under it keeps it clean): ~38
## triangles close up instead of ~150.
static func house_window(spec: HouseSpec, wall_tex: int) -> WindowSpec:
	var w := WindowSpec.new()
	w.wall_depth = _thickness(spec)
	w.wall_texture = wall_tex
	w.wall_color = spec.wall_color
	w.dressing = WindowSpec.default_dressing()
	make_cheap(w)
	return w


## Outside only, flat frame (see house_window).
static func make_cheap(w: WindowSpec) -> void:
	w.outside_only = true
	if w.dressing:
		w.dressing.side_depth = 0.0
		w.dressing.top_depth = 0.0


## Adds windows to house `h` at its free spots (window_spots), cutting them into its walls
## like the Window tool, tied to it. Returns the new window brushes; `carved` gets other brushes
## the cuts changed (brush -> snapshot before), for undo.
static func add_windows(root: LevelRoot, h: LevelBrush, carved := {}) -> Array[LevelBrush]:
	var spec := h.house
	var added: Array[LevelBrush] = []
	var wall_tex := root._palette_index(spec.wall_texture)
	for s in window_spots(root.data, h, Vector2(0.9, 1.0)):
		var w := house_window(spec, wall_tex)
		var ob := LevelBrush.new()
		ob.tag = StringName("window_%08x" % randi())
		ob.hand_edited = true
		ob.host = h.tag
		ob.mount = Vector3(s[1], s[2], s[0])
		ob.window = w
		ob.transform = transform_for(h, ob, ob.mount)
		var oxf := w.opening_xf(ob.transform)
		var snaps := {}
		for other in root.data.brushes:
			if other and not carved.has(other):
				snaps[other] = other.snapshot()
		var cuts := PassageBuilder.carve_opening(root, root.global_transform * oxf, w.opening_size().x, w.opening_size().y,
			w.carve_depth(), ob.tag, w.cut_trim(), w.shape())
		for c in cuts:
			if not carved.has(c.brush) and not c.brush in added:
				carved[c.brush] = snaps.get(c.brush, c.before)
		w.mark_carved(oxf)
		root.data.add_brush(ob)
		root._generate_window(ob)  # (its frame, sill and pane now, not on the next sync)
		added.append(ob)
	return added
