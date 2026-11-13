@tool
class_name ValueStats
extends RefCounted
## How a picture reads by value (lightness, Lab L 0..100): its spread and key, for the value
## view's readout. p10 / p50 / p90: the lightness a tenth, half and nine tenths of the
## picture sit under; spread = p90 - p10 (Kakariko by day ~60; under ~30 reads flat).
## Key: high (mostly light, open and safe), low (mostly dark, tense), mid (everything in the
## middle: dull or foggy unless meant).

const BINS := 32


## Stats of `img` (any size; sampled on a grid of about `samples` pixels).
static func of(img: Image, samples := 40000) -> Dictionary:
	if img == null:
		return {}
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var step := maxi(1, int(sqrt(float(img.get_width() * img.get_height()) / samples)))
	var ls := PackedFloat32Array()
	var hist := PackedInt32Array()
	hist.resize(BINS)
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			var l := lightness(img.get_pixel(x, y))
			ls.append(l)
			hist[clampi(int(l / 100.0 * BINS), 0, BINS - 1)] += 1
	ls.sort()
	var n := ls.size()
	var p10 := ls[n / 10]
	var p50 := ls[n / 2]
	var p90 := ls[n * 9 / 10]
	var light := 0
	var dark := 0
	for l in ls:
		if l >= 60.0:
			light += 1
		elif l < 35.0:
			dark += 1
	var key := "mid"
	if light > n * 0.45:
		key = "high"
	elif dark > n * 0.45:
		key = "low"
	return {p10 = p10, p50 = p50, p90 = p90, spread = p90 - p10, key = key, hist = hist}


## Lab lightness of a display colour.
static func lightness(c: Color) -> float:
	var lin := func(v: float) -> float: return v / 12.92 if v <= 0.04045 else pow((v + 0.055) / 1.055, 2.4)
	var y: float = 0.2126 * lin.call(c.r) + 0.7152 * lin.call(c.g) + 0.0722 * lin.call(c.b)
	return 116.0 * (pow(y, 1.0 / 3.0) if y > 0.008856 else 7.787 * y + 16.0 / 116.0) - 16.0


## One line of text for stats `s`.
static func describe(s: Dictionary) -> String:
	if s.is_empty():
		return "—"
	var verdict := ""
	if s.spread < 30.0:
		verdict = " · flat: values crowd together"
	elif s.spread > 55.0:
		verdict = " · full range"
	return "darks %d · mids %d · lights %d · spread %d · %s key%s" % [roundi(s.p10), roundi(s.p50), roundi(s.p90), roundi(s.spread), s.key, verdict]


## A histogram image (BINS bars, dark to light) for `a`, with `b` (a reference) outlined
## over it; w x h.
static func histogram(a: Dictionary, b: Dictionary, w := 256, h := 56) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.1, 0.1, 0.12))
	var bw := w / BINS
	for i in BINS:
		var shade := Color(i / float(BINS), i / float(BINS), i / float(BINS)).lerp(Color(0.5, 0.5, 0.5), 0.3)
		img.fill_rect(Rect2i(i * bw, h - 3, bw, 3), shade)
	for pair in [[a, Color(0.85, 0.85, 0.9), true], [b, Color(0.95, 0.65, 0.3), false]]:
		var s: Dictionary = pair[0]
		if s.is_empty():
			continue
		var hist: PackedInt32Array = s.hist
		var top := 1
		for v in hist:
			top = maxi(top, v)
		for i in BINS:
			var bh := int(float(hist[i]) / top * (h - 6))
			if pair[2]:
				img.fill_rect(Rect2i(i * bw + 1, h - 4 - bh, bw - 2, bh), pair[1])
			else:
				img.fill_rect(Rect2i(i * bw + 1, h - 4 - bh, bw - 2, 2), pair[1])
	return img
