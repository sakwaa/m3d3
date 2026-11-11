extends Node
# Goal-driven tower route test: each step steers the stick (relative to the tower) until a
# condition holds (or times out).
const TC := Vector3(0, 0, -52)
var p: Actor
var steps := []  # [label, stick: String, until: Callable, timeout, press]
var i := -1
var t_step := 0.0
var t := 0.0
var log_t := 0.0
var failed := false


func deg() -> float:
	var v := p.global_position - TC
	return rad_to_deg(atan2(v.x, v.z))


func into() -> Vector3:
	var a := deg_to_rad(deg())
	return -Vector3(sin(a), 0, cos(a))


func right() -> Vector3:
	var a := deg_to_rad(deg())
	return Vector3(cos(a), 0, -sin(a))


func st() -> StringName:
	return p.state_of(&"Locomotion").name


func y() -> float:
	return p.global_position.y


func put(deg_at: float, r: float, h: float) -> void:
	var a := deg_to_rad(deg_at)
	p.global_position = TC + Vector3(sin(a) * r, h, cos(a) * r)


func _ready() -> void:
	add_child(load("res://zones/debug/climb_sandbox/climb_sandbox.tscn").instantiate())
	p = (load("res://player/player.tscn") as PackedScene).instantiate()
	add_child(p)
	p.scripted = true
	var test := OS.get_environment("CLIMB_TEST")
	match test:
		"p0":
			put(0, 14, 0)
			steps = [
				["walk into the skirt", "in", func(): return st() == &"Climb", 10.0],
				["climb up the lean-back", "in", func(): return st() == &"ClimbUp", 22.5],
				["onto terrace 1", "", func(): return st() == &"Idle" and y() > 7.9, 7.5]]
		"p0gap":
			put(12, 14, 0)
			steps = [
				["walk into the skirt", "in", func(): return st() == &"Climb", 10.0],
				["up a bit", "in", func(): return y() > 3.0, 10.0],
				["right to the gap", "right", func(): return false, 5.0],
				["leap right", "right", func(): return st() == &"Leap", 1.2, &"jump"],
				["land on the next slab", "right", func(): return st() == &"Climb" and deg() > 25.0, 5.0]]
		"p1":
			put(66, 9.0, 8)
			steps = [
				["walk into stage 2 vines", "in", func(): return st() == &"Climb", 10.0],
				["up to the band", "in", func(): return false, 6.2],
				["leap up over the band", "in", func(): return st() == &"Leap", 1.2, &"jump"],
				["land above it", "in", func(): return st() in [&"Climb", &"Hang"] and y() > 9.5, 5.0],
				["up to the lip", "in", func(): return st() == &"Hang", 10.0],
				["shimmy right", "right", func(): return deg() > 98.0, 30.0],
				["up the vines above", "in", func(): return st() == &"Climb", 5.0],
				["to terrace 2", "in", func(): return st() == &"Idle" and y() > 15.9, 15.0]]
		"p2":
			put(205, 7.4, 16)
			steps = [
				["walk into stage 3 vines", "in", func(): return st() == &"Climb", 10.0],
				["up the overhang into the ceiling", "in", func(): return st() == &"Ceiling", 17.5],
				["out along the ceiling", "out", func(): return st() == &"Hang", 15.0],
				["pull up onto the cornice", "in", func(): return st() == &"Idle" and y() > 22.7, 10.0]]
		"p3":
			put(230, 7.5, 22.8)
			steps = [
				["walk into the vines", "in", func(): return st() == &"Climb", 10.0],
				["up a bit", "in", func(): return y() > 24.0, 7.5],
				["right through the fins", "right", func(): return fposmod(deg(), 360.0) > 266.0, 35.0],
				["up to terrace 3", "in", func(): return st() == &"Idle" and y() > 26.9, 15.0]]
		"p4":
			put(292, 6.2, 27)
			steps = [
				["walk into the pilaster", "in", func(): return st() == &"Climb", 10.0],
				["up it", "in", func(): return y() > 28.6, 7.5],
				["leap right", "right", func(): return st() == &"Leap", 1.2, &"jump"],
				["land on pilaster 2", "right", func(): return st() == &"Climb" and fposmod(deg(), 360.0) > 305.0, 5.0],
				["up it", "in", func(): return y() > 31.0, 7.5],
				["leap up-right", "upright", func(): return st() == &"Leap", 1.2, &"jump"],
				["catch the lip", "upright", func(): return st() == &"Hang", 5.0],
				["shimmy right", "right", func(): return fposmod(deg(), 360.0) > 12.0 and fposmod(deg(), 360.0) < 90.0, 30.0],
				["up the last vines", "in", func(): return st() == &"Climb", 5.0],
				["onto the crown", "in", func(): return st() == &"Idle" and y() > 37.9, 15.0]]
		"grip":
			put(112, 6.0, 27)
			steps = [
				["walk into the grip column", "in", func(): return st() == &"Climb", 10.0],
				["11 m straight up", "in", func(): return st() == &"Idle" and y() > 37.9, 35.0]]


func _physics_process(delta: float) -> void:
	t += delta
	t_step += delta
	if i < 0 or (i < steps.size() and (steps[i][2].call() or t_step > steps[i][3])):
		if i >= 0:
			var ok: bool = steps[i][2].call()
			# Timed steps (until never true) are fine to run out.
			if not ok and steps[i][0] not in ["up to the band", "right to the gap"]:
				print("FAIL at '%s' (state %s, y %.2f, deg %.1f, grip %.1f)" % [steps[i][0], st(), y(), deg(), p.grip.value])
				failed = true
				var cl = p.machine(&"Locomotion").states[&"Climb"]
				var n: Vector3 = cl.normal
				var o := p.global_position
				var c: Vector3 = cl.centre_of(o)
				var up: Vector3 = ClimbState.up_of(n)
				print("  n ", n, " o ", o, " want ", cl._want)
				var ahead: Dictionary = cl.ray(c, up, 0.03 + cl.gap(n))
				print("  ahead ", ahead.get("position"), " ", ahead.get("normal"))
				var c2 := c + up * 0.03
				var hit: Dictionary = cl.ray(c2 + n * 0.3, -n, cl.gap(n) + 0.6)
				print("  hit ", hit.get("position"), " ", hit.get("normal"), " holds ", cl.holds_wall(hit))
				if not hit.is_empty():
					var wo: Vector3 = cl.wall_origin(hit)
					print("  wall_origin ", wo, " fits ", cl.fits(wo))
					var q := PhysicsShapeQueryParameters3D.new()
					q.shape = p.get_child(0).shape if p.get_child(0) is CollisionShape3D else null
					for ch in p.get_children():
						if ch is CollisionShape3D: q.shape = ch.shape; q.transform = Transform3D(Basis(), wo + ch.position)
					q.collision_mask = p.collision_mask
					q.exclude = [p.get_rid()]
					for r in p.get_world_3d().direct_space_state.get_rest_info(q).keys():
						pass
					print("  rest ", p.get_world_3d().direct_space_state.get_rest_info(q))
				cl.read_capsule()
				for h in [0.8, 1.4, 0.8]:
					var hh: Dictionary = cl.ray(o + Vector3.UP * h, into(), 0.95)
					print("  into h ", h, " ", hh.get("position"), " n ", hh.get("normal"), " ", Surface.describe(Surface.of_ray(hh)) if not hh.is_empty() else "-", " holds ", cl.holds_wall(hh), " fits ", cl.fits(cl.wall_origin(hh)) if not hh.is_empty() else "-", " r ", Vector2(o.x, o.z + 52).length())
				var led: Dictionary = cl.find_ledge(o, -n, ClimbState.HANDS - 0.5, ClimbState.HANDS + 0.25)
				print("  ledge ", led)
				get_tree().quit()
				return
			print("  ok %s (t %.1f, y %.2f, deg %.1f, grip %.1f)" % [steps[i][0], t, y(), deg(), p.grip.value])
		i += 1
		t_step = 0.0
		if i >= steps.size():
			print("PASS")
			get_tree().quit()
			return
		if steps[i].size() > 4:
			p.intent.press(steps[i][4])
			if OS.get_environment("DBG") != "":
				var cl = p.machine(&"Locomotion").states[&"Climb"]
				var n: Vector3 = cl.normal
				var c: Vector3 = cl.centre_of(p.global_position)
				var dirv: Vector3 = ClimbState.right_of(n)
				print("  n ", n, " c ", c)
				var s := 2.2
				while s >= 0.8:
					var c2 := c + dirv * s
					var hit: Dictionary = cl.ray(c2 + n * 0.5, -n, cl.gap(n) + 1.0)
					print("   s %.1f hit %s holds %s fits %s clear %s" % [s, hit.get("normal"), cl.holds_wall(hit), cl.fits(cl.wall_origin(hit)) if not hit.is_empty() else false, cl.ray(c + n * 0.15, (c2 - c).normalized(), c.distance_to(c2)).is_empty()])
					s -= 0.2
	var m := Vector3.ZERO
	match steps[i][1]:
		"in": m = into()
		"out": m = -into()
		"right": m = right()
		"upright": m = (into() + right()).normalized()
	p.intent.move = m
	if OS.get_environment("TRACE") != "" and Engine.get_physics_frames() % 6 == 0:
		var cl = p.machine(&"Locomotion").states[&"Climb"]
		print("T %.2f %s y %.2f gait %s ph %.2f want %s gw %s" % [t, st(), y(), cl.gait_kind, cl.gait_phase, cl._want, cl.gait_want])
