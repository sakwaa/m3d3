@tool
class_name LevelSurfaces
extends RefCounted
## Which Surface (footstep sound | gameplay flags) each level face bakes into collision:
##  1. its base texture's surface (N64Texture.surface());
##  2. replaced by the topmost visible overlay layer covering at least COVERED of the face,
##     if that layer's texture has a surface (a mud path painted over grass sounds of mud);
##  3. then the face's Surface override: its sound (if any) replaces, its flags add.

## Mean mask coverage from which an overlay layer decides a face's surface.
const COVERED := 0.5


## Surfaces of every face of `brush`.
static func brush_faces(data: LevelData, brush: LevelBrush) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(brush.get_face_count())
	for f in out.size():
		out[f] = face(data, brush, f)
	return out


static func face(data: LevelData, brush: LevelBrush, f: int) -> int:
	var s := texture_surface(data.textures[brush.get_face_texture(f)] if brush.get_face_texture(f) >= 0
		and brush.get_face_texture(f) < data.textures.size() else null)
	var layers := data.layers_of(brush.get_face_layer_set(f))
	for l in range(mini(layers.size(), LevelData.MAX_LAYERS) - 1, -1, -1):
		var layer: PaintLayer = layers[l]
		if layer == null or not layer.enabled or not layer.texture is N64Texture:
			continue
		if coverage(brush.get_face_mask(f, l)) >= COVERED:
			s = texture_surface(layer.texture)
			break
	return combine(s, brush.get_face_surface(f))


## A surface with an override on top: the override's sound (if not Default) replaces,
## its flags add.
static func combine(s: int, override: int) -> int:
	if override == 0:
		return s
	var snd := Surface.sound(override) if Surface.sound(override) != Surface.Sound.DEFAULT else Surface.sound(s)
	return snd | ((s | override) & ~Surface.SOUND_MASK)


static func texture_surface(tex: Texture2D) -> int:
	return tex.surface() if tex is N64Texture else 0


## Mean coverage of a face mask (0 = none or no mask), from its smallest mip (a box average).
static func coverage(img: Image) -> float:
	if img == null:
		return 0.0
	var m := img.duplicate() as Image
	if m.get_format() != Image.FORMAT_L8:
		m.convert(Image.FORMAT_L8)
	if m.get_width() > 1 or m.get_height() > 1:
		m.generate_mipmaps()
	var count := m.get_mipmap_count()
	var offset := m.get_mipmap_offset(count) if count > 0 else 0
	return m.get_data()[offset] / 255.0
