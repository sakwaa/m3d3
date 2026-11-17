extends Area3D
## Demo actor: collectable that sets a persistent GameState flag and never respawns.
## With `small_key`, it also adds one to the zone's small-key count (for locked Doors);
## `item` gives a GameState item (grip pieces).

@export var flag_id := "zone/pickup"
@export var small_key := false
## GameState item given on pickup (e.g. "grip_piece"); empty = none.
@export var item: StringName
@export var color := Color(1.0, 0.85, 0.2)


func _ready() -> void:
	if GameState.get_flag(flag_id):
		queue_free()
		return
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.5
	shape.shape = sphere
	add_child(shape)
	var mi := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.3
	mesh.height = 0.6
	mesh.radial_segments = 8
	mesh.rings = 4
	mi.mesh = mesh
	mi.material_override = shiny_material(color)
	add_child(mi)
	body_entered.connect(_on_body_entered)


## OoT / MM's shiny get-item look (rupees, tokens, the Boss Key: references/combiners/REPORT.md):
## a reflection texture looked up by the normal (texgen), its contrast pushed about a pivot
## ((T0 - PRIM) x k + T0), then mapped from a dark to a bright shade of `c`.
static func shiny_material(c: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = preload("res://addons/n64_runtime/shaders/n64_textured.gdshader")
	m.set_shader_parameter(&"albedo_texture", preload("res://textures/shine/chrome.res"))
	m.set_shader_parameter(&"cc_on", true)
	m.set_shader_parameter(&"cc_texgen", true)
	m.set_shader_parameter(&"cc_base", 7)  # (T0 - PRIM) * k + T0
	m.set_shader_parameter(&"cc_tint", 4)  # mix(ENV, PRIM, COMBINED)
	m.set_shader_parameter(&"cc_alpha", 1)
	m.set_shader_parameter(&"cc_k", 0.8)
	m.set_shader_parameter(&"cc_prim", c.lightened(0.55))
	m.set_shader_parameter(&"cc_env", c.darkened(0.6))
	return m


func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group(&"player"):
		GameState.set_flag(flag_id)
		if small_key and ZoneManager.zone:
			var keys_flag := ZoneManager.zone.flag("small_keys")
			GameState.set_flag(keys_flag, int(GameState.get_flag(keys_flag, 0)) + 1)
		if item != &"":
			GameState.give_item(item)
		print("[actor] collected %s" % flag_id)
		queue_free()
