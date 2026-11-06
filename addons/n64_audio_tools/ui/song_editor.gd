@tool
extends VBoxContainer
## Song editor (N64 Sounds > a song): the song's parts (MIDI files, one per part, e.g. a
## clip exported from Ableton), each with its channel, instrument (from the open bank),
## volume, pan, repeat and mute; loop points (bars, or CC111 in the MIDI); an overview of
## the notes per channel with the loop and playhead (click to seek); play / stop through
## the game's music player. The song rebuilds after every change and when a part's MIDI
## file changes on disk (re-export, then come back to Godot).
## Banks from a CD64 song bank (one slot per channel: channel n plays program n - 1, the
## drum kit channel 10) list their instruments as "ch 3: Strings"; picking one moves the
## part to its channel, and changing a part's channel picks that channel's instrument, so
## each part plays what CD64 previewed on it.
## Songs playing a bank set (library instruments; "Bank set" menu) name each part's
## instrument ("instrument" in the part): the builder gives it the set's program. The
## instrument list shows the set's instruments (slots by channel for CD64 song sets), then
## the library's other instruments ("+ add: ..."), which picking adds to the set.

const SONG_DIR := "res://audio/songs"
const ROW_H := 18
const CH_COLORS := [Color(0.45, 0.75, 1.0), Color(1.0, 0.6, 0.35), Color(0.55, 0.9, 0.5), Color(0.95, 0.5, 0.75),
	Color(0.9, 0.85, 0.4), Color(0.6, 0.55, 1.0), Color(0.4, 0.9, 0.85), Color(1.0, 0.45, 0.45)]

var workspace: Control
var song: Resource  # N64Song
var song_path := ""

var _name: LineEdit
var _bank_label: Label
var _play_button: Button
var _pos_label: Label
var _loop_midi: CheckBox
var _loop_start: SpinBox
var _loop_end: SpinBox
var _info: Label
var _overview: Control
var _parts: GridContainer
var _status: Label
var _add_dialog: EditorFileDialog
var _player: Node  # N64MusicPlayer
var _builder: RefCounted
var _updating := false
## Overview cache: channel -> [[start, end, key], …].
var _notes := {}
## CD64 song-bank slots of the part's bank: instrument -> channel (0-15), and back.
var _slot_of := {}
var _slot_ins := {}
var _set_menu: MenuButton  # the song's bank set (from the library)


func _init() -> void:
	size_flags_vertical = SIZE_EXPAND_FILL
	add_theme_constant_override(&"separation", 6)
	var s := EditorInterface.get_editor_scale()
	var top := HFlowContainer.new()
	add_child(top)
	_name = LineEdit.new()
	_name.custom_minimum_size.x = 180 * s
	_name.text_submitted.connect(func(t): _set_song(&"Name", t))
	_name.focus_exited.connect(func(): _set_song(&"Name", _name.text))
	top.add_child(_name)
	_play_button = _btn(top, "▶ Play", _toggle_play)
	_btn(top, "⏮", func(): _seek(0.0))
	_pos_label = Label.new()
	_pos_label.custom_minimum_size.x = 150 * s
	top.add_child(_pos_label)
	_btn(top, "Add MIDI parts…", _dialog_add)
	_btn(top, "Rebuild", rebuild)
	_bank_label = Label.new()
	_bank_label.modulate = Color(1, 1, 1, 0.7)
	top.add_child(_bank_label)
	_btn(top, "Use open bank", _use_open_bank)
	_set_menu = MenuButton.new()
	_set_menu.text = "Bank set"
	_set_menu.flat = false
	_set_menu.tooltip_text = "Play the song with a bank set of the instrument library (parts then name their instruments)"
	_set_menu.about_to_popup.connect(_fill_set_menu)
	_set_menu.get_popup().id_pressed.connect(_set_picked)
	top.add_child(_set_menu)

	var loop := HFlowContainer.new()
	add_child(loop)
	_loop_midi = CheckBox.new()
	_loop_midi.text = "Loop start from CC111"
	_loop_midi.tooltip_text = "A CC111 event in any part marks the loop start (RPG Maker convention).\nIn Ableton: draw CC111 automation (any value) at the loop start in one clip."
	_loop_midi.toggled.connect(func(on): _set_song(&"LoopFromMidi", on); rebuild())
	loop.add_child(_loop_midi)
	loop.add_child(_label("Loop start (bar)"))
	_loop_start = _spin(0, 999, 0.25)
	_loop_start.tooltip_text = "Bar the loop goes back to (1 = the start). 0 = no loop: the song plays once."
	_loop_start.value_changed.connect(func(v): _set_loop(&"LoopStart", v))
	loop.add_child(_loop_start)
	loop.add_child(_label("Loop end (bar)"))
	_loop_end = _spin(0, 999, 0.25)
	_loop_end.tooltip_text = "Bar where it jumps back (0 = the end of the song)."
	_loop_end.value_changed.connect(func(v): _set_loop(&"LoopEnd", v))
	loop.add_child(_loop_end)
	_info = Label.new()
	_info.modulate = Color(1, 1, 1, 0.7)
	loop.add_child(_info)

	_overview = Control.new()
	_overview.custom_minimum_size.y = 110 * s
	_overview.clip_contents = true
	_overview.draw.connect(_draw_overview)
	_overview.gui_input.connect(_overview_input)
	add_child(_overview)

	var head := HBoxContainer.new()
	add_child(head)
	var title := Label.new()
	title.text = "Parts"
	title.add_theme_color_override(&"font_color", Color(0.7, 0.85, 1.0))
	head.add_child(title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.custom_minimum_size.y = 120 * s
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_parts = GridContainer.new()
	_parts.columns = 8
	_parts.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(_parts)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.modulate = Color(1, 0.75, 0.45)
	add_child(_status)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PROCESS and _player and song:
		var playing: bool = _player.IsPlaying()
		_play_button.text = "■ Stop" if playing else "▶ Play"
		_pos_label.text = "%s  (%.2f s)" % [_bar_text(_player.GetPosition()), _player.GetPosition()]
		_overview.queue_redraw()


func edit(s: Resource, path: String) -> void:
	_stop()
	song = s
	song_path = path
	_ensure_tools()
	set_process(true)
	refresh()


func _ensure_tools() -> void:
	if _builder == null:
		var b = load("res://addons/n64_audio_tools/cs/N64SongBuilder.cs")
		if b and b.can_instantiate():
			_builder = b.new()
	if _player == null:
		var p = load("res://game/audio/N64MusicPlayer.cs")
		if p and p.can_instantiate():
			_player = p.new()
			add_child(_player)


# --- Build / save ------------------------------------------------------------------------------

## Compiles the parts into the song's events and saves it.
func rebuild() -> void:
	if song == null:
		return
	_ensure_tools()
	if _builder == null:
		_status.text = "C# not built yet (Build the project), can't read MIDI."
		return
	var was_playing: bool = _player != null and _player.IsPlaying()
	var at: float = _player.GetPosition() if was_playing else 0.0
	var err: String = _builder.Build(song)
	_status.text = err
	_save()
	refresh()
	if was_playing:
		_play(at)


## Rebuilds if any part's MIDI file changed on disk since the last build (re-export from
## the DAW, then come back to Godot). Returns true if it rebuilt.
func rebuild_if_changed() -> bool:
	if song == null:
		return false
	for t in song.Tracks:
		var path: String = t.get("path", "")
		if FileAccess.file_exists(path) and int(FileAccess.get_modified_time(path)) != int(t.get("mtime", 0)):
			rebuild()
			_status.text = ("MIDI changed on disk: rebuilt.\n" + _status.text).strip_edges()
			return true
	return false


func _save() -> void:
	if song == null or song_path == "":
		return
	var err := ResourceSaver.save(song, song_path)
	if err != OK:
		push_error("N64 Sounds: can't save %s (%s)." % [song_path, error_string(err)])


func _set_song(prop: StringName, value: Variant) -> void:
	if _updating or song == null or song.get(prop) == value:
		return
	song.set(prop, value)
	_save()
	if workspace:
		workspace.refresh_tree_keep()


func _set_loop(prop: StringName, bar: float) -> void:
	if _updating or song == null:
		return
	var seconds := -1.0 if bar <= 0.0 else (bar - 1.0) * _bar_seconds()
	if prop == &"LoopStart" and bar > 0.0:
		_loop_midi.set_pressed_no_signal(false)
		song.LoopFromMidi = false
	song.set(prop, seconds)
	_save()
	refresh()


func _use_open_bank() -> void:
	if song == null or workspace == null or workspace.bank == null:
		return
	if workspace.library_mode:
		push_warning("N64 Sounds: the library isn't a bank: pick a bank set (Bank set) for the song.")
		return
	if workspace.bank_path == "":
		push_warning("N64 Sounds: save the bank first; the song links to it by file.")
		return
	song.Bank = load(workspace.bank_path)
	song.BankSet = null
	_save()
	refresh()


func _fill_set_menu() -> void:
	var pm := _set_menu.get_popup()
	pm.clear()
	var sets: Array = workspace.library_sets() if workspace else []
	for i in sets.size():
		pm.add_radio_check_item("%s  (%.1f KB)" % [sets[i].Name, sets[i].StoredBytes() / 1024.0], i)
		pm.set_item_checked(pm.item_count - 1, song != null and song.BankSet == sets[i])
	if sets.is_empty():
		pm.add_item("(no bank sets: make one in the library)", -2)
		pm.set_item_disabled(0, true)
	pm.add_separator()
	pm.add_item("None (use the bank)", -1)


func _set_picked(id: int) -> void:
	if song == null:
		return
	if id == -1:
		song.BankSet = null
	elif id >= 0:
		use_set(workspace.library_sets()[id])
	rebuild()


## Plays the song with bank set `st`: parts keep their instrument where the set has it (by
## name, else the instrument on their program).
func use_set(st: Resource) -> void:
	song.BankSet = st
	var sb = st.SoundBank
	for t in song.Tracks:
		if t.has("instrument") and st.EntryFor(t.instrument) != null:
			continue
		for ins in sb.Instruments:
			if ins.IsDrumKit == t.get("drums", false) and (ins.IsDrumKit or (ins.Program == int(t.get("program", 0)) and ins.Bank == int(t.get("bank", 0)))):
				t.instrument = ins.get_meta(&"n64_name", ins.Name)
				break


# --- Parts ---------------------------------------------------------------------------------

func _dialog_add() -> void:
	if _add_dialog == null:
		_add_dialog = EditorFileDialog.new()
		_add_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILES
		_add_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
		_add_dialog.title = "Add MIDI parts (one file per part)"
		_add_dialog.add_filter("*.mid, *.midi", "MIDI files")
		_add_dialog.files_selected.connect(add_parts)
		EditorInterface.get_base_control().add_child(_add_dialog)
	_add_dialog.popup_file_dialog()


## Adds MIDI files as parts: one part per file, or per track for multi-track files. Each
## gets the next free channel (drum-like tracks on MIDI channel 10 go to the drum kit).
func add_parts(paths: PackedStringArray) -> void:
	if song == null:
		return
	_ensure_tools()
	for path in paths:
		var p := _project_path(path)
		var info: Dictionary = _builder.Describe(p) if _builder else {}
		if info.has("error"):
			_status.text = "%s: %s" % [p.get_file(), info.error]
			continue
		var tracks: Array = info.get("tracks", []).filter(func(t): return t.notes > 0)
		if tracks.is_empty():
			_status.text = "%s has no notes." % p.get_file()
			continue
		for t in tracks:
			var part := {path = p, midi_track = t.track if tracks.size() > 1 else -1, volume = 0.79, pan = 0.0,
				repeat = false, mute = false, name = t.name if t.name != "" else p.get_file().get_basename()}
			var drums: bool = t.channels.has(9)
			if drums:
				part.drums = true
				part.channel = 9
			else:
				part.channel = _free_channel()
				var ins = _first_instrument(false)
				# Song bank: the MIDI's own channel if its slot is free, else the first free slot.
				var slot := _free_slot(t.channels[0] if t.channels.size() == 1 else -1)
				if slot >= 0:
					part.channel = slot
					ins = _slot_ins[slot]
				part.program = ins.Program if ins else 0
				part.bank = ins.Bank if ins else 0
				if ins and song.BankSet:
					part.instrument = ins.get_meta(&"n64_name", ins.Name)
			if drums and song.BankSet and _first_instrument(true):
				part.instrument = _first_instrument(true).get_meta(&"n64_name", "")
			song.Tracks.append(part)
	rebuild()


func _project_path(path: String) -> String:
	var local := ProjectSettings.localize_path(path)
	return local if local.begins_with("res://") else path


func _free_channel() -> int:
	var used := {}
	for t in song.Tracks:
		used[int(t.get("channel", -1))] = true
	for ch in 16:
		if ch != 9 and not used.has(ch):
			return ch
	return 0


## CD64 song-bank slots (N64Cd64Importer tags; EXPORT_FORMAT.md "Song banks"): song-bank
## sidecars give each instrument its channel (metadata cd64_channel, 1-16). Exports from
## before that: the instruments of one export that all sit at bank 0, program = channel - 1
## (0-15), the drum kit (if any) at channel 10; any instrument breaking that, and its
## export is an ordinary set: no slots.
func _find_slots() -> void:
	_slot_of.clear()
	_slot_ins.clear()
	var b = _bank()
	if b == null:
		return
	var by_export := {}
	for ins in b.Instruments:
		if ins and ins.has_meta(&"cd64_export"):
			var tag: String = ins.get_meta(&"cd64_export")
			if not by_export.has(tag):
				by_export[tag] = []
			by_export[tag].append(ins)
	for tag in by_export:
		var slots := {}
		var given: Array = by_export[tag].filter(func(i): return i.has_meta(&"cd64_channel"))
		for ins in given:
			slots[int(ins.get_meta(&"cd64_channel")) - 1] = ins
		for ins in by_export[tag] if given.is_empty() else []:
			if ins.Bank != 0 or ins.Program > 15 or ins.IsDrumKit != (ins.Program == 9) or slots.has(ins.Program):
				slots = {}
				break
			slots[ins.Program] = ins
		for ch in slots:
			if not _slot_ins.has(ch):  # two song banks in one bank: the first one's
				_slot_ins[ch] = slots[ch]
				_slot_of[slots[ch]] = ch
	_slot_ins.sort()


## A song-bank channel no part uses yet (`want` if free), or -1. Not the drum channel.
func _free_slot(want: int) -> int:
	_find_slots()
	var used := {}
	for t in song.Tracks:
		used[int(t.get("channel", -1))] = true
	if want >= 0 and want != 9 and _slot_ins.has(want) and not used.has(want):
		return want
	for ch in _slot_ins:
		if ch != 9 and not used.has(ch):
			return ch
	return -1


func _first_instrument(drums: bool):
	var b = _bank()
	if b:
		for ins in b.Instruments:
			if ins and ins.IsDrumKit == drums:
				return ins
	return null


func _bank():
	if song and song.BankSet:
		return song.BankSet.SoundBank
	if song and song.Bank:
		return song.Bank
	return workspace.bank if workspace and not workspace.library_mode else null


func _rebuild_parts() -> void:
	for c in _parts.get_children():
		c.queue_free()
	for h in ["", "Part", "Ch", "Instrument", "Volume", "Pan", "Repeat", ""]:
		var l := _label(h)
		l.modulate = Color(1, 1, 1, 0.55)
		_parts.add_child(l)
	var b = _bank()
	_find_slots()
	for i in song.Tracks.size():
		var t: Dictionary = song.Tracks[i]
		var mute := CheckBox.new()
		mute.button_pressed = not t.get("mute", false)
		mute.tooltip_text = "Play this part"
		mute.toggled.connect(func(on): _part(i, &"mute", not on))
		_parts.add_child(mute)
		var name_l := _label("%s%s" % [t.get("name", String(t.path).get_file()), "" if int(t.get("midi_track", -1)) < 0 else " (track %d)" % t.midi_track])
		name_l.tooltip_text = t.path
		name_l.size_flags_horizontal = SIZE_EXPAND_FILL
		name_l.clip_text = true
		name_l.custom_minimum_size.x = 120
		_parts.add_child(name_l)
		var ch := _spin(1, 16, 1)
		ch.value = int(t.get("channel", 0)) + 1
		ch.editable = not t.get("drums", false)
		ch.tooltip_text = "MIDI channel (drum kits play on 10)"
		ch.value_changed.connect(func(v): _part_channel(i, int(v) - 1))
		_parts.add_child(ch)
		var inst := OptionButton.new()
		inst.fit_to_longest_item = false
		inst.custom_minimum_size.x = 160
		var sel := -1
		if b:
			# Song-bank slots first, by channel.
			var listed: Array = _slot_ins.values()
			for ins in b.Instruments:
				if ins and not _slot_of.has(ins):
					listed.append(ins)
			for ins in listed:
				if _slot_of.has(ins):
					inst.add_item("ch %d: %s%s" % [_slot_of[ins] + 1, "🥁 " if ins.IsDrumKit else "", ins.Name])
				else:
					inst.add_item("%s %03d %s" % ["🥁" if ins.IsDrumKit else "♪", ins.Program, ins.Name])
				inst.set_item_metadata(inst.item_count - 1, ins)
				var match_drum: bool = t.get("drums", false) == ins.IsDrumKit
				if song.BankSet and t.has("instrument"):
					if ins.get_meta(&"n64_name", "") == t.instrument:
						sel = inst.item_count - 1
				elif match_drum and int(t.get("program", 0)) == ins.Program and (ins.IsDrumKit or int(t.get("bank", 0)) == ins.Bank):
					sel = inst.item_count - 1
				elif match_drum and ins.IsDrumKit and sel < 0 and not t.has("program"):
					sel = inst.item_count - 1
		# Bank set: the library's other instruments, added to the set when picked.
		var lib = workspace.bank if song.BankSet and workspace and workspace.library_mode else null
		if lib:
			var first := true
			for ins in lib.Instruments:
				if song.BankSet.Has(ins) or ins.IsDrumKit != t.get("drums", false):
					continue
				if first:
					inst.add_separator()
					first = false
				inst.add_item("+ add: %s%s" % ["[kit] " if ins.IsDrumKit else "", ins.Name])
				inst.set_item_metadata(inst.item_count - 1, {add = ins})
		if inst.item_count == 0:
			inst.add_item("(open a bank)" if song.BankSet == null else "(the bank set is empty)")
		inst.select(sel)
		# A slot's instrument on another channel plays, but not what CD64 previewed there.
		var picked = inst.get_item_metadata(sel) if sel >= 0 else null
		if picked and _slot_of.has(picked) and _slot_of[picked] != int(t.get("channel", 0)):
			inst.add_theme_color_override(&"font_color", Color(1, 0.75, 0.45))
			inst.tooltip_text = "CD64 previewed %s on channel %d; this part plays it on channel %d." % [
				picked.Name, _slot_of[picked] + 1, int(t.get("channel", 0)) + 1]
		inst.item_selected.connect(func(k): _part_picked(i, inst.get_item_metadata(k)))
		_parts.add_child(inst)
		var vol := HSlider.new()
		vol.min_value = 0.0
		vol.max_value = 1.0
		vol.step = 0.01
		vol.value = float(t.get("volume", 0.79))
		vol.custom_minimum_size.x = 80
		vol.drag_ended.connect(func(_c): _part(i, &"volume", vol.value))
		_parts.add_child(vol)
		var pan := HSlider.new()
		pan.min_value = -1.0
		pan.max_value = 1.0
		pan.step = 0.05
		pan.value = float(t.get("pan", 0.0))
		pan.custom_minimum_size.x = 60
		pan.drag_ended.connect(func(_c): _part(i, &"pan", pan.value))
		_parts.add_child(pan)
		var rep := CheckBox.new()
		rep.button_pressed = t.get("repeat", false)
		rep.tooltip_text = "Repeat to the song's length (a 1-bar drum loop under a longer melody)"
		rep.toggled.connect(func(on): _part(i, &"repeat", on))
		_parts.add_child(rep)
		var del := _btn(_parts, "✕", func(): song.Tracks.remove_at(i); rebuild())
		del.tooltip_text = "Remove the part"


func _part(i: int, key: StringName, value: Variant) -> void:
	if _updating:
		return
	song.Tracks[i][key] = value
	rebuild()


## A picked list item: an instrument of the bank (set), or a library one to add to the set.
func _part_picked(i: int, meta) -> void:
	if meta is Dictionary and meta.has("add") and song.BankSet:
		song.BankSet.Add(meta.add)
		if workspace:
			workspace.save_set(song.BankSet)
		for ins in song.BankSet.SoundBank.Instruments:
			if ins.get_meta(&"n64_name", "") == meta.add.Name:
				_part_instrument(i, ins)
				return
		return
	_part_instrument(i, meta)


func _part_instrument(i: int, ins) -> void:
	if ins == null or ins is Dictionary:
		return
	var t: Dictionary = song.Tracks[i]
	t.drums = ins.IsDrumKit
	t.program = ins.Program
	t.bank = ins.Bank
	if song.BankSet and ins.has_meta(&"n64_name"):
		t.instrument = ins.get_meta(&"n64_name")
	else:
		t.erase("instrument")
	if ins.IsDrumKit:
		t.channel = 9
	elif _slot_of.has(ins):
		t.channel = _slot_of[ins]  # a song-bank slot: its channel
	elif int(t.get("channel", 0)) == 9:
		t.channel = _free_channel()
	rebuild()


## A part playing a song-bank slot follows the channel to that channel's slot.
func _part_channel(i: int, channel: int) -> void:
	if _updating:
		return
	var t: Dictionary = song.Tracks[i]
	t.channel = channel
	var cur = _slot_ins.get(int(t.get("program", -1))) if not t.get("drums", false) else null
	if cur and int(t.get("bank", 0)) == 0 and _slot_ins.has(channel) and not _slot_ins[channel].IsDrumKit:
		t.program = _slot_ins[channel].Program
		t.bank = 0
		if song.BankSet and _slot_ins[channel].has_meta(&"n64_name"):
			t.instrument = _slot_ins[channel].get_meta(&"n64_name")
	rebuild()


# --- Display -----------------------------------------------------------------------------

func refresh() -> void:
	if song == null:
		return
	_updating = true
	_name.text = song.Name
	_loop_midi.set_pressed_no_signal(song.LoopFromMidi)
	_loop_start.set_value_no_signal(0.0 if song.LoopStart < 0 else song.LoopStart / _bar_seconds() + 1.0)
	_loop_end.set_value_no_signal(0.0 if song.LoopEnd < 0 else song.LoopEnd / _bar_seconds() + 1.0)
	if song.BankSet:
		_bank_label.text = "Bank set: %s (%.1f KB)" % [song.BankSet.Name, song.BankSet.StoredBytes() / 1024.0]
	else:
		_bank_label.text = "Bank: %s" % (song.Bank.resource_path.get_file() if song.Bank else "(the open bank / the player's)")
	var ev: int = song.Events.size()
	_info.text = "%s · %.1f s · %d BPM %d/4 · %d events%s" % [_bar_text(song.Length, true), song.Length, roundi(song.Bpm),
		song.BeatsPerBar, ev, " · loops %s → %s" % [_bar_text(song.LoopStart), _bar_text(song.EffectiveLoopEnd)] if song.Loops else " · plays once"]
	_cache_notes()
	_rebuild_parts()
	_updating = false
	_overview.queue_redraw()


func _bar_seconds() -> float:
	return 60.0 / maxf(song.Bpm, 1.0) * maxi(song.BeatsPerBar, 1)


## "bar 3.2" (bar.beat, 1-based; the first tempo's bars).
func _bar_text(seconds: float, length := false) -> String:
	var beat := seconds / (60.0 / maxf(song.Bpm, 1.0))
	if length:
		return "%.1f bars" % (beat / maxi(song.BeatsPerBar, 1))
	var bar := floori(beat / maxi(song.BeatsPerBar, 1))
	return "bar %d.%d" % [bar + 1, floori(fmod(beat, maxi(song.BeatsPerBar, 1))) + 1]


func _cache_notes() -> void:
	_notes.clear()
	var times: PackedFloat64Array = song.Times
	var evs: PackedInt32Array = song.Events
	var open := {}  # (ch, key) -> start
	for i in mini(times.size(), evs.size()):
		var e := evs[i]
		var type := (e >> 28) & 15
		var ch := (e >> 24) & 15
		var key := (e >> 16) & 0xFF
		if type == 1:
			open[ch * 128 + key] = times[i]
		elif type == 2 and open.has(ch * 128 + key):
			if not _notes.has(ch):
				_notes[ch] = []
			_notes[ch].append([open[ch * 128 + key], times[i], key])
			open.erase(ch * 128 + key)


func _draw_overview() -> void:
	var r := Rect2(Vector2.ZERO, _overview.size)
	_overview.draw_rect(r, Color(0.09, 0.095, 0.11))
	if song == null or song.Length <= 0.0:
		return
	var px: float = r.size.x / song.Length
	if song.Loops:
		_overview.draw_rect(Rect2(song.LoopStart * px, 0, (song.EffectiveLoopEnd - song.LoopStart) * px, r.size.y), Color(0.3, 0.75, 0.35, 0.12))
	# Bar lines.
	var bar := _bar_seconds()
	var t := 0.0
	while t < song.Length:
		_overview.draw_line(Vector2(t * px, 0), Vector2(t * px, r.size.y), Color(1, 1, 1, 0.06))
		t += bar
	var chans := _notes.keys()
	chans.sort()
	var rows := maxi(chans.size(), 1)
	var row_h := r.size.y / rows
	for ri in chans.size():
		var ch: int = chans[ri]
		var y0 := ri * row_h
		var col: Color = CH_COLORS[ch % CH_COLORS.size()]
		_overview.draw_string(get_theme_default_font(), Vector2(3, y0 + 12), "ch %d" % (ch + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(col, 0.7))
		var lo := 127
		var hi := 0
		for n in _notes[ch]:
			lo = mini(lo, n[2])
			hi = maxi(hi, n[2])
		var span := maxf(hi - lo, 1.0)
		for n in _notes[ch]:
			# Single-key parts (a kick) sit mid-row.
			var y: float = y0 + row_h * 0.5 if hi == lo else y0 + 3 + (1.0 - (n[2] - lo) / span) * (row_h - 8)
			_overview.draw_rect(Rect2(n[0] * px, y, maxf((n[1] - n[0]) * px, 2.0), 3), col)
	if song.Loops:
		for x in [song.LoopStart * px, song.EffectiveLoopEnd * px]:
			_overview.draw_line(Vector2(x, 0), Vector2(x, r.size.y), Color(0.4, 0.95, 0.45), 2.0)
	if _player:
		var x: float = _player.GetPosition() * px
		_overview.draw_line(Vector2(x, 0), Vector2(x, r.size.y), Color(1, 1, 1, 0.9), 1.5)


func _overview_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and song and song.Length > 0.0:
		_seek(mb.position.x / _overview.size.x * song.Length)


# --- Playback ----------------------------------------------------------------------------

func _toggle_play() -> void:
	if _player and _player.IsPlaying():
		_stop()
	else:
		_play(_player.GetPosition() if _player and _player.GetPosition() < song.Length - 0.05 else 0.0)


func _play(from: float) -> void:
	_ensure_tools()
	if _player == null or song == null:
		return
	var b = _bank()
	if b == null:
		_status.text = "Open a bank (or link one: Use open bank) to hear the song."
		return
	_player.Bank = b
	_player.Play(song, 0.0, from)


func _stop() -> void:
	if _player:
		_player.Stop(0.15)


func _seek(seconds: float) -> void:
	if _player == null or song == null:
		return
	if _player.IsPlaying():
		_player.Seek(seconds)
	else:
		_play(seconds)
		_player.Stop()
		_player.Seek(seconds)


# --- Widgets -------------------------------------------------------------------------------

func _btn(parent: Control, text: String, fn: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(fn)
	parent.add_child(b)
	return b


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _spin(lo: float, hi: float, step: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	return s
