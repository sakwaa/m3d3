@tool
class_name PassageSpec
extends OpeningSpec
## A passage brush's settings (LevelBrush.passage): an OoT-style corridor out of the zone.
## The level builds its floor (and, through a wall, side walls + ceiling) from these, and a
## Passage node (exit trigger, fade, arrival spawn, dressing) as its generated child, in the
## editor, in game and on export. The brush's origin is the threshold; -Z points out.

## Passage properties the generated Passage node takes over.
const NODE_PROPERTIES := [&"target_zone", &"target_spawn", &"spawn_id", &"arrival_offset", &"width", &"height", &"top", &"arch_rise",
	&"depth", &"trigger_start", &"fade_enabled", &"fade_lead", &"fade_start", &"fade_end", &"fade_margin"]

@export_group("Waypoint")
@export_file("*.tscn") var target_zone := "":
	set(v):
		target_zone = v
		emit_changed()
@export var target_spawn: StringName = &"default":
	set(v):
		target_spawn = v
		emit_changed()
## Id other zones use (ZoneExit / Passage target_spawn) to arrive through this passage.
@export var spawn_id: StringName = &"passage":
	set(v):
		spawn_id = v
		emit_changed()
## How far inside the threshold the player appears.
@export var arrival_offset := 1.5:
	set(v):
		arrival_offset = v
		emit_changed()

@export_group("Shape")
@export var width := 1.2:
	set(v):
		width = maxf(v, 0.1)
		emit_changed()
@export var height := 2.4:
	set(v):
		height = maxf(v, 0.1)
		emit_changed()
@export var depth := 5.0:
	set(v):
		depth = maxf(v, 0.1)
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
## Depth fraction after which entering the corridor triggers travel.
@export_range(0.0, 0.95) var trigger_start := 0.6:
	set(v):
		trigger_start = v
		emit_changed()

@export_group("Fade")
@export var fade_enabled := true:
	set(v):
		fade_enabled = v
		emit_changed()
## Metres in front of the opening where the darkening begins.
@export var fade_lead := 1.5:
	set(v):
		fade_lead = maxf(v, 0.0)
		emit_changed()
@export_range(0.0, 1.0) var fade_start := 0.0:
	set(v):
		fade_start = v
		emit_changed()
@export_range(0.0, 1.0) var fade_end := 0.9:
	set(v):
		fade_end = v
		emit_changed()
## Extra size around the corridor (past the threshold) so walls and ceilings built around it
## are darkened too; the room's wall around the doorway stays lit.
@export var fade_margin := 0.6:
	set(v):
		fade_margin = maxf(v, 0.0)
		emit_changed()

@export_group("Dressing")
## Casing / trim around the opening on the room side (shareable with doors). Empty = none.
## Built into the level with the corridor (lit, baked and painted like the walls).
@export var dressing: OpeningDressing:
	set(v):
		if dressing and dressing.changed.is_connected(emit_changed):
			dressing.changed.disconnect(emit_changed)
		dressing = v
		if dressing:
			dressing.changed.connect(emit_changed)
		emit_changed()

@export_group("Surfaces")
## Corridor floor: the texture (level palette index, -1 = none), face UV tweak and brush
## transform (level space) of the floor it was placed on: the corridor's own UV tweak is
## worked out from these whenever it's rebuilt, so the pattern carries on across the
## threshold wherever the passage is moved / resized to.
@export var floor_texture := -1:
	set(v):
		floor_texture = v
		emit_changed()
@export var floor_uv := Vector4(0, 0, 1, 0):
	set(v):
		floor_uv = v
		emit_changed()
@export_storage var floor_source_xf := Transform3D.IDENTITY
## That floor face's corners (level space) and their shade (painted rgb, AO in alpha): the
## corridor floor takes the shade at its own spot, so the threshold has no seam.
@export_storage var floor_source_points := PackedVector3Array()
@export_storage var floor_source_shades := PackedColorArray()
## Painted colour of the floor / wall it was placed on (recoloured textures take their
## colour from it), given to the corridor's floor / walls.
@export var floor_color := Color.WHITE:
	set(v):
		floor_color = v
		emit_changed()
@export var wall_color := Color.WHITE:
	set(v):
		wall_color = v
		emit_changed()
## Through a wall: side walls + ceiling in the wall's texture (-1 = none).
@export var shell := false:
	set(v):
		shell = v
		emit_changed()
@export var wall_texture := -1:
	set(v):
		wall_texture = v
		emit_changed()
@export var wall_uv := Vector4(0, 0, 1, 0):
	set(v):
		wall_uv = v
		emit_changed()


## The opening sits on the threshold: the brush's own transform.
func opening_xf(brush_xf: Transform3D) -> Transform3D:
	return brush_xf
