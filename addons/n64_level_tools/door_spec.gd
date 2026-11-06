@tool
class_name DoorSpec
extends OpeningSpec
## A door brush's settings (LevelBrush.door). The level builds the door's surroundings from
## these: the lining through the wall (sides, top, floor; the wall's and floor's textures),
## the trim, and invisible pick faces where the panel hangs; and a Door node (panel,
## interaction, rooms / travel, lock) as a generated node under the Zone, outside any Room
## (so it never unloads with one), in the editor, in game and on export. The brush's
## origin is where the panel hangs (bottom centre); +Z faces the side it was placed from.

## Door properties the generated Door node takes over (rooms are paths, resolved apart).
const NODE_PROPERTIES := [&"mode", &"style", &"target_zone", &"target_spawn", &"spawn_id", &"dark_behind",
	&"lock", &"lock_flag", &"door_id", &"width", &"height", &"top", &"arch_rise", &"thickness", &"interact_range", &"arrival_offset",
	&"panel_surface", &"panel_texture", &"wall_depth", &"wall_center_z"]

@export var mode := Door.Mode.ROOM:
	set(v):
		mode = v
		notify_property_list_changed()
		emit_changed()
@export var style := Door.Style.SWING:
	set(v):
		style = v
		emit_changed()

@export_group("Rooms")
## Room on the local -Z side (behind the arrow). Path from the scene's root.
@export_node_path("Node3D") var room_a: NodePath:
	set(v):
		room_a = v
		emit_changed()
## Room on the local +Z side (the arrow points into it). Path from the scene's root.
@export_node_path("Node3D") var room_b: NodePath:
	set(v):
		room_b = v
		emit_changed()

@export_group("Zone")
@export_file("*.tscn") var target_zone := "":
	set(v):
		target_zone = v
		emit_changed()
@export var target_spawn: StringName = &"default":
	set(v):
		target_spawn = v
		emit_changed()
## Id other zones use to arrive through this door.
@export var spawn_id: StringName = &"door":
	set(v):
		spawn_id = v
		emit_changed()
## Room arrivals start in (path from the scene's root; empty = the Room the level is in).
@export_node_path("Node3D") var arrival_room: NodePath:
	set(v):
		arrival_room = v
		emit_changed()
## Darken what's behind the door while it is open (OoT's black doorway).
@export var dark_behind := true:
	set(v):
		dark_behind = v
		emit_changed()

@export_group("Lock")
@export var lock := Door.Lock.NONE:
	set(v):
		lock = v
		emit_changed()
## Lock.FLAG: GameState flag that must be truthy for the door to open.
@export var lock_flag := "":
	set(v):
		lock_flag = v
		emit_changed()
## Identifies the door in save data (small-key unlocks). Set when placed; keep it stable.
@export var door_id: StringName:
	set(v):
		door_id = v
		emit_changed()

@export_group("Shape")
@export var width := 1.2:
	set(v):
		width = maxf(v, 0.2)
		emit_changed()
@export var height := 2.4:
	set(v):
		height = maxf(v, 0.2)
		emit_changed()
## Top of the opening: flat, round arch or pointed arch (the trim and lining follow).
@export var top := OpeningShape.Top.FLAT:
	set(v):
		top = v
		emit_changed()
## How much of the height the arch takes (0 = half the width round, equilateral pointed).
@export_range(0.0, 5.0, 0.05, "or_greater", "suffix:m") var arch_rise := 0.0:
	set(v):
		arch_rise = maxf(v, 0.0)
		emit_changed()
@export var thickness := 0.15:
	set(v):
		thickness = maxf(v, 0.02)
		emit_changed()
## Distance from the door at which the player can use it (both sides).
@export var interact_range := 1.5:
	set(v):
		interact_range = maxf(v, 0.3)
		emit_changed()
## How far past the door the player ends up.
@export var arrival_offset := 1.2:
	set(v):
		arrival_offset = v
		emit_changed()
## Panel surface: an N64 texture tiled over both faces at the project texel density.
@export var panel_surface: Texture2D:
	set(v):
		panel_surface = v
		emit_changed()
## Picture of the whole door, stretched over the panel (wins over panel_surface).
@export var panel_texture: Texture2D:
	set(v):
		panel_texture = v
		emit_changed()
## The wall's faces around the door along its Z (set by the Door tool): front face at
## wall_center_z + wall_depth / 2 (the opening, +Z side), back at - wall_depth / 2.
@export var wall_depth := 0.25:
	set(v):
		wall_depth = maxf(v, 0.0)
		emit_changed()
@export var wall_center_z := 0.0:
	set(v):
		wall_center_z = v
		emit_changed()

@export_group("Dressing")
## Casing / trim around the opening (sides from the dressing), built into the level.
@export var dressing: OpeningDressing:
	set(v):
		if dressing and dressing.changed.is_connected(emit_changed):
			dressing.changed.disconnect(emit_changed)
		dressing = v
		if dressing:
			dressing.changed.connect(emit_changed)
		emit_changed()

@export_group("Surfaces")
## Lining through the wall (sides + top + floor), when the door was cut through one.
@export var lining := false:
	set(v):
		lining = v
		emit_changed()
## Lining floor: texture (level palette index, -1 = none), UV tweak and the transform of
## the floor it continues (its pattern carries on), and its painted colour.
@export var floor_texture := -1:
	set(v):
		floor_texture = v
		emit_changed()
@export var floor_uv := Vector4(0, 0, 1, 0):
	set(v):
		floor_uv = v
		emit_changed()
@export_storage var floor_source_xf := Transform3D.IDENTITY
@export var floor_color := Color.WHITE:
	set(v):
		floor_color = v
		emit_changed()
## Lining sides + top: the wall's texture, UV tweak and painted colour.
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
## Brushes the Door tool built with it for the next room (back wall, starter floor):
## {tag: shape hash when built}; deleting the door also deletes those still untouched.
@export_storage var extra_hashes := {}


func _validate_property(property: Dictionary) -> void:
	var room_only := [&"room_a", &"room_b"]
	var zone_only := [&"target_zone", &"target_spawn", &"spawn_id", &"arrival_room", &"dark_behind"]
	if (mode == Door.Mode.ZONE and property.name in room_only) or (mode == Door.Mode.ROOM and property.name in zone_only):
		property.usage &= ~PROPERTY_USAGE_EDITOR


## The opening is the wall's front face (+Z side of the door).
func opening_xf(brush_xf: Transform3D) -> Transform3D:
	return brush_xf * Transform3D(Basis(), Vector3(0, 0, front_z()))


func carve_depth() -> float:
	return wall_depth + 0.02


## Z (door local) of the wall's front face.
func front_z() -> float:
	return wall_center_z + wall_depth * 0.5


## [[z of a wall face, +1 / -1 = way the trim sticks out], ...] for the trim's sides.
func dressing_faces() -> Array:
	var faces := []
	if dressing == null:
		return faces
	if dressing.sides != OpeningDressing.Sides.BACK:
		faces.append([wall_center_z + wall_depth * 0.5, 1.0])
	if dressing.sides != OpeningDressing.Sides.FRONT:
		faces.append([wall_center_z - wall_depth * 0.5, -1.0])
	return faces
