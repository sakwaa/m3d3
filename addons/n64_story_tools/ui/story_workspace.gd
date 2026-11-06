@tool
extends VBoxContainer
## "Story" main-screen workspace (beside 2D / 3D / Script): edits the story database
## (StoryDatabase, Project Settings > n64/story/database) and the dialogues.
##  - Dialogue: the conversation graphs (see dialogue_editor.gd);
##  - Schedules: each NPC's week on a timeline (see schedule_editor.gd);
##  - Cutscenes: scripted scenes on a timeline with a preview (see cutscene_editor.gd);
##  - Characters: who speaks (name, name tag colour, voice); dialogue refers to them by id;
##  - Items: the inventory items (kind, capacity, icon, when the player loses them again);
##  - Flags: registered GameState flags, grouped by scope ("baker/met" under baker/), with
##    their kind and reset rule (never, leaving the zone, end of day / week, another flag).
## Changes save by themselves (also after undo / redo). The database is created on first
## open if it doesn't exist yet.

const RegistryPanel := preload("res://addons/n64_story_tools/ui/registry_panel.gd")
const DialogueEditor := preload("res://addons/n64_story_tools/ui/dialogue_editor.gd")
const ScheduleEditor := preload("res://addons/n64_story_tools/ui/schedule_editor.gd")
const CutsceneEditor := preload("res://addons/n64_story_tools/ui/cutscene_editor.gd")
const RESET_NAMES := ["never", "zone exit", "day end", "week end", "on flag"]

var db: StoryDatabase
var _path_label: Label
var _status: Label
var _tabs: TabContainer
var dialogue_editor: Control
var schedule_editor: Control
var cutscene_editor: Control
var _characters: Control
var _items: Control
var _flags: Control
var _save_timer: Timer
var _saved_sig := ""


func _init() -> void:
	name = "Story"
	size_flags_vertical = SIZE_EXPAND_FILL
	var bar := HBoxContainer.new()
	add_child(bar)
	_path_label = Label.new()
	bar.add_child(_path_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	bar.add_child(spacer)
	_status = Label.new()
	_status.modulate.a = 0.6
	bar.add_child(_status)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(_tabs)
	dialogue_editor = DialogueEditor.new()
	_tabs.add_child(dialogue_editor)
	schedule_editor = ScheduleEditor.new()
	_tabs.add_child(schedule_editor)
	cutscene_editor = CutsceneEditor.new()
	_tabs.add_child(cutscene_editor)
	_characters = RegistryPanel.new()
	_characters.setup("characters", "character", PackedStringArray(["Name", "Id", "Voice"]),
		func(): return _new_character(),
		func(c: CharacterDef): return PackedStringArray([c.display_name if c.display_name != "" else String(c.id),
			String(c.id), "silent" if c.silent else "%s %d Hz" % [CharacterDef.Timbre.keys()[c.voice_timbre].to_lower(), c.voice_pitch]]))
	_tabs.add_child(_characters)
	_items = RegistryPanel.new()
	_items.setup("items", "item", PackedStringArray(["Name", "Id", "Kind"]),
		func(): return _new_item(),
		func(it: ItemDef): return PackedStringArray([it.display_name if it.display_name != "" else String(it.id),
			String(it.id), ItemDef.Kind.keys()[it.kind].to_lower()
				+ (" ×%d" % it.max_count if it.capacity() > 1 else "")]))
	_tabs.add_child(_items)
	_flags = RegistryPanel.new()
	_flags.setup("flags", "flag", PackedStringArray(["Flag", "Kind", "Resets"]),
		func(): return _new_flag(),
		func(f: FlagDef): return PackedStringArray([f.id.substr(f.id.find("/") + 1) if f.scope() != "" else f.id,
			FlagDef.Kind.keys()[f.kind].to_lower(),
			RESET_NAMES[f.reset] + (" (%s)" % f.reset_flag if f.reset == FlagDef.Reset.ON_FLAG else "")]),
		func(f: FlagDef): return f.scope())
	_tabs.add_child(_flags)
	for p in [_characters, _items, _flags]:
		p.edited.connect(_queue_save)

	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.4
	_save_timer.timeout.connect(save)
	add_child(_save_timer)


func _ready() -> void:
	EditorInterface.get_editor_undo_redo().version_changed.connect(_queue_save)


## Loads (or creates) the project's database.
func open() -> void:
	var path: String = ProjectSettings.get_setting(StoryDatabase.SETTING, StoryDatabase.DEFAULT_PATH)
	var loaded := StoryDatabase.load_project()
	if loaded == null:
		loaded = StoryDatabase.new()
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		ResourceSaver.save(loaded, path)
		loaded.take_over_path(path)
		EditorInterface.get_resource_filesystem().update_file(path)
	if loaded != db:
		db = loaded
		_saved_sig = _signature()
		for p in [_characters, _items, _flags]:
			p.set_database(db)
		dialogue_editor.db = db
		dialogue_editor.refresh_files()
		schedule_editor.db = db
		cutscene_editor.db = db
	schedule_editor.refresh_list()
	cutscene_editor.refresh_files()
	_path_label.text = "Story database: %s" % path
	_update_status()


func open_dialogue(path: String) -> void:
	open()
	_tabs.current_tab = dialogue_editor.get_index()
	dialogue_editor.open_dialogue(path)


func open_cutscene(path: String) -> void:
	open()
	_tabs.current_tab = cutscene_editor.get_index()
	cutscene_editor.open_cutscene(path)


func open_schedule(sc: NpcSchedule) -> void:
	open()
	_tabs.current_tab = schedule_editor.get_index()
	schedule_editor.open_schedule(sc)


func _queue_save() -> void:
	if db:
		_save_timer.start()


## Saves when anything changed since the last save (refreshing the lists too).
func save() -> void:
	if db == null:
		return
	var sig := _signature()
	if sig == _saved_sig:
		return
	db.reindex()
	var err := ResourceSaver.save(db, db.resource_path)
	if err != OK:
		push_error("Story: couldn't save %s (%s)" % [db.resource_path, error_string(err)])
		return
	_saved_sig = sig
	for p in [_characters, _items, _flags]:
		p.refresh()
	# Speaker names and pickers in the open dialogue follow the database.
	if dialogue_editor.dialogue:
		dialogue_editor._queue_rebuild()
	_update_status()


func _update_status() -> void:
	_status.text = "%d characters · %d items · %d flags" % [db.characters.size(), db.items.size(), db.flags.size()] if db else ""


## Every stored value, to tell whether the database changed.
func _signature() -> String:
	var parts := PackedStringArray()
	for list in [db.characters, db.items, db.flags]:
		parts.append("|")
		for e in list:
			if e == null:
				parts.append("null")
				continue
			for p in e.get_property_list():
				if p.usage & PROPERTY_USAGE_STORAGE and p.name != "script":
					var v = e.get(p.name)
					parts.append(v.resource_path if v is Resource else str(v))
	return "\n".join(parts)


func _new_character() -> CharacterDef:
	var c := CharacterDef.new()
	c.id = _free_id(db.character_ids(), "new_character")
	c.display_name = "New character"
	c.name_color = Color.from_hsv(randf(), 0.55, 0.95)
	return c


func _new_item() -> ItemDef:
	var it := ItemDef.new()
	it.id = _free_id(db.item_ids(), "new_item")
	it.display_name = "New item"
	return it


func _new_flag() -> FlagDef:
	var f := FlagDef.new()
	# New flags land in the selected flag's scope.
	var sel = _flags._selected
	var scope: String = sel.scope() if sel else ""
	f.id = _free_id(db.flag_ids(), (scope + "/" if scope != "" else "") + "new_flag")
	return f


static func _free_id(taken: PackedStringArray, base: String) -> String:
	if not taken.has(base):
		return base
	var n := 2
	while taken.has("%s%d" % [base, n]):
		n += 1
	return "%s%d" % [base, n]
