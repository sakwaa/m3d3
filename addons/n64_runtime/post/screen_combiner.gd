@tool
class_name ScreenCombiner
extends Resource
## The RDP's colour combiner run over the whole picture (N64VideoOut, after the screen looks'
## grade, before the frame copy, HUD and 16-bit dither): each cycle is (A - B) * C + D,
## colour and alpha with their own inputs, one or two cycles (two-cycle mode feeds cycle 1's
## result to cycle 2 as COMBINED). The textures are the framebuffer itself (FRAME) and a copy
## of it shrunk by halves (BLUR: the way Tharo's N64 bloom reads the picture back), as Kaze
## shows in "3D Art is Math (on the N64)".
## Values work as the RDP's 9-bit maths: -0.5..0 clamps to black, 1..1.5 to full, and past
## that they wrap round (a bright channel pushed past 1.5 turns dark; one pulled under -0.5
## turns bright) - Overflow: Clamp keeps everything in range instead.
## Colours here are display colours (the framebuffer's values, not linear light). Picked by
## a ScreenLook in Combiner mode (zones, rooms, weather keys, cutscene Screen cues), which
## blends it in and out; primitive / environment can be tweened while it shows.

## The inputs. Colour slots read colours (single values spread to grey); alpha slots read
## the alpha of each: COMBINED -> combined alpha, FRAME / BLUR -> their brightness,
## PRIMITIVE / ENVIRONMENT -> their alpha.
enum Source {
	COMBINED,        ## cycle 1's result (cycle 2 only; 0 in cycle 1)
	COMBINED_ALPHA,  ## cycle 1's alpha result
	FRAME,           ## the picture (TEXEL0)
	FRAME_I,         ## the picture's brightness (an intensity texture)
	BLUR,            ## the shrunk picture, read back filtered (TEXEL1)
	BLUR_I,          ## its brightness
	PRIMITIVE,
	PRIM_ALPHA,
	ENVIRONMENT,
	ENV_ALPHA,
	NOISE,           ## per pixel, new each frame (the RDP's NOISE)
	DEPTH,           ## 0 at the camera .. 1 at depth_far and the sky
	CENTRE,          ## 0 in the middle of the screen .. 1 in the corners
	ONE,
	ZERO,
	DEPTH_BANDS,     ## the depth buffer read as a colour picture (MM's debug depth view, RGBA):
	                 ## bright repeating bands that crowd towards the distance
}

const NAMES := ["COMBINED", "COMB α", "FRAME", "FRAME I", "BLUR", "BLUR I", "PRIM", "PRIM α",
	"ENV", "ENV α", "NOISE", "DEPTH", "CENTRE", "1", "0", "DEPTH BANDS"]

enum Cycles { ONE_CYCLE = 1, TWO_CYCLE = 2 }
enum Overflow {
	WRAP,   ## the RDP: past -0.5 / 1.5 values wrap round
	CLAMP,  ## everything clamped to 0..1
}
## How far the BLUR copy is shrunk.
enum Blur {
	HALF,     ## half size
	QUARTER,  ## a quarter
	EIGHTH,   ## an eighth (Tharo's three halvings)
	N64_ROWS, ## 30 rows (Tharo's 40 x 30 from a 240-line picture): big soft blocks
}

@export var cycles := Cycles.ONE_CYCLE:
	set(v):
		cycles = v
		notify_property_list_changed()
		emit_changed()
@export_group("Cycle 1 colour", "c1_")
@export var c1_a := Source.ZERO:
	set(v): c1_a = v; emit_changed()
@export var c1_b := Source.ZERO:
	set(v): c1_b = v; emit_changed()
@export var c1_c := Source.ZERO:
	set(v): c1_c = v; emit_changed()
@export var c1_d := Source.FRAME:
	set(v): c1_d = v; emit_changed()
@export_group("Cycle 1 alpha", "c1_alpha_")
@export var c1_alpha_a := Source.ZERO:
	set(v): c1_alpha_a = v; emit_changed()
@export var c1_alpha_b := Source.ZERO:
	set(v): c1_alpha_b = v; emit_changed()
@export var c1_alpha_c := Source.ZERO:
	set(v): c1_alpha_c = v; emit_changed()
@export var c1_alpha_d := Source.ONE:
	set(v): c1_alpha_d = v; emit_changed()
@export_group("Cycle 2 colour", "c2_")
@export var c2_a := Source.ZERO:
	set(v): c2_a = v; emit_changed()
@export var c2_b := Source.ZERO:
	set(v): c2_b = v; emit_changed()
@export var c2_c := Source.ZERO:
	set(v): c2_c = v; emit_changed()
@export var c2_d := Source.COMBINED:
	set(v): c2_d = v; emit_changed()
@export_group("Cycle 2 alpha", "c2_alpha_")
@export var c2_alpha_a := Source.ZERO:
	set(v): c2_alpha_a = v; emit_changed()
@export var c2_alpha_b := Source.ZERO:
	set(v): c2_alpha_b = v; emit_changed()
@export var c2_alpha_c := Source.ZERO:
	set(v): c2_alpha_c = v; emit_changed()
@export var c2_alpha_d := Source.COMBINED_ALPHA:
	set(v): c2_alpha_d = v; emit_changed()
@export_group("")
## The two constant colours (alpha used by PRIM α / ENV α and the alpha slots).
@export var primitive := Color(1, 1, 1, 1):
	set(v): primitive = v; emit_changed()
@export var environment := Color(0, 0, 0, 0):
	set(v): environment = v; emit_changed()
@export var overflow := Overflow.WRAP:
	set(v): overflow = v; emit_changed()
@export var blur := Blur.N64_ROWS:
	set(v): blur = v; emit_changed()
## Bright pass before the shrink: the picture multiplied by itself this many times (a
## combiner redraw of FRAME x FRAME each), so the BLUR copy keeps the bright places (lamps,
## windows, sky) and drops the rest - bloom without washing the whole picture.
@export_range(0, 3) var blur_bright := 0:
	set(v): blur_bright = v; emit_changed()
## Metres at which DEPTH reaches 1.
@export_range(1.0, 500.0, 1.0, "suffix:m") var depth_far := 60.0:
	set(v): depth_far = v; emit_changed()


func _validate_property(property: Dictionary) -> void:
	if cycles == Cycles.ONE_CYCLE and String(property.name).begins_with("c2_"):
		property.usage = PROPERTY_USAGE_NO_EDITOR


func _get_property_list() -> Array:
	return [{name = "formula", type = TYPE_STRING, hint = PROPERTY_HINT_MULTILINE_TEXT,
		usage = PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY}]


func _get(property: StringName) -> Variant:
	return formula() if property == &"formula" else null


## The cycles written out, e.g. "1: (BLUR - FRAME) × PRIM α + FRAME".
func formula() -> String:
	var lines := []
	for i in int(cycles):
		var s := selectors(i)
		lines.append("%d: (%s - %s) × %s + %s   α (%s - %s) × %s + %s" % ([i + 1] +
			Array(s).map(func(x): return NAMES[x])))
	return "\n".join(lines)


## Cycle `i`'s 8 inputs: colour a, b, c, d, alpha a, b, c, d.
func selectors(i: int) -> PackedInt32Array:
	if i == 0:
		return PackedInt32Array([c1_a, c1_b, c1_c, c1_d, c1_alpha_a, c1_alpha_b, c1_alpha_c, c1_alpha_d])
	return PackedInt32Array([c2_a, c2_b, c2_c, c2_d, c2_alpha_a, c2_alpha_b, c2_alpha_c, c2_alpha_d])


func uses(input: Source) -> bool:
	for i in int(cycles):
		if input in selectors(i):
			return true
	return false


## The shader's block for this combiner (8 vec4s; selectors as floats), shown at `weight`.
func pack(weight: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for i in 2:
		var s := selectors(i) if i < int(cycles) else PackedInt32Array([Source.ZERO, Source.ZERO, Source.ZERO, Source.COMBINED,
			Source.ZERO, Source.ZERO, Source.ZERO, Source.COMBINED_ALPHA])
		for x in s:
			out.append(float(x))
	out.append_array([primitive.r, primitive.g, primitive.b, primitive.a,
		environment.r, environment.g, environment.b, environment.a,
		1.0 if overflow == Overflow.WRAP else 0.0, weight, float(blur), depth_far,
		float(blur_bright), 0.0, 0.0, 0.0])
	return out
