class_name N64TextureAnalysis
extends RefCounted
## Picks a zoom (and crop centre) from image content, so detail survives the drop to
## N64 resolution:
##   - feature size: autocorrelation of the high-passed luminance; the lag where it falls
##     below 0.5 is the typical detail size (grass blades, pebbles, grain);
##   - period: a later autocorrelation peak means a repeating pattern (bricks, tiles,
##     planks) and its repeat length;
##   - centre: the region whose colour statistics best match the whole image and that
##     holds the fewest outlier pixels (a stray leaf or speck repeats in every tile).

## Analysis resolution (shorter side, pixels).
const SIZE := 320
## Target texels across one detail feature / one pattern repeat in the final texture.
const FEATURE_TEXELS := 2.0
const PERIOD_TEXELS := 12.0
const MIN_REPEATS := 2.0
## Higher zooms blow single blades/grains up so far that anti-tiling rotation reads as swirls.
const MAX_ZOOM := 4.0
## Bricks / planks: target texels per course, and their zoom cap (no rotation, so no
## swirl; the crop still spans several source pixels per texel).
const COURSE_TEXELS := 16.0
const MAX_COURSE_ZOOM := 8.0


## Size-independent measurements, as fractions of the source's shorter side.
## {feature: float, period: float (0 = none), image: Image (analysis copy)}
static func measure(source: Image) -> Dictionary:
	var img := source.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var k := float(SIZE) / mini(img.get_width(), img.get_height())
	img.resize(maxi(8, roundi(img.get_width() * k)), maxi(8, roundi(img.get_height() * k)), Image.INTERPOLATE_BILINEAR)
	var w := img.get_width()
	var h := img.get_height()
	# High-pass: luminance minus a heavy blur, so lighting gradients don't read as detail.
	var low := img.duplicate() as Image
	low.resize(maxi(1, w / 20), maxi(1, h / 20), Image.INTERPOLATE_BILINEAR)
	low.resize(w, h, Image.INTERPOLATE_BILINEAR)
	var hp := PackedFloat32Array()
	hp.resize(w * h)
	for y in h:
		for x in w:
			hp[y * w + x] = img.get_pixel(x, y).get_luminance() - low.get_pixel(x, y).get_luminance()
	var cx := _autocorr(hp, w, h, true)
	var cy := _autocorr(hp, w, h, false)
	var shorter := float(mini(w, h))
	var feature := minf(_corr_length(cx), _corr_length(cy)) / shorter
	var px := _period(cx) / shorter
	var py := _period(cy) / shorter
	# Courses / planks: lines that run the full width (or height) show up far more clearly
	# in row (column) averages than in 2D autocorrelation muddied by staggered joints.
	var row_period := _profile_period(hp, w, h, true) / shorter
	var col_period := _profile_period(hp, w, h, false) / shorter
	return {feature = feature, period = py if py > 0.0 else px, image = img,
		period_v = row_period, period_h = col_period}


## Zoom for an output size (texels) from measure() results.
static func zoom_for(m: Dictionary, out_size: Vector2i) -> float:
	var texels := float(mini(out_size.x, out_size.y))
	var zoom := FEATURE_TEXELS / maxf(m.feature * texels, 0.001)
	if m.period > 0.0:
		var max_zoom := maxf(1.0, 1.0 / (MIN_REPEATS * m.period))
		zoom = clampf(PERIOD_TEXELS / (m.period * texels), 1.0, max_zoom)
	return clampf(snappedf(zoom, 0.25), 1.0, MAX_ZOOM)


## Centre (0..1) of the zoomed region that looks most like the whole image.
static func typical_center(m: Dictionary, zoom: float, aspect: float) -> Vector2:
	var img: Image = m.image
	var w := img.get_width()
	var h := img.get_height()
	var rh := minf(h, w / aspect) / zoom
	var rw := rh * aspect
	var global := _stats(img, Rect2i(0, 0, w, h))
	var best := Vector2(0.5, 0.5)
	var best_score := INF
	for gy in 7:
		for gx in 7:
			var c := Vector2(lerpf(rw * 0.5, w - rw * 0.5, gx / 6.0), lerpf(rh * 0.5, h - rh * 0.5, gy / 6.0))
			var s := _stats(img, Rect2i(int(c.x - rw * 0.5), int(c.y - rh * 0.5), int(rw), int(rh)), global)
			var score: float = (s.mean - global.mean).length() + 0.5 * absf(s.std - global.std) + 4.0 * s.outliers
			if score < best_score:
				best_score = score
				best = c / Vector2(w, h)
	return best


## Applies auto zoom + centre to settings (surface tiling textures only).
static func apply(m: Dictionary, s: Dictionary) -> void:
	if s.tiling == N64TextureConverter.Tiling.NONE:
		s.zoom = 1.0
		return
	s.zoom = zoom_for(m, s.size)
	_snap_to_courses(m, s)
	s.crop_center = typical_center(m, s.zoom, float(s.size.x) / s.size.y)
	_align_to_courses(m, s)


## Textures that tile in one direction only (bricks, planks) repeat unblended across the
## other one, so the crop must hold whole courses there (s.courses, or ~COURSE_TEXELS per
## course when 0): an even count unless Row shuffle is on, so running bond stays
## staggered from one repeat to the next. Sets s.zoom for ~COURSE_TEXELS per course
## (within 1..MAX_COURSE_ZOOM).
static func _snap_to_courses(m: Dictionary, s: Dictionary) -> void:
	var tiling: int = s.tiling
	var vertical := tiling == N64TextureConverter.Tiling.SEAMLESS_U
	if not vertical and tiling != N64TextureConverter.Tiling.SEAMLESS_V:
		return
	var period: float = m.get("period_v" if vertical else "period_h", 0.0)
	if period <= 0.0:
		return
	var img: Image = m.image
	var w := float(img.get_width())
	var h := float(img.get_height())
	var size: Vector2i = s.size
	var aspect := float(size.x) / size.y
	var blend: float = s.seam_blend if s.seam_blend > 0.0 else N64TextureConverter.DEFAULT_SEAM_BLEND
	var wrap: bool = s.seam_blend <= 0.0
	var b := 1.0 if wrap else 1.0 + blend * 0.5
	# Crop extent across the unblended direction at zoom 1 (as crop_rect computes it).
	var base: float = minf(h, w / (aspect * b)) if vertical else minf(h / b, w / aspect) * aspect
	var course := period * minf(w, h)
	# Even counts keep running bond staggered across repeats; Row shuffle randomises that
	# anyway, so any count works there.
	var step := 1 if int(s.get("anti_tiling", 0)) == 3 else 2
	var max_count := floori(base / course / step) * step
	if max_count < step:
		return
	var min_count := clampi(ceili(base / (MAX_COURSE_ZOOM * course) / step - 1e-4) * step, step, max_count)
	var texels := float(size.y if vertical else size.x)
	var want: int = int(s.get("courses", 0))
	if want <= 0:
		want = roundi(texels / COURSE_TEXELS)  # auto: ~COURSE_TEXELS per course
	want = maxi(step, roundi(float(want) / step) * step)
	var count := clampi(want, min_count, max_count)
	s.zoom = base / (count * course)


## Moves the crop so its edge across the unblended direction sits on a mortar line (the
## line that stands out most in every course): repeats then join mortar to mortar, so
## Row shuffle can slide rows sideways without cutting bricks.
static func _align_to_courses(m: Dictionary, s: Dictionary) -> void:
	var vertical: bool = s.tiling == N64TextureConverter.Tiling.SEAMLESS_U
	if not vertical and s.tiling != N64TextureConverter.Tiling.SEAMLESS_V:
		return
	var img: Image = m.image
	var w := img.get_width()
	var h := img.get_height()
	var period: float = m.get("period_v" if vertical else "period_h", 0.0) * mini(w, h)
	if period < 2.0:
		return
	# Mean brightness of each line, folded over the course period: mortar is the line that
	# stands out most (lighter or darker) in every course.
	var n := h if vertical else w
	var line := PackedFloat32Array()
	line.resize(n)
	for i in n:
		var sum := 0.0
		var count := 0
		for j in range(0, w if vertical else h, 2):
			sum += img.get_pixel(j, i).get_luminance() if vertical else img.get_pixel(i, j).get_luminance()
			count += 1
		line[i] = sum / count
	var steps := maxi(roundi(period), 2)
	var folded := PackedFloat32Array()
	folded.resize(steps)
	for k in steps:
		var total := 0.0
		var count := 0
		var p := k * period / steps
		while p < n - 1:
			# Linear interpolation between lines for sub-pixel periods.
			var i0 := int(p)
			total += lerpf(line[i0], line[i0 + 1], p - i0)
			count += 1
			p += period
		folded[k] = total / maxi(count, 1)
	var mean := 0.0
	for v in folded:
		mean += v
	mean /= steps
	var best_phase := 0.0
	var best_dev := -1.0
	for k in steps:
		if absf(folded[k] - mean) > best_dev:
			best_dev = absf(folded[k] - mean)
			best_phase = k * period / steps
	# Crop extent in analysis pixels (as crop_rect computes it) and its current start.
	var size: Vector2i = s.size
	var aspect := float(size.x) / size.y
	var blend: float = s.seam_blend if s.seam_blend > 0.0 else N64TextureConverter.DEFAULT_SEAM_BLEND
	var b := 1.0 if s.seam_blend <= 0.0 else 1.0 + blend * 0.5
	var extent: float = (minf(h, w / (aspect * b)) if vertical else minf(h / b, w / aspect) * aspect) / s.zoom
	var c: Vector2 = s.crop_center
	var length := float(h if vertical else w)
	var start: float = (c.y if vertical else c.x) * length - extent * 0.5
	var snapped := best_phase + roundf((start - best_phase) / period) * period
	while snapped + extent > length and snapped - period >= 0.0:
		snapped -= period
	while snapped < 0.0:
		snapped += period
	if snapped + extent > length:
		return
	if vertical:
		c.y = (snapped + extent * 0.5) / length
	else:
		c.x = (snapped + extent * 0.5) / length
	s.crop_center = c


## Repeat length (analysis pixels, sub-pixel) of the row (or column) mean profile, or 0.
static func _profile_period(hp: PackedFloat32Array, w: int, h: int, rows: bool) -> float:
	var n := h if rows else w
	var m := w if rows else h
	var prof := PackedFloat32Array()
	prof.resize(n)
	for i in n:
		var sum := 0.0
		for j in m:
			sum += hp[i * w + j] if rows else hp[j * w + i]
		prof[i] = sum / m
	var max_lag := n / 3
	var c := PackedFloat32Array()
	c.resize(max_lag + 1)
	for lag in max_lag + 1:
		var sum := 0.0
		for i in n - lag:
			sum += prof[i] * prof[i + lag]
		c[lag] = sum / (n - lag)
	var c0 := maxf(c[0], 1e-9)
	var dipped := false
	for lag in range(2, max_lag):
		var v := c[lag] / c0
		if not dipped:
			dipped = v < 0.1
			continue
		if v > 0.3 and c[lag] >= c[lag - 1] and c[lag] >= c[lag + 1]:
			# Parabolic peak refinement.
			var a := c[lag - 1]
			var bb := c[lag]
			var cc := c[lag + 1]
			var den := a - 2.0 * bb + cc
			return lag + (0.5 * (a - cc) / den if absf(den) > 1e-12 else 0.0)
	return 0.0


static func _autocorr(hp: PackedFloat32Array, w: int, h: int, horizontal: bool) -> PackedFloat32Array:
	var n := w if horizontal else h
	var lines := h if horizontal else w
	var max_lag := n / 3
	var out := PackedFloat32Array()
	out.resize(max_lag + 1)
	for lag in max_lag + 1:
		var sum := 0.0
		var count := 0
		for line in range(0, lines, 4):
			for i in range(0, n - lag, 2):
				var a := hp[line * w + i] if horizontal else hp[i * w + line]
				var b := hp[line * w + i + lag] if horizontal else hp[(i + lag) * w + line]
				sum += a * b
				count += 1
		out[lag] = sum / maxi(count, 1)
	var var0 := maxf(out[0], 1e-9)
	for lag in out.size():
		out[lag] /= var0
	return out


## Lag where the correlation first falls below 0.5 (interpolated), at least 1.
static func _corr_length(c: PackedFloat32Array) -> float:
	for lag in range(1, c.size()):
		if c[lag] < 0.5:
			var prev := c[lag - 1]
			return maxf(1.0, lag - 1 + (prev - 0.5) / maxf(prev - c[lag], 1e-6))
	return c.size()


## First clear peak after the correlation dips: the repeat length of a pattern, or 0.
static func _period(c: PackedFloat32Array) -> float:
	var dipped := false
	for lag in range(2, c.size() - 1):
		if not dipped:
			dipped = c[lag] < 0.1
			continue
		if c[lag] > 0.25 and c[lag] >= c[lag - 1] and c[lag] >= c[lag + 1]:
			return lag
	return 0.0


## Mean colour, luminance spread and (given global stats) the fraction of outlier pixels
## further than 2.5 standard deviations from the global mean luminance.
static func _stats(img: Image, r: Rect2i, global := {}) -> Dictionary:
	var sum := Vector3.ZERO
	var sum_l := 0.0
	var sum_l2 := 0.0
	var count := 0
	var outliers := 0
	var step := 4 if global.is_empty() else 2
	var g_l := 0.0
	var g_limit := INF
	if not global.is_empty():
		g_l = global.mean_l
		g_limit = 2.5 * maxf(global.std, 0.01)
	for y in range(r.position.y, r.end.y, step):
		for x in range(r.position.x, r.end.x, step):
			var c := img.get_pixel(clampi(x, 0, img.get_width() - 1), clampi(y, 0, img.get_height() - 1))
			var l := c.get_luminance()
			sum += Vector3(c.r, c.g, c.b)
			sum_l += l
			sum_l2 += l * l
			count += 1
			if absf(l - g_l) > g_limit:
				outliers += 1
	count = maxi(count, 1)
	var mean_l := sum_l / count
	return {mean = sum / count, mean_l = mean_l, std = sqrt(maxf(sum_l2 / count - mean_l * mean_l, 0.0)),
		outliers = float(outliers) / count}
