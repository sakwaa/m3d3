extends Node
# Edge first: for each swing, how well the blade's edge (the sword's ±X) lines up with the
# way the blade moves across its length while it's moving fast (1 = edge leading, 0 = flat
# leading) during sideways strokes, with StrikeRig's edge roll off and on. PASS when on averages > 0.85.
var p: Actor
var fails := 0

func _ready() -> void:
	var floor := StaticBody3D.new(); var cs := CollisionShape3D.new(); var sh := BoxShape3D.new(); sh.size = Vector3(40, 1, 40)
	cs.shape = sh; floor.add_child(cs); floor.position.y = -0.5; add_child(floor)
	p = (load("res://player/player.tscn") as PackedScene).instantiate()
	add_child(p)
	p.scripted = true
	for i in 30:
		await get_tree().physics_frame
	p._sheathe(false)
	for swing in [&"SlashD", &"SlashH2", &"SlashV", &"SlashH", &"Stab"]:
		var off := await measure(swing, false)
		var on := await measure(swing, true)
		var ok := on > 0.85
		if not ok:
			fails += 1
		print("%s %-8s edge alignment: off %.2f  on %.2f" % ["PASS" if ok else "FAIL", swing, off, on])
	print("DONE fails=%d" % fails)
	get_tree().quit()

func measure(swing: StringName, lead: bool) -> float:
	StrikeRig.edge_lead = lead
	p.machine(&"Action").request(&"Ready", true)
	for i in 20:
		await get_tree().physics_frame
	p.machine(&"Action").request(swing, true)
	var prev := Vector3.INF
	var total := 0.0
	var n := 0
	for i in 60:
		await get_tree().process_frame
		var s := p.state_of(&"Action")
		if s.name != swing:
			break
		var xf: Transform3D = p._sword.global_transform
		var along := xf.basis.y.normalized()
		var sweet := xf * Vector3(0, 0.5, 0) - p.global_position
		if prev != Vector3.INF:
			var moved := sweet - prev
			var across := moved - along * moved.dot(along)
			# A real sideways stroke: fast, and more across the blade than along it (a stab's
			# thrust leads with the point; the edge doesn't matter there).
			if across.length() > 0.015 and across.length() > 0.6 * moved.length():
				var edge := (xf.basis.x - along * xf.basis.x.dot(along)).normalized()
				total += absf(edge.dot(across.normalized()))
				n += 1
		prev = sweet
	return total / maxf(n, 1)
