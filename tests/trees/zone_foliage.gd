extends Node3D
## A zone's trees in two foliage styles from the same cameras: an overview, eye height at
## the spawn (3 ways), mid-distance onto the trees, and under one looking up. Saves
## <style>_<view>.png to OUT.
##   ZONE=res://... OUT=dir [STYLES=0,2] tools/godot_run.sh --path . --resolution 960x540 tests/trees/zone_foliage.tscn

var _cam: Camera3D


func _ready() -> void:
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _run() -> void:
	var out := OS.get_environment("OUT")
	DirAccess.make_dir_recursive_absolute(out)
	var styles: Array = Array(OS.get_environment("STYLES").split(",")).map(func(x): return int(x)) if OS.get_environment("STYLES") != "" else [0, 2]
	for style in styles:
		TreeBuilder.foliage_override = style
		var zone: Node = (load(OS.get_environment("ZONE")) as PackedScene).instantiate()
		add_child(zone)
		GameState.set_time(15.0)
		await _frames(3)
		for c in get_tree().root.find_children("*", "CanvasLayer", true, false):
			c.visible = false
		var trees := zone.find_children("*", "", true, false).filter(func(n): return n is WorldTree)
		var spawn := Vector3.ZERO
		for n in zone.find_children("*", "Node3D", true, false):
			if n is SpawnPoint:
				spawn = n.global_position
				break
		var tc := Vector3.ZERO
		for t in trees:
			tc += t.global_position
		tc /= maxf(trees.size(), 1)
		var near: Node3D = trees[0]
		for t in trees:
			if t.global_position.distance_to(spawn) < near.global_position.distance_to(spawn):
				near = t
		var eye := spawn + Vector3.UP * 1.6
		var to_trees := (tc - spawn) * Vector3(1, 0, 1)
		to_trees = to_trees.normalized() if to_trees.length() > 0.1 else Vector3.FORWARD
		var mid_from := tc - to_trees * 28.0
		mid_from.y = tc.y + 3.0
		var under := near.global_position + Vector3(1.5, 1.6, 1.5)
		var views := [
			["overview", tc + Vector3(0, 30, 42), tc],
			["spawn_trees", eye, eye + to_trees * 10.0 + Vector3.UP * 1.5],
			["spawn_left", eye, eye + to_trees.rotated(Vector3.UP, PI * 0.5) * 10.0 + Vector3.UP * 1.5],
			["spawn_right", eye, eye + to_trees.rotated(Vector3.UP, -PI * 0.5) * 10.0 + Vector3.UP * 1.5],
			["mid", mid_from, tc + Vector3.UP * 5.0],
			["under", under, near.global_position + Vector3(-1.0, 9.0, -2.0)],
		]
		if _cam == null:
			_cam = Camera3D.new()
			_cam.fov = 65.0
			add_child(_cam)
		for v in views:
			for c in find_children("*", "Camera3D", true, false):
				if c != _cam:
					c.current = false
			_cam.make_current()
			_cam.global_position = v[1]
			_cam.look_at(v[2])
			await _frames(12)
			var img := get_viewport().get_texture().get_image()
			img.resize(960, int(960.0 * img.get_height() / img.get_width()), Image.INTERPOLATE_BILINEAR)
			img.save_png(out + "/%d_%s.png" % [style, v[0]])
		print("[zf] style %d: %d trees, spawn %s, trees centre %s" % [style, trees.size(), spawn, tc])
		zone.queue_free()
		await _frames(3)
	get_tree().quit()
