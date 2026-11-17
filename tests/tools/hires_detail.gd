extends Node
## Hi-res close-up detail (N64Texture lod_mode 3) for the market's brush textures: each
## texture's source rebuilt with the same settings and grade at 4x (2x when the source is too
## small; at most 512) into textures/detail/hires/<name>_hi.res, set as its detail_texture.
##   Godot --headless --path . res://tests/tools/hires_detail.tscn [TEXTURES=res://a.res,...]
##   DRY=1: only list what would be made.

const MARKET := ["res://textures/wood/wood_2.res", "res://textures/concrete/stucco_3.res",
	"res://textures/grass/157_green_grass.res", "res://textures/ground/mud.res", "res://textures/brick/block_4.res",
	"res://textures/rock/stone_wall_stacked.res", "res://textures/rock/cobbles_granite_setts.res",
	"res://textures/rock/cobblestone_square.res", "res://textures/brick/block_6.res",
	"res://textures/concrete/concrete_bare.res", "res://textures/wood/wood_planks_8.res",
	"res://textures/roof/shingles_1.res", "res://textures/roof/shingles_3.res", "res://textures/roof/shingles_5.res",
	"res://textures/roof/shingles_7.res", "res://textures/roof/red_shingles_1.res",
	"res://textures/fabric/generated/planks_wood_2.res", "res://textures/doors/wood_plank_door.res",
	"res://textures/brick/brick_2.res", "res://textures/brick/53_old_bricks.res",
	"res://textures/stairs/53_old_bricks_stairs.res", "res://textures/rock/river_rock_1.res"]
const OUT := "res://textures/detail/hires/"
const MAX := 512
## How much of the copy's detail shows close up (1 = all of it: the 3-point filtered base
## disappears under a bare high-res photo; 0.33 keeps the N64 look with grain on it).
const STRENGTH := 0.33


func _ready() -> void:
	var list: Array = Array(OS.get_environment("TEXTURES").split(",")) if OS.get_environment("TEXTURES") != "" else MARKET
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	for p in list:
		_make(p)
	get_tree().quit()


func _make(path: String) -> void:
	var t := load(path) as N64Texture
	if t == null:
		print("skip (not an N64Texture): ", path)
		return
	var src := Image.load_from_file(t.source_path) if t.source_path != "" else null
	if src == null:
		print("skip (no source image): %s (%s)" % [path.get_file(), t.source_path])
		return
	var s := t.get_settings()
	var size: Vector2i = s.size
	var f := 4
	while f > 1 and (size.x * f > MAX or size.y * f > MAX or size.x * f > src.get_width() / maxf(t.zoom, 1.0) or size.y * f > src.get_height() / maxf(t.zoom, 1.0)):
		f /= 2
	if f < 2:
		print("skip (source too small or texture already %s): %s" % [size, path.get_file()])
		return
	print("%-30s %s -> %s  (source %dx%d)" % [path.get_file(), size, size * f, src.get_width(), src.get_height()])
	if OS.get_environment("DRY") != "":
		return
	s.size = size * f
	s.no_budget = true
	s.format = N64TextureConverter.Format.RGBA16  # (smooth detail, not a 16-colour palette)
	var result := N64TextureConverter.convert(src, s)
	var hi := N64Texture.new()
	hi.set_image(N64TextureLibrary.with_mipmaps(result.image))
	hi.category = &"detail"
	hi.usage = t.usage
	hi.tiling = t.tiling
	hi.format = N64TextureConverter.Format.RGBA16
	hi.texture_size = size * f
	var out := OUT + path.get_file().get_basename() + "_hi.res"
	_save(hi, out)
	t.lod_mode = 3
	t.detail_texture = load(out)
	t.detail_repeats = 1.0
	t.detail_strength = STRENGTH
	_save(t, path)


func _save(r: Resource, path: String) -> void:
	var uid := ResourceLoader.get_resource_uid(path) if ResourceLoader.exists(path) else ResourceUID.INVALID_ID
	var err := ResourceSaver.save(r, path)
	if uid != ResourceUID.INVALID_ID:
		ResourceSaver.set_uid(path, uid)
	r.take_over_path(path)
	if err != OK:
		print("save failed ", path, " ", error_string(err))
