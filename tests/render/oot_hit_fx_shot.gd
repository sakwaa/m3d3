extends Node3D
## OotHitFx close up: WHITE mark + blue blood, METAL mark + clang (blue light), DUST mark,
## RED mark + green blood, side by side; frames saved every 20 Hz tick for 10 ticks.
## OUT=<dir> tools/godot_run.sh --path . --fixed-fps 60 tests/render/oot_hit_fx_shot.tscn

var _frames := 0


func _ready() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.2, 0.22, 0.26)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.5, 0.5, 0.55)
	add_child(env)
	var g := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(10, 6)
	g.mesh = pm
	add_child(g)
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 1.2, 3.4)
	cam.look_at(Vector3(0, 1.0, 0))
	OotHitFx.hit_mark(self, Vector3(-2.4, 1.0, 0), OotHitFx.Mark.WHITE)
	OotHitFx.blood(self, Vector3(-2.4, 1.0, 0), OotHitFx.Blood.BLUE)
	OotHitFx.hit_mark(self, Vector3(-0.8, 1.0, 0), OotHitFx.Mark.METAL)
	OotHitFx.clang(self, Vector3(-0.8, 1.0, 0), true)
	OotHitFx.hit_mark(self, Vector3(0.8, 1.0, 0), OotHitFx.Mark.DUST)
	OotHitFx.hit_mark(self, Vector3(2.4, 1.0, 0), OotHitFx.Mark.RED)
	OotHitFx.blood(self, Vector3(2.4, 1.0, 0), OotHitFx.Blood.GREEN)


func _process(_d: float) -> void:
	_frames += 1
	if _frames % 3 == 1:
		get_viewport().get_texture().get_image().save_png("%s/t_%02d.png" % [OS.get_environment("OUT"), _frames / 3])
	if _frames >= 30:
		get_tree().quit()
