@tool
class_name OpeningSpec
extends Resource
## What passage and door brushes share: a wall opening the level tools cut for them (and cut
## again whenever its size / place / trim changes) and the trim around it. Subclasses give
## `width`, `height` and `dressing`, and where the opening is (opening_xf()).

## What's carved in the wall now (level space; set by the level tools).
@export_storage var carved := false
@export_storage var carved_width := 0.0
@export_storage var carved_height := 0.0
## The opening's transform when cut (level space; see opening_xf()).
@export_storage var carved_xf := Transform3D.IDENTITY
## The trim reach the wall was also cut along (see trim()).
@export_storage var carved_trim := Vector2.ZERO
## PassageBuilder.CARVE_VERSION it was cut with.
@export_storage var carved_version := 0
## The opening's shape when cut (see shape()).
@export_storage var carved_shape := Vector2.ZERO


## The opening's face (level space): origin bottom centre, +Z out of the wall towards
## where it was placed from. `brush_xf`: the brush's transform.
func opening_xf(brush_xf: Transform3D) -> Transform3D:
	return brush_xf


## How deep behind the opening's face wall surfaces get cut.
func carve_depth() -> float:
	return 2.0


func opening_size() -> Vector2:
	return Vector2(get(&"width"), get(&"height"))


## (OpeningShape.Top, arch rise) of the opening.
func shape() -> Vector2:
	return Vector2(get(&"top"), get(&"arch_rise"))


## How far the built trim reaches out from the opening (side, top); zero without one.
func trim() -> Vector2:
	var d: OpeningDressing = get(&"dressing")
	return Vector2(d.side_width, d.top_height) if d and d.texture else Vector2.ZERO


## The carved opening matches the size / trim at `xf` (the opening's transform now).
func carve_matches(xf: Transform3D) -> bool:
	var size := opening_size()
	return is_equal_approx(carved_width, size.x) and is_equal_approx(carved_height, size.y) \
		and carved_xf.is_equal_approx(xf) and carved_trim.is_equal_approx(trim()) and carved_shape.is_equal_approx(shape()) \
		and not stale_cut()


## Cut with older carving rules while it has a trim (the wall needs its trim cuts redone).
func stale_cut() -> bool:
	return carved and trim() != Vector2.ZERO and carved_version < preload("res://addons/n64_level_tools/passage_builder.gd").CARVE_VERSION


## Records the opening as cut now at `xf`.
func mark_carved(xf: Transform3D) -> void:
	carved = true
	carved_width = opening_size().x
	carved_height = opening_size().y
	carved_xf = xf
	carved_trim = trim()
	carved_shape = shape()
	carved_version = preload("res://addons/n64_level_tools/passage_builder.gd").CARVE_VERSION
