@tool
class_name RopeStyle
extends Resource
## Look of a rope brush (LevelBrush.rope_style): a cutout texture repeated along a thin
## ribbon that hangs between the rope's points (washing lines, lantern strings, bunting).
## The texture runs along its width (the rope horizontal in the image), its height across
## the rope; repeats keep its proportions, stretched a little so each section holds whole
## repeats. Shareable between ropes; editing it regenerates the ropes using it.

## Repeated along the rope (alpha = holes: frayed edges, flags with gaps between them).
@export var texture: Texture2D:
	set(v):
		texture = v
		emit_changed()
## How wide the ribbon is (the texture's height fills it).
@export_range(0.01, 2.0, 0.01, "or_greater", "suffix:m") var width := 0.06:
	set(v):
		width = maxf(v, 0.005)
		emit_changed()
## Two ribbons crossed (flat and upright), so the rope reads from below and from the side;
## off: one upright ribbon (flags, bunting: seen from the side).
@export var crossed := true:
	set(v):
		crossed = v
		emit_changed()
## Shortest straight piece the curve is made of (shorter = smoother where it bends a lot,
## more faces).
@export_range(0.1, 4.0, 0.05, "suffix:m") var segment_length := 0.5:
	set(v):
		segment_length = maxf(v, 0.05)
		emit_changed()
## Most the rope turns from one straight piece to the next: a gentle sag needs only a few
## pieces (a 16 m rope sagging 0.75 m: 4), a deep one more. 0: pieces segment_length long.
@export_range(0.0, 45.0, 0.5, "suffix:°") var max_bend := 6.0:
	set(v):
		max_bend = maxf(v, 0.0)
		emit_changed()
