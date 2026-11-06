@tool
class_name GlyphAlphabet
extends Resource
## An in-game script (tooling only: text is baked into textures, the alphabet and the
## typed text never ship). The atlas is a grid of cells, `cell_size` pixels each, its alpha
## the ink; `tokens` names each cell in order (row by row). A syllable block is drawn by
## laying the cells of its parts over each other in one square: its consonant (or "_" for
## none) — drawn in the cell's top part — its vowel (bottom part) and a final "N" (right
## edge). A cell named for a whole syllable ("ka", "kan") replaces that layering for it, so
## a refined atlas can draw any syllable by hand. "." and "," are punctuation.
##
## Several alphabets can exist (regions, eras); whatever uses one rebuilds its textures
## when the atlas is edited / reimported (in the editor, and in the bake on export).

@export var atlas: Texture2D:
	set(v):
		if atlas and atlas.changed.is_connected(emit_changed):
			atlas.changed.disconnect(emit_changed)
		atlas = v
		if atlas and Engine.is_editor_hint():
			atlas.changed.connect(emit_changed)
		_image = null
		emit_changed()
@export var cell_size := Vector2i(16, 16):
	set(v):
		cell_size = v.max(Vector2i(2, 2))
		emit_changed()
@export var tokens := PackedStringArray():
	set(v):
		tokens = v
		emit_changed()

var _image: Image


func _init() -> void:
	changed.connect(func(): _image = null)


## The atlas's pixels (RGBA8, cached until it changes).
func image() -> Image:
	if _image == null and atlas:
		_image = atlas.get_image()
		if _image:
			_image = _image.duplicate()
			if _image.is_compressed():
				_image.decompress()
			_image.convert(Image.FORMAT_RGBA8)
	return _image


## The cell named `token`, as an image (null: the alphabet doesn't have it).
func cell(token: String) -> Image:
	var i := tokens.find(token)
	var img := image()
	if i < 0 or img == null:
		return null
	var cols := maxi(img.get_width() / cell_size.x, 1)
	var r := Rect2i(Vector2i(i % cols, i / cols) * cell_size, cell_size)
	if not Rect2i(Vector2i.ZERO, img.get_size()).encloses(r):
		return null
	return img.get_region(r)


## Changes whenever anything drawn with this alphabet would look different.
func content_key() -> int:
	var img := image()
	return hash([tokens, cell_size, img.get_data() if img else PackedByteArray()])
