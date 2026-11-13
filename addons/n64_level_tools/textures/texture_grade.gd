@tool
class_name TextureGrade
extends Resource
## One colour language for the whole texture library, baked in at conversion (N64Texture
## rebuilds: after the downsample, before tinting and the N64 quantise, so CI palettes are
## chosen from the graded colours). Textures from many photo sources come out as if one
## artist had painted them. Mood per place belongs to ScreenLook instead (runtime).
##  1. Normalise (optional): each texture's average brightness and saturation pulled towards
##     its category's target (Measure Targets fills those from the library).
##  2. LUT: the project grade (strip, HaldCLUT or imported .cube), per category overridable.
## Non-destructive: sources stay in textures/_source; each texture remembers what it was
## graded with, and Apply To Textures rebuilds only the ones that changed. Strength 0 /
## no LUT and no normalising = the plain conversion.
## Workflow: Make Grade Sheet -> grade textures/_grade/grade_sheet.png as one picture in an
## image editor -> set Graded Sheet to the result -> Use Graded Sheet -> Apply To Textures.
## Or per category from references: add GradeReferences (a region of a screenshot showing the
## material as it should look) -> Match References -> Apply To Textures.
## Textures are graded as their folder's category, or their own `grade_as`. Generated
## textures without a source (signs, rope...) keep an ungraded snapshot in
## textures/_source/_snapshots/ and are graded from it, so they can be reprocessed too.
## Lives at the project setting n64/textures/grade (editor only; not shipped).

const SETTING := "n64/textures/grade"
const DEFAULT_PATH := "res://textures/_grade/texture_grade.tres"
const DIR := "res://textures/_grade/"
const SHEET_N := 32
const THUMB := 64

## The grade's lookup table (strip, HaldCLUT image or imported .cube).
@export var lut: Texture2D
## How much of the LUT applies (0 = off).
@export_range(0.0, 1.0, 0.05) var strength := 1.0
## Per category (folder name): a multiplier on strength (0 = left alone: effects, signs...).
@export var category_strength := {&"effects": 0.0, &"signs": 0.0, &"sky": 0.0, &"variation": 0.0, &"shine": 0.0}
## Per category: its own LUT instead of the project one.
@export var category_luts := {}
## Pull each texture's average brightness / saturation towards its category's target first.
@export_range(0.0, 1.0, 0.05) var normalize := 0.0
## Per category: target (average luminance, average saturation), from Measure Targets.
@export var category_targets := {}
## Per category: the value band its textures should sit in (Lab lightness lo..hi, 0..100;
## the texture's own value, before lighting). Textures outside are pulled to the nearest
## edge by value_strength: the value structure as data (ground light, plaster light-mid,
## stone mid, timber dark). Measure Values shows where each category sits now.
@export var value_bands := {}
@export_range(0.0, 1.0, 0.05) var value_strength := 1.0
## Per-category references (Match References works out each of those categories' textures'
## move towards them).
@export var references: Array[GradeReference] = []
## Match References' result: texture path -> PackedFloat32Array(hue turn (radians), chroma
## x, lightness x, amount, main colour a, b, gate). Graded per pixel in Lab: pixels near the
## texture's main colour move, others (flowers in grass) much less; detail is kept.
@export var texture_matches := {}
## Your graded copy of grade_sheet.png (any path), read by Use Graded Sheet.
@export_global_file("*.png") var graded_sheet := ""

@export_tool_button("Measure Targets", "ColorPick") var measure_button := measure_targets
@export_tool_button("Match References", "ColorPick") var match_button := match_references
@export_tool_button("Measure Values", "Histogram") var values_button := measure_values
@export_tool_button("Make Grade Sheet", "Image") var sheet_button := make_grade_sheet
@export_tool_button("Use Graded Sheet", "Load") var use_sheet_button := use_graded_sheet
@export_tool_button("Apply To Textures", "Reload") var apply_button := apply_to_textures

static var _strips := {}  # lut texture -> [strip Image, data hash]


static func current() -> TextureGrade:
	var path: String = ProjectSettings.get_setting(SETTING, DEFAULT_PATH)
	return load(path) as TextureGrade if ResourceLoader.exists(path) else null


## Grade settings for a texture of `category` (converter "grade" key; {} = none) and the key
## it's remembered by. `path`: the texture's, for its reference match.
func settings_for(category: StringName, amount: float, path := "") -> Dictionary:
	var k := strength * float(category_strength.get(category, 1.0)) * amount
	var tex: Texture2D = category_luts.get(category, lut)
	var strip_entry: Array = _strip(tex) if tex and k > 0.0 else []
	var m: PackedFloat32Array = texture_matches.get(path, PackedFloat32Array()).duplicate()
	if m.size() == 7:
		m[3] *= amount
	var matched := m.size() == 7 and m[3] > 0.0
	var band: Variant = value_bands.get(category) if value_strength > 0.0 and amount > 0.0 else null
	# (A matched texture is already brought in line with its reference: no normalising.)
	var norm := 0.0 if matched else normalize * amount * (1.0 if float(category_strength.get(category, 1.0)) > 0.0 else 0.0)
	var target: Variant = category_targets.get(category)
	if strip_entry.is_empty() and (norm <= 0.0 or target == null) and not matched and band == null:
		return {}
	var out := {strength = k if not strip_entry.is_empty() else 0.0, normalize = norm if target != null else 0.0,
		target = target if target != null else Vector2(0.5, 0.3)}
	if matched:
		out.match = m
	if band != null:
		out.band = Vector3(band.x, band.y, value_strength * amount)
	if not strip_entry.is_empty():
		out.strip = strip_entry[0]
	out.key = str(hash([strip_entry[1] if not strip_entry.is_empty() else 0, snappedf(out.strength, 0.001),
		snappedf(out.normalize, 0.001), out.target, Array(m).map(func(v): return snappedf(v, 0.001)) if matched else 0,
		out.get("band", 0)]))
	return out


static func _strip(tex: Texture2D) -> Array:
	if _strips.has(tex):
		return _strips[tex]
	var strip := LutFile.strip_from_image(tex.get_image())
	var entry := [strip, hash(strip.get_data())] if strip else []
	_strips[tex] = entry
	return entry


## Average luminance and saturation of an image's opaque pixels.
static func stats(img: Image) -> Vector2:
	var l := 0.0
	var sat := 0.0
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a < 0.5:
				continue
			l += c.get_luminance()
			sat += maxf(c.r, maxf(c.g, c.b)) - minf(c.r, minf(c.g, c.b))
			n += 1
	return Vector2(l, sat) / maxf(n, 1)


## Every N64Texture in the library: [[path, texture]].
static func library() -> Array:
	var out := []
	var dirs := ["res://textures/"]
	while not dirs.is_empty():
		var d: String = dirs.pop_back()
		for sub in DirAccess.get_directories_at(d):
			if not sub.begins_with("_"):
				dirs.append(d + sub + "/")
		for f in DirAccess.get_files_at(d):
			if f.get_extension() == "res":
				var t := load(d + f) as N64Texture
				if t:
					out.append([d + f, t])
	return out


## Category targets: the median average brightness / saturation of each category's textures.
func measure_targets() -> void:
	var by := {}
	for e in library():
		var t: N64Texture = e[1]
		var img := ungraded(t)
		if img == null:
			continue
		var c := t.grade_category()
		if not by.has(c):
			by[c] = []
		by[c].append(stats(img))
	var targets := {}
	for c in by:
		var ls: Array = by[c].map(func(v): return v.x)
		var ss: Array = by[c].map(func(v): return v.y)
		ls.sort()
		ss.sort()
		targets[c] = Vector2(snappedf(ls[ls.size() / 2], 0.001), snappedf(ss[ss.size() / 2], 0.001))
	category_targets = targets
	emit_changed()
	print("[TextureGrade] targets for %d categories" % targets.size())


## A contact sheet of the library by category (as they are now) with the current grade's
## strip along the top (neutral when there's none): grade it as one picture, then Use Graded
## Sheet reads the strip back, your changes on top of the grade so far.
func make_grade_sheet() -> void:
	var lib := library()
	lib.sort_custom(func(a, b): return [String(a[1].category), a[0]] < [String(b[1].category), b[0]])
	var strip_w := SHEET_N * SHEET_N
	var cols := maxi(strip_w / THUMB, 16)
	var rows := ceili(lib.size() / float(cols)) + 1
	var sheet := Image.create(cols * THUMB, SHEET_N + 8 + rows * THUMB, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.5, 0.5, 0.5))
	sheet.blit_rect(effective_strip(), Rect2i(0, 0, strip_w, SHEET_N), Vector2i.ZERO)
	var i := 0
	var last := &""
	for e in lib:
		var t: N64Texture = e[1]
		if t.category != last and i % cols != 0:
			i += cols - i % cols  # each category starts a row
		last = t.category
		var img := t.get_image()
		if img == null:
			continue
		img = img.duplicate()
		if img.is_compressed():
			img.decompress()
		img.clear_mipmaps()
		img.convert(Image.FORMAT_RGBA8)
		img.resize(THUMB, THUMB, Image.INTERPOLATE_NEAREST)
		sheet.blit_rect(img, Rect2i(0, 0, THUMB, THUMB), Vector2i((i % cols) * THUMB, SHEET_N + 8 + (i / cols) * THUMB))
		i += 1
	DirAccess.make_dir_recursive_absolute(DIR)
	sheet.save_png(DIR + "grade_sheet.png")
	print("[TextureGrade] grade sheet: %s (%d textures; the LUT strip is the top-left %d x %d)" % [ProjectSettings.globalize_path(DIR + "grade_sheet.png"), lib.size(), strip_w, SHEET_N])


## The project grade as it applies now (LUT at `strength`), SHEET_N levels.
func effective_strip() -> Image:
	var out := LutFile.neutral(SHEET_N)
	if lut == null or strength <= 0.0:
		return out
	var e := _strip(lut)
	if e.is_empty():
		return out
	for y in SHEET_N:
		for x in SHEET_N * SHEET_N:
			var c := out.get_pixel(x, y)
			out.set_pixel(x, y, c.lerp(LutFile.apply(e[0], c), strength))
	return out


## Reads the LUT strip back from your graded sheet and makes it the project LUT.
func use_graded_sheet() -> void:
	var img := Image.load_from_file(graded_sheet)
	if img == null:
		push_error("[TextureGrade] can't load %s" % graded_sheet)
		return
	img.convert(Image.FORMAT_RGBA8)
	var strip := img.get_region(Rect2i(0, 0, SHEET_N * SHEET_N, SHEET_N))
	var tex := ImageTexture.create_from_image(strip)
	DirAccess.make_dir_recursive_absolute(DIR)
	ResourceSaver.save(tex, DIR + "grade_lut.res")
	tex.take_over_path(DIR + "grade_lut.res")
	lut = tex
	strength = 1.0  # (the strip already holds the old strength)
	_strips.clear()
	emit_changed()
	print("[TextureGrade] project LUT from %s" % graded_sheet)


## Rebuilds the textures whose grade changed (all with `force`).
func apply_to_textures(force := false) -> void:
	if DisplayServer.get_name() == "headless":
		# (The dummy renderer keeps no texture pixels: rebuilt images wouldn't be saved.)
		push_error("[TextureGrade] Apply To Textures needs a real renderer (not --headless).")
		return
	_strips.clear()
	var t0 := Time.get_ticks_msec()
	var done := 0
	var skipped := 0
	for e in library():
		var t: N64Texture = e[1]
		var g := settings_for(t.grade_category(), t.grade_amount, e[0])
		if not force and g.get("key", "") == t.graded_key:
			continue
		if t.source_path == "" or not FileAccess.file_exists(t.source_path):
			if _regrade_snapshot(t, e[0], g) == OK:
				done += 1
				skipped += 1
			continue
		if t.rebuild() == OK:
			done += 1
	print("[TextureGrade] rebuilt %d textures in %.1f s (%d of them from snapshots). Build & Play / Build All Zones to see them in levels." % [done, (Time.get_ticks_msec() - t0) / 1000.0, skipped])


const SNAPSHOT_DIR := "res://textures/_source/_snapshots/"


## Where a sourceless texture's ungraded original is kept.
static func snapshot_path(res_path: String) -> String:
	return SNAPSHOT_DIR + res_path.trim_prefix("res://textures/").get_basename() + ".png"


## A sourceless (generated) texture graded from its snapshot, taken first if it has none.
func _regrade_snapshot(t: N64Texture, res_path: String, g: Dictionary) -> Error:
	var snap := snapshot_path(res_path)
	var img: Image
	if FileAccess.file_exists(snap):
		img = Image.load_from_file(snap)
	else:
		img = t.get_image().duplicate()
		if img.is_compressed():
			img.decompress()
		img.clear_mipmaps()
		img.convert(Image.FORMAT_RGBA8)
		DirAccess.make_dir_recursive_absolute(snap.get_base_dir())
		img.save_png(snap)
	img.convert(Image.FORMAT_RGBA8)
	if not g.is_empty():
		N64TextureConverter.apply_grade(img, g)
	t.graded_key = g.get("key", "")
	t.set_image(N64TextureLibrary.with_mipmaps(img))
	return ResourceSaver.save(t, res_path)


## A texture as it is before any grade: converted from its source without one, or its
## snapshot (sourceless ones that have been graded), or its image (never graded).
static func ungraded(t: N64Texture) -> Image:
	var img: Image
	if t.source_path != "" and FileAccess.file_exists(t.source_path) and t.graded_key != "":
		var src := Image.load_from_file(t.source_path)
		if src:
			var s := t.get_settings()
			s.grade = {}
			img = N64TextureConverter.convert(src, s).image
	elif t.source_path == "" and FileAccess.file_exists(snapshot_path(t.resource_path)):
		img = Image.load_from_file(snapshot_path(t.resource_path))
	if img == null:
		img = t.get_image()
		if img == null:
			return null
		img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.clear_mipmaps()
	img.convert(Image.FORMAT_RGBA8)
	return img


## Where each category's textures sit by value (ungraded, Lab lightness median and range)
## against its band; printed, with the ones outside it.
func measure_values() -> void:
	var by := {}
	for e in library():
		var t: N64Texture = e[1]
		var img := ungraded(t)
		if img == null:
			continue
		var c := t.grade_category()
		if not by.has(c):
			by[c] = []
		by[c].append([mean_lightness(img), String(e[0]).get_file()])
	var cats := by.keys()
	cats.sort()
	for c in cats:
		var vals: Array = by[c].map(func(v): return v[0])
		vals.sort()
		var band: Variant = value_bands.get(c)
		var outside := []
		if band != null:
			for v in by[c]:
				if v[0] < band.x - 1.0 or v[0] > band.y + 1.0:
					outside.append(v[1])
		print("[TextureGrade] %-9s values %2d..%2d (median %2d)  band %s%s" % [c, roundi(vals[0]), roundi(vals[-1]), roundi(vals[vals.size() / 2]),
			("%d..%d" % [roundi(band.x), roundi(band.y)]) if band != null else "—",
			("  · %d outside" % outside.size()) if band != null else ""])


## Average Lab lightness of an image's opaque pixels.
static func mean_lightness(img: Image) -> float:
	var s := 0.0
	var n := 0
	var step := maxi(1, img.get_width() / 32)
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			var c := img.get_pixel(x, y)
			if c.a >= 0.5:
				s += ValueStats.lightness(c)
				n += 1
	return s / maxf(n, 1)


# --- Matching references --------------------------------------------------------------

## Works out, for every texture in each reference's category, how to move its colours to
## the reference's (texture_matches), and a preview per category (match_<category>_
## preview.png: before / after, the reference region below, left-out textures marked red).
## Textures that don't look like the rest of their category (a flower bed among grass) are
## left out and listed: set their grade_as. Apply To Textures then grades them.
func match_references() -> void:
	var lib := library()
	var matches := {}
	for r: GradeReference in references:
		if r == null or r.category == &"" or r.image_path == "":
			continue
		var ref := _reference_pixels(r)
		if ref.is_empty():
			push_warning("[TextureGrade] can't read %s" % r.image_path)
			continue
		var theirs := _lab_stats(ref)
		var members := []  # [path, image, stats]
		for e in lib:
			if (e[1] as N64Texture).grade_category() == r.category:
				var img := ungraded(e[1])
				if img:
					members.append([e[0], img, _lab_stats(_trimmed(_pixels_of([img])))])
		if members.is_empty():
			push_warning("[TextureGrade] no textures graded as '%s'" % r.category)
			continue
		# A texture fits when its main colour is near the reference's hue (or it's near grey
		# and so is the reference): an orange flower bed doesn't become grass.
		var ta := Vector2(theirs.mean.y, theirs.mean.z)
		var left_out := []
		var previews := []
		for m in members:
			var st: Dictionary = m[2]
			var oa := Vector2(st.mean.y, st.mean.z)
			var fit := 1.0
			if oa.length() > 10.0 and ta.length() > 6.0:
				fit = clampf((deg_to_rad(80.0) - absf(wrapf(ta.angle() - oa.angle(), -PI, PI))) / deg_to_rad(30.0), 0.0, 1.0)
			elif oa.length() > 18.0 and ta.length() <= 6.0:
				fit = 0.0  # a colourful texture against a grey reference
			if fit <= 0.0:
				left_out.append(String(m[0]).get_file())
			var mv := _match_for(st, theirs, r)
			mv[3] = r.amount * fit
			if mv[3] > 0.0:
				matches[m[0]] = mv
			previews.append([m[1], mv])
		_match_preview(previews, r)
		print("[TextureGrade] %s: %d textures moved towards L %.0f a %.0f b %.0f%s" % [r.category, members.size() - left_out.size(),
			theirs.mean.x, theirs.mean.y, theirs.mean.z,
			("; left out (don't look like %s, set grade_as): %s" % [r.category, ", ".join(left_out)]) if not left_out.is_empty() else ""])
	texture_matches = matches
	emit_changed()


## The move for a texture with Lab stats `st` towards the reference's (see texture_matches;
## amount 0). Grey textures (little chroma) aren't turned.
static func _match_for(st: Dictionary, theirs: Dictionary, r: GradeReference) -> PackedFloat32Array:
	var oa := Vector2(st.mean.y, st.mean.z)
	var ta := Vector2(theirs.mean.y, theirs.mean.z)
	var turn := 0.0
	if oa.length() > 4.0 and ta.length() > 4.0:
		turn = wrapf(ta.angle() - oa.angle(), -PI, PI)
	var chroma := clampf(ta.length() / maxf(oa.length(), 4.0), 0.5, 1.4)
	var light := lerpf(1.0, clampf(theirs.mean.x / maxf(st.mean.x, 1.0), 0.75, 1.35), r.lightness)
	var gate := maxf(Vector2(st.sd.y, st.sd.z).length() * 1.5, 10.0)
	return PackedFloat32Array([turn, chroma, light, 0.0, oa.x, oa.y, gate])


## `c` moved by `m` (texture_matches entry), in Lab, as far as it's near the main colour.
static func match_color(c: Color, m: PackedFloat32Array) -> Color:
	var l := to_lab(c)
	var d := Vector2(l.y - m[4], l.z - m[5])
	var w := m[3] * exp(-d.length_squared() / (2.0 * m[6] * m[6]))
	if w < 0.002:
		return c
	var ab := Vector2(l.y, l.z).rotated(m[0]) * m[1]
	var out := from_lab(Vector3(clampf(l.x * m[2], 0.0, 100.0), ab.x, ab.y))
	out.a = c.a
	return c.lerp(out, w)


## `px` with outliers dropped (beyond 2 deviations in lightness or colour).
static func _trimmed(px: PackedVector3Array) -> PackedVector3Array:
	var st := _lab_stats(px)
	var kept := PackedVector3Array()
	var lim := 2.0 * Vector2(st.sd.y, st.sd.z).length()
	for l in px:
		if absf(l.x - st.mean.x) <= 2.0 * st.sd.x and Vector2(l.y - st.mean.y, l.z - st.mean.z).length() <= lim:
			kept.append(l)
	return kept if kept.size() >= 4 else px


## Lab colours of the reference region (outliers dropped: shadows, highlights, things in
## front of the material).
static func _reference_pixels(r: GradeReference) -> PackedVector3Array:
	var img := Image.load_from_file(r.image_path)
	if img == null:
		return PackedVector3Array()
	img.convert(Image.FORMAT_RGBA8)
	var rect := Rect2i(0, 0, img.get_width(), img.get_height())
	if r.region.has_area():
		rect = Rect2i(Vector2i(r.region.position * Vector2(img.get_size())), Vector2i(r.region.size * Vector2(img.get_size())))
	var px := PackedVector3Array()
	var step := maxi(1, int(sqrt(float(rect.size.x * rect.size.y) / 20000.0)))
	for y in range(rect.position.y, rect.end.y, step):
		for x in range(rect.position.x, rect.end.x, step):
			px.append(to_lab(img.get_pixel(x, y)))
	return _trimmed(px)


static func _pixels_of(imgs: Array) -> PackedVector3Array:
	var px := PackedVector3Array()
	for img: Image in imgs:
		var step := maxi(1, img.get_width() / 32)
		for y in range(0, img.get_height(), step):
			for x in range(0, img.get_width(), step):
				var c := img.get_pixel(x, y)
				if c.a >= 0.5:
					px.append(to_lab(c))
	return px


static func _lab_stats(px: PackedVector3Array) -> Dictionary:
	var m := Vector3.ZERO
	var m2 := Vector3.ZERO
	for l in px:
		m += l
		m2 += l * l
	var n := maxf(px.size(), 1)
	m /= n
	var v := (m2 / n - m * m).max(Vector3.ONE * 0.0001)
	return {mean = m, sd = Vector3(sqrt(v.x), sqrt(v.y), sqrt(v.z))}


## Preview: up to 14 textures before (top) / after (middle), left-out ones outlined red,
## the reference region along the bottom.
func _match_preview(items: Array, r: GradeReference) -> void:
	var count := mini(items.size(), 14)
	var sheet := Image.create(count * 64, 64 * 2 + 72, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.12, 0.12, 0.12))
	for i in count:
		var a := (items[i][0] as Image).duplicate() as Image
		a.resize(64, 64, Image.INTERPOLATE_NEAREST)
		var mv: PackedFloat32Array = items[i][1]
		var b := a.duplicate() as Image
		if mv[3] > 0.0:
			for y in 64:
				for x in 64:
					b.set_pixel(x, y, match_color(b.get_pixel(x, y), mv))
		else:
			for k in 64:
				for edge in [Vector2i(k, 0), Vector2i(k, 63), Vector2i(0, k), Vector2i(63, k)]:
					b.set_pixelv(edge, Color.RED)
		sheet.blit_rect(a, Rect2i(0, 0, 64, 64), Vector2i(i * 64, 0))
		sheet.blit_rect(b, Rect2i(0, 0, 64, 64), Vector2i(i * 64, 64))
	var ref := Image.load_from_file(r.image_path)
	if ref:
		ref.convert(Image.FORMAT_RGBA8)
		if r.region.has_area():
			ref = ref.get_region(Rect2i(Vector2i(r.region.position * Vector2(ref.get_size())), Vector2i(r.region.size * Vector2(ref.get_size()))))
		var w := mini(int(ref.get_width() * 64 / float(ref.get_height())), sheet.get_width())
		ref.resize(w, 64, Image.INTERPOLATE_BILINEAR)
		sheet.blit_rect(ref, Rect2i(0, 0, w, 64), Vector2i(0, 136))
	DirAccess.make_dir_recursive_absolute(DIR)
	sheet.save_png(DIR + "match_%s_preview.png" % r.category)


static func _lin(v: float) -> float:
	return v / 12.92 if v <= 0.04045 else pow((v + 0.055) / 1.055, 2.4)


static func _srgb(v: float) -> float:
	v = clampf(v, 0.0, 1.0)
	return v * 12.92 if v <= 0.0031308 else 1.055 * pow(v, 1.0 / 2.4) - 0.055


static func _f(t: float) -> float:
	return pow(t, 1.0 / 3.0) if t > 0.008856 else 7.787 * t + 16.0 / 116.0


static func _finv(t: float) -> float:
	return t * t * t if t > 0.206893 else (t - 16.0 / 116.0) / 7.787


static func to_lab(c: Color) -> Vector3:
	var r := _lin(c.r)
	var g := _lin(c.g)
	var b := _lin(c.b)
	var x := (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
	var y := 0.2126 * r + 0.7152 * g + 0.0722 * b
	var z := (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
	return Vector3(116.0 * _f(y) - 16.0, 500.0 * (_f(x) - _f(y)), 200.0 * (_f(y) - _f(z)))


static func from_lab(l: Vector3) -> Color:
	var fy := (l.x + 16.0) / 116.0
	var x := _finv(fy + l.y / 500.0) * 0.95047
	var y := _finv(fy)
	var z := _finv(fy - l.z / 200.0) * 1.08883
	return Color(_srgb(3.2406 * x - 1.5372 * y - 0.4986 * z), _srgb(-0.9689 * x + 1.8758 * y + 0.0415 * z),
		_srgb(0.0557 * x - 0.2040 * y + 1.0570 * z))
