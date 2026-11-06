@tool
class_name FenceStyle
extends Resource
## Look of a Fence (OoT / MM style): every part is a flat, double-sided quad whose texture's
## alpha cuts the shape (cutout), so the art does the work: a panel texture repeated along
## each span (rails, pickets, gaps), posts as crossed quads, end caps on the posts at the
## ends and beside openings, and an arch over openings. Shareable between fences; editing
## it regenerates the fences using it (in the editor).

enum SlopeMode {
	FOLLOW,   ## Panels tilt with the ground between posts; posts stay vertical.
	STEPPED,  ## Each span's panel is level, stepping up / down at the posts.
	LEVEL,    ## Every panel at one height along the whole fence; posts stretch to the ground.
}
## Fence types the texture generator can draw (level tools: Generate fence textures).
enum Kind {
	TWO_RAIL,    ## Two horizontal rails.
	THREE_RAIL,  ## Three horizontal rails.
	PICKET,      ## Pointed pickets on two back rails.
	LATTICE,     ## Diagonal criss-cross slats between a top and bottom rail.
	BOARDS,      ## Solid vertical boards (no gaps).
}
enum Grain { AUTO, SIDE_TO_SIDE, UP_AND_DOWN }
enum Collision {
	FULL,  ## Invisible wall the fence's full height (can't be jumped).
	LOW,   ## Wall `low_collision_height` tall (the player can hop over).
	NONE,
}

@export_group("Panel")
## Repeated along each span (alpha = holes). Fills the panel height; repeats keep the
## texture's proportions, stretched a little so each span holds whole repeats.
@export var panel_texture: Texture2D:
	set(v):
		panel_texture = v
		emit_changed()
@export_range(0.2, 5.0, 0.05, "suffix:m") var panel_height := 1.2:
	set(v):
		panel_height = v
		emit_changed()
## Gap between the ground and the panel's bottom edge.
@export_range(0.0, 2.0, 0.05, "suffix:m") var panel_lift := 0.0:
	set(v):
		panel_lift = v
		emit_changed()
## Default distance between posts (a fence's own Post spacing overrides it); spans are
## evened out so none is longer.
@export_range(0.5, 8.0, 0.25, "suffix:m") var max_spacing := 2.0:
	set(v):
		max_spacing = v
		emit_changed()

@export_group("Posts")
## Crossed quads at every post (none: no posts, panels meet edge to edge).
@export var post_texture: Texture2D:
	set(v):
		post_texture = v
		emit_changed()
@export_range(0.04, 1.0, 0.01, "suffix:m") var post_width := 0.2:
	set(v):
		post_width = v
		emit_changed()
## Post height above the ground (the texture fills it).
@export_range(0.2, 6.0, 0.05, "suffix:m") var post_height := 1.3:
	set(v):
		post_height = v
		emit_changed()
## How far posts reach below their point into the ground (no gap under them on slopes or
## at a platform's edge).
@export_range(0.0, 2.0, 0.05, "suffix:m") var post_sink := 0.3:
	set(v):
		post_sink = v
		emit_changed()
## Replaces the post texture at the fence's ends and beside openings (none: plain posts).
@export var end_cap_texture: Texture2D:
	set(v):
		end_cap_texture = v
		emit_changed()
## End-cap quad width (0 = the post width); generated caps are wider than the post.
@export_range(0.0, 2.0, 0.01, "suffix:m") var end_cap_width := 0.0:
	set(v):
		end_cap_width = v
		emit_changed()
## End-cap post height (0 = the post height).
@export_range(0.0, 6.0, 0.05, "suffix:m") var end_cap_height := 0.0:
	set(v):
		end_cap_height = v
		emit_changed()

@export_group("Arch")
## Spans each opening, post to post (alpha = the arch's shape); none: openings stay bare.
## The posts beside an arched opening reach up to its top.
@export var arch_texture: Texture2D:
	set(v):
		arch_texture = v
		emit_changed()
## Height of the arch quad.
@export_range(0.1, 4.0, 0.05, "suffix:m") var arch_height := 0.8:
	set(v):
		arch_height = v
		emit_changed()
## Ground to the arch's bottom edge (the clearance under it).
@export_range(0.5, 6.0, 0.05, "suffix:m") var arch_clearance := 2.2:
	set(v):
		arch_clearance = v
		emit_changed()

@export_group("Generate")
## What the generator draws (inspector: Generate fence textures). Its results land in the
## textures above; edit them or the inputs below and generate again.
@export var kind := Kind.TWO_RAIL
## Material for rails, pickets, boards and the arch (e.g. a wood texture).
@export var rail_material: Texture2D
## Material for posts and end caps (empty: the rail material).
@export var post_material: Texture2D
## Which way the materials' grain runs in their texture (Auto: detected). The generator
## turns them so rails, arches and slats get grain along their length and posts, pickets
## and boards get it up and down.
@export var material_grain := Grain.AUTO
## Generated texels per metre of the material (N64 levels: ~32).
@export_range(8, 128, 1) var texels_per_metre := 32

@export_group("Shape")
@export var slope_mode := SlopeMode.FOLLOW:
	set(v):
		slope_mode = v
		emit_changed()
@export var collision := Collision.FULL:
	set(v):
		collision = v
		emit_changed()
@export_range(0.2, 2.0, 0.05, "suffix:m") var low_collision_height := 0.6:
	set(v):
		low_collision_height = v
		emit_changed()
## Thickness of the invisible wall (thicker = harder to clip into at speed).
@export_range(0.05, 1.0, 0.05, "suffix:m") var collision_thickness := 0.3:
	set(v):
		collision_thickness = v
		emit_changed()
