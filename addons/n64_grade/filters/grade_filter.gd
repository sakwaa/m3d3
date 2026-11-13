@tool
class_name GradeFilter
extends Resource
## One filter (adjustment) layer in a Grade stack: `apply` turns a colour into the filter's
## colour, then the blend mode and opacity mix it over what came in, like an adjustment
## layer in Krita / Photoshop. Works in display colours (0..1, as the texture stores them).
## Subclasses override `apply` (and `title`, `prepare` for main-thread setup such as
## loading a LUT). `apply` runs on worker threads: read-only, no engine calls that need
## the main thread.

enum Blend { NORMAL, MULTIPLY, SCREEN, OVERLAY, SOFT_LIGHT, HARD_LIGHT, COLOUR, LUMINOSITY }

@export var enabled := true
@export_range(0.0, 1.0, 0.01) var opacity := 1.0
@export var blend := Blend.NORMAL
## The time keys it applies to (baked light filters only; one bit per LightingSchedule key):
## a night-only gradient map, a warmer noon...
@export_flags("Key 1", "Key 2", "Key 3", "Key 4") var keys := 15
## Set on filters in the baked light stack (shows Keys).
@export_storage var on_light := false


func _validate_property(p: Dictionary) -> void:
	if p.name == "keys":
		if not on_light:
			p.usage = PROPERTY_USAGE_STORAGE
		else:
			var s := LightingSchedule.load_project()
			if s and not s.keys.is_empty():
				p.hint_string = ",".join(s.keys.slice(0, 4).map(func(k): return k.name))

const LUMA := Vector3(0.299, 0.587, 0.114)


func title() -> String:
	return "Filter"


## Main-thread setup before a processing pass (default: nothing).
func prepare() -> void:
	pass


## The filter's colour for `c` (alpha ignored); `index`: the pixel's index (for noise).
func apply(c: Color, _index: int) -> Color:
	return c


## `apply` with the texel's position in its mip level (dither); default ignores it.
func apply_xy(c: Color, index: int, _xy: Vector2i) -> Color:
	return apply(c, index)


## Whether it looks at the whole texture before running (GradeProcessor then calls
## for_image with the texture as it is at this point of the chain).
func needs_image() -> bool:
	return false


## A copy set up for one texture (thread-safe: never changes this one). Default: itself.
func for_image(_img: Image) -> GradeFilter:
	return self


## Whether the result depends on the pixel's position (no per-colour caching).
func per_pixel() -> bool:
	return false


## `c` through the filter: apply, blend, opacity (alpha kept).
func run(c: Color, index: int, xy := Vector2i.ZERO) -> Color:
	var f := apply_xy(c, index, xy)
	var out := blend_colours(c, f, blend)
	out = c.lerp(out, opacity)
	out.a = c.a
	return out.clamp()


## A string that changes whenever the filter's result would (for skipping unchanged work).
func signature() -> String:
	var parts := []
	for p in get_property_list():
		if p.usage & PROPERTY_USAGE_STORAGE and p.name != "resource_path" and p.name != "resource_name" and p.name != "script":
			var v = get(p.name)
			if v is Gradient:
				parts.append([v.offsets, v.colors, v.interpolation_mode])
			elif v is Resource:
				parts.append(_resource_sig(v))
			else:
				parts.append(v)
	return var_to_str(parts)


static func _resource_sig(r: Resource) -> Array:
	var out := []
	for p in r.get_property_list():
		if p.usage & PROPERTY_USAGE_STORAGE and p.name != "script":
			out.append(r.get(p.name))
	return out


static func luma(c: Color) -> float:
	return c.r * LUMA.x + c.g * LUMA.y + c.b * LUMA.z


static func blend_colours(b: Color, f: Color, mode: int) -> Color:
	match mode:
		Blend.MULTIPLY:
			return Color(b.r * f.r, b.g * f.g, b.b * f.b)
		Blend.SCREEN:
			return Color(_screen(b.r, f.r), _screen(b.g, f.g), _screen(b.b, f.b))
		Blend.OVERLAY:
			return Color(_hard(f.r, b.r), _hard(f.g, b.g), _hard(f.b, b.b))
		Blend.SOFT_LIGHT:
			return Color(_soft(b.r, f.r), _soft(b.g, f.g), _soft(b.b, f.b))
		Blend.HARD_LIGHT:
			return Color(_hard(b.r, f.r), _hard(b.g, f.g), _hard(b.b, f.b))
		Blend.COLOUR:
			return _set_lum(f, luma(b))
		Blend.LUMINOSITY:
			return _set_lum(b, luma(f))
	return f


static func _screen(b: float, f: float) -> float:
	return 1.0 - (1.0 - b) * (1.0 - f)


## Hard light of `f` over `b` (overlay = the same with them swapped).
static func _hard(b: float, f: float) -> float:
	return 2.0 * b * f if f <= 0.5 else _screen(b, 2.0 * f - 1.0)


## W3C soft light.
static func _soft(b: float, f: float) -> float:
	if f <= 0.5:
		return b - (1.0 - 2.0 * f) * b * (1.0 - b)
	var d := ((16.0 * b - 12.0) * b + 4.0) * b if b <= 0.25 else sqrt(b)
	return b + (2.0 * f - 1.0) * (d - b)


## `c` with lightness `l`, hue and saturation kept (W3C SetLum + ClipColor).
static func _set_lum(c: Color, l: float) -> Color:
	var d := l - luma(c)
	var r := Color(c.r + d, c.g + d, c.b + d)
	var lum := luma(r)
	var n := minf(r.r, minf(r.g, r.b))
	var x := maxf(r.r, maxf(r.g, r.b))
	if n < 0.0:
		r = Color(lum + (r.r - lum) * lum / (lum - n), lum + (r.g - lum) * lum / (lum - n), lum + (r.b - lum) * lum / (lum - n))
	if x > 1.0:
		r = Color(lum + (r.r - lum) * (1.0 - lum) / (x - lum), lum + (r.g - lum) * (1.0 - lum) / (x - lum), lum + (r.b - lum) * (1.0 - lum) / (x - lum))
	return r


## Every filter kind: [script path, menu name] (paths, not preloads: they extend this).
static func kinds() -> Array:
	return [
		["res://addons/n64_grade/filters/grade_levels.gd", "Levels"],
		["res://addons/n64_grade/filters/grade_hue_sat.gd", "Hue / saturation"],
		["res://addons/n64_grade/filters/grade_balance.gd", "Colour balance"],
		["res://addons/n64_grade/filters/grade_gradient_map.gd", "Gradient map"],
		["res://addons/n64_grade/filters/grade_fill.gd", "Colour fill (glaze)"],
		["res://addons/n64_grade/filters/grade_lut.gd", "LUT"],
		["res://addons/n64_grade/filters/grade_palette.gd", "Palette (Lospec)"],
		["res://addons/n64_grade/filters/grade_posterize.gd", "Posterize"],
		["res://addons/n64_grade/filters/grade_noise.gd", "Noise"],
		["res://addons/n64_grade/filters/grade_colour_adjust.gd", "Colour adjust"],
	]
