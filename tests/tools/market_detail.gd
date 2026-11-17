extends Node
## Detail textures for the market's ground (the RDP's detail texture mode, N64Texture
## lod_mode = Detail): makes textures/detail/stone_grain.res and grass_grain.res (32 x 32 I8
## grain, seamless) if missing and sets them on the ground textures below.
##   Godot --headless --path . res://tests/tools/market_detail.tscn

const STONE := ["res://textures/rock/cobbles_granite_setts.res", "res://textures/rock/cobblestone_square.res",
	"res://textures/ground/mud.res", "res://textures/brick/53_old_bricks.res", "res://textures/brick/block_1.res",
	"res://textures/concrete/concrete_bare.res"]
const GRASS := ["res://textures/grass/157_green_grass.res"]


func _ready() -> void:
	var stone := _grain("res://textures/detail/stone_grain.res", false)
	var grass := _grain("res://textures/detail/grass_grain.res", true)
	for p in STONE:
		_apply(p, stone, 8.0, 0.45)
	for p in GRASS:
		_apply(p, grass, 5.0, 0.6)
	get_tree().quit()


func _apply(path: String, detail: Texture2D, repeats: float, strength: float) -> void:
	var t := load(path) as N64Texture
	if t == null:
		print("skip (not an N64Texture): ", path)
		return
	t.lod_mode = 2
	t.detail_texture = detail
	t.detail_repeats = repeats
	t.detail_strength = strength
	_save(t, path)
	print("detail on %s: %s x%.1f, %.2f" % [path.get_file(), detail.resource_path.get_file(), repeats, strength])


## Seamless 32 x 32 grain around mid grey: stone = soft mottling, grass = upright streaks.
func _grain(path: String, streaks: bool) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path)
	var n := FastNoiseLite.new()
	n.seed = 7 if streaks else 3
	# (not cellular: its cell borders read as a second, finer grout grid on paving)
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH if not streaks else FastNoiseLite.TYPE_VALUE
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = 3
	n.frequency = 0.12 if not streaks else 0.35
	var size := 32
	var src := n.get_seamless_image(size, size if not streaks else size * 4)
	src.convert(Image.FORMAT_RGBA8)
	if streaks:
		src.resize(size, size, Image.INTERPOLATE_BILINEAR)  # (4x squashed: tall streaks)
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var lo := 1.0
	var hi := 0.0
	for y in size:
		for x in size:
			var v := src.get_pixel(x, y).r
			lo = minf(lo, v)
			hi = maxf(hi, v)
	for y in size:
		for x in size:
			var v := (src.get_pixel(x, y).r - lo) / maxf(hi - lo, 0.001)
			v = roundf((0.3 + v * 0.4) * 255.0) / 255.0  # I8, 0.3 .. 0.7 around grey
			img.set_pixel(x, y, Color(v, v, v, v))
	img.generate_mipmaps()
	var t := N64Texture.new()
	t.set_image(img)
	t.category = &"detail"
	t.usage = N64TextureConverter.Usage.DETAIL
	t.tiling = N64TextureConverter.Tiling.SEAMLESS
	t.format = N64TextureConverter.Format.I8
	t.texture_size = Vector2i(size, size)
	_save(t, path)
	return t


func _save(t: Resource, path: String) -> void:
	var uid := ResourceLoader.get_resource_uid(path) if ResourceLoader.exists(path) else ResourceUID.INVALID_ID
	var err := ResourceSaver.save(t, path)
	if uid != ResourceUID.INVALID_ID:
		ResourceSaver.set_uid(path, uid)
	t.take_over_path(path)
	if err != OK:
		print("save failed ", path, " ", error_string(err))
