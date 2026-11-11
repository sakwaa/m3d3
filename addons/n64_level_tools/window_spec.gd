@tool
class_name WindowSpec
extends OpeningSpec
## A window brush's settings (LevelBrush.window). The level tools cut its opening through the
## wall (and cut it again when it moves or changes size, like a door's) and the level builds
## its surroundings from these: the reveal through the wall in the wall's texture, a frame
## (the dressing) on the outside and the inside, a sill under it and an opaque glass pane
## in the middle, so nothing behind it needs building. The brush's origin is the bottom centre of
## the opening on the wall's centre line; +Z faces out of the wall.

@export var width := 0.9:
	set(v):
		width = maxf(v, 0.2)
		emit_changed()
@export var height := 1.0:
	set(v):
		height = maxf(v, 0.2)
		emit_changed()
## Top of the opening: flat, round arch or pointed arch (the frame and reveal follow).
@export var top := OpeningShape.Top.FLAT:
	set(v):
		top = v
		emit_changed()
## Arch height above the springing (0 = the shape's natural rise).
@export var arch_rise := 0.0:
	set(v):
		arch_rise = maxf(v, 0.0)
		emit_changed()
## The wall's thickness here (set when placed): front face at +wall_depth / 2.
@export var wall_depth := 0.3:
	set(v):
		wall_depth = maxf(v, 0.02)
		emit_changed()
@export_group("Dressing")
## Frame around the opening, on both faces of the wall.
@export var dressing: OpeningDressing:
	set(v):
		if dressing and dressing.changed.is_connected(emit_changed):
			dressing.changed.disconnect(emit_changed)
		dressing = v
		if dressing:
			dressing.changed.connect(emit_changed)
		emit_changed()
## Sill under the opening, outside: how far it sticks out, how tall it is and how far it
## reaches past the frame on each side (0 depth = no sill).
@export_range(0.0, 0.5, 0.01, "suffix:m") var sill_depth := 0.1:
	set(v):
		sill_depth = v
		emit_changed()
@export_range(0.0, 0.3, 0.01, "suffix:m") var sill_height := 0.06:
	set(v):
		sill_height = v
		emit_changed()
@export_range(0.0, 0.5, 0.01, "suffix:m") var sill_reach := 0.12:
	set(v):
		sill_reach = v
		emit_changed()
## The pane in the middle of the wall: this picture stretched across the opening once
## (opaque; none = just `pane_color`), shaded by `pane_color`.
@export var pane_texture: Texture2D = preload("res://textures/glass/window_glass.res"):
	set(v):
		pane_texture = v
		emit_changed()
@export var pane_color := Color.WHITE:
	set(v):
		pane_color = v
		emit_changed()
## Lit from inside in the evening while someone's home (the house's settings; a window on
## its own: always, or `home_flag`).
@export var lights := true:
	set(v):
		lights = v
		emit_changed()
## A window on its own: someone's home while this GameState flag is set ("" = always).
## Windows in a house follow the house's Lights settings.
@export var home_flag := "":
	set(v):
		home_flag = v
		emit_changed()
@export_group("Surfaces")
## Reveal: the wall's texture (level palette index), UV tweak and painted colour.
@export var wall_texture := -1:
	set(v):
		wall_texture = v
		emit_changed()
@export var wall_uv := Vector4(0, 0, 1, 0):
	set(v):
		wall_uv = v
		emit_changed()
@export var wall_color := Color.WHITE:
	set(v):
		wall_color = v
		emit_changed()


## The opening is the wall's front face (+Z side of the window).
func opening_xf(brush_xf: Transform3D) -> Transform3D:
	return brush_xf * Transform3D(Basis(), Vector3(0, 0, front_z()))


func carve_depth() -> float:
	return wall_depth + 0.02


func front_z() -> float:
	return wall_depth * 0.5


## The frame on both wall faces (see DoorSpec.dressing_faces).
func dressing_faces() -> Array:
	if dressing == null:
		return []
	return [[wall_depth * 0.5, 1.0], [-wall_depth * 0.5, -1.0]]


## A wooden frame like Kakariko's: a plain casing, mitred.
static func default_dressing() -> OpeningDressing:
	var d := OpeningDressing.new()
	d.texture = load("res://textures/wood/wood_2.res")
	d.joint = OpeningDressing.Joint.MITRE
	d.side_width = 0.1
	d.top_height = 0.1
	d.side_depth = 0.04
	d.top_depth = 0.05
	return d
