@tool
class_name StoryDatabase
extends Resource
## The game's story data (Project Settings > n64/story/database): characters, items,
## registered flags and the NPC schedules (each its own file). Edited in the Story workspace (addons/n64_story_tools).

const SETTING := "n64/story/database"
const DEFAULT_PATH := "res://game/story/story_db.tres"

@export var characters: Array[CharacterDef] = []
@export var items: Array[ItemDef] = []
@export var flags: Array[FlagDef] = []
@export var schedules: Array[NpcSchedule] = []

var _character_index := {}
var _item_index := {}
var _flag_index := {}
var _indexed := false


static func load_project() -> StoryDatabase:
	var path: String = ProjectSettings.get_setting(SETTING, DEFAULT_PATH)
	return load(path) as StoryDatabase if ResourceLoader.exists(path) else null


## Translated text for `key`, or `fallback` while there's no translation for it.
static func localized(key: String, fallback: String) -> String:
	var t := TranslationServer.translate(key)
	return fallback if t == StringName(key) else String(t)


func find_character(id: StringName) -> CharacterDef:
	_index()
	return _character_index.get(id)


func character_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for c in characters:
		if c and c.id != &"":
			out.append(String(c.id))
	out.sort()
	return out


func find_item(id: StringName) -> ItemDef:
	_index()
	return _item_index.get(id)


func find_flag(id: String) -> FlagDef:
	_index()
	return _flag_index.get(id)


func flag_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for f in flags:
		if f and f.id != "":
			out.append(f.id)
	out.sort()
	return out


func item_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for it in items:
		if it and it.id != &"":
			out.append(String(it.id))
	out.sort()
	return out


## Flags and items resetting on `rule` (and for ON_FLAG, on `trigger` being set).
func resetting(rule: FlagDef.Reset, trigger := "") -> Dictionary:
	var out := {flags = PackedStringArray(), items = PackedStringArray()}
	for f in flags:
		if f and f.reset == rule and (rule != FlagDef.Reset.ON_FLAG or f.reset_flag == trigger):
			out.flags.append(f.id)
	for it in items:
		if it and it.reset == rule and (rule != FlagDef.Reset.ON_FLAG or it.reset_flag == trigger):
			out.items.append(String(it.id))
	return out


## Call after ids change (editor).
func reindex() -> void:
	_indexed = false


func _index() -> void:
	if _indexed and not Engine.is_editor_hint():
		return
	_character_index.clear()
	_item_index.clear()
	_flag_index.clear()
	for c in characters:
		if c:
			_character_index[c.id] = c
	for it in items:
		if it:
			_item_index[it.id] = it
	for f in flags:
		if f:
			_flag_index[f.id] = f
	_indexed = true
