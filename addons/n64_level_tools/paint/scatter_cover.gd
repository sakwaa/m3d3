@tool
class_name ScatterCover
extends RefCounted
## Flat flower (or petal / leaf) cover for overlay layers: a few of the chosen cut-outs
## sprinkled into a small tileable RGBA16 texture (1-bit alpha, wrapping across the edges
## so it repeats seamlessly). Paint it with an overlay layer (Mix) over grass: meadows at
## no geometry cost. Saved as an N64Texture (res://textures/flowers/cover_*.res).

const DIR := "res://textures/flowers"


## Makes and saves a cover texture: `size` px square covering `metres` per repeat, with
## `count` cut-outs about `item_px` across. Returns it (or null).
static func make(items: Array, size := 64, metres := 1.0, count := 8, item_px := 14, seed_value := 0,
		edge_dark := 0.55) -> Texture2D:
	var sources := []
	for t in items:
		if t is Texture2D:
			var img: Image = t.get_image()
			if img:
				img = img.duplicate()
				img.decompress()
				img.convert(Image.FORMAT_RGBA8)
				sources.append(img)
	if sources.is_empty():
		return null
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value if seed_value != 0 else Time.get_ticks_usec()
	var out := Image.create(size, size, false, Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 0))
	var taken := []
	for i in count:
		var src: Image = sources[i % sources.size()]
		var px := maxi(4, roundi(item_px * rng.randf_range(0.75, 1.25)))
		var w := maxi(2, roundi(px * float(src.get_width()) / maxf(src.get_height(), 1)))
		var stamp: Image = src.duplicate()
		stamp.resize(w, px, Image.INTERPOLATE_NEAREST)
		# Spread them out: a few tries for a spot away from the others (wrapping).
		var at := Vector2i.ZERO
		for t in 12:
			at = Vector2i(rng.randi() % size, rng.randi() % size)
			var clear := true
			for q: Vector2i in taken:
				var d := Vector2(absi(at.x - q.x), absi(at.y - q.y))
				d = Vector2(minf(d.x, size - d.x), minf(d.y, size - d.y))
				if d.length() < px * 0.9:
					clear = false
					break
			if clear:
				break
		taken.append(at)
		for y in stamp.get_height():
			for x in stamp.get_width():
				var c := stamp.get_pixel(x, y)
				if c.a < 0.5:
					continue
				# N64 RGBA16: 5 bits per channel, 1-bit alpha.
				c = Color(roundf(c.r * 31.0) / 31.0, roundf(c.g * 31.0) / 31.0, roundf(c.b * 31.0) / 31.0, 1.0)
				out.set_pixel((at.x + x) % size, (at.y + y) % size, c)
	# A darker ring around each cut-out (like scattered ones' Darken edge), and colours
	# bled into the transparent texels so filtering doesn't fringe.
	var edges := []
	for y in size:
		for x in size:
			if out.get_pixel(x, y).a < 0.5:
				continue
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				if out.get_pixel(posmod(x + d.x, size), posmod(y + d.y, size)).a < 0.5:
					edges.append(Vector2i(x, y))
					break
	for e: Vector2i in edges:
		var c := out.get_pixel(e.x, e.y)
		out.set_pixel(e.x, e.y, Color(roundf(c.r * edge_dark * 31.0) / 31.0, roundf(c.g * edge_dark * 31.0) / 31.0,
			roundf(c.b * edge_dark * 31.0) / 31.0, 1.0))
	N64TextureConverter.bleed_alpha(out)
	out.generate_mipmaps()
	var tex := N64Texture.new()
	tex.set_image(out)
	tex.category = &"flowers"
	tex.usage = N64TextureConverter.Usage.SURFACE
	tex.tiling = N64TextureConverter.Tiling.SEAMLESS
	tex.format = N64TextureConverter.Format.RGBA16
	tex.texture_size = Vector2i(size, size)
	tex.world_size = metres
	tex.anti_tiling = 2  # offset + rotate per cell: no visible grid of repeats
	DirAccess.make_dir_recursive_absolute(DIR)
	var n := 1
	while FileAccess.file_exists("%s/cover_%d.res" % [DIR, n]):
		n += 1
	var path := "%s/cover_%d.res" % [DIR, n]
	if ResourceSaver.save(tex, path) != OK:
		return null
	if Engine.is_editor_hint():
		var ei = Engine.get_singleton(&"EditorInterface")
		ei.get_resource_filesystem().update_file(path)
	return load(path)
