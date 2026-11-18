extends Node
## Forest citadel playability: the player walks from the spawn through the entrance cleft
## (checks it reaches the valley floor), walks the first switchback leg up the hillside
## (checks it gets to the turn), climbs the carved stairs from the terrace to the river
## terrace (checks it gets to the top), then is put by the capstan and turns it fully (checks
## the gate, the side branch, the wheel and the doorway's blocks). Prints CITADEL PASS / FAIL.
##   godot --path . --resolution 960x540 tests/zones/citadel_walk_test.tscn  [ZONE=res://... a copy]

var fails := 0


func _ready() -> void:
	var path := OS.get_environment("ZONE") if OS.get_environment("ZONE") != "" else "res://zones/forest/forest_citadel.tscn"
	var zone: Node = (load(path) as PackedScene).instantiate()
	zone.set(&"intro", false)  # (the title card hands control back to the pad when it ends)
	get_tree().root.add_child.call_deferred(zone)
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().current_scene = zone
	ZoneManager._adopt_current_scene(&"")
	for i in 30:
		await get_tree().physics_frame
	var p := ZoneManager.player
	p.scripted = true
	p.intent.clear()
	# The entrance cleft: from the spawn, north between the spurs onto the valley floor.
	var spawn := (zone.get_node("Spawn_default") as Node3D).global_position
	p.teleport(Transform3D(Basis.IDENTITY, spawn + Vector3.UP * 0.4))
	for i in 60 * 30:
		p.intent.move = Vector3.BACK
		await get_tree().physics_frame
		if p.global_position.z > -126.0:
			break
	p.intent.move = Vector3.ZERO
	_check("cleft", p.global_position.z > -126.0, "player at %s (from %s)" % [p.global_position, spawn])
	# The first switchback leg: from the arrival along the path to its first turn.
	var a := Vector3(0.0, 0.4, -126.0)
	var b := Vector3(36.0, 0.0, -114.0)
	p.teleport(Transform3D(Basis.IDENTITY, a))
	for i in 60 * 30:
		var to := Vector3(b.x - p.global_position.x, 0.0, b.z - p.global_position.z)
		if to.length() < 1.0:
			break
		p.intent.move = to.normalized()
		await get_tree().physics_frame
	p.intent.move = Vector3.ZERO
	var at := p.global_position
	_check("switchback", Vector2(at.x - b.x, at.z - b.z).length() < 1.5 and at.y > 2.0, "player at %s" % at)
	# The carved stairs: from the walkway at their foot up the east wall, walking north.
	p.teleport(Transform3D(Basis.IDENTITY, Vector3(33.5, 30.4, 4.0)))  # (the generator's TERRACE_X - 2.5)
	p.facing = Vector3.BACK
	for i in 60 * 30:
		p.intent.move = Vector3.BACK
		await get_tree().physics_frame
		if p.global_position.z > 50.0:
			break
	p.intent.move = Vector3.ZERO
	_check("stairs", p.global_position.y > 49.0, "player at %s" % p.global_position)
	# The capstan: stand behind spoke 0 and push it round.
	var cap: Capstan = get_tree().get_nodes_in_group(Capstan.GROUP)[0]
	var d0: Vector3 = cap.spoke_dirs()[0]
	var t0 := Vector3.UP.cross(d0)
	p.teleport(Transform3D(Basis.IDENTITY, cap.global_position + d0 * cap.grip_radius() - t0 * 0.6 + Vector3.UP * 0.1))
	p.facing = t0
	for i in 20:
		await get_tree().physics_frame
	p.intent.hold(&"grab", true)
	for i in 15:
		await get_tree().physics_frame
	print("CITADEL grabbed: ", p.machines[0].current.name)
	var guard := 0
	while cap.value() < 0.999 and guard < 60 * 120:
		p.intent.move = p.facing
		await get_tree().physics_frame
		guard += 1
	p.intent.hold(&"grab", false)
	p.intent.move = Vector3.ZERO
	for i in 60 * 25:
		await get_tree().physics_frame
	var gate := get_tree().root.find_children("*", "ScrewGate", true, false)
	var gate_open: float = (gate[0] as ScrewGate).open if not gate.is_empty() else -1.0
	var doors := get_tree().root.find_children("*", "MachineDoor", true, false)
	var moved := doors.map(func(d): return (d as MachineDoor).moved)
	_check("machine", cap.value() > 0.999 and gate_open > 0.99 and MachineBus.value(&"wheel") > 0.99 and moved.all(func(m): return m > 0.99),
		"capstan %.2f gate %.2f side %.2f wheel %.2f doors %s" % [cap.value(), gate_open, MachineBus.value(&"side"), MachineBus.value(&"wheel"), moved])
	print("CITADEL done, %d failed" % fails)
	get_tree().quit(1 if fails else 0)


func _check(case: String, ok: bool, detail: String) -> void:
	print("CITADEL %s %s  %s" % ["PASS" if ok else "FAIL", case, detail])
	if not ok:
		fails += 1
