@tool
class_name BodyPlan
extends RefCounted
## A skeleton type (humanoid, quadruped, ...): fixed bone names and hierarchy, posed from a
## few proportion parameters, plus the IK chains and the mannequin's starter shapes.
## Every character of a type shares bone names, so animations, look-at, IK and state
## machine bindings work the same on all of them.
##
## Adding a type: a script in body_plans/ extending BodyPlan that overrides id(),
## display_name(), params(), define() and chains(). Define the centre and LEFT side only
## (left = -X; models face -Z); right-side bones, chains and poles are mirrored
## automatically (names ending in _L become _R).

const PLANS_DIR := "res://addons/n64_actor_tools/body_plans/"


## One bone: rest position in model space (feet on y = 0, facing -Z) and its starter
## mannequin shape.
class Bone:
	var name: StringName
	var parent: StringName
	var head: Vector3
	var tail: Vector3
	## -1 left, 0 centre, 1 right.
	var side := 0
	## tube: ring of `sides` from radius.x (head) to radius.y (tail). box: `box` (width,
	## depth) along the bone. none: no starter piece.
	var shape := &"tube"
	var radius := Vector2(0.05, 0.04)
	var box := Vector2(0.1, 0.1)
	var sides := 6

	func length() -> float:
		return head.distance_to(tail)


## Two-bone IK: `upper` and `lower` bend toward `pole` (model space direction) to put the
## head of `end` (wrist / ankle) on the target; `end` keeps its orientation.
class Chain:
	var name: StringName
	var upper: StringName
	var lower: StringName
	var end: StringName
	var pole := Vector3.FORWARD


func id() -> StringName:
	return &""


func display_name() -> String:
	return String(id()).capitalize()


## Proportion parameters: [{name, default, min, max, step}] (metres unless noted).
func params() -> Array[Dictionary]:
	return []


## Centre + left bones for resolved parameters `p` (every param present).
func define(_p: Dictionary) -> Array[Bone]:
	return []


## Left-side (and centre) IK chains.
func chains() -> Array[Chain]:
	return []


## Missing parameters filled with defaults, out-of-range ones clamped.
func resolve(values: Dictionary) -> Dictionary:
	var p := {}
	for d in params():
		p[d.name] = clampf(float(values.get(d.name, d.default)), d.min, d.max)
	return p


## Proportions whose bones' lengths best match `measured` (bone -> metres), starting
## from `values` (character editor v2: the skeleton follows meshes edited in Blender).
## Least squares with a light pull toward the start, so parameters no measured bone
## depends on stay put; changes under half a step are dropped, the rest rounded to steps.
func fit(measured: Dictionary, values: Dictionary) -> Dictionary:
	var defs := params()
	var start := resolve(values)
	var names: Array = measured.keys()
	if names.is_empty() or defs.is_empty():
		return start
	var target := PackedFloat64Array()
	for n in names:
		target.append(measured[n])
	var p := start.duplicate()
	var reg := 1e-4
	for _iter in 8:
		var base := _lengths(p, names)
		var r := PackedFloat64Array()
		for i in names.size():
			r.append(base[i] - target[i])
		# Normal equations (J^T J + reg W) d = -(J^T r + reg W (p - start)).
		var m := defs.size()
		var a: Array[PackedFloat64Array] = []
		var g := PackedFloat64Array()
		var cols: Array[PackedFloat64Array] = []
		for d in defs:
			var h := maxf(float(d.step), 1e-3)
			var q := p.duplicate()
			q[d.name] = p[d.name] + h
			var moved := _lengths(q, names)
			var col := PackedFloat64Array()
			for i in names.size():
				col.append((moved[i] - base[i]) / h)
			cols.append(col)
		for j in m:
			var row := PackedFloat64Array()
			row.resize(m)
			var wj: float = reg / pow(maxf(defs[j].max - defs[j].min, 1e-3), 2)
			for k in m:
				var s := 0.0
				for i in names.size():
					s += cols[j][i] * cols[k][i]
				row[k] = s + (wj if j == k else 0.0)
			a.append(row)
			var gj: float = wj * (p[defs[j].name] - start[defs[j].name])
			for i in names.size():
				gj += cols[j][i] * r[i]
			g.append(-gj)
		var step := _solve(a, g)
		var change := 0.0
		for j in m:
			var d: Dictionary = defs[j]
			var v: float = clampf(p[d.name] + step[j], d.min, d.max)
			change = maxf(change, absf(v - p[d.name]))
			p[d.name] = v
		if change < 1e-5:
			break
	for d in defs:
		var st := float(d.step)
		if absf(p[d.name] - start[d.name]) < st * 0.5:
			p[d.name] = start[d.name]
		else:
			p[d.name] = clampf(snappedf(p[d.name], st), d.min, d.max)
	return p


func _lengths(p: Dictionary, names: Array) -> PackedFloat64Array:
	var by_name := {}
	for b in all_bones(p):
		by_name[b.name] = b.length()
	var out := PackedFloat64Array()
	for n in names:
		out.append(by_name.get(n, 0.0))
	return out


## Solves a x = b (small, dense; Gaussian elimination with partial pivoting).
static func _solve(a: Array[PackedFloat64Array], b: PackedFloat64Array) -> PackedFloat64Array:
	var n := b.size()
	for c in n:
		var piv := c
		for r in range(c + 1, n):
			if absf(a[r][c]) > absf(a[piv][c]):
				piv = r
		if absf(a[piv][c]) < 1e-12:
			continue
		if piv != c:
			var t := a[c]
			a[c] = a[piv]
			a[piv] = t
			var tb := b[c]
			b[c] = b[piv]
			b[piv] = tb
		for r in range(c + 1, n):
			var f := a[r][c] / a[c][c]
			if f == 0.0:
				continue
			for k in range(c, n):
				a[r][k] -= f * a[c][k]
			b[r] -= f * b[c]
	var x := PackedFloat64Array()
	x.resize(n)
	for c in range(n - 1, -1, -1):
		if absf(a[c][c]) < 1e-12:
			continue
		var s := b[c]
		for k in range(c + 1, n):
			s -= a[c][k] * x[k]
		x[c] = s / a[c][c]
	return x


## Every bone (right side mirrored from the left), parents before children.
func all_bones(values: Dictionary) -> Array[Bone]:
	var out: Array[Bone] = []
	for b in define(resolve(values)):
		out.append(b)
		if b.side == -1:
			out.append(mirrored(b))
	return out


func all_chains() -> Array[Chain]:
	var out: Array[Chain] = []
	for c in chains():
		out.append(c)
		if String(c.end).ends_with("_L"):
			var r := Chain.new()
			r.name = mirror_name(c.name)
			r.upper = mirror_name(c.upper)
			r.lower = mirror_name(c.lower)
			r.end = mirror_name(c.end)
			r.pole = Vector3(-c.pole.x, c.pole.y, c.pole.z)
			out.append(r)
	return out


static func mirror_name(n: StringName) -> StringName:
	var s := String(n)
	if s.ends_with("_L"):
		return StringName(s.left(-2) + "_R")
	if s.ends_with("_R"):
		return StringName(s.left(-2) + "_L")
	return n


static func mirrored(b: Bone) -> Bone:
	var r := Bone.new()
	r.name = mirror_name(b.name)
	r.parent = mirror_name(b.parent)
	r.head = Vector3(-b.head.x, b.head.y, b.head.z)
	r.tail = Vector3(-b.tail.x, b.tail.y, b.tail.z)
	r.side = 1
	r.shape = b.shape
	r.radius = b.radius
	r.box = b.box
	r.sides = b.sides
	return r


# --- Helpers for plan scripts -------------------------------------------------------------

func tube(bone_name: StringName, parent: StringName, head: Vector3, tail: Vector3, r_head: float, r_tail: float, sides := 6) -> Bone:
	var b := _bone(bone_name, parent, head, tail)
	b.shape = &"tube"
	b.radius = Vector2(r_head, r_tail)
	b.sides = sides
	return b


func block(bone_name: StringName, parent: StringName, head: Vector3, tail: Vector3, width: float, depth: float) -> Bone:
	var b := _bone(bone_name, parent, head, tail)
	b.shape = &"box"
	b.box = Vector2(width, depth)
	return b


func joint(bone_name: StringName, parent: StringName, head: Vector3, tail: Vector3) -> Bone:
	var b := _bone(bone_name, parent, head, tail)
	b.shape = &"none"
	return b


func chain(chain_name: StringName, upper: StringName, lower: StringName, end: StringName, pole: Vector3) -> Chain:
	var c := Chain.new()
	c.name = chain_name
	c.upper = upper
	c.lower = lower
	c.end = end
	c.pole = pole
	return c


func param(param_name: String, default: float, lo: float, hi: float, step := 0.01) -> Dictionary:
	return {name = param_name, default = default, min = lo, max = hi, step = step}


func _bone(bone_name: StringName, parent: StringName, head: Vector3, tail: Vector3) -> Bone:
	var b := Bone.new()
	b.name = bone_name
	b.parent = parent
	b.head = head
	b.tail = tail
	b.side = -1 if String(bone_name).ends_with("_L") else 0
	return b


# --- Registry ---------------------------------------------------------------------------

static var _plans := {}


## Every plan in body_plans/, by id.
static func all() -> Dictionary:
	if _plans.is_empty():
		# Exported apps (the iOS mesh builder) list compiled scripts: "x.gd.remap" / "x.gdc";
		# loading "x.gd" still works through the remap.
		var names := {}
		for f in DirAccess.get_files_at(PLANS_DIR):
			f = f.trim_suffix(".remap")
			if f.get_extension() == "gdc":
				f = f.get_basename() + ".gd"
			if f.get_extension() == "gd":
				names[f] = true
		for f in names:
			var script: Script = load(PLANS_DIR.path_join(f))
			if script == null or not script.can_instantiate():
				push_error("Body plan %s failed to load." % f)
				continue
			var plan = script.new()
			if plan is BodyPlan and plan.id() != &"":
				_plans[plan.id()] = plan
	return _plans


static func find(plan_id: StringName) -> BodyPlan:
	return all().get(plan_id)
