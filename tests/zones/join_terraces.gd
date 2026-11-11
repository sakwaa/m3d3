extends Node
## Closes the cracks between neighbouring houses: side walls facing each other up to MAX_GAP
## apart each move halfway across (the houses join into a terrace, HouseTerrace); a back or
## side against another house grows across the whole crack (fronts, with their doors, never
## move). Then every house is built again, the level relit (timed keys and rain light, as Bake Lighting does) and baked.
##   SCENE=res://zones/town1/town_1_market_square.tscn tools/godot_run.sh --path . tests/zones/join_terraces.tscn
## (editor closed; windowed for the lighting bake). DRY=1: only list what would move.

const MAX_GAP := 0.25
const SIDES := [Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD]  # (BACK: +z, the front)


func _ready() -> void:
	var zone: Node = (load(OS.get_environment("SCENE")) as PackedScene).instantiate()
	add_child(zone)
	await get_tree().process_frame
	var root: LevelRoot = zone.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)[0]
	var data: LevelData = root.data
	var path := data.resource_path
	var uid := ResourceLoader.get_resource_uid(path)
	var houses := data.brushes.filter(func(b): return b and b.is_house())
	# Every crack: a wall of one house facing a wall of another up to MAX_GAP away, sharing
	# some length. Side to side, each moves halfway across; otherwise one house grows across
	# the whole crack from its back (or else a side): a front never moves (its doors).
	var cracks := {}  # [house, side (local normal)] -> how far it moves (the most asked)
	var seen := {}
	var move := func(h: LevelBrush, n: Vector3, g: float) -> void:
		cracks[[h, n]] = maxf(cracks.get([h, n], 0.0), g)
	for b: LevelBrush in houses:
		var inv := b.transform.affine_inverse()
		for o: LevelBrush in houses:
			if o == b or seen.has([o, b]):
				continue
			var rel := inv * o.transform
			for n in SIDES:
				for m in SIDES:
					var g := _gap(b.house, n, o.house, m, rel)
					if g < 0.0:
						continue
					seen[[b, o]] = true
					if n.x != 0.0 and m.x != 0.0:
						move.call(b, n, g * 0.5)
						move.call(o, m, g * 0.5)
					elif n == Vector3.FORWARD:
						move.call(b, n, g)
					elif m == Vector3.FORWARD:
						move.call(o, m, g)
					elif n.x != 0.0:
						move.call(b, n, g)
					elif m.x != 0.0:
						move.call(o, m, g)
					else:
						print("%s / %s: front to front, left" % [b.tag, o.tag])
	print("%d walls to move" % cracks.size())
	if OS.get_environment("DRY") != "":
		for c in cracks:
			print("  %s side %s by %.3f" % [c[0].tag, c[1], cracks[c]])
		get_tree().quit()
		return
	# Doors / windows in a wall that moves would be left inside it: say so (and leave it).
	var stuck := {}
	for c in cracks:
		var b: LevelBrush = c[0]
		var n: Vector3 = c[1]
		var inv := b.transform.affine_inverse()
		var half := Vector3(b.house.width * 0.5, 0, b.house.depth * 0.5)
		for o: LevelBrush in data.brushes:
			if o and o.opening_spec() != null:
				var q := inv * o.transform.origin
				if absf(q.dot(n) - half.dot(n.abs())) < 0.4 and (q - n * q.dot(n)).abs().x <= half.x + 0.1 and (q - n * q.dot(n)).abs().z <= half.z + 0.1:
					print("  %s: %s stands in the wall that moves: left as is" % [b.tag, o.tag])
					stuck[c] = true
	for c in stuck:
		cracks.erase(c)
	for c in cracks:
		var b: LevelBrush = c[0]
		var n: Vector3 = c[1]
		var g: float = cracks[c]
		# The wall moves out by g: the house grows by g that way, its centre by half.
		if n.x != 0.0:
			b.house.width += g
		else:
			b.house.depth += g
		b.transform = Transform3D(b.transform.basis, b.transform * (n * g * 0.5))
	var joined := 0
	for b: LevelBrush in houses:
		root._generate_house(b, houses)
		joined += HouseTerrace.joins(b, houses).size()
	print("joined sides: %d" % joined)
	await preload("res://tests/zones/relight.gd").relight(zone, root)
	var res := LevelBaker.bake(data, root.merge_coplanar)
	data.baked_mesh = res.mesh
	data.baked_chunks = res.chunks
	data.set_baked_collision(res)
	var err := ResourceSaver.save(data, path, ResourceSaver.FLAG_COMPRESS)
	if uid != ResourceUID.INVALID_ID:
		ResourceSaver.set_uid(path, uid)
	print("saved %s: %s, %d baked tris" % [path, error_string(err), res.stats.baked_tris])
	get_tree().quit()


## The crack between wall `n` of house `h` and wall `m` of house `oh` (`rel`: oh's local to
## h's), or -1 when they don't face each other across one.
func _gap(h: HouseSpec, n: Vector3, oh: HouseSpec, m: Vector3, rel: Transform3D) -> float:
	if (rel.basis * m).normalized().dot(n) > -0.999:
		return -1.0
	var half := Vector3(h.width * 0.5, 0, h.depth * 0.5)
	var ohalf := Vector3(oh.width * 0.5, 0, oh.depth * 0.5)
	var p := rel * (m * ohalf)
	var g := (p - n * half).dot(n)
	if g <= HouseTerrace.JOIN_GAP or g > MAX_GAP:
		return -1.0
	# Shared length along the wall.
	var along := Vector3(absf(n.z), 0, absf(n.x))
	var c := (rel.origin).dot(along)
	var oh_half := (ohalf * Vector3(absf(m.z), 0, absf(m.x))).length()
	var h_half := (half * along).length()
	if minf(h_half, c + oh_half) - maxf(-h_half, c - oh_half) < HouseTerrace.MIN_OVERLAP:
		return -1.0
	return g
