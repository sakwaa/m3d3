extends Node
# Jump timing check: rise time, apex, airtime (target, OoT remake: ~0.25 s, ~1 m, ~0.57 s).
# Run: godot --headless --path . tests/move/jump.tscn
func _ready() -> void:
	var floor := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40, 1, 40)
	cs.shape = box
	floor.add_child(cs)
	floor.position.y = -0.5
	add_child(floor)
	var p: Actor = (load("res://player/player.tscn") as PackedScene).instantiate()
	add_child(p)
	p.scripted = true
	for i in 30:
		await get_tree().physics_frame
	var y0 := p.global_position.y
	p.intent.press(&"jump")
	var top := y0
	var t_top := 0.0
	var t := 0.0
	var left := false
	for i in 120:
		await get_tree().physics_frame
		t += 1.0 / Engine.physics_ticks_per_second
		if p.global_position.y > top:
			top = p.global_position.y
			t_top = t
		left = left or not p.is_on_floor()
		if left and p.is_on_floor():
			break
	print("jump: rise %.2f s, apex %.2f m, airtime %.2f s" % [t_top, top - y0, t])
	get_tree().quit()
