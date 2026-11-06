@tool
class_name PaintLayer
extends Resource
## One overlay texture layer of a level. Where it shows is painted per face (masks
## stored on each LevelBrush); how it combines with the layers below is `blend`.

## HEIGHT: like Mix, but at the mask edge each texel goes to whichever texture is "taller"
## (brighter than its own average), so mud fills the gaps between grass clumps instead of
## cross-fading. Shaped by the edge settings below.
## HEIGHT_ORDER: Height, plus each layer stands higher the further down the list it is
## (`order_height` per step), so later layers fill the gaps of earlier ones and win where
## they meet; texture detail still breaks up the edge.
enum Blend { MIX, MULTIPLY, ADD, SUBTRACT, SCREEN, OVERLAY, HEIGHT, SHINE, HEIGHT_ORDER }
## Shine: the texture is a reflection map (e.g. textures/shine/*) looked
## up by the surface's facing towards the camera, added where painted (wet / polished).
const BLEND_NAMES := ["Mix", "Multiply", "Add", "Subtract", "Screen", "Overlay", "Height", "Shine", "Height by order"]
## Height added per place in the layer list (x order_height), in texel-height units.
const ORDER_STEP := 0.3

@export var name := "Overlay":
	set(value):
		name = value
		emit_changed()
@export var texture: Texture2D:
	set(value):
		texture = value
		emit_changed()
@export var blend := Blend.MIX:
	set(value):
		blend = value
		emit_changed()
@export_range(0.0, 1.0) var opacity := 1.0:
	set(value):
		opacity = value
		emit_changed()
## Metres per texture repeat; 0 = Auto (the texture's own size: its World size, or width
## in px / project texels per metre).
@export var tile_size := 1.0:
	set(value):
		tile_size = maxf(value, 0.0)
		emit_changed()
## With no texture the layer is a flat colour through its mask (darkening spots with a
## noise mask, painted grime / shadow); opacity sets how strong.
@export var shade_color := Color.BLACK:
	set(value):
		# Layers saved while the property was being added can hold null.
		shade_color = value if value is Color else Color.BLACK
		emit_changed()


## shade_color, or black if a stale value slipped through.
func get_shade() -> Color:
	var c: Variant = shade_color
	return c if c is Color else Color.BLACK
@export var tint := Color.WHITE:
	set(value):
		tint = value
		emit_changed()
@export var enabled := true:
	set(value):
		enabled = value
		emit_changed()
## Use this layer's own gradient colours instead of the texture's tint.
@export var override_tint := false:
	set(value):
		override_tint = value
		emit_changed()
@export var tint_dark := Color(0.2, 0.2, 0.2):
	set(value):
		tint_dark = value
		emit_changed()
@export var tint_light := Color.WHITE:
	set(value):
		tint_light = value
		emit_changed()
@export_group("Height Blend Edge")
## 0 = soft, wide transition; 1 = crisp, texel-sharp edge.
@export_range(0.0, 1.0, 0.05) var edge_sharpness := 0.6:
	set(value):
		edge_sharpness = value
		emit_changed()
## World-space noise that makes the edge wander (gaps, islands).
@export_range(0.0, 1.0, 0.05) var edge_noise := 0.5:
	set(value):
		edge_noise = value
		emit_changed()
## Darkens the transition band (damp soil / trampled grass).
@export_range(0.0, 1.0, 0.05) var edge_darken := 0.35:
	set(value):
		edge_darken = value
		emit_changed()
## Height blends: shadow cast onto what's below, just outside this layer's edge, so it
## reads as lying on top (grass overhanging a dirt path). 0 = none.
@export_range(0.0, 1.0, 0.05) var edge_shadow := 0.0:
	set(value):
		edge_shadow = value
		emit_changed()
## Height by order: how much higher each step down the list stands (0 = plain Height).
@export_range(0.0, 1.0, 0.05) var order_height := 0.5:
	set(value):
		order_height = value
		emit_changed()
@export_group("Variation")
## Shared-noise brightness variation that breaks up repetition (0 = off).
@export_range(0.0, 1.0, 0.05) var variation := 0.0:
	set(value):
		variation = value
		emit_changed()
## Metres per noise repeat (bigger = broader patches).
@export_range(0.5, 64.0, 0.5) var variation_size := 8.0:
	set(value):
		variation_size = value
		emit_changed()
## 0 = light & dark, 1 = darken only.
@export_enum("Light & dark", "Darken") var variation_mode := 0:
	set(value):
		variation_mode = value
		emit_changed()
@export_group("Noise Mask")
## Shows the layer where the shared noise is high (0 = off), on top of / instead of
## painting. Sampled in each face's own projection.
@export_range(0.0, 1.0, 0.05) var noise_coverage := 0.0:
	set(value):
		noise_coverage = value
		emit_changed()
## Metres per noise repeat.
@export_range(0.5, 64.0, 0.5) var noise_size := 4.0:
	set(value):
		noise_size = value
		emit_changed()
@export_range(0.0, 1.0, 0.05) var noise_softness := 0.3:
	set(value):
		noise_softness = value
		emit_changed()
## Noise only (ignores painting), Painted + noise, or Break up painting (painted x noise).
@export_enum("Noise only", "Painted + noise", "Break up painting") var noise_combine := 1:
	set(value):
		noise_combine = value
		emit_changed()
## Noise mask only on faces with this base texture (empty = all faces), e.g. moss on
## the brick walls but not the grass floor.
@export var noise_base: Texture2D:
	set(value):
		noise_base = value
		emit_changed()


@export_group("Animation")
## Use this layer's own scroll instead of its texture's (the same water flowing at
## different speeds in different places).
@export var override_scroll := false:
	set(value):
		override_scroll = value
		emit_changed()
@export_range(-8.0, 8.0, 0.05, "or_greater", "or_less", "suffix:m/s") var scroll_speed := 0.0:
	set(value):
		scroll_speed = value
		emit_changed()
@export var scroll_direction := Vector3(0, -1, 1):
	set(value):
		scroll_direction = value
		emit_changed()
@export_group("")


## Shader scroll and flipbook params: the texture's, with this layer's scroll if overridden.
func anim_params() -> Array:
	var p: Array = texture.anim_params() if texture is N64Texture else [Vector4.ZERO, Vector4(1, 1, 1, 0)]
	if override_scroll:
		p[0] = Vector4(scroll_direction.x, scroll_direction.y, scroll_direction.z, scroll_speed)
	return p


func is_height_blend() -> bool:
	return blend == Blend.HEIGHT or blend == Blend.HEIGHT_ORDER


## Extra height for the layer at `index` in the list (Height by order only).
func order_offset(index: int) -> float:
	return order_height * ORDER_STEP * (index + 1) if blend == Blend.HEIGHT_ORDER else 0.0


## Metres per repeat actually used (resolves Auto).
func effective_tile_size() -> float:
	if tile_size > 0.0:
		return tile_size
	return texture.metres_per_repeat() if texture is N64Texture else 1.0
