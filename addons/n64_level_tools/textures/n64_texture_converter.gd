class_name N64TextureConverter
extends RefCounted
## Turns a hi-res image into an N64-spec texture:
##   pick a region (zoom: a 1/zoom subsection around crop_center, like N64 textures that
##   show a close-up of a photo) -> scale it to 4x target -> make it seamless with an
##   image-quilting min-cut seam (both / U / V) -> colour adjust -> 4x4 box downsample (wrap-safe) ->
##   quantise to the N64 format. Decals/details (tiling NONE) are resized whole.
## Also guesses category / usage / tiling / format from file names.

enum Format { RGBA32, RGBA16, IA16, IA8, IA4, I8, I4, CI8, CI4 }
enum Tiling { SEAMLESS, SEAMLESS_U, SEAMLESS_V, NONE }
enum Usage { SURFACE, DECAL, DETAIL }
## How colour is applied in the shader (like the RDP colour combiner):
## NONE: texture colours as-is. MULTIPLY: texel x tint_light.
## GRADIENT: lerp(tint_dark, tint_light, texel) — greyscale texture, two-colour palette.
enum TintMode { NONE, MULTIPLY, GRADIENT }

const FORMAT_NAMES := ["RGBA32", "RGBA16", "IA16", "IA8", "IA4", "I8", "I4", "CI8", "CI4"]
const TILING_NAMES := ["Seamless", "Seamless U", "Seamless V", "None (decal/detail)"]
const USAGE_NAMES := ["Surface", "Decal", "Detail"]
const TINT_NAMES := ["None", "Multiply", "Gradient"]
## Categories imported with a gradient tint (palette control) that keeps part of the
## texture's own colours (tint_amount 0.5). Greyscale I4 + amount 1 is the fully
## recolourable N64 intensity style.
const TINT_CATEGORIES := ["grass", "ground", "rock", "cement", "water"]
const DEFAULT_TINT_AMOUNT := 0.5

## bits per texel, max texels that fit TMEM (4 KB; CI formats keep the palette in the
## upper 2 KB), palette size, greyscale, alpha bits.
const FORMAT_INFO := {
	Format.RGBA32: {bits = 32, texels = 1024, palette = 0, gray = false},
	Format.RGBA16: {bits = 16, texels = 2048, palette = 0, gray = false},
	Format.IA16: {bits = 16, texels = 2048, palette = 0, gray = true},
	Format.IA8: {bits = 8, texels = 4096, palette = 0, gray = true},
	Format.IA4: {bits = 4, texels = 8192, palette = 0, gray = true},
	Format.I8: {bits = 8, texels = 4096, palette = 0, gray = true},
	Format.I4: {bits = 4, texels = 8192, palette = 0, gray = true},
	Format.CI8: {bits = 8, texels = 2048, palette = 256, gray = false},
	Format.CI4: {bits = 4, texels = 4096, palette = 16, gray = false},
}

const WORK_SCALE := 4
const DEFAULT_SEAM_BLEND := 0.35
## Object photos (doors, windows, props): sharpening and thin-line keeping at import.
const DEFAULT_OBJECT_SHARPEN := 0.6
const DEFAULT_OBJECT_KEEP_LINES := 0.5
## Default zoom for tiling surface textures (1/2 of the photo -> chunkier, N64-like detail).
const DEFAULT_SURFACE_ZOOM := 2.0

## Keywords match the start of name tokens ("bricks076" ~ "brick"). Decal/detail rules win
## anywhere in the name; otherwise the last matching word decides ("mossy_cobblestone" -> rock).
const CATEGORY_RULES := [
	{category = "decal", usage = Usage.DECAL, tiling = Tiling.NONE, format = Format.RGBA16, size = Vector2i(32, 32),
		keywords = ["decal", "sign", "graffiti", "crack", "stain", "puddle", "splat", "poster", "emblem", "symbol", "logo", "footprint", "blood", "leak", "scorch", "label"]},
	{category = "detail", usage = Usage.DETAIL, tiling = Tiling.NONE, format = Format.I4, size = Vector2i(64, 64),
		keywords = ["detail", "noise", "grunge", "overlay", "grime", "smudge", "dust", "scratches"]},
	{category = "plants", usage = Usage.SURFACE, tiling = Tiling.NONE, format = Format.RGBA16, size = Vector2i(32, 64),
		keywords = ["plant", "leaf", "leaves", "foliage", "bush", "flower", "vine", "ivy", "hedge", "fern", "branch", "tree"]},
	{category = "grass", usage = Usage.SURFACE, tiling = Tiling.SEAMLESS, format = Format.CI4, size = Vector2i(64, 64),
		keywords = ["grass", "lawn", "turf", "moss", "meadow"]},
	{category = "wood", usage = Usage.SURFACE, tiling = Tiling.SEAMLESS_U, format = Format.CI4, size = Vector2i(64, 64),
		keywords = ["wood", "plank", "bark", "log", "timber", "board", "fence", "crate", "parquet"]},
	{category = "brick", usage = Usage.SURFACE, tiling = Tiling.SEAMLESS_U, format = Format.CI4, size = Vector2i(64, 64),
		keywords = ["brick", "masonry", "blocks", "cinder"]},
	{category = "roof", usage = Usage.SURFACE, tiling = Tiling.SEAMLESS_U, format = Format.CI8, size = Vector2i(64, 32),
		keywords = ["roof", "shingle", "thatch"]},
	{category = "fabric", usage = Usage.SURFACE, tiling = Tiling.SEAMLESS, format = Format.CI8, size = Vector2i(32, 32),
		keywords = ["fabric", "cloth", "carpet", "rug", "curtain", "textile", "leather"]},
	{category = "tiles", usage = Usage.SURFACE, tiling = Tiling.SEAMLESS, format = Format.CI4, size = Vector2i(64, 64),
		keywords = ["tile", "paving", "pavers", "mosaic"]},
	{category = "cement", usage = Usage.SURFACE, tiling = Tiling.SEAMLESS, format = Format.CI4, size = Vector2i(64, 64),
		keywords = ["cement", "concrete", "plaster", "stucco", "asphalt"]},
	{category = "rock", usage = Usage.SURFACE, tiling = Tiling.SEAMLESS, format = Format.CI4, size = Vector2i(64, 64),
		keywords = ["rock", "stone", "cliff", "boulder", "pebble", "cobble", "slate", "granite", "marble"]},
	{category = "ground", usage = Usage.SURFACE, tiling = Tiling.SEAMLESS, format = Format.CI4, size = Vector2i(64, 64),
		keywords = ["dirt", "soil", "mud", "ground", "earth", "sand", "gravel", "snow", "ice", "path", "clay"]},
	{category = "metal", usage = Usage.SURFACE, tiling = Tiling.SEAMLESS, format = Format.RGBA16, size = Vector2i(32, 32),
		keywords = ["metal", "iron", "steel", "rust", "copper", "brass", "grate", "chain", "aluminum"]},
	{category = "water", usage = Usage.SURFACE, tiling = Tiling.SEAMLESS, format = Format.CI4, size = Vector2i(64, 64),
		keywords = ["water", "lava", "liquid", "ocean", "river"]},
]
const FALLBACK_RULE := {category = "misc", usage = Usage.SURFACE, tiling = Tiling.SEAMLESS, format = Format.RGBA16, size = Vector2i(32, 32)}

## Default metres covered by one texture repeat (width), per category. N64 games stretched
## small textures over several metres; 1 m repeats read as busy, visible tiling.
## Default anti-tiling per category: 2 = offset + rotate (organic), 1 = offset only,
## missing = off (patterned textures, where randomising breaks the pattern).
const ANTI_TILING := {grass = 2, ground = 2, rock = 2, water = 2, detail = 2, cement = 1, brick = 3, wood = 3}

## PBR maps that aren't colour; skipped on import.
const NON_COLOR_TOKENS := ["normal", "normalgl", "normaldx", "nrm", "nor", "rough", "roughness", "gloss", "glossiness",
	"displacement", "disp", "height", "ao", "ambientocclusion", "occlusion", "metallic", "metalness", "specular", "spec", "bump", "opacity"]
const NOISE_TOKENS := ["color", "colour", "albedo", "diffuse", "basecolor", "base", "col", "diff", "jpg", "jpeg", "png", "tga", "1k", "2k", "4k", "8k", "16k",
	"texture", "textures", "seamless", "hr", "hq", "pbr", "sketchuptextureclub", "stc"]


# --- Naming / categories ------------------------------------------------------------

static func tokens(file_name: String) -> PackedStringArray:
	var base := file_name.get_file().get_basename()
	var spaced := ""
	for i in base.length():
		var c := base[i]
		# Split camelCase: "BrickWall" -> "brick wall".
		if i > 0 and c == c.to_upper() and c != c.to_lower() and base[i - 1] == base[i - 1].to_lower() and base[i - 1] != base[i - 1].to_upper():
			spaced += " "
		spaced += c
	var out := PackedStringArray()
	for t in spaced.to_lower().replace("-", " ").replace("_", " ").replace(".", " ").split(" ", false):
		out.append(t)
	return out


static func is_non_color_map(file_name: String) -> bool:
	for t in tokens(file_name):
		if t in NON_COLOR_TOKENS:
			return true
	return false


## Clean snake_case name without resolution / map-type noise.
static func clean_name(file_name: String) -> String:
	var kept := PackedStringArray()
	for t in tokens(file_name):
		if not t in NOISE_TOKENS:
			kept.append(t)
	return "_".join(kept) if not kept.is_empty() else "texture"


## Default settings guessed from the file name (and alpha, for cut-out images).
static func guess_settings(file_name: String, has_alpha := false, aspect := 1.0) -> Dictionary:
	var rule: Dictionary = FALLBACK_RULE
	var toks := tokens(file_name)
	var found := false
	for r in CATEGORY_RULES:
		if r.usage != Usage.SURFACE and _rule_matches(r, toks):
			rule = r
			found = true
			break
	if not found:
		for i in range(toks.size() - 1, -1, -1):
			for r in CATEGORY_RULES:
				if r.usage == Usage.SURFACE and _rule_matches(r, [toks[i]]):
					rule = r
					found = true
					break
			if found:
				break
	var settings := default_settings()
	settings.name = clean_name(file_name)
	settings.category = rule.category
	settings.usage = rule.usage
	settings.tiling = rule.tiling
	settings.format = rule.format
	settings.size = rule.size
	settings.world_size = 0.0  # Auto: from the project texel density
	settings.anti_tiling = ANTI_TILING.get(rule.category, 0)
	if rule.category in TINT_CATEGORIES:
		settings.tint_mode = TintMode.GRADIENT
	if has_alpha and FORMAT_INFO[settings.format].palette > 0 and rule.usage != Usage.SURFACE:
		settings.format = Format.RGBA16
	if settings.tiling == Tiling.NONE:
		settings.size = best_size_for_aspect(settings.format, aspect)
	elif settings.usage == Usage.SURFACE:
		# Replaced by image analysis (N64TextureAnalysis) when the importer can measure it.
		settings.zoom = DEFAULT_SURFACE_ZOOM
		settings.zoom_auto = true
	elif "seamless" in toks or "tileable" in toks:
		# Source already tiles (e.g. sketchuptextureclub "..._texture_seamless_06810"):
		# skip seam blending, which would only soften it, and tile both ways (the source
		# already does). Downscaling stays wrap-safe.
		settings.seam_blend = 0.0
		settings.tiling = Tiling.SEAMLESS
	return settings


static func _rule_matches(rule: Dictionary, toks) -> bool:
	for t in toks:
		for k in rule.keywords:
			# Prefix match ("planks", "bricks076", "cobblestone") but not adjectives ("dirty").
			if t.begins_with(k) and t.substr(k.length()) != "y":
				return true
	return false


static func default_settings() -> Dictionary:
	return {
		name = "texture", category = "misc", usage = Usage.SURFACE, tiling = Tiling.SEAMLESS,
		format = Format.RGBA16, size = Vector2i(32, 32), seam_blend = DEFAULT_SEAM_BLEND,
		saturation = 1.0, contrast = 1.0, brightness = 0.0, zoom = 1.0, crop_center = Vector2(0.5, 0.5),
		world_size = 0.0, anti_tiling = 0, anti_tiling_scale = 0.75,
		tint_mode = TintMode.NONE, tint_auto = true, tint_dark = Color(0.2, 0.2, 0.2), tint_light = Color.WHITE,
		tint_amount = DEFAULT_TINT_AMOUNT, tint_range = Vector2(0.0, 1.0),
		zoom_auto = false, object = N64ObjectExtract.Kind.NONE, mirror = false, holes = 0, sharpen = 0.0, keep_lines = 0.0,
	}


## Object photos (plain background): extract settings for `kind` (from
## N64ObjectExtract.analyse); `aspect` is the extracted object's width / height.
static func apply_object(settings: Dictionary, kind: N64ObjectExtract.Kind, mirror: bool, aspect: float,
		holes := N64ObjectExtract.Holes.GLASS) -> void:
	settings.object = kind
	settings.mirror = mirror
	settings.holes = holes
	settings.object_aspect = aspect
	if kind == N64ObjectExtract.Kind.NONE:
		return
	settings.category = N64ObjectExtract.KIND_CATEGORIES[kind]
	settings.usage = Usage.SURFACE
	settings.tiling = Tiling.NONE
	# Doors: 256 colours (wood grain + iron); windows / props: 1-bit alpha cut-outs.
	var door := kind == N64ObjectExtract.Kind.DOOR
	settings.format = Format.CI8 if door and holes == N64ObjectExtract.Holes.GLASS else Format.RGBA16
	settings.size = best_size_for_aspect(settings.format, aspect, true)
	settings.zoom = 1.0
	settings.zoom_auto = false
	settings.seam_blend = 0.0
	settings.anti_tiling = 0
	settings.tint_mode = TintMode.NONE
	# Photos shrunk this far lose their outlines; N64 art was painted crisp.
	settings.sharpen = DEFAULT_OBJECT_SHARPEN
	settings.keep_lines = DEFAULT_OBJECT_KEEP_LINES


## Power-of-two sizes that fit the format's TMEM budget, largest first.
static func size_options(format: Format) -> Array[Vector2i]:
	var budget: int = FORMAT_INFO[format].texels
	var out: Array[Vector2i] = []
	for w in [256, 128, 64, 32, 16, 8]:
		for h in [256, 128, 64, 32, 16, 8]:
			if w * h <= budget and w * h >= 64 and maxi(w, h) <= 4 * mini(w, h):
				out.append(Vector2i(w, h))
	out.sort_custom(func(a, b):
		if a.x * a.y != b.x * b.y:
			return a.x * a.y > b.x * b.y
		return absi(a.x - a.y) < absi(b.x - b.y) or (absi(a.x - a.y) == absi(b.x - b.y) and a.x > b.x))
	return out


## Largest in-budget size whose aspect is closest to `aspect` (decals keep proportions).
## `prefer_texels`: the most texels among sizes within ~1.6x of the aspect (objects
## stretched over a mesh, where detail matters more than exact proportions).
static func best_size_for_aspect(format: Format, aspect: float, prefer_texels := false) -> Vector2i:
	var best := Vector2i.ZERO
	var best_err := INF
	if prefer_texels:
		for sz in size_options(format):  # largest first
			if absf(log(float(sz.x) / sz.y) - log(aspect)) < 0.47:
				return sz
	for sz in size_options(format):
		var err := absf(log(float(sz.x) / sz.y) - log(aspect))
		if err < best_err - 0.01:
			best_err = err
			best = sz
	return best


static func fits(format: Format, size: Vector2i) -> bool:
	return size.x * size.y <= FORMAT_INFO[format].texels


static func tmem_bytes(format: Format, size: Vector2i) -> int:
	var info: Dictionary = FORMAT_INFO[format]
	return size.x * size.y * info.bits / 8 + info.palette * 2


# --- Conversion ---------------------------------------------------------------------

## Returns {image: Image (RGBA8, exact N64 colours), palette: PackedColorArray}.
static func convert(source: Image, s: Dictionary) -> Dictionary:
	var format: Format = s.format
	var size: Vector2i = s.size
	if not fits(format, size):
		size = size_options(format)[0]
	var img := source.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	if s.get("object", 0) != N64ObjectExtract.Kind.NONE:
		img = N64ObjectExtract.extract(img, s.object, s.get("mirror", false), s.get("holes", 0))

	var tiling: Tiling = s.tiling
	var zoom: float = maxf(s.get("zoom", 1.0), 1.0)
	var source_tiles: bool = s.seam_blend <= 0.0
	if tiling == Tiling.NONE:
		img.resize(size.x * WORK_SCALE, size.y * WORK_SCALE, Image.INTERPOLATE_LANCZOS)
	elif source_tiles and zoom <= 1.0:
		# Whole image of an already-tiling source: nothing to blend.
		_crop_to_aspect(img, float(size.x) / size.y)
		img.resize(size.x * WORK_SCALE, size.y * WORK_SCALE, Image.INTERPOLATE_LANCZOS)
	else:
		var blend: float = s.seam_blend if s.seam_blend > 0.0 else DEFAULT_SEAM_BLEND
		img = _tileable_region(img, size * WORK_SCALE, tiling, zoom, s.get("crop_center", Vector2(0.5, 0.5)), blend, source_tiles)
	_adjust(img, s.saturation, s.contrast, s.brightness)
	img = _box_down(img, WORK_SCALE, s.get("keep_lines", 0.0))
	if s.get("sharpen", 0.0) > 0.0:
		_sharpen(img, s.sharpen, tiling)

	var info: Dictionary = FORMAT_INFO[format]
	var tint_dark: Color = s.get("tint_dark", Color(0.2, 0.2, 0.2))
	var tint_light: Color = s.get("tint_light", Color.WHITE)
	var tint_range := Vector2(0.0, 1.0)
	if s.get("tint_mode", TintMode.NONE) == TintMode.GRADIENT:
		if s.get("tint_auto", true):
			var tints := suggest_tints(img)
			tint_dark = tints[0]
			tint_light = tints[1]
		if info.gray:
			# Intensity texture: stretch so the gradient uses all grey levels.
			_stretch_to_gradient(img, tint_dark, tint_light)
		else:
			# Colour texture: the shader maps luminance in this range onto the gradient.
			tint_range = Vector2(tint_dark.get_luminance(), maxf(tint_light.get_luminance(), tint_dark.get_luminance() + 0.01))

	var palette := PackedColorArray()
	if info.palette > 0:
		palette = _quantize_indexed(img, info.palette)
	else:
		_quantize_direct(img, format)
		bleed_alpha(img)
	return {image = img, palette = palette, tint_dark = tint_dark, tint_light = tint_light, tint_range = tint_range}


## Two-colour palette for a gradient tint: average colours of the darkest and lightest
## ~15% of pixels, so lerp(dark, light, grey) reproduces the photo closely.
static func suggest_tints(img: Image) -> Array[Color]:
	var lums := PackedFloat32Array()
	for y in img.get_height():
		for x in img.get_width():
			lums.append(img.get_pixel(x, y).get_luminance())
	var sorted := lums.duplicate()
	sorted.sort()
	var lo := sorted[int(sorted.size() * 0.15)]
	var hi := sorted[int(sorted.size() * 0.85)]
	var dark := Vector3.ZERO
	var light := Vector3.ZERO
	var nd := 0
	var nl := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			var l := lums[y * img.get_width() + x]
			if l <= lo:
				dark += Vector3(c.r, c.g, c.b)
				nd += 1
			elif l >= hi:
				light += Vector3(c.r, c.g, c.b)
				nl += 1
	dark /= maxi(nd, 1)
	light /= maxi(nl, 1)
	return [Color(dark.x, dark.y, dark.z), Color(light.x, light.y, light.z)]


## Rewrites pixels as grey = position between the palette's dark and light luminance,
## using the full grey range (all 16 levels of I4) for the gradient.
static func _stretch_to_gradient(img: Image, dark: Color, light: Color) -> void:
	var lo := dark.get_luminance()
	var hi := maxf(light.get_luminance(), lo + 0.01)
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			var t := clampf((c.get_luminance() - lo) / (hi - lo), 0.0, 1.0)
			img.set_pixel(x, y, Color(t, t, t, c.a))


static func _crop_to_aspect(img: Image, aspect: float) -> void:
	var w := img.get_width()
	var h := img.get_height()
	if absf(float(w) / h - aspect) < 0.01:
		return
	var cw := w
	var ch := h
	if float(w) / h > aspect:
		cw = int(h * aspect)
	else:
		ch = int(w / aspect)
	var cropped := img.get_region(Rect2i((w - cw) / 2, (h - ch) / 2, cw, ch))
	img.copy_from(cropped)


## Region of the image (1/zoom of it, around `center` in 0..1), scaled to exactly `out`
## pixels and made tileable along the tiling axes: the first `blend / 2` of each axis
## overlaps the pixels just past the opposite edge and joins them along a minimum-error
## cut, so the wrap seam is continuous real image content. `wrap` lets the region (and its overlap)
## wrap around a source that already tiles.
static func _tileable_region(img: Image, out: Vector2i, tiling: Tiling, zoom: float, center: Vector2,
		blend: float, wrap: bool) -> Image:
	var tile_u := tiling == Tiling.SEAMLESS or tiling == Tiling.SEAMLESS_U
	var tile_v := tiling == Tiling.SEAMLESS or tiling == Tiling.SEAMLESS_V
	var bu := blend * 0.5 if tile_u else 0.0
	var bv := blend * 0.5 if tile_v else 0.0
	var aspect := float(out.x) / out.y
	var w := img.get_width()
	var h := img.get_height()
	# Region height in source pixels: as big as fits (with overlap unless wrapping) / zoom.
	var fit_h := minf(h / (1.0 if wrap else 1.0 + bv), w / (aspect * (1.0 if wrap else 1.0 + bu)))
	var region_h := fit_h / zoom
	# Scale the source so the region maps to exactly `out` pixels.
	var k := out.y / region_h
	var sw := maxi(1, roundi(w * k))
	var sh := maxi(1, roundi(h * k))
	var src := img.duplicate() as Image
	src.resize(sw, sh, Image.INTERPOLATE_LANCZOS)
	var mx := roundi(out.x * bu)
	var my := roundi(out.y * bv)
	if not wrap:
		mx = mini(mx, maxi(sw - out.x, 0))
		my = mini(my, maxi(sh - out.y, 0))
	var x0 := roundi(center.x * sw - out.x * 0.5)
	var y0 := roundi(center.y * sh - out.y * 0.5)
	if not wrap:
		x0 = clampi(x0, 0, maxi(sw - out.x - mx, 0))
		y0 = clampi(y0, 0, maxi(sh - out.y - my, 0))

	# Horizontal pass over the region plus the overlap rows the vertical pass needs.
	var strip := Image.create(out.x, out.y + my, false, Image.FORMAT_RGBA8)
	for y in out.y + my:
		for x in out.x:
			strip.set_pixel(x, y, _px(src, x0 + x, y0 + y, wrap))
	if mx >= 4:
		var beyond := Image.create(mx, out.y + my, false, Image.FORMAT_RGBA8)
		for y in out.y + my:
			for x in mx:
				beyond.set_pixel(x, y, _px(src, x0 + x + out.x, y0 + y, wrap))
		_quilt_seam(strip, beyond, mx, true)
	var result := strip.get_region(Rect2i(0, 0, out.x, out.y))
	if my >= 4:
		var below := strip.get_region(Rect2i(0, out.y, out.x, my))
		_quilt_seam(result, below, my, false)
	return result


## Image-quilting seam (Efros & Freeman 2001). The first `band` columns (or rows) of `img`
## overlap `beyond` — the pixels just past the opposite edge, which continue seamlessly
## across the wrap. A minimum-error path through the band (dynamic programming, the path
## may shift one pixel per step) decides where `beyond` hands over to the region, so the
## join follows places where both already match instead of cross-fading (no ghosting).
static func _quilt_seam(img: Image, beyond: Image, band: int, vertical_cut: bool) -> void:
	var length := img.get_height() if vertical_cut else img.get_width()
	var lo := 2  # keep the outer edge fully `beyond` so the wrap stays continuous
	var hi := band - 2
	var cost := PackedFloat32Array()
	cost.resize(length * band)
	for i in length:
		for j in band:
			var a := beyond.get_pixel(j, i) if vertical_cut else beyond.get_pixel(i, j)
			var b := img.get_pixel(j, i) if vertical_cut else img.get_pixel(i, j)
			var d := Vector3(a.r - b.r, a.g - b.g, a.b - b.b)
			cost[i * band + j] = d.length_squared() if j >= lo and j < hi else 1e6
	# Accumulate minimum path cost along the seam, then backtrack the cheapest path.
	var acc := cost.duplicate()
	for i in range(1, length):
		for j in band:
			var best := acc[(i - 1) * band + j]
			if j > 0:
				best = minf(best, acc[(i - 1) * band + j - 1])
			if j < band - 1:
				best = minf(best, acc[(i - 1) * band + j + 1])
			acc[i * band + j] += best
	var cut := PackedInt32Array()
	cut.resize(length)
	var j_best := lo
	for j in range(lo, hi):
		if acc[(length - 1) * band + j] < acc[(length - 1) * band + j_best]:
			j_best = j
	cut[length - 1] = j_best
	for i in range(length - 2, -1, -1):
		var prev := cut[i + 1]
		var pick := prev
		for j in [prev - 1, prev + 1]:
			if j >= lo and j < hi and acc[i * band + j] < acc[i * band + pick]:
				pick = j
		cut[i] = pick
	# Before the cut take `beyond`, after it the region, with a 2 px feather at the cut.
	for i in length:
		for j in band:
			var t := smoothstep(cut[i] - 1.0, cut[i] + 1.0, j + 0.5)
			var x := j if vertical_cut else i
			var y := i if vertical_cut else j
			var a := beyond.get_pixel(j, i) if vertical_cut else beyond.get_pixel(i, j)
			img.set_pixel(x, y, a.lerp(img.get_pixel(x, y), t))


static func _px(img: Image, x: int, y: int, wrap: bool) -> Color:
	if wrap:
		return img.get_pixel(posmod(x, img.get_width()), posmod(y, img.get_height()))
	return img.get_pixel(clampi(x, 0, img.get_width() - 1), clampi(y, 0, img.get_height() - 1))


## Region of the source a conversion uses, as a rect in 0..1 source coordinates (for the
## importer's preview overlay). Matches _tileable_region's maths.
static func crop_rect(source_size: Vector2i, s: Dictionary) -> Rect2:
	var size: Vector2i = s.size
	var tiling: Tiling = s.tiling
	if tiling == Tiling.NONE:
		return Rect2(0, 0, 1, 1)
	var zoom: float = maxf(s.get("zoom", 1.0), 1.0)
	var wrap: bool = s.seam_blend <= 0.0
	var blend: float = s.seam_blend if s.seam_blend > 0.0 else DEFAULT_SEAM_BLEND
	var bu := blend * 0.5 if tiling != Tiling.SEAMLESS_V else 0.0
	var bv := blend * 0.5 if tiling != Tiling.SEAMLESS_U else 0.0
	var aspect := float(size.x) / size.y
	var w := float(source_size.x)
	var h := float(source_size.y)
	var rh := minf(h / (1.0 if wrap else 1.0 + bv), w / (aspect * (1.0 if wrap else 1.0 + bu))) / zoom
	var rw := rh * aspect
	var c: Vector2 = s.get("crop_center", Vector2(0.5, 0.5))
	var x0 := c.x * w - rw * 0.5
	var y0 := c.y * h - rh * 0.5
	if not wrap:
		x0 = clampf(x0, 0.0, maxf(w - rw * (1.0 + bu), 0.0))
		y0 = clampf(y0, 0.0, maxf(h - rh * (1.0 + bv), 0.0))
	return Rect2(x0 / w, y0 / h, rw / w, rh / h)


static func _adjust(img: Image, saturation: float, contrast: float, brightness: float) -> void:
	if is_equal_approx(saturation, 1.0) and is_equal_approx(contrast, 1.0) and is_zero_approx(brightness):
		return
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			var l := c.get_luminance()
			var rgb := Vector3(c.r, c.g, c.b)
			rgb = Vector3(l, l, l).lerp(rgb, saturation)
			rgb = (rgb - Vector3.ONE * 0.5) * contrast + Vector3.ONE * (0.5 + brightness)
			img.set_pixel(x, y, Color(clampf(rgb.x, 0, 1), clampf(rgb.y, 0, 1), clampf(rgb.z, 0, 1), c.a))


## Integer box downsample with alpha-weighted colour (no dark fringes on cut-outs).
## Integer box downsample with alpha-weighted colour (no dark fringes on cut-outs).
## `keep_lines` > 0: blocks crossed by a thin dark line (plank gaps, outlines, iron straps)
## lean towards their darkest pixels instead of averaging the line away.
static func _box_down(img: Image, k: int, keep_lines := 0.0) -> Image:
	var w := img.get_width() / k
	var h := img.get_height() / k
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var inv := 1.0 / (k * k)
	for y in h:
		for x in w:
			var acc := Vector3.ZERO
			var a := 0.0
			var dark := Vector3.ZERO
			var dark_lum := INF
			for dy in k:
				for dx in k:
					var c := img.get_pixel(x * k + dx, y * k + dy)
					acc += Vector3(c.r, c.g, c.b) * c.a
					a += c.a
					if c.a > 0.5 and c.get_luminance() < dark_lum:
						dark_lum = c.get_luminance()
						dark = Vector3(c.r, c.g, c.b)
			var rgb := acc / a if a > 0.0 else Vector3.ZERO
			if keep_lines > 0.0 and dark_lum < INF:
				var lum := rgb.dot(Vector3(0.2126, 0.7152, 0.0722))
				# How much darker the darkest pixel is than the block (relative, so dark
				# wood counts too); ordinary grain stays averaged.
				var t := clampf(((lum - dark_lum) / maxf(lum, 0.05) - 0.35) / 0.4, 0.0, 1.0)
				rgb = rgb.lerp(dark, t * keep_lines * 0.7)
			out.set_pixel(x, y, Color(rgb.x, rgb.y, rgb.z, a * inv))
	return out


## Unsharp mask at the final size: pushes each texel away from its 3x3 neighbourhood
## average. Edges wrap on tiling axes and clamp otherwise.
static func _sharpen(img: Image, amount: float, tiling: Tiling) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var wrap_u := tiling == Tiling.SEAMLESS or tiling == Tiling.SEAMLESS_U
	var wrap_v := tiling == Tiling.SEAMLESS or tiling == Tiling.SEAMLESS_V
	var src := img.duplicate() as Image
	for y in h:
		for x in w:
			var c := src.get_pixel(x, y)
			if c.a < 0.5:
				continue
			var sum := Vector3.ZERO
			var n := 0.0
			for oy in [-1, 0, 1]:
				for ox in [-1, 0, 1]:
					var px: int = posmod(x + ox, w) if wrap_u else clampi(x + ox, 0, w - 1)
					var py: int = posmod(y + oy, h) if wrap_v else clampi(y + oy, 0, h - 1)
					var q := src.get_pixel(px, py)
					if q.a < 0.5:
						continue
					sum += Vector3(q.r, q.g, q.b)
					n += 1.0
			var blur := sum / n
			var rgb := Vector3(c.r, c.g, c.b)
			rgb = (rgb + (rgb - blur) * amount).clamp(Vector3.ZERO, Vector3.ONE)
			img.set_pixel(x, y, Color(rgb.x, rgb.y, rgb.z, c.a))


## Quantises to `bits` levels and returns the level's standard 8-bit expansion. The small
## bias makes Image.set_pixel (which truncates) store exactly that 8-bit value.
static func _q(v: float, bits: int) -> float:
	var levels := (1 << bits) - 1
	var level := roundf(clampf(v, 0.0, 1.0) * levels)
	return (roundf(level * 255.0 / levels) + 0.25) / 255.0


## Transparent texels take the colour of their nearest opaque neighbours (alpha stays 0),
## so filtering and mipmaps don't pull the cut-out's old background (a white photo
## backdrop) into its edges as a halo.
static func bleed_alpha(img: Image, passes := 8) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var filled := {}
	for y in h:
		for x in w:
			if img.get_pixel(x, y).a >= 0.5:
				filled[Vector2i(x, y)] = true
	if filled.size() == w * h or filled.is_empty():
		return
	for pass_i in passes:
		var added := {}
		for y in h:
			for x in w:
				var at := Vector2i(x, y)
				if filled.has(at):
					continue
				var sum := Vector3.ZERO
				var n := 0
				for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
						Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)]:
					var q := at + d
					if q.x < 0 or q.y < 0 or q.x >= w or q.y >= h or not filled.has(q):
						continue
					var c := img.get_pixel(q.x, q.y)
					sum += Vector3(c.r, c.g, c.b)
					n += 1
				if n > 0:
					sum /= n
					added[at] = Color(sum.x, sum.y, sum.z, img.get_pixel(x, y).a)
		if added.is_empty():
			break
		for at: Vector2i in added:
			img.set_pixel(at.x, at.y, added[at])
			filled[at] = true


static func to_rgba5551(c: Color) -> Color:
	return Color(_q(c.r, 5), _q(c.g, 5), _q(c.b, 5), 1.0 if c.a >= 0.5 else 0.0)


static func _quantize_direct(img: Image, format: Format) -> void:
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			var l := c.get_luminance()
			match format:
				Format.RGBA32:
					continue
				Format.RGBA16:
					c = to_rgba5551(c)
				Format.IA16:
					c = Color(_q(l, 8), _q(l, 8), _q(l, 8), _q(c.a, 8))
				Format.IA8:
					c = Color(_q(l, 4), _q(l, 4), _q(l, 4), _q(c.a, 4))
				Format.IA4:
					c = Color(_q(l, 3), _q(l, 3), _q(l, 3), 1.0 if c.a >= 0.5 else 0.0)
				Format.I8:
					c = Color(_q(l, 8), _q(l, 8), _q(l, 8), 1.0)
				Format.I4:
					c = Color(_q(l, 4), _q(l, 4), _q(l, 4), 1.0)
			img.set_pixel(x, y, c)


## Median-cut palette (+ k-means refinement), stored as RGBA5551, applied to the image.
## Transparent texels (alpha < 0.5) get a reserved palette entry.
static func _quantize_indexed(img: Image, count: int) -> PackedColorArray:
	var opaque: Array[Vector3] = []
	var has_clear := false
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a < 0.5:
				has_clear = true
			else:
				opaque.append(Vector3(c.r, c.g, c.b))
	var slots := count - (1 if has_clear else 0)
	var centers := _median_cut(opaque, slots)
	centers = _kmeans(opaque, centers, 3)

	var palette := PackedColorArray()
	if has_clear:
		palette.append(Color(0, 0, 0, 0))
	var seen := {}
	for c in centers:
		var q := to_rgba5551(Color(c.x, c.y, c.z))
		if not seen.has(q):
			seen[q] = true
			palette.append(q)

	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a < 0.5:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			img.set_pixel(x, y, _nearest(palette, Vector3(c.r, c.g, c.b)))
	return palette


static func _median_cut(colors: Array[Vector3], count: int) -> Array[Vector3]:
	var boxes: Array = [colors.duplicate()]
	while boxes.size() < count:
		var best := -1
		var best_range := 0.0
		var best_axis := 0
		for i in boxes.size():
			var box: Array = boxes[i]
			if box.size() < 2:
				continue
			var lo := Vector3.ONE
			var hi := Vector3.ZERO
			for c in box:
				lo = lo.min(c)
				hi = hi.max(c)
			var r := hi - lo
			var axis := 0 if r.x >= r.y and r.x >= r.z else (1 if r.y >= r.z else 2)
			if r[axis] > best_range:
				best_range = r[axis]
				best = i
				best_axis = axis
		if best < 0 or best_range <= 0.0:
			break
		var box: Array = boxes[best]
		var axis := best_axis
		box.sort_custom(func(a, b): return a[axis] < b[axis])
		var mid := box.size() / 2
		boxes[best] = box.slice(0, mid)
		boxes.append(box.slice(mid))
	var out: Array[Vector3] = []
	for box in boxes:
		if box.is_empty():
			continue
		var sum := Vector3.ZERO
		for c in box:
			sum += c
		out.append(sum / box.size())
	return out


static func _kmeans(colors: Array[Vector3], centers: Array[Vector3], iterations: int) -> Array[Vector3]:
	for it in iterations:
		var sums: Array[Vector3] = []
		var counts := PackedInt32Array()
		sums.resize(centers.size())
		counts.resize(centers.size())
		for i in centers.size():
			sums[i] = Vector3.ZERO
		for c in colors:
			var best := 0
			var best_d := INF
			for i in centers.size():
				var d := c.distance_squared_to(centers[i])
				if d < best_d:
					best_d = d
					best = i
			sums[best] += c
			counts[best] += 1
		for i in centers.size():
			if counts[i] > 0:
				centers[i] = sums[i] / counts[i]
	return centers


static func _nearest(palette: PackedColorArray, c: Vector3) -> Color:
	var best := palette[0]
	var best_d := INF
	for p in palette:
		if p.a == 0.0:
			continue
		var d := Vector3(p.r, p.g, p.b).distance_squared_to(c)
		if d < best_d:
			best_d = d
			best = p
	return best
