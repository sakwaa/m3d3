@tool
extends Node3D
## Editor-only scale reference: the player's collision capsule (read from player.gd, so it
## tracks changes), eye / camera height, facing, and how high a jump reaches. Added to the
## edited scene without an owner, so it is never saved.

const PLAYER_SCRIPT := "res://player/player.gd"
const BODY_COLOR := Color(0.3, 0.9, 1.0, 0.35)
const LINE_COLOR := Color(0.3, 0.9, 1.0, 0.9)
const JUMP_COLOR := Color(1.0, 0.75, 0.25, 0.8)


func _ready() -> void:
	var c := (load(PLAYER_SCRIPT) as Script).get_script_constant_map()
	var radius: float = c.get("BODY_RADIUS", 0.35)
	var height: float = c.get("BODY_HEIGHT", 1.6)
	var eye: float = c.get("CAMERA_HEIGHT", 1.4)
	var jump_v: float = c.get("JUMP_VELOCITY", 5.5)
	var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	# Feet rise v^2 / 2g at the top of a jump.
	var jump := jump_v * jump_v / (2.0 * gravity)

	var body := CapsuleMesh.new()
	body.radius = radius
	body.height = height
	_add(body, Vector3(0, height * 0.5, 0), BODY_COLOR)
	_ring(radius, 0.0, LINE_COLOR)
	_ring(radius, eye, LINE_COLOR)
	_ring(radius * 1.6, jump, JUMP_COLOR)
	_ring(radius * 1.6, jump + height, Color(JUMP_COLOR, 0.35))
	var nose := BoxMesh.new()
	nose.size = Vector3(0.08, 0.08, 0.25)
	_add(nose, Vector3(0, eye, -radius - 0.1), LINE_COLOR)
	# Heights sit close together (eye 1.4 / jump 1.54 / top 1.6), so spread the labels in
	# screen space: height above the head, eye to the left, jump heights to the right.
	_label("%.2f m" % height, Vector3(0, height + 0.12, 0), LINE_COLOR, Vector2.ZERO, HORIZONTAL_ALIGNMENT_CENTER)
	_label("eye %.2f m" % eye, Vector3(0, eye, 0), LINE_COLOR, Vector2(-70, 0), HORIZONTAL_ALIGNMENT_RIGHT)
	_label("jump: feet %.2f m" % jump, Vector3(0, jump, 0), JUMP_COLOR, Vector2(110, 0), HORIZONTAL_ALIGNMENT_LEFT)
	_label("jump: head %.2f m" % (jump + height), Vector3(0, jump + height, 0), Color(JUMP_COLOR, 0.6),
		Vector2(110, 0), HORIZONTAL_ALIGNMENT_LEFT)


func _add(mesh: Mesh, pos: Vector3, color: Color) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = color
	mi.material_override = mat
	add_child(mi)


func _ring(radius: float, y: float, color: Color) -> void:
	var torus := TorusMesh.new()
	torus.inner_radius = radius - 0.015
	torus.outer_radius = radius + 0.015
	torus.rings = 32
	torus.ring_segments = 4
	_add(torus, Vector3(0, y, 0), color)


func _label(text: String, pos: Vector3, color: Color, offset: Vector2, align: HorizontalAlignment) -> void:
	var l := Label3D.new()
	l.text = text
	l.position = pos
	l.pixel_size = 0.004
	l.font_size = 40
	l.outline_size = 8
	l.modulate = Color(color, 1.0)
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.horizontal_alignment = align
	l.offset = offset
	add_child(l)
