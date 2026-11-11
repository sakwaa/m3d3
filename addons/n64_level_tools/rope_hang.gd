@tool
class_name RopeHang
extends Resource
## Something hung along a rope brush (LevelBrush.rope_hangs): a scene (lanterns, bells), a
## cutout card built into the rope's geometry (shimenawa straw tassels, shide paper
## streamers, cloth banners, or any texture), or string lights (glowing bulbs, StringLights). Several on one rope mix (tassels with shide
## between them: same spacing, offset 0.5). Shareable; editing it regenerates the ropes.

const GlyphText := preload("res://addons/n64_level_tools/glyphs/glyph_text.gd")

enum Kind {
	SCENE,   ## An instance of `scene` at each spot (its origin hangs from the cord).
	TASSEL,  ## Shimenawa straw tassel (crossed cards).
	SHIDE,   ## Zigzag paper streamer, flat along the rope.
	BANNER,  ## Cloth banner, flat along the rope (colours below, or a texture).
	CARD,    ## Your own cutout texture, flat along the rope.
	LIGHTS,  ## String lights: a bulb at each spot, glowing at dusk and night (StringLights).
}
enum Placement {
	SPACED,          ## Every `spacing` metres along each section (evened out).
	SECTION_MIDDLE,  ## One at the middle of each section.
	POINTS,          ## At the rope's points between sections (not its two ends).
}

@export var kind := Kind.TASSEL:
	set(v):
		kind = v
		notify_property_list_changed()
		emit_changed()
@export var scene: PackedScene:
	set(v):
		scene = v
		emit_changed()
## Cutout texture (alpha = shape), fitted to the card once; empty = the kind's own
## (generated). Its top edge hangs from the cord.
@export var texture: Texture2D:
	set(v):
		texture = v
		emit_changed()
## Card width x height (metres).
@export var size := Vector2(0.18, 0.45):
	set(v):
		size = v.max(Vector2(0.01, 0.01))
		emit_changed()
## Two cards crossed (reads from every side); off: one card in the rope's plane.
@export var crossed := true:
	set(v):
		crossed = v
		emit_changed()

@export_group("Placement")
@export var placement := Placement.SPACED:
	set(v):
		placement = v
		notify_property_list_changed()
		emit_changed()
@export_range(0.1, 20.0, 0.05, "or_greater", "suffix:m") var spacing := 1.0:
	set(v):
		spacing = maxf(v, 0.1)
		emit_changed()
## Shift along the spacing (0.5 = halfway between another hang's spots at the same spacing).
@export_range(0.0, 1.0, 0.01) var offset := 0.0:
	set(v):
		offset = v
		emit_changed()
## Cord between the rope and what hangs (the rope's texture; 0 = right on the rope).
@export_range(0.0, 4.0, 0.01, "or_greater", "suffix:m") var drop := 0.0:
	set(v):
		drop = maxf(v, 0.0)
		emit_changed()

@export_group("Lights")
## Bulb colour when lit (warm white by default).
@export var light_color := Color(1.0, 0.75, 0.4):
	set(v):
		light_color = v
		emit_changed()
## Bulb diameter and the soft glow round it (metres).
@export_range(0.02, 0.5, 0.01, "suffix:m") var bulb_size := 0.09:
	set(v):
		bulb_size = v
		emit_changed()
@export_range(0.0, 2.0, 0.01, "suffix:m") var glow_size := 0.5:
	set(v):
		glow_size = v
		emit_changed()
## Bulbs flicker a little, each on its own.
@export var flicker := false:
	set(v):
		flicker = v
		emit_changed()

@export_group("Banner")
@export var cloth_color := Color(0.85, 0.85, 0.8):
	set(v):
		cloth_color = v
		emit_changed()
## Border, hem and the crest.
@export var trim_color := Color(0.55, 0.12, 0.1):
	set(v):
		trim_color = v
		emit_changed()
## Crest in the middle (none / circle / diamond / three bars).
@export_enum("None", "Circle", "Diamond", "Bars") var crest := 1:
	set(v):
		crest = v
		emit_changed()
## Words on the banner, in English (a new line starts a new column), written in
## `alphabet` top to bottom, columns right to left, instead of the crest: each syllable a
## block of its sounds, words that sound alike told apart by a spelling mark, so it reads
## back exactly (capitals aside). Only the drawing ships: the English stays in the project.
@export_multiline var text := "":
	set(v):
		text = v
		notify_property_list_changed()
		emit_changed()
## How the text is written: each word's sounds per block (start | vowel | end), spelling
## marks, word symbols, and anything that can't be written or wouldn't read back the same ("!").
@export_custom(PROPERTY_HINT_MULTILINE_TEXT, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var text_sounds: String:
	get:
		return GlyphText.breakdown(text, symbols_used()) if not text.strip_edges().is_empty() else ""
	set(_v):
		pass
## Script the text is written in: a SyllabaryAlphabet (hand-drawn), a StrokeAlphabet
## (joined shorthand outlines) or a GlyphAlphabet (syllable blocks). Empty: the project's
## syllabary, DEFAULT_ALPHABET.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "SyllabaryAlphabet,StrokeAlphabet,GlyphAlphabet") var alphabet: Resource:
	set(v):
		if alphabet and alphabet.changed.is_connected(emit_changed):
			alphabet.changed.disconnect(emit_changed)
		alphabet = v
		if alphabet and Engine.is_editor_hint():
			alphabet.changed.connect(emit_changed)
		emit_changed()
@export var ink_color := Color(0.1, 0.08, 0.08):
	set(v):
		ink_color = v
		emit_changed()
## Words with a word symbol (SyllabaryAlphabet, drawn in the Script Builder) spelled out on
## this banner instead; every other such word is written with its symbol. Set in the
## inspector's Word symbols group, a tick box per word of the text that has one.
@export_storage var spelled_out := PackedStringArray():
	set(v):
		spelled_out = v
		emit_changed()


func _validate_property(property: Dictionary) -> void:
	var hide := false
	match property.name:
		"scene": hide = kind != Kind.SCENE
		"texture", "size": hide = kind == Kind.SCENE or kind == Kind.LIGHTS
		"crossed": hide = kind == Kind.SCENE or kind == Kind.LIGHTS
		"light_color", "bulb_size", "glow_size", "flicker": hide = kind != Kind.LIGHTS
		"spacing", "offset": hide = placement != Placement.SPACED
		"cloth_color", "trim_color", "crest", "text", "alphabet", "ink_color", "text_sounds": hide = kind != Kind.BANNER
	if hide:
		property.usage &= ~PROPERTY_USAGE_EDITOR


## The banner's words written with their symbol (the rest of the text's symbol words are
## spelled out).
func symbols_used() -> PackedStringArray:
	var out := PackedStringArray()
	for w in GlyphText.symbol_words_in(text, text_alphabet()):
		if not w in spelled_out:
			out.append(w)
	return out


func _get_property_list() -> Array[Dictionary]:
	if kind != Kind.BANNER or not Engine.is_editor_hint():
		return []
	var words := GlyphText.symbol_words_in(text, text_alphabet())
	if words.is_empty():
		return []
	var out: Array[Dictionary] = [{name = "Word symbols", type = TYPE_NIL, usage = PROPERTY_USAGE_GROUP, hint_string = "symbol_"}]
	for w in words:
		out.append({name = "symbol_" + w, type = TYPE_BOOL, usage = PROPERTY_USAGE_EDITOR})
	return out


func _get(property: StringName) -> Variant:
	var p := String(property)
	if p.begins_with("symbol_"):
		return not p.trim_prefix("symbol_") in spelled_out
	return null


func _set(property: StringName, value: Variant) -> bool:
	var p := String(property)
	if not p.begins_with("symbol_"):
		return false
	var w := p.trim_prefix("symbol_")
	var s := spelled_out.duplicate()
	if value:
		s.erase(w)
	elif not w in s:
		s.append(w)
	spelled_out = s
	return true


## Defaults that suit a kind (the inspector's starting point for a new hang).
static func preset(k: Kind) -> RopeHang:
	var h := RopeHang.new()
	h.kind = k
	match k:
		Kind.SCENE:
			h.spacing = 1.5
			h.drop = 0.25
		Kind.TASSEL:
			h.size = Vector2(0.16, 0.4)
			h.spacing = 1.0
		Kind.SHIDE:
			h.size = Vector2(0.16, 0.36)
			h.crossed = false
			h.spacing = 1.0
			h.offset = 0.5
		Kind.BANNER:
			h.size = Vector2(0.5, 1.2)
			h.crossed = false
			h.placement = Placement.SECTION_MIDDLE
		Kind.CARD:
			h.size = Vector2(0.3, 0.3)
			h.crossed = false
		Kind.LIGHTS:
			h.spacing = 0.6
			h.drop = 0.04
	return h


const DEFAULT_ALPHABET := "res://glyphs/syllabary/alphabet.tres"


## The alphabet the banner's text is drawn in (null: none available). Editing it (even the
## default one) rebuilds the banner.
func text_alphabet() -> Resource:
	var a: Resource = alphabet
	if a == null and ResourceLoader.exists(DEFAULT_ALPHABET):
		a = load(DEFAULT_ALPHABET)
	if a and Engine.is_editor_hint() and not a.changed.is_connected(emit_changed):
		a.changed.connect(emit_changed)
	return a
