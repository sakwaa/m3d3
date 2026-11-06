@tool
extends HSplitContainer
## The Story workspace's Schedules tab:
##  - left: the game's NPC schedules (the story database lists them; files live in
##    res://story/schedules), New, Remove;
##  - middle: the selected NPC's day as a timeline (schedule_timeline.gd), its parts in
##    priority order (+ Part, Duplicate, ▲ / ▼ to reorder, Remove), and what-if controls:
##    the day, the weather, and every flag / item its conditions mention, so you can see
##    which part wins when (if it rains on day 2, after the key is found…);
##  - right: the inspector for the selected part (or the schedule itself) and problems
##    (missing zones, spots or paths, walks that arrive after their window ends).
## Every change is undoable and saves by itself.

const PreviewState := preload("res://addons/n64_story_tools/preview_state.gd")
const Timeline := preload("res://addons/n64_story_tools/ui/schedule_timeline.gd")
const Check := preload("res://addons/n64_story_tools/dialogue_check.gd")
const DIR := "res://story/schedules"

var db: StoryDatabase:
	set(value):
		db = value
		_gs.story = value
var schedule: NpcSchedule

var _gs: Node = PreviewState.new()
var _list: ItemList
var _timeline: Control
var _day: OptionButton
var _weather: OptionButton
var _whatif: HFlowContainer
var _inspector: EditorInspector
var _inspected: Object
var _problems: ItemList
var _header: Label
var _status: Label
var _new_dialog: ConfirmationDialog
var _new_id: LineEdit
var _new_character: OptionButton
var _save_timer: Timer
var _last := {}


func _init() -> void:
	name = "Schedules"
	size_flags_vertical = SIZE_EXPAND_FILL
	var s := EditorInterface.get_editor_scale()
	# Left: schedules.
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 200 * s
	add_child(left)
	var bar := HBoxContainer.new()
	left.add_child(bar)
	var new_btn := Button.new()
	new_btn.text = "New"
	new_btn.pressed.connect(_ask_new)
	bar.add_child(new_btn)
	var remove_btn := Button.new()
	remove_btn.text = "Remove"
	remove_btn.tooltip_text = "Take the selected schedule out of the game (its file stays)"
	remove_btn.pressed.connect(_remove_schedule)
	bar.add_child(remove_btn)
	_list = ItemList.new()
	_list.size_flags_vertical = SIZE_EXPAND_FILL
	_list.item_selected.connect(func(i: int): open_schedule(_list.get_item_metadata(i)))
	left.add_child(_list)
	_status = Label.new()
	_status.modulate.a = 0.6
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_status)

	var split := HSplitContainer.new()
	split.size_flags_horizontal = SIZE_EXPAND_FILL
	add_child(split)
	var middle := VBoxContainer.new()
	middle.size_flags_horizontal = SIZE_EXPAND_FILL
	split.add_child(middle)
	_header = Label.new()
	_header.text = "Open or create a schedule."
	middle.add_child(_header)
	var parts := HBoxContainer.new()
	middle.add_child(parts)
	for spec in [["+ Part", "Add a part (it goes last: the usual routine)", _add_part],
			["Duplicate", "Copy the selected part", _duplicate_part],
			["▲", "Higher priority (checked earlier)", func(): _move_part(-1)],
			["▼", "Lower priority", func(): _move_part(1)],
			["Remove", "Remove the selected part", _remove_part]]:
		var b := Button.new()
		b.text = spec[0]
		b.tooltip_text = spec[1]
		b.pressed.connect(spec[2])
		parts.add_child(b)
	var whatif_bar := HBoxContainer.new()
	middle.add_child(whatif_bar)
	var l := Label.new()
	l.text = "What if:"
	whatif_bar.add_child(l)
	_day = OptionButton.new()
	for d in 5:
		_day.add_item("Day %d" % (d + 1))
	_day.item_selected.connect(func(i: int):
		_gs.day = i + 5  # a week in, so "yesterday" exists
		_refresh_view())
	whatif_bar.add_child(_day)
	_weather = OptionButton.new()
	_weather.item_selected.connect(func(i: int):
		_gs.weather = StringName(_weather.get_item_text(i))
		_refresh_view())
	whatif_bar.add_child(_weather)
	_whatif = HFlowContainer.new()
	middle.add_child(_whatif)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	middle.add_child(scroll)
	_timeline = Timeline.new()
	_timeline.size_flags_horizontal = SIZE_EXPAND_FILL
	_timeline.tooltip_text = " "
	_timeline.gs = _gs
	_timeline.selected.connect(func(i: int): _inspect(schedule.entries[i]))
	_timeline.hours_changed.connect(func(i: int, done: bool):
		if done:
			_changed("Change part hours")
		else:
			_refresh_problems()
		if _inspected == schedule.entries[i]:
			_inspector.edit(_inspected))
	scroll.add_child(_timeline)

	var side := VSplitContainer.new()
	side.custom_minimum_size.x = 340 * s
	split.add_child(side)
	_inspector = EditorInspector.new()
	_inspector.size_flags_vertical = SIZE_EXPAND_FILL
	_inspector.property_edited.connect(func(_p):
		_changed("Edit %s" % _p)
		_refresh_view())
	side.add_child(_inspector)
	var lower := VBoxContainer.new()
	side.add_child(lower)
	var pl := Label.new()
	pl.text = "Problems"
	lower.add_child(pl)
	_problems = ItemList.new()
	_problems.custom_minimum_size.y = 120 * s
	_problems.size_flags_vertical = SIZE_EXPAND_FILL
	_problems.item_selected.connect(func(i: int):
		var idx = _problems.get_item_metadata(i)
		if idx is int and idx >= 0:
			_select_part(idx))
	lower.add_child(_problems)

	_new_dialog = ConfirmationDialog.new()
	_new_dialog.title = "New schedule"
	var box := VBoxContainer.new()
	var hint := Label.new()
	hint.text = "NPC id (one per person: collector_1, collector_2…):"
	box.add_child(hint)
	_new_id = LineEdit.new()
	box.add_child(_new_id)
	var hint2 := Label.new()
	hint2.text = "Character:"
	box.add_child(hint2)
	_new_character = OptionButton.new()
	box.add_child(_new_character)
	_new_dialog.add_child(box)
	_new_dialog.confirmed.connect(func():
		var i := _new_character.selected
		_create(_new_id.text, _new_character.get_item_metadata(i) if i >= 0 else ""))
	add_child(_new_dialog)

	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.5
	_save_timer.timeout.connect(save)
	add_child(_save_timer)


func _ready() -> void:
	add_child(_gs)
	_gs.day = 5


# --- Schedules ----------------------------------------------------------------------

func refresh_list() -> void:
	_list.clear()
	if db == null:
		return
	for sc in db.schedules:
		if sc == null:
			continue
		var c := db.find_character(sc.character)
		var i := _list.add_item("%s  (%s)" % [sc.id, c.get_display_name() if c else String(sc.character)])
		_list.set_item_metadata(i, sc)
		if sc == schedule:
			_list.select(i)
	_weather.clear()
	var table := WeatherTable.load_project()
	var ids: Array = table.ids() if table else [&"sunny", &"rain"]
	for id in ids:
		_weather.add_item(String(id))
		if id == _gs.weather:
			_weather.select(_weather.item_count - 1)


func _ask_new() -> void:
	if db == null:
		return
	_new_id.text = ""
	_new_character.clear()
	for id in db.character_ids():
		_new_character.add_item(db.find_character(StringName(id)).get_display_name())
		_new_character.set_item_metadata(_new_character.item_count - 1, id)
	_new_dialog.popup_centered(Vector2i(360, 0))
	_new_id.grab_focus()


func _create(id: String, character: String) -> void:
	id = id.strip_edges().to_lower().replace(" ", "_").replace("-", "_")
	if id == "" or not id.is_valid_ascii_identifier():
		_status.text = "Ids are letters, digits and _."
		return
	if db.schedules.any(func(x): return x and x.id == StringName(id)):
		_status.text = "There's already a schedule '%s'." % id
		return
	var path := DIR.path_join(id + ".tres")
	var sc := NpcSchedule.new()
	sc.id = id
	sc.character = character if character != "" else id
	var routine := ScheduleEntry.new()
	routine.label = "Usual routine"
	sc.entries.append(routine)
	DirAccess.make_dir_recursive_absolute(DIR)
	ResourceSaver.save(sc, path)
	sc = ResourceLoader.load(path)
	EditorInterface.get_resource_filesystem().update_file(path)
	db.schedules.append(sc)
	_save_db()
	refresh_list()
	open_schedule(sc)


func _remove_schedule() -> void:
	if schedule == null:
		return
	db.schedules.erase(schedule)
	_save_db()
	_status.text = "%s is out of the game (%s kept)." % [schedule.id, schedule.resource_path]
	schedule = null
	_timeline.schedule = null
	_inspect(null)
	refresh_list()
	_refresh_view()


func _save_db() -> void:
	ResourceSaver.save(db, db.resource_path)


func open_schedule(sc: NpcSchedule) -> void:
	if schedule and not _save_timer.is_stopped():
		save()
	schedule = sc
	_timeline.schedule = sc
	_timeline.selected_index = -1
	_last = _snapshot() if sc else {}
	_header.text = "%s  (%s)" % [sc.id, sc.resource_path] if sc else ""
	_inspect(sc)
	_refresh_view()


func save() -> void:
	_save_timer.stop()
	if schedule and schedule.resource_path != "":
		ResourceSaver.save(schedule, schedule.resource_path)


# --- Parts --------------------------------------------------------------------------

func _selected() -> int:
	return schedule.entries.find(_inspected) if schedule and _inspected is ScheduleEntry else -1


func _select_part(i: int) -> void:
	_timeline.selected_index = i
	_inspect(schedule.entries[i] if i >= 0 else schedule)
	_timeline.queue_redraw()


func _add_part() -> void:
	if schedule == null:
		return
	var e := ScheduleEntry.new()
	var prev: ScheduleEntry = schedule.entries.back() if not schedule.entries.is_empty() else null
	if prev:
		e.zone = prev.zone
		e.days = prev.days
		e.from_hour = prev.to_hour
		e.to_hour = minf(prev.to_hour + 2.0, 24.0)
	schedule.entries.append(e)
	_changed("Add part")
	_select_part(schedule.entries.size() - 1)


func _duplicate_part() -> void:
	var i := _selected()
	if i < 0:
		return
	schedule.entries.insert(i + 1, schedule.entries[i].duplicate_deep())
	_changed("Duplicate part")
	_select_part(i + 1)


func _move_part(step: int) -> void:
	var i := _selected()
	var j := i + step
	if i < 0 or j < 0 or j >= schedule.entries.size():
		return
	var e := schedule.entries[i]
	schedule.entries.remove_at(i)
	schedule.entries.insert(j, e)
	_changed("Reorder parts")
	_select_part(j)


func _remove_part() -> void:
	var i := _selected()
	if i < 0:
		return
	schedule.entries.remove_at(i)
	_changed("Remove part")
	_select_part(-1)


# --- Undo ---------------------------------------------------------------------------

func _snapshot() -> Dictionary:
	return {
		id = schedule.id, character = schedule.character, dialogue = schedule.dialogue,
		entries = schedule.entries.map(func(e): return e.duplicate_deep() if e else null),
	}


func _restore(snap: Dictionary, sc: NpcSchedule) -> void:
	if schedule != sc:
		open_schedule(sc)
	var keep := _selected()
	schedule.id = snap.id
	schedule.character = snap.character
	schedule.dialogue = snap.dialogue
	schedule.entries.assign(snap.entries.map(func(e): return e.duplicate_deep() if e else null))
	_last = snap
	_select_part(keep if keep < schedule.entries.size() else -1)
	_refresh_view()
	_save_timer.start()


func _changed(action: String) -> void:
	if schedule == null:
		return
	var after := _snapshot()
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action(action, UndoRedo.MERGE_DISABLE, schedule)
	ur.add_do_method(self, &"_restore", after, schedule)
	ur.add_undo_method(self, &"_restore", _last, schedule)
	ur.commit_action(false)
	_last = after
	_save_timer.start()
	_refresh_view()


# --- View ---------------------------------------------------------------------------

func _inspect(obj: Object) -> void:
	_inspected = obj
	_inspector.edit(obj)


func _refresh_view() -> void:
	_rebuild_whatif()
	_timeline.arrivals = _arrivals()
	_timeline.refresh()
	_refresh_problems()


## Walk parts: hours from their start to the end of their path.
func _arrivals() -> Dictionary:
	var out := {}
	if schedule == null:
		return out
	var def: CharacterDef = db.find_character(schedule.character) if db else null
	var speed := def.walk_speed if def else 1.4
	var sph := 45.0  # GameState.seconds_per_game_hour
	for i in schedule.entries.size():
		var e: ScheduleEntry = schedule.entries[i]
		if e and e.activity == ScheduleEntry.Activity.WALK and e.zone != "":
			var paths: Dictionary = ScheduleEntry.places_in(e.zone).paths
			if paths.has(e.place):
				out[i] = paths[e.place] / speed / sph
	return out


## A switch for every flag (a number box for counters) and item the parts' conditions
## mention.
func _rebuild_whatif() -> void:
	for c in _whatif.get_children():
		_whatif.remove_child(c)
		c.queue_free()
	if schedule == null:
		return
	var flags := {}
	var items := {}
	for e in schedule.entries:
		if e == null:
			continue
		for c in e.conditions:
			if c == null:
				continue
			if c.kind == StoryCondition.Kind.FLAG and c.flag != "":
				flags[c.flag] = c.test != StoryCondition.Test.IS_SET
			elif c.kind in [StoryCondition.Kind.ITEM, StoryCondition.Kind.EQUIPPED] and c.item != &"":
				items[String(c.item)] = c.kind == StoryCondition.Kind.EQUIPPED
	for f in flags:
		if flags[f]:
			var box := HBoxContainer.new()
			var l := Label.new()
			l.text = f
			box.add_child(l)
			var spin := SpinBox.new()
			spin.min_value = -99
			spin.max_value = 999
			spin.value = int(_gs.get_flag(f, 0))
			spin.value_changed.connect(func(v: float):
				_gs.flags[f] = int(v)
				_timeline.queue_redraw())
			box.add_child(spin)
			_whatif.add_child(box)
		else:
			_whatif.add_child(_switch(f, bool(_gs.get_flag(f)), func(on: bool):
				_gs.flags[f] = on))
	for it in items:
		_whatif.add_child(_switch(("equipped " if items[it] else "has ") + it,
			_gs.equipped == it if items[it] else _gs.has_item(StringName(it)), func(on: bool):
				if items[it]:
					_gs.equipped = it if on else ""
				else:
					_gs.items[it] = 1 if on else 0))


func _switch(text: String, on: bool, apply: Callable) -> CheckBox:
	var b := CheckBox.new()
	b.text = text
	b.button_pressed = on
	b.toggled.connect(func(v: bool):
		apply.call(v)
		_timeline.queue_redraw())
	return b


func _refresh_problems() -> void:
	_problems.clear()
	if schedule == null:
		return
	var theme := EditorInterface.get_editor_theme()
	var add := func(index: int, text: String, error := false):
		var i := _problems.add_item(("Part %d: " % (index + 1) if index >= 0 else "") + text,
			theme.get_icon(&"StatusError" if error else &"StatusWarning", &"EditorIcons"))
		_problems.set_item_metadata(i, index)
	if db and db.find_character(schedule.character) == null:
		add.call(-1, "Unknown character '%s'." % schedule.character, true)
	var arrivals := _arrivals()
	for i in schedule.entries.size():
		var e: ScheduleEntry = schedule.entries[i]
		if e == null:
			continue
		if e.days == 0:
			add.call(i, "No days ticked: it never happens.")
		if e.activity == ScheduleEntry.Activity.AWAY:
			continue
		if e.zone == "" or not FileAccess.file_exists(e.zone):
			add.call(i, "Pick the zone it happens in." if e.zone == "" else "Zone %s is missing." % e.zone, true)
			continue
		var places := ScheduleEntry.places_in(e.zone)
		var kind := "path" if e.activity == ScheduleEntry.Activity.WALK else "spot"
		var known: Dictionary = places.paths if e.activity == ScheduleEntry.Activity.WALK else places.spots
		if e.place == &"":
			add.call(i, "Pick the %s." % kind, true)
		elif not known.has(e.place):
			add.call(i, "No %s '%s' in %s (add an Npc%s)." % [kind, e.place, e.zone.get_file(), kind.capitalize()], true)
		if arrivals.has(i) and arrivals[i] > e.duration():
			add.call(i, "The walk takes %d min but the part lasts %d." % [roundi(arrivals[i] * 60), roundi(e.duration() * 60)])
		if e.dialogue == null and schedule.dialogue == null:
			add.call(i, "Nothing to say (no dialogue here or on the schedule).")
		var sink := func(_id: String, text: String, error := false): add.call(i, text, error)
		Check._check_conditions("", e.conditions, db, sink)
	if _problems.item_count == 0:
		_problems.add_item("No problems.")
		_problems.set_item_metadata(0, -1)
