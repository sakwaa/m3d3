class_name Effects
extends RefCounted
## One-shot effects: `Effects.spawn(preload("res://game/effects/dust_puff.tres"), position)`.
## Each spawn is an EffectEmitter that frees itself when its sprites are gone.


## Plays `effect` once at a world position, emitting along `normal` (up by default).
static func spawn(effect: N64Effect, at: Vector3, normal := Vector3.UP) -> EffectEmitter:
	var tree := Engine.get_main_loop() as SceneTree
	if effect == null or tree == null or tree.root == null:
		return null
	var e := EffectEmitter.new()
	e.autoplay = false
	e.one_shot = true
	e.effect = effect
	var parent: Node = tree.current_scene if tree.current_scene else tree.root
	parent.add_child(e)
	var up := normal.normalized() if normal.length() > 0.001 else Vector3.UP
	var x := up.cross(Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT).normalized()
	e.global_transform = Transform3D(Basis(x, up, x.cross(up)), at)
	e.restart()
	return e
