@tool
extends Node3D
## Editor-only backdrop for character scenes (added as an internal child of the edited
## ActorModel, so it's never saved or exported):
##  - STUDIO: flat mid-grey, soft key + fill light, plain floor with contact shadows;
##  - SILHOUETTE: the character solid black on a light background (does the pose read?);
##  - MEASURE: grey floor and walls with a 0.25 m grid and the player's game heights
##    (step, eye, jump apex, body), for arcs, crouch depth and foot sliding;
##  - SKY: nothing here; Godot's preview sky / sun (the in-game style check).

enum Kind { STUDIO, SILHOUETTE, MEASURE, SKY }
const NAMES := ["Studio grey", "Silhouette", "Measure grid", "Preview sky"]

const STUDIO_BG := Color(0.36, 0.37, 0.39)
const STUDIO_FLOOR := Color(0.42, 0.43, 0.45)
const SILHOUETTE_BG := Color(0.9, 0.9, 0.88)
## Measure walls sit this far out (a box seen from outside: only the far walls draw).
const ROOM := 2.0
## Player numbers (player/player.gd): body height, camera height, jump speed; floor snap
## stands in for the step height.
const BODY_HEIGHT := 1.6
const EYE_HEIGHT := 1.4
const JUMP_VELOCITY := 5.5
const STEP_HEIGHT := 0.3

const GRID_SHADER := """
shader_type spatial;
render_mode unshaded, cull_back;
uniform vec3 base : source_color = vec3(0.4);
uniform vec3 line : source_color = vec3(0.3);
uniform vec3 major : source_color = vec3(0.24);
uniform float cell = 0.25;
uniform float major_every = 4.0;
uniform vec4 marks = vec4(-1.0);
uniform vec3 mark_color : source_color = vec3(1.0, 0.65, 0.2);
varying vec3 world;
void vertex() { world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
float grid(vec2 p, float size) {
	vec2 g = abs(fract(p / size - 0.5) - 0.5) / (fwidth(p) / size);
	return 1.0 - clamp(min(g.x, g.y), 0.0, 1.0);
}
void fragment() {
	vec3 n = abs(NORMAL * mat3(VIEW_MATRIX));
	vec2 p = n.y > 0.5 ? world.xz : (n.x > 0.5 ? world.zy : world.xy);
	vec3 c = mix(base, line, grid(p, cell));
	c = mix(c, major, grid(p, cell * major_every));
	if (n.y < 0.5) {
		for (int i = 0; i < 4; i++) {
			if (marks[i] > 0.0) {
				float d = abs(world.y - marks[i]) / fwidth(world.y);
				c = mix(c, mark_color, 1.0 - clamp(d - 0.5, 0.0, 1.0));
			}
		}
	}
	ALBEDO = c;
}
"""

var kind := Kind.STUDIO
var model: Node3D
var _silhouette: StandardMaterial3D


func setup(m: Node3D, k: Kind) -> void:
	model = m
	name = "EditorBackdrop"
	set_kind(k)


func set_kind(k: Kind) -> void:
	kind = k
	for c in get_children():
		c.queue_free()
	_apply_silhouette(false)
	match kind:
		Kind.STUDIO:
			_environment(STUDIO_BG, Color(0.75, 0.78, 0.82), 0.55)
			_lights(true)
			_floor(STUDIO_FLOOR)
		Kind.SILHOUETTE:
			_environment(SILHOUETTE_BG, Color.WHITE, 1.0)
			_floor(SILHOUETTE_BG.darkened(0.06))
			_apply_silhouette(true)
		Kind.MEASURE:
			_environment(STUDIO_BG, Color(0.75, 0.78, 0.82), 0.55)
			_lights(true)
			_measure_room()


## The character's mesh may be rebuilt (new surfaces); call after a rebuild.
func refresh() -> void:
	_apply_silhouette(kind == Kind.SILHOUETTE)


func _exit_tree() -> void:
	_apply_silhouette(false)


func _apply_silhouette(on: bool) -> void:
	var mi: MeshInstance3D = model.get(&"mesh_instance") if model else null
	if mi == null or not is_instance_valid(mi):
		return
	if on and _silhouette == null:
		_silhouette = StandardMaterial3D.new()
		_silhouette.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_silhouette.albedo_color = Color(0.05, 0.05, 0.06)
	mi.material_override = _silhouette if on else null


func _environment(bg: Color, ambient: Color, ambient_energy: float) -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = bg
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = ambient
	env.ambient_light_energy = ambient_energy
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


## Key light from front-left above (shadows for foot contact), soft fill from the back right.
func _lights(shadows: bool) -> void:
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-50, -35, 0)
	key.light_energy = 0.9
	key.shadow_enabled = shadows
	add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, 150, 0)
	fill.light_energy = 0.3
	add_child(fill)


func _floor(color: Color) -> void:
	var mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(12, 12)
	mi.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 1.0
	mi.material_override = mat
	mi.position.y = -0.002
	add_child(mi)


func _measure_room() -> void:
	var gravity := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	var apex := JUMP_VELOCITY * JUMP_VELOCITY / (2.0 * gravity)
	var heights := [[STEP_HEIGHT, "step %.2f m"], [EYE_HEIGHT, "eye %.2f m"], [apex, "jump apex %.2f m"], [BODY_HEIGHT, "body %.2f m"]]
	var shader := Shader.new()
	shader.code = GRID_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter(&"base", STUDIO_FLOOR)
	mat.set_shader_parameter(&"line", STUDIO_FLOOR.darkened(0.18))
	mat.set_shader_parameter(&"major", STUDIO_FLOOR.darkened(0.35))
	mat.set_shader_parameter(&"marks", Vector4(heights[0][0], heights[1][0], heights[2][0], heights[3][0]))
	# Floor + four inward-facing walls: from outside the room only the far walls show.
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(ROOM * 2, ROOM * 2)
	ground.mesh = plane
	ground.material_override = mat
	ground.position.y = -0.002
	add_child(ground)
	var h := 2.5
	for spec in [[Vector3(0, h * 0.5, -ROOM), Vector3(0, 0, 0)], [Vector3(0, h * 0.5, ROOM), Vector3(0, 180, 0)],
			[Vector3(-ROOM, h * 0.5, 0), Vector3(0, 90, 0)], [Vector3(ROOM, h * 0.5, 0), Vector3(0, -90, 0)]]:
		var wall := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(ROOM * 2, h)
		wall.mesh = quad
		wall.material_override = mat
		wall.position = spec[0]
		wall.rotation_degrees = spec[1]
		add_child(wall)
	# Labels alternate sides (eye / apex / body are close together).
	for i in heights.size():
		var hh: Array = heights[i]
		var label := Label3D.new()
		label.text = hh[1] % hh[0]
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.fixed_size = true
		label.pixel_size = 0.0022
		label.font_size = 16
		label.outline_size = 4
		label.modulate = Color(1.0, 0.75, 0.35)
		label.no_depth_test = true
		var right := i % 2 == 0
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if right else HORIZONTAL_ALIGNMENT_RIGHT
		label.position = Vector3(0.6 if right else -0.6, hh[0], 0)
		add_child(label)
