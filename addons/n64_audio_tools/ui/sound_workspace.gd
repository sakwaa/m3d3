@tool
extends VBoxContainer
## "N64 Sounds" main-screen workspace (beside 2D / 3D / Script): edits one sound bank
## (N64SoundBank, res://audio/banks/*.res), laid out like Polyphone:
##  - toolbar: new / open / save bank, import recordings or a CD64 bank, bank size against
##    the sample RAM budget (Project Settings > n64/audio/bank_budget_kb);
##  - left tree: the bank's samples and instruments (with the sample bytes each plays);
##  - centre: the selected item's editor (samples: a zoomable waveform with draggable
##    cut and loop markers + processing settings + A/B playback);
##  - bottom: a keyboard that plays the selected sample at any pitch.
## Samples keep their recording's path and settings, so they can be re-processed any time
## (re-processing updates the sample in place).
## Library (toolbar > Library): the same workspace on the instrument library (N64Library,
## Project Settings > n64/audio/library_path) instead of one bank: the tree lists its
## instruments (with the samples each plays, the sets using it), all samples, the bank sets
## (N64BankSet: what one song / area loads, with its RAM) and the areas (N64AudioArea: the
## sets an area loads, worst-case RAM against the budget). Samples several instruments play
## are re-processed only after asking (change all of them, or fork a copy for the
## instrument it was opened from); Save merges samples that end up identical.

const BANK_DIR := "res://audio/banks"
const InstrumentEditor := preload("res://addons/n64_audio_tools/ui/instrument_editor.gd")
const SongEditor := preload("res://addons/n64_audio_tools/ui/song_editor.gd")
const BankSetEditor := preload("res://addons/n64_audio_tools/ui/bank_set_editor.gd")
const AreaEditor := preload("res://addons/n64_audio_tools/ui/area_editor.gd")
const RATES := [8000, 11025, 16000, 22050, 32000]
const DEFAULTS := {start = 0.0, end = -1.0, fade_ms = 0.0, rate = 16000, lowpass = 0.0, trim = true, normalize = true,
	gain_db = 0.0, bits = 16, predictors = 4, loop = "none", loop_start = -1.0, loop_end = -1.0, crossfade_ms = 0.0,
	root_key = -1, tune_cents = 0.0}
## Sample RAM a bank may use (ADPCM + books, N64SoundBank.StoredBytes), in KB: the toolbar
## turns yellow past 80 % and red past it. Registered by plugin.gd.
const BUDGET_SETTING := "n64/audio/bank_budget_kb"
const DEFAULT_BUDGET_KB := 512
## Folder of the instrument library (N64Library.PathSetting). Registered by plugin.gd.
const LIBRARY_SETTING := "n64/audio/library_path"
const DEFAULT_LIBRARY := "res://audio/library"
const CUT_COLOR := Color(1.0, 0.55, 0.25)

var bank: Resource  # N64SoundBank (in library mode: the N64Library)
var bank_path := ""
var dirty := false
## Editing the instrument library rather than a bank.
var library_mode := false

var _bank_label: Label
var _tree: Tree
var _editor_stack: Control
var _sample_editor: Control
var _empty_label: Label
var _wave: Control
var _grid: GridContainer
var _name: LineEdit
var _source_label: Label
var _info: Label
var _keyboard: Control
var _player: AudioStreamPlayer
var _timer: Timer
var _open_dialog: EditorFileDialog
var _save_dialog: EditorFileDialog
var _import_dialog: EditorFileDialog
var _cd64_dialog: EditorFileDialog
var _cd64_confirm: ConfirmationDialog
var _cd64_path := ""  # export waiting for "update existing bank?" / "into which bank?"
var _cd64_target := ""  # bank the dialog's OK imports it into
var _cd64_own_button: Button  # the dialog's "Own bank"
var _cd64_open_button: Button  # ... "Into open bank" (when another legacy bank is open)
var _fields := {}  # setting -> control
var _updating := false

var _selected: Resource  # N64Sample
var _instrument: Resource  # N64Instrument being edited
var _inst_editor: Control
## Instrument previews play through the game's synth (N64Synth), so they sound exactly
## like the game. Made on first use (C# loads after the plugin).
var _synth: Node
var _synth_notes := {}  # key -> voice id
## The open song (N64Song, res://audio/songs/*.tres): its parts are MIDI files; it plays
## with this bank (or the bank it links to).
var song: Resource
var song_path := ""
var _song_editor: Control
var _song_shown := false
var _song_dialog: EditorFileDialog
var _song_new := false
var _export_dialog: EditorFileDialog
var _export_sfz := false
var _procs := {}  # sample -> N64AudioProcessor with its recording loaded (or false)
var _view_start := 0.0  # waveform view, in seconds
var _view_len := 1.0
var _drag := ""  # "", "pan", "loop_start", "loop_end", "cut_start", "cut_end"
var _drag_from := Vector2.ZERO
var _drag_view := 0.0
var _play_started := 0
var _play_pitch := 1.0
var _play_n64 := true
var _pressed_key := -1
var _tools: Object  # N64LibraryTools (library mode)
var _sets: Array = []  # the library's bank sets
var _areas: Array = []
var _set_editor: Control
var _area_editor: Control
var _set: Resource  # bank set being edited
var _area: Resource  # area being edited
var _ctx_instrument: Resource  # the instrument a selected sample was opened under (tree)
var _snapshot := {}  # the selected sample's settings as last processed (shared-sample check)
var _snapshot_loop := Vector2i.ZERO
var _snap_for: Resource
var _shared_ok := {}  # shared samples the user agreed to re-process for everyone
var _shared_dialog: ConfirmationDialog
var _fork_button: Button
var _bank_buttons: Array = []  # toolbar buttons of bank mode only
var _lib_buttons: Array = []  # ... of library mode only
var _lib_export_dialog: EditorFileDialog
var _lib_export_names := PackedStringArray()
var _lib_export_name := ""
var _lib_export_ask: ConfirmationDialog
var _lib_export_sel: Button  # its "Only <selection>"


func _init() -> void:
	name = "N64 Sounds"
	size_flags_vertical = SIZE_EXPAND_FILL
	var s := EditorInterface.get_editor_scale()
	# Toolbar.
	var bar := HFlowContainer.new()
	add_child(bar)
	var lib_btn := _btn(bar, "Library", open_library)
	lib_btn.tooltip_text = "The instrument library: every instrument and sample, the bank sets songs and areas load, the areas' RAM"
	_btn(bar, "New bank", _new_bank)
	_btn(bar, "Open…", func(): _dialog_open())
	_btn(bar, "Save", _save)
	_bank_buttons.append(_btn(bar, "Save as…", func(): _dialog_save()))
	var conv := _btn(bar, "Convert bank to library", convert_bank)
	_bank_buttons.append(conv)
	conv.tooltip_text = "Copy this bank's samples and instruments into the library (shared where it has them already) and make a bank set with its programs. The bank itself is not changed."
	bar.add_child(VSeparator.new())
	_btn(bar, "Import recordings…", func(): _dialog_import())
	_btn(bar, "Import CD64 bank…", func(): _dialog_import_cd64())
	_btn(bar, "New instrument", func(): _new_instrument(false))
	_btn(bar, "New drum kit", func(): _new_instrument(true))
	var dup := _btn(bar, "Duplicate as variant", duplicate_variant)
	_lib_buttons.append(dup)
	dup.tooltip_text = "A new instrument with the selected one's settings and samples (no extra RAM until you re-process its samples: they are forked then)"
	_btn(bar, "Delete", _delete_selected)
	bar.add_child(VSeparator.new())
	_lib_buttons.append(_btn(bar, "New bank set", new_set))
	_lib_buttons.append(_btn(bar, "New area", new_area))
	_lib_buttons.append(_btn(bar, "Export library for CD64…", func(): _dialog_export_library()))
	bar.add_child(VSeparator.new())
	_btn(bar, "Export SF2…", func(): _dialog_export(false))
	_btn(bar, "Export SFZ…", func(): _dialog_export(true))
	bar.add_child(VSeparator.new())
	_btn(bar, "New song…", func(): _dialog_song(true))
	_btn(bar, "Open song…", func(): _dialog_song(false))
	bar.add_child(VSeparator.new())
	_bank_label = Label.new()
	_bank_label.mouse_filter = Control.MOUSE_FILTER_PASS  # tooltip: what each instrument takes
	bar.add_child(_bank_label)

	var split := HSplitContainer.new()
	split.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(split)
	_tree = Tree.new()
	_tree.custom_minimum_size.x = 240 * s
	_tree.hide_root = true
	_tree.item_selected.connect(_on_tree_selected)
	split.add_child(_tree)
	_editor_stack = MarginContainer.new()
	_editor_stack.size_flags_horizontal = SIZE_EXPAND_FILL
	split.add_child(_editor_stack)
	_empty_label = Label.new()
	_empty_label.text = "Open or create a sound bank, then import recordings (WAV).\nSelect a sample to edit it; the keyboard below plays it."
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_label.modulate = Color(1, 1, 1, 0.6)
	_editor_stack.add_child(_empty_label)
	_build_sample_editor()
	_song_editor = SongEditor.new()
	_song_editor.workspace = self
	_song_editor.visible = false
	_editor_stack.add_child(_song_editor)
	_inst_editor = InstrumentEditor.new()
	_inst_editor.workspace = self
	_inst_editor.visible = false
	_editor_stack.add_child(_inst_editor)
	_set_editor = BankSetEditor.new()
	_set_editor.workspace = self
	_set_editor.visible = false
	_editor_stack.add_child(_set_editor)
	_area_editor = AreaEditor.new()
	_area_editor.workspace = self
	_area_editor.visible = false
	_editor_stack.add_child(_area_editor)

	_keyboard = Control.new()
	_keyboard.custom_minimum_size.y = 90 * s
	_keyboard.draw.connect(_draw_keyboard)
	_keyboard.gui_input.connect(_keyboard_input)
	add_child(_keyboard)

	_player = AudioStreamPlayer.new()
	add_child(_player)
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = 0.25
	_timer.timeout.connect(_reprocess_selected)
	add_child(_timer)
	_refresh_tree()
	_update_mode_buttons()


## A bank to work on (made on first use: C# classes load after the editor builds this).
func _ensure_bank() -> bool:
	if bank == null:
		bank = _make(&"N64SoundBank")
		_refresh_tree()
	return bank != null


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and is_visible_in_tree():
		_ensure_bank()
	# Back from the DAW: rebuild the song if a part's MIDI was re-exported.
	if what == NOTIFICATION_APPLICATION_FOCUS_IN and song and _song_editor.rebuild_if_changed():
		_refresh_tree()


func _build_sample_editor() -> void:
	var s := EditorInterface.get_editor_scale()
	_sample_editor = VBoxContainer.new()
	_sample_editor.visible = false
	_editor_stack.add_child(_sample_editor)
	var head := HBoxContainer.new()
	_sample_editor.add_child(head)
	_name = LineEdit.new()
	_name.custom_minimum_size.x = 200 * s
	_name.text_changed.connect(func(t): if _selected and not _updating: _selected.Name = t; _mark_dirty(); _refresh_tree_names())
	head.add_child(_name)
	_btn(head, "▶ Original", func(): _play(false, -1))
	_btn(head, "▶ N64", func(): _play(true, -1))
	_btn(head, "■", func(): _player.stop())
	_btn(head, "Zoom to fit", func(): _fit_view(); _wave.queue_redraw())
	_source_label = Label.new()
	_source_label.modulate = Color(1, 1, 1, 0.6)
	_source_label.size_flags_horizontal = SIZE_EXPAND_FILL
	_source_label.clip_text = true
	_source_label.custom_minimum_size.x = 40
	head.add_child(_source_label)
	var body := HSplitContainer.new()
	body.size_flags_vertical = SIZE_EXPAND_FILL
	_sample_editor.add_child(body)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = SIZE_EXPAND_FILL
	body.add_child(left)
	_wave = Control.new()
	_wave.size_flags_vertical = SIZE_EXPAND_FILL
	_wave.custom_minimum_size = Vector2(300, 160) * s
	_wave.mouse_default_cursor_shape = Control.CURSOR_CROSS
	_wave.clip_contents = true
	_wave.draw.connect(_draw_wave)
	_wave.gui_input.connect(_wave_input)
	left.add_child(_wave)
	var hint := Label.new()
	hint.text = "Wheel zooms · right / middle drag pans · drag the orange cut markers on the recording (start / end) · drag the green loop markers (switches the loop to manual)"
	hint.modulate = Color(1, 1, 1, 0.5)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = 100
	left.add_child(hint)
	_info = Label.new()
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info.custom_minimum_size.x = 100
	left.add_child(_info)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.x = 310 * s
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(_grid)
	_field("start", "Start", _spin(0, 600, 0.001, " s"), "Where the sample begins in the recording (cut before anything else). Drag the orange marker on the waveform.")
	_field("end", "End", _spin(-1, 600, 0.001, " s"), "Where it ends in the recording. -1 = the recording's end. Loop times count from the sample's start (Start, plus any silence Trim removes).")
	_field("fade_ms", "Fade-out", _spin(0, 10000, 1, " ms"), "Linear fade over the last part of the sample. Ignored when looping.")
	var rate := OptionButton.new()
	for r in RATES:
		rate.add_item("%d Hz" % r)
	rate.tooltip_text = "Lower = smaller and more muffled. N64 instruments mostly sat at 8–22 kHz."
	_field("rate", "Rate", rate)
	_field("lowpass", "Low-pass", _spin(0, 16000, 100, " Hz"), "0 = just under the new rate's limit. Lower for a softer, darker tone.")
	_field("trim", "Trim silence", CheckBox.new())
	_field("normalize", "Normalise (-1 dB)", CheckBox.new())
	_field("gain_db", "Gain", _spin(-24, 24, 0.5, " dB"))
	_field("bits", "Bit depth", _spin(4, 16, 1, " bit"), "16 = off. Lower adds quantisation grit before ADPCM.")
	_field("predictors", "ADPCM book", _spin(1, 8, 1, " predictors"), "More predictors fit varied material better.")
	var loop := OptionButton.new()
	for l in ["None (one-shot)", "Auto (seamless points)", "Manual"]:
		loop.add_item(l)
	_field("loop", "Loop", loop)
	_field("loop_start", "Loop start", _spin(-1, 600, 0.001, " s"), "-1 = auto hint (40 % in). Drag the marker on the waveform.")
	_field("loop_end", "Loop end", _spin(-1, 600, 0.001, " s"), "-1 = auto hint (near the end). The sample is cut after the loop.")
	_field("crossfade_ms", "Crossfade", _spin(0, 200, 1, " ms"))
	_field("root_key", "Root key", _spin(-1, 127, 1, ""), "MIDI note of the recording. -1 = detect the pitch.")
	_field("tune_cents", "Tune", _spin(-100, 100, 1, " cents"))


# --- Bank ------------------------------------------------------------------------------------------

func _new_bank() -> void:
	_leave_library()
	bank = _make(&"N64SoundBank")
	bank_path = ""
	dirty = false
	_selected = null
	_procs.clear()
	_refresh_tree()
	_show_editor()


func _make(cls: StringName) -> Resource:
	var paths := {&"N64SoundBank": "res://game/audio/N64SoundBank.cs", &"N64Sample": "res://game/audio/N64Sample.cs",
		&"N64Instrument": "res://game/audio/N64Instrument.cs", &"N64BankSet": "res://game/audio/N64BankSet.cs",
		&"N64AudioArea": "res://game/audio/N64AudioArea.cs"}
	var script = load(paths[cls])
	return script.new() if script and script.can_instantiate() else null


func open_bank(path: String) -> void:
	var b = load(path)
	if b == null or not "Samples" in b:
		push_warning("N64 Sounds: %s isn't a sound bank." % path)
		return
	if b.get_script() and b.get_script().resource_path.ends_with("N64Library.cs"):
		open_library()
		return
	_leave_library()
	bank = b
	bank_path = path
	dirty = false
	_selected = null
	_procs.clear()
	_refresh_tree()
	_show_editor()


func _save() -> void:
	if not _ensure_bank():
		return
	if library_mode:
		_save_library()
		return
	if bank_path.is_empty():
		_dialog_save()
		return
	DirAccess.make_dir_recursive_absolute(bank_path.get_base_dir())
	var err := ResourceSaver.save(bank, bank_path)
	if err == OK:
		dirty = false
		bank.take_over_path(bank_path)
		EditorInterface.get_resource_filesystem().scan()
	else:
		push_error("N64 Sounds: saving %s failed (%s)." % [bank_path, error_string(err)])
	_refresh_label()


func _mark_dirty() -> void:
	dirty = true
	_refresh_label()


func mark_dirty() -> void:
	_mark_dirty()


## Rebuilds the tree keeping the current selection (names changed).
func refresh_tree_keep() -> void:
	_refresh_tree()


func _refresh_label() -> void:
	if bank == null:
		_bank_label.text = "Build the C# project (Build, top right), then reopen this tab."
		return
	if library_mode:
		var total := 0
		for s in bank.Samples:
			total += s.StoredBytes()
		_bank_label.text = "  Library %s%s  |  %d instruments, %d samples (%.1f KB in all)  |  %d bank sets, %d areas" % [
			_tools.Root if _tools else "", " *" if dirty else "", bank.Instruments.size(), bank.Samples.size(), total / 1024.0, _sets.size(), _areas.size()]
		var over := _areas.filter(func(a): return a.WorstCaseBytes() > budget_bytes()).map(func(a): return a.Name)
		over.append_array(_sets.filter(func(st): return st.StoredBytes() > budget_bytes()).map(func(st): return "set " + st.Name))
		if not over.is_empty():
			_bank_label.text += "  |  OVER BUDGET: " + ", ".join(over)
		_bank_label.add_theme_color_override(&"font_color", Color(1, 0.4, 0.35) if not over.is_empty() else Color(1, 1, 1))
		_bank_label.tooltip_text = "The library holds every instrument; songs and areas load bank sets (Project Settings > %s, budget %s)." % [LIBRARY_SETTING, BUDGET_SETTING]
		return
	var used: int = bank.StoredBytes()
	var budget := budget_bytes()
	_bank_label.text = "  %s%s  ·  %d samples, %d instruments  ·  %.1f / %d KB%s" % [
		bank_path.get_file() if bank_path else "(unsaved bank)", " *" if dirty else "",
		bank.Samples.size(), bank.Instruments.size(), used / 1024.0, budget / 1024,
		"  ·  ⚠ %.1f KB over budget" % ((used - budget) / 1024.0) if used > budget else ""]
	# Like the debug HUD's budgets: yellow past 80 %, red past 100 %.
	var col := Color(1, 0.4, 0.35) if used > budget else (Color(1, 0.85, 0.4) if used > budget * 0.8 else Color(1, 1, 1))
	_bank_label.add_theme_color_override(&"font_color", col)
	_bank_label.tooltip_text = budget_report(bank)


## Sample RAM budget of a bank, bytes (Project Settings > n64/audio/bank_budget_kb).
static func budget_bytes() -> int:
	return maxi(int(ProjectSettings.get_setting(BUDGET_SETTING, DEFAULT_BUDGET_KB)), 1) * 1024


## Bytes of the samples an instrument plays (each sample once).
static func instrument_bytes(ins) -> int:
	var seen := {}
	var n := 0
	for z in ins.Zones:
		var s = z.get("sample")
		if s and not seen.has(s):
			seen[s] = true
			n += s.StoredBytes()
	return n


## The bank's sample RAM against the budget, per instrument (the toolbar's tooltip).
static func budget_report(b) -> String:
	var used: int = b.StoredBytes()
	var budget := budget_bytes()
	var lines := PackedStringArray(["Sample RAM: %.1f KB of the %d KB budget (%d %%, Project Settings > %s)" % [
		used / 1024.0, budget / 1024, roundi(100.0 * used / budget), BUDGET_SETTING]])
	var played := {}
	for ins in b.Instruments:
		if ins == null:
			continue
		var n := instrument_bytes(ins)
		lines.append("  %s %03d %s: %.1f KB (%d %%)" % ["🥁" if ins.IsDrumKit else "♪", ins.Program, ins.Name, n / 1024.0, roundi(100.0 * n / maxi(used, 1))])
		for z in ins.Zones:
			if z.get("sample"):
				played[z.sample] = true
	var unused := 0
	for s in b.Samples:
		if s and not played.has(s):
			unused += s.StoredBytes()
	if unused > 0:
		lines.append("  no instrument plays: %.1f KB" % (unused / 1024.0))
	lines.append("Samples played by several instruments count for each.")
	return "\n".join(lines)


# --- Tree -------------------------------------------------------------------------------------------

func _refresh_tree() -> void:
	_tree.clear()
	var root := _tree.create_item()
	if song:
		var si := _tree.create_item(root)
		si.set_text(0, "♫ Song: %s" % song.Name)
		si.set_metadata(0, song)
		if _song_shown:
			si.select(0)
	if bank == null:
		_refresh_label()
		return
	if library_mode:
		_refresh_library_tree(root)
		_refresh_label()
		return
	var samples := _tree.create_item(root)
	samples.set_text(0, "Samples (%d)" % bank.Samples.size())
	samples.set_selectable(0, false)
	for i in bank.Samples.size():
		var s = bank.Samples[i]
		var it := _tree.create_item(samples)
		it.set_text(0, "%s   %s%s" % [s.Name, _note_name(s.RootKey), "  ⟲" if s.Loop else ""])
		it.set_metadata(0, s)
		_tag_tooltip(it, s)
		if s == _selected:
			it.select(0)
	var inst := _tree.create_item(root)
	inst.set_text(0, "Instruments (%d)" % bank.Instruments.size())
	inst.set_selectable(0, false)
	for s in bank.Instruments:
		var it := _tree.create_item(inst)
		it.set_text(0, "%s %03d  %s  (%d zones · %.1f KB)" % ["🥁" if s.IsDrumKit else "♪", s.Program, s.Name, s.Zones.size(),
			instrument_bytes(s) / 1024.0])
		it.set_metadata(0, s)
		_tag_tooltip(it, s)
		if s == _instrument:
			it.select(0)
	_refresh_label()


## Imported items name the CD64 export they came from (N64Cd64Importer tags them).
func _tag_tooltip(it: TreeItem, r: Resource) -> void:
	if r.has_meta(&"cd64_export"):
		it.set_tooltip_text(0, "From the CD64 export \"%s\" (re-importing it replaces this)" % r.get_meta(&"cd64_export"))


func _refresh_tree_names() -> void:
	var it := _tree.get_selected()
	if it and _selected:
		it.set_text(0, "%s   %s%s" % [_selected.Name, _note_name(_selected.RootKey), "  ⟲" if _selected.Loop else ""])


func _on_tree_selected() -> void:
	var it := _tree.get_selected()
	var meta = it.get_metadata(0) if it else null
	_song_shown = meta != null and "Events" in meta and "Tracks" in meta
	_selected = meta if meta and "Adpcm" in meta else null
	_instrument = meta if meta and "Zones" in meta else null
	_set = meta if meta and "Entries" in meta else null
	_area = meta if meta and "MusicSets" in meta else null
	# A sample listed under an instrument: forks of a shared sample go to that instrument.
	var parent = it.get_parent().get_metadata(0) if it and it.get_parent() else null
	_ctx_instrument = parent if _selected and parent and "Zones" in parent else null
	_show_editor()


func _show_editor() -> void:
	_song_editor.visible = _song_shown and song != null
	_sample_editor.visible = _selected != null and not _song_editor.visible
	_inst_editor.visible = _instrument != null and _selected == null and not _song_editor.visible
	_set_editor.visible = _set != null and not _song_editor.visible
	_area_editor.visible = _area != null and not _song_editor.visible
	_empty_label.visible = _selected == null and _instrument == null and _set == null and _area == null and not _song_editor.visible
	if _set_editor.visible:
		_set_editor.edit(_set)
	if _area_editor.visible:
		_area_editor.edit(_area)
	# The keyboard plays samples / instruments; songs have their own transport.
	_keyboard.visible = not _song_editor.visible
	if _inst_editor.visible:
		_inst_editor.edit(_instrument)
	if _selected:
		_load_settings()
		_fit_view()
		_update_info()
	# After _load_settings (it fills in missing defaults): what a cancelled change returns to.
	if _selected != _snap_for:
		_snap_for = _selected
		_take_snapshot()
	_wave.queue_redraw()
	_keyboard.queue_redraw()


# --- Import / processing -------------------------------------------------------------------------

func import_files(paths: PackedStringArray) -> void:
	if not _ensure_bank():
		push_warning("N64 Sounds: build the C# project first (Build, top right).")
		return
	var failed := PackedStringArray()
	var last = null
	for path in paths:
		var proc = _new_processor()
		if proc == null:
			push_warning("N64 Sounds: build the C# project first.")
			return
		var err: String = proc.LoadWav(path)
		if err != "":
			failed.append("%s (%s)" % [path.get_file(), err])
			continue
		var settings := DEFAULTS.duplicate()
		var s := _make(&"N64Sample")
		s.Name = path.get_file().get_basename().to_snake_case()
		s.SourcePath = path
		s.Settings = settings
		s.CopyFrom(proc.Process(settings))
		_procs[s] = proc
		bank.Samples.append(s)
		last = s
	if not failed.is_empty():
		push_warning("N64 Sounds: couldn't import " + ", ".join(failed))
	if last:
		_selected = last
		_mark_dirty()
	_refresh_tree()
	_show_editor()


## A CD64 export (folder or its .n64bank.json) goes into `target` (default: its own bank,
## res://audio/banks/<name>.res), its ADPCM carried over as is (plays exactly what the CD64
## plugin previewed). What it brings is tagged with the export's name, so importing the same
## export again updates only that, in place (N64Cd64Importer has the rules).
func import_cd64(path: String, target := "") -> void:
	if target == "library":
		import_cd64_library(path)
		return
	var imp = _new_cd64_importer()
	if imp == null:
		push_warning("N64 Sounds: build the C# project first.")
		return
	if target == "":
		target = imp.BankPathFor(path)
	var err: String = imp.Import(path, target)
	if err != "":
		push_error("N64 Sounds: CD64 import of %s failed: %s" % [path, err])
		return
	print("[N64 Sounds] %s" % imp.Summary)
	EditorInterface.get_resource_filesystem().scan()
	open_bank(target)


## A CD64 export into the instrument library (N64LibraryTools.ImportCd64): samples shared
## with the library where it has the same processing of the same recording, the export's
## instruments updated by name, and (song / sfx / plain exports) a bank set named after it.
func import_cd64_library(path: String) -> void:
	var t = _lib_tools()
	if t == null:
		push_warning("N64 Sounds: build the C# project first.")
		return
	if library_mode and dirty:
		_save_library()
	var err: String = t.ImportCd64(path)
	if err != "":
		push_error("N64 Sounds: CD64 import of %s into the library failed: %s" % [path, err])
		return
	print("[N64 Sounds] %s" % t.Summary)
	EditorInterface.get_resource_filesystem().scan()
	open_library()
	if t.LastSetPath != "":
		_select_meta(load(t.LastSetPath))


func _new_cd64_importer() -> Object:
	var script = load("res://addons/n64_audio_tools/cs/N64Cd64Importer.cs")
	return script.new() if script and script.can_instantiate() else null


func _new_processor() -> Object:
	var script = load("res://addons/n64_audio_tools/cs/N64AudioProcessor.cs")
	return script.new() if script and script.can_instantiate() else null


## The processor with this sample's recording loaded (null if the recording is missing).
func _proc(s) -> Object:
	if _procs.has(s):
		return _procs[s] if _procs[s] else null
	var p = _new_processor()
	if p and s.SourcePath != "" and p.LoadWav(s.SourcePath) == "":
		_procs[s] = p
		return p
	_procs[s] = false
	return null


func _reprocess_selected() -> void:
	var p = _proc(_selected) if _selected else null
	if p == null:
		return
	# Library: a sample other instruments play too changes only when the user says so.
	if library_mode and not _shared_ok.has(_selected) and _selected.Settings != _snapshot and bank.UsersOf(_selected).size() > 1:
		_ask_shared()
		return
	var t := Time.get_ticks_msec()
	_selected.CopyFrom(p.Process(_selected.Settings))
	_selected.set_meta(&"snr", p.AdpcmSnr(_selected))
	_selected.set_meta(&"ms", Time.get_ticks_msec() - t)
	_take_snapshot()
	_mark_dirty()
	_refresh_tree_names()
	_update_info()
	_wave.queue_redraw()
	_keyboard.queue_redraw()


func _delete_selected() -> void:
	if library_mode and (_set or _area):
		_lib_tools().DeleteFile(_set if _set else _area)
		_set = null
		_area = null
		_reload_sets()
		EditorInterface.get_resource_filesystem().scan()
		_refresh_tree()
		_show_editor()
		return
	if _instrument:
		bank.Instruments.erase(_instrument)
		_instrument = null
		_mark_dirty()
		_refresh_tree()
		_show_editor()
		return
	if _selected == null:
		return
	# Zones playing this sample go with it.
	for ins in bank.Instruments:
		for i in range(ins.Zones.size() - 1, -1, -1):
			if ins.Zones[i].get("sample") == _selected:
				ins.Zones.remove_at(i)
	bank.Samples.erase(_selected)
	_procs.erase(_selected)
	_selected = null
	_mark_dirty()
	_refresh_tree()
	_show_editor()


# --- Settings -------------------------------------------------------------------------------------

func _field(key: String, label: String, control: Control, tip := "") -> void:
	var l := Label.new()
	l.text = label
	_grid.add_child(l)
	control.size_flags_horizontal = SIZE_EXPAND_FILL
	control.tooltip_text = tip if tip else control.tooltip_text
	_grid.add_child(control)
	_fields[key] = control
	if control is OptionButton:
		control.item_selected.connect(func(_i): _setting_changed())
	elif control is CheckBox:
		control.toggled.connect(func(_on): _setting_changed())
	elif control is Range:
		control.value_changed.connect(func(_v): _setting_changed())


func _load_settings() -> void:
	var st: Dictionary = _selected.Settings
	for k in DEFAULTS:
		if not st.has(k):
			st[k] = DEFAULTS[k]
	_updating = true
	_name.text = _selected.Name
	for k in _fields:
		var c: Control = _fields[k]
		match k:
			"rate":
				c.select(maxi(RATES.find(int(st.rate)), 0))
			"loop":
				c.select(maxi(["none", "auto", "manual"].find(st.loop), 0))
			_:
				if c is CheckBox:
					c.button_pressed = st[k]
				else:
					c.value = st[k]
	var has_source := _proc(_selected) != null
	for c in _fields.values():
		if c is BaseButton:
			c.disabled = not has_source
		elif c is Range:
			c.editable = has_source
	_source_label.text = "  from %s" % _selected.SourcePath if has_source else "  recording missing: settings locked (%s)" % _selected.SourcePath
	_updating = false


func _setting_changed() -> void:
	if _updating or _selected == null:
		return
	var st: Dictionary = _selected.Settings
	for k in _fields:
		var c: Control = _fields[k]
		match k:
			"rate":
				st.rate = RATES[c.selected]
			"loop":
				st.loop = ["none", "auto", "manual"][c.selected]
			_:
				st[k] = c.button_pressed if c is CheckBox else (int(c.value) if k in ["bits", "predictors", "root_key"] else c.value)
	_timer.start()


func _update_info() -> void:
	if _selected == null:
		return
	var s = _selected
	var p = _proc(s)
	var src := "recording %.2f s @ %d Hz (%d KB as 16-bit)" % [p.SourceSeconds, p.SourceRate, p.SourceFrames * 2 / 1024] if p else "recording not found"
	if p and (_cut_start(s) > 0.0 or float(s.Settings.get("end", -1.0)) >= 0.0):
		src += " · cut %.3f–%.3f s" % [_cut_start(s), _cut_end(s, p.SourceSeconds)]
	_info.text = "%s\nN64: %.2f s @ %d Hz · root %s %+.0f c · %s · %.1f KB%s%s" % [
		src, s.Seconds(), s.SampleRate, _note_name(s.RootKey), s.TuneCents,
		"loop %.3f–%.3f s" % [s.LoopStart / float(s.SampleRate), s.LoopEnd / float(s.SampleRate)] if s.Loop else "one-shot",
		s.StoredBytes() / 1024.0,
		" · ADPCM %.0f dB SNR" % s.get_meta(&"snr") if s.has_meta(&"snr") else "",
		" · %d ms" % s.get_meta(&"ms") if s.has_meta(&"ms") else ""]


# --- Waveform ---------------------------------------------------------------------------------------

func _fit_view() -> void:
	var p = _proc(_selected) if _selected else null
	var secs: float = p.SourceSeconds if p else (_selected.Seconds() if _selected else 1.0)
	_view_start = 0.0
	_view_len = maxf(secs, 0.01)


func _x_of(t: float) -> float:
	return (t - _view_start) / _view_len * _wave.size.x


func _t_of(x: float) -> float:
	return _view_start + x / maxf(_wave.size.x, 1.0) * _view_len


func _draw_wave() -> void:
	var w := _wave
	var font := w.get_theme_default_font()
	w.draw_rect(Rect2(Vector2.ZERO, w.size), Color(0.09, 0.1, 0.12))
	if _selected == null:
		return
	var s = _selected
	var p = _proc(s)
	var ruler := 18.0
	var h := (w.size.y - ruler) * 0.5
	# Time ruler.
	# Ruler labels at least ~80 px apart: 1, 2 or 5 x a power of ten.
	var want := _view_len * 80.0 / maxf(w.size.x, 1.0)
	var mag := pow(10.0, floor(log(want) / log(10.0)))
	var step := mag * (1.0 if want <= mag else (2.0 if want <= mag * 2.0 else (5.0 if want <= mag * 5.0 else 10.0)))
	var t := ceilf(_view_start / step) * step
	while t < _view_start + _view_len:
		var x := _x_of(t)
		w.draw_line(Vector2(x, 0), Vector2(x, w.size.y), Color(1, 1, 1, 0.06))
		w.draw_string(font, Vector2(x + 3, 13), "%s s" % str(snappedf(t, step)), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.5))
		t += step
	var cols := maxi(int(w.size.x), 2)
	if p:
		# The recording, from the processor's min / max (whole file) re-sampled to the view.
		var full: PackedFloat32Array = p.SourceWaveform(4096)
		var secs: float = p.SourceSeconds
		var rec := Rect2(0, ruler, w.size.x, h - 2)
		_band(full, secs, rec, Color(0.55, 0.65, 0.85), "Recording")
		# The cut (start / end): what's left out is dimmed; the fade-out ramps down to the end.
		var cs := _x_of(_cut_start(s))
		var ce := _x_of(_cut_end(s, secs))
		w.draw_rect(Rect2(0, rec.position.y, maxf(cs, 0.0), rec.size.y), Color(0, 0, 0, 0.5))
		w.draw_rect(Rect2(ce, rec.position.y, maxf(w.size.x - ce, 0.0), rec.size.y), Color(0, 0, 0, 0.5))
		var fade := float(s.Settings.get("fade_ms", 0.0)) / 1000.0
		if fade > 0.0 and s.Settings.get("loop", "none") == "none":
			var fx := _x_of(maxf(_cut_end(s, secs) - fade, _cut_start(s)))
			w.draw_line(Vector2(fx, rec.position.y), Vector2(ce, rec.end.y), CUT_COLOR, 1.5)
		for x in [cs, ce]:
			w.draw_line(Vector2(x, rec.position.y), Vector2(x, rec.end.y), CUT_COLOR, 2.0)
			w.draw_rect(Rect2(x - 5, rec.end.y - 10, 10, 10), CUT_COLOR)
	# The N64 sample (cut / trimmed / looped), from the cut's start under the recording.
	var off := _n64_offset(s)
	var pcm: PackedByteArray = s.PcmBytes()
	var n := pcm.size() / 2
	var mm := PackedFloat32Array()
	mm.resize(cols * 2)
	var secs_n: float = s.Seconds()
	for c in cols:
		var t0 := _t_of(c) - off
		var t1 := _t_of(c + 1) - off
		var a := int(t0 * s.SampleRate)
		var b := maxi(a + 1, int(t1 * s.SampleRate))
		var lo := 0.0
		var hi := 0.0
		if a < n and b > 0:
			var stride := maxi((b - a) / 48, 1)
			for k in range(maxi(a, 0), mini(b, n), stride):
				var v := pcm.decode_s16(k * 2) / 32768.0
				lo = minf(lo, v)
				hi = maxf(hi, v)
		mm[c * 2] = lo
		mm[c * 2 + 1] = hi
	var band := Rect2(0, ruler + h + 2, w.size.x, h - 2)
	var mid := band.position.y + band.size.y * 0.5
	for c in cols:
		w.draw_line(Vector2(c, mid - mm[c * 2 + 1] * band.size.y * 0.5), Vector2(c, mid - mm[c * 2] * band.size.y * 0.5), Color(0.95, 0.75, 0.35))
	w.draw_string(font, band.position + Vector2(6, 14), "N64 (%d Hz)" % s.SampleRate, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.6))
	var end_x := _x_of(off + secs_n)
	w.draw_rect(Rect2(end_x, band.position.y, w.size.x - end_x, band.size.y), Color(0, 0, 0, 0.35))
	w.draw_rect(Rect2(0, band.position.y, maxf(_x_of(off), 0.0), band.size.y), Color(0, 0, 0, 0.35))
	if s.Loop:
		var xs := _x_of(off + s.LoopStart / float(s.SampleRate))
		var xe := _x_of(off + s.LoopEnd / float(s.SampleRate))
		w.draw_rect(Rect2(xs, band.position.y, xe - xs, band.size.y), Color(0.4, 1.0, 0.5, 0.07))
		for x in [xs, xe]:
			w.draw_line(Vector2(x, ruler), Vector2(x, w.size.y), Color(0.4, 1.0, 0.5), 2.0)
			w.draw_rect(Rect2(x - 5, ruler, 10, 10), Color(0.4, 1.0, 0.5))
	# Playhead.
	if _player.playing:
		var pt := _player.get_playback_position()
		if _play_n64 and s.Loop and pt * s.SampleRate >= s.LoopEnd:
			var span: float = (s.LoopEnd - s.LoopStart) / float(s.SampleRate)
			pt = s.LoopStart / float(s.SampleRate) + fmod(pt - s.LoopStart / float(s.SampleRate), maxf(span, 1e-4))
		var px := _x_of(pt + off if _play_n64 else pt)
		w.draw_line(Vector2(px, ruler), Vector2(px, w.size.y), Color(1, 0.35, 0.3), 1.5)


## The cut (settings start / end), in seconds of the recording.
func _cut_start(s) -> float:
	return maxf(float(s.Settings.get("start", 0.0)), 0.0)


func _cut_end(s, secs: float) -> float:
	var e := float(s.Settings.get("end", -1.0))
	return secs if e < 0.0 or e > secs else e


## Where the N64 sample starts on the recording's time line: the cut's start plus the
## silence Trim removes (times in the sample, like its loop, count from there). 0 without
## a recording.
func _n64_offset(s) -> float:
	var p = _proc(s)
	return p.SampleStartSeconds(s.Settings) if p else 0.0


func _band(full: PackedFloat32Array, secs: float, r: Rect2, col: Color, label: String) -> void:
	var buckets := full.size() / 2
	var mid := r.position.y + r.size.y * 0.5
	for c in int(r.size.x):
		var b := int(_t_of(c) / maxf(secs, 1e-6) * buckets)
		var b2 := maxi(b + 1, int(_t_of(c + 1) / maxf(secs, 1e-6) * buckets))
		if b < 0 or b >= buckets:
			continue
		var lo := 0.0
		var hi := 0.0
		for k in range(b, mini(b2, buckets)):
			lo = minf(lo, full[k * 2])
			hi = maxf(hi, full[k * 2 + 1])
		_wave.draw_line(Vector2(c, mid - hi * r.size.y * 0.5), Vector2(c, mid - lo * r.size.y * 0.5), col)
	_wave.draw_string(_wave.get_theme_default_font(), r.position + Vector2(6, 14), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.6))


func _wave_input(event: InputEvent) -> void:
	if _selected == null:
		return
	var mb := event as InputEventMouseButton
	if mb:
		if mb.pressed and mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var at := _t_of(mb.position.x)
			var f := 0.8 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.25
			_view_len = clampf(_view_len * f, 0.002, 600.0)
			_view_start = at - mb.position.x / maxf(_wave.size.x, 1.0) * _view_len
			_wave.queue_redraw()
		elif mb.pressed and mb.button_index in [MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			_drag = "pan"
			_drag_from = mb.position
			_drag_view = _view_start
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var p = _proc(_selected)
			# Cut markers on the recording (top half), loop markers on the N64 sample.
			if p and mb.position.y < 18.0 + (_wave.size.y - 18.0) * 0.5:
				for which in ["cut_start", "cut_end"]:
					var t := _cut_start(_selected) if which == "cut_start" else _cut_end(_selected, p.SourceSeconds)
					if absf(_x_of(t) - mb.position.x) < 8.0:
						_drag = which
			elif _selected.Loop:
				for which in ["loop_start", "loop_end"]:
					var smp: int = _selected.LoopStart if which == "loop_start" else _selected.LoopEnd
					if absf(_x_of(_n64_offset(_selected) + smp / float(_selected.SampleRate)) - mb.position.x) < 8.0:
						_drag = which
		elif not mb.pressed:
			if _drag.begins_with("loop") or _drag.begins_with("cut"):
				_timer.start()
			_drag = ""
		_wave.accept_event()
	var mm := event as InputEventMouseMotion
	if mm and _drag != "":
		if _drag == "pan":
			_view_start = _drag_view - (mm.position.x - _drag_from.x) / maxf(_wave.size.x, 1.0) * _view_len
		elif _drag.begins_with("cut"):
			# Dragging a cut marker: start / end at that time of the recording (dragged
			# onto the recording's end, the end follows it: -1).
			var st: Dictionary = _selected.Settings
			var secs: float = _proc(_selected).SourceSeconds
			var t := clampf(_t_of(mm.position.x), 0.0, secs)
			if _drag == "cut_start":
				st.start = clampf(t, 0.0, _cut_end(_selected, secs) - 0.01)
			else:
				st["end"] = -1.0 if _x_of(secs) - mm.position.x < 4.0 else maxf(t, _cut_start(_selected) + 0.01)
			_load_settings()
		else:
			# Dragging a loop marker: manual loop at that time.
			var st: Dictionary = _selected.Settings
			st.loop = "manual"
			st.loop_start = _selected.LoopStart / float(_selected.SampleRate)
			st.loop_end = _selected.LoopEnd / float(_selected.SampleRate)
			st[_drag] = maxf(_t_of(mm.position.x) - _n64_offset(_selected), 0.0)
			if _drag == "loop_start":
				_selected.LoopStart = int(st.loop_start * _selected.SampleRate)
			else:
				_selected.LoopEnd = int(st.loop_end * _selected.SampleRate)
			_load_settings()
		_wave.queue_redraw()
		_wave.accept_event()


# --- Playback / keyboard -----------------------------------------------------------------------------

## Plays the selected sample: the recording, or the N64 version at `note` (-1 = its root).
func _play(n64: bool, note: int) -> void:
	if _selected == null:
		return
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	var p = _proc(_selected)
	if n64 or p == null:
		stream.data = _selected.PcmBytes()
		stream.mix_rate = _selected.SampleRate
		if _selected.Loop:
			stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
			stream.loop_begin = _selected.LoopStart
			stream.loop_end = _selected.LoopEnd
	else:
		stream.data = p.SourcePcmBytes()
		stream.mix_rate = p.SourceRate
	_play_n64 = n64 or p == null
	var semis: float = 0.0 if note < 0 else (note - _selected.RootKey) - _selected.TuneCents / 100.0
	_play_pitch = pow(2.0, semis / 12.0) if note >= 0 else 1.0
	_player.stream = stream
	_player.pitch_scale = _play_pitch
	_player.play()


func _process(_delta: float) -> void:
	if _player.playing and is_visible_in_tree():
		_wave.queue_redraw()


const KEY_LO := 24  # C1
const KEY_HI := 108  # C8


func _white_keys() -> Array:
	var out := []
	for k in range(KEY_LO, KEY_HI + 1):
		if not posmod(k, 12) in [1, 3, 6, 8, 10]:
			out.append(k)
	return out


func _key_rects() -> Dictionary:
	var whites := _white_keys()
	var ww := _keyboard.size.x / whites.size()
	var h := _keyboard.size.y
	var out := {}
	for i in whites.size():
		out[whites[i]] = Rect2(i * ww, 0, ww, h)
	for k in range(KEY_LO, KEY_HI + 1):
		if posmod(k, 12) in [1, 3, 6, 8, 10]:
			var left: Rect2 = out[k - 1]
			out[k] = Rect2(left.end.x - ww * 0.32, 0, ww * 0.64, h * 0.6)
	return out


func _draw_keyboard() -> void:
	var kb := _keyboard
	var rects := _key_rects()
	var root: int = _selected.RootKey if _selected else -1
	# Instruments: keys that play something are tinted.
	var mapped := {}
	if _instrument and not _selected:
		for z in _instrument.Zones:
			for k in range(int(z.get("key_lo", 0)), int(z.get("key_hi", 127)) + 1):
				mapped[k] = true
	var font := kb.get_theme_default_font()
	for k in rects:
		if posmod(k, 12) in [1, 3, 6, 8, 10]:
			continue
		var col := Color(0.92, 0.92, 0.92) if mapped.is_empty() or mapped.has(k) else Color(0.6, 0.6, 0.62)
		if k == root:
			col = Color(0.55, 0.9, 0.6)
		if k == _pressed_key:
			col = Color(1.0, 0.75, 0.35)
		kb.draw_rect(rects[k], col)
		kb.draw_rect(rects[k], Color(0.2, 0.2, 0.2), false, 1.0)
		if posmod(k, 12) == 0:
			kb.draw_string(font, Vector2(rects[k].position.x + 2, rects[k].end.y - 4), _note_name(k), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0, 0, 0, 0.6))
	for k in rects:
		if not posmod(k, 12) in [1, 3, 6, 8, 10]:
			continue
		var col := Color(0.12, 0.12, 0.12) if mapped.is_empty() or mapped.has(k) else Color(0.3, 0.3, 0.32)
		if k == root:
			col = Color(0.3, 0.6, 0.35)
		if k == _pressed_key:
			col = Color(0.85, 0.55, 0.2)
		kb.draw_rect(rects[k], col)


func _keyboard_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			var rects := _key_rects()
			var hit := -1
			for k in rects:  # black keys sit on top
				if posmod(k, 12) in [1, 3, 6, 8, 10] and rects[k].has_point(mb.position):
					hit = k
			if hit < 0:
				for k in rects:
					if rects[k].has_point(mb.position):
						hit = k
			if hit >= 0:
				_pressed_key = hit
				if _instrument and not _selected:
					note_on(hit, 100)
				else:
					_play(true, hit)
		else:
			if _instrument and not _selected:
				note_off(_pressed_key)
			_pressed_key = -1
			if _selected and _selected.Loop:
				_player.stop()
		_keyboard.queue_redraw()


# --- Instruments --------------------------------------------------------------------------------

func _new_instrument(drums: bool) -> void:
	if not _ensure_bank():
		return
	var ins := _make(&"N64Instrument")
	ins.Name = "drum_kit" if drums else "instrument_%d" % (bank.Instruments.size() + 1)
	if library_mode:
		ins.Name = bank.UniqueName(ins.Name, null)
	ins.IsDrumKit = drums
	ins.Bank = 128 if drums else 0
	# Next free program number.
	var used := {}
	for i in bank.Instruments:
		used[Vector2i(i.Bank, i.Program)] = true
	while used.has(Vector2i(ins.Bank, ins.Program)) and ins.Program < 127:
		ins.Program += 1
	if drums:
		ins.Envelope = Vector4(0.001, 0.0, 1.0, 0.1)
	bank.Instruments.append(ins)
	_instrument = ins
	_selected = null
	_mark_dirty()
	_refresh_tree()
	_show_editor()


## Instrument preview: the note through the N64 synth (zones, envelope, vibrato, reverb).
func note_on(key: int, velocity: int) -> void:
	if _synth == null:
		var script = load("res://game/audio/N64Synth.cs")
		if script == null or not script.can_instantiate():
			return
		_synth = script.new()
		add_child(_synth)
	note_off(key)
	var id: int = _synth.PlayNote(_instrument, key, velocity, 1.0, 0.0)
	if id != 0:
		_synth_notes[key] = id


func note_off(key: int) -> void:
	if _synth and _synth_notes.has(key):
		_synth.StopNote(_synth_notes[key])
		_synth_notes.erase(key)


# --- Songs -------------------------------------------------------------------------------------

func _dialog_song(new: bool) -> void:
	_song_new = new
	if _song_dialog == null:
		_song_dialog = _make_dialog(EditorFileDialog.FILE_MODE_SAVE_FILE, EditorFileDialog.ACCESS_RESOURCES, "Song",
			"*.tres, *.res ; N64 songs", func(p): new_song(p) if _song_new else open_song(p))
	_song_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE if new else EditorFileDialog.FILE_MODE_OPEN_FILE
	_song_dialog.title = "New song" if new else "Open song"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SongEditor.SONG_DIR))
	_song_dialog.current_dir = SongEditor.SONG_DIR
	if new:
		_song_dialog.current_file = "new_song.tres"
	_song_dialog.popup_file_dialog()


## A new, empty song saved at `path` (then: Add MIDI parts).
func new_song(path: String) -> void:
	var script = load("res://game/audio/N64Song.cs")
	if script == null or not script.can_instantiate():
		push_warning("N64 Sounds: build the C# project first.")
		return
	var s = script.new()
	s.Name = path.get_file().get_basename()
	if library_mode and _set and _set.resource_path != "":
		s.BankSet = _set
	elif bank_path != "" and not library_mode:
		s.Bank = load(bank_path)
	var err := ResourceSaver.save(s, path)
	if err != OK:
		push_error("N64 Sounds: can't save %s (%s)." % [path, error_string(err)])
		return
	EditorInterface.get_resource_filesystem().update_file(path)
	open_song(path)


func open_song(path: String) -> void:
	var s = load(path)
	if s == null or not "Tracks" in s:
		push_warning("N64 Sounds: %s isn't a song." % path)
		return
	song = s
	song_path = path
	# A song linked to a bank opens that bank too (instruments for its parts); one playing a
	# bank set opens the library.
	if song.BankSet and not library_mode:
		open_library()
	elif not song.BankSet and song.Bank and song.Bank.resource_path != "" and song.Bank.resource_path != bank_path:
		open_bank(song.Bank.resource_path)
	_song_shown = true
	_selected = null
	_instrument = null
	_song_editor.edit(song, path)
	_song_editor.rebuild_if_changed()
	_refresh_tree()
	_show_editor()


# --- Export --------------------------------------------------------------------------------------

func _dialog_export(sfz: bool) -> void:
	if not _ensure_bank() or bank.Instruments.is_empty():
		push_warning("N64 Sounds: add an instrument first (exports contain instruments).")
		return
	_export_sfz = sfz
	if _export_dialog == null:
		_export_dialog = EditorFileDialog.new()
		_export_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
		_export_dialog.file_selected.connect(_export_to)
		_export_dialog.dir_selected.connect(_export_to)
		EditorInterface.get_base_control().add_child(_export_dialog)
	_export_dialog.clear_filters()
	if sfz:
		_export_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
		_export_dialog.title = "Export SFZ (choose a folder: one .sfz per instrument + samples/)"
	else:
		_export_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
		_export_dialog.add_filter("*.sf2", "SoundFont 2")
		_export_dialog.title = "Export SF2"
		_export_dialog.current_file = "%s.sf2" % (bank_path.get_file().get_basename() if bank_path else "bank")
	_export_dialog.popup_file_dialog()


func export_bank(path: String, sfz: bool) -> String:
	var script = load("res://addons/n64_audio_tools/cs/N64SoundFontExporter.cs")
	if script == null or not script.can_instantiate():
		return "build the C# project first"
	var ex = script.new()
	return ex.WriteSfz(bank, path) if sfz else ex.WriteSf2(bank, path)


func _export_to(path: String) -> void:
	var err := export_bank(path, _export_sfz)
	if err != "":
		push_error("N64 Sounds: export failed: %s" % err)
	else:
		print("[N64 Sounds] Exported %s to %s" % ["SFZ" if _export_sfz else "SF2", path])


# --- Library ----------------------------------------------------------------------------------------

## The instrument library's folder (Project Settings > n64/audio/library_path).
static func library_root() -> String:
	var p := str(ProjectSettings.get_setting(LIBRARY_SETTING, DEFAULT_LIBRARY))
	return (p if p != "" else DEFAULT_LIBRARY).trim_suffix("/")


func _lib_tools() -> Object:
	if _tools == null:
		var script = load("res://addons/n64_audio_tools/cs/N64LibraryTools.cs")
		if script == null or not script.can_instantiate():
			return null
		_tools = script.new()
	_tools.Root = library_root()
	return _tools


## Opens the instrument library (made on first save if there's none).
func open_library() -> void:
	var t = _lib_tools()
	if t == null:
		push_warning("N64 Sounds: build the C# project first (Build, top right).")
		return
	if library_mode and dirty:
		_save_library()
	bank = t.Load()
	bank_path = t.IndexPath
	library_mode = true
	dirty = false
	_selected = null
	_instrument = null
	_set = null
	_area = null
	_procs.clear()
	_shared_ok.clear()
	_reload_sets()
	_update_mode_buttons()
	_refresh_tree()
	_show_editor()


func _leave_library() -> void:
	if library_mode and dirty:
		_save_library()
	library_mode = false
	_set = null
	_area = null
	_update_mode_buttons()


func _update_mode_buttons() -> void:
	for b in _bank_buttons:
		b.visible = not library_mode
	for b in _lib_buttons:
		b.visible = library_mode


func _reload_sets() -> void:
	var t = _lib_tools()
	_sets = Array(t.LoadSets()) if t else []
	_areas = Array(t.LoadAreas()) if t else []


## The library's bank sets (the area editor's and song editor's lists).
func library_sets() -> Array:
	if _sets.is_empty() and _lib_tools():
		_reload_sets()
	return _sets


func _save_library() -> void:
	var t = _lib_tools()
	t.Summary = ""
	var err: String = t.Save(bank)
	if err != "":
		push_error("N64 Sounds: saving the library failed: %s" % err)
		return
	if t.Summary != "":
		print("[N64 Sounds] Library: %s" % t.Summary)
	dirty = false
	for st in _sets:
		st.Invalidate()
	EditorInterface.get_resource_filesystem().scan()
	_refresh_tree()


## Saves a bank set (its instruments must be library files: unsaved ones are saved first).
func save_set(st: Resource) -> void:
	var t = _lib_tools()
	for e in st.Entries:
		var ins = e.get("instrument")
		if ins and ins.resource_path == "":
			_save_library()
			break
	var err: String = t.SaveSet(st)
	if err != "":
		push_error("N64 Sounds: %s" % err)
	if not _sets.has(st):
		_sets.append(st)
	_refresh_tree()


func save_area(a: Resource) -> void:
	var err: String = _lib_tools().SaveArea(a)
	if err != "":
		push_error("N64 Sounds: %s" % err)
	if not _areas.has(a):
		_areas.append(a)
	_refresh_tree()


func new_set() -> void:
	if not library_mode:
		return
	var st := _make(&"N64BankSet")
	st.Name = _lib_tools().UniqueSetName("New set", null)
	# Starts with the selected instrument, if any.
	if _instrument:
		st.Add(_instrument)
	save_set(st)
	_select_meta(st)


func new_area() -> void:
	if not library_mode:
		return
	var a := _make(&"N64AudioArea")
	a.Name = "New area"
	if _set:
		if int(_set.Kind) == 1:
			a.SfxSets = [_set]
		else:
			a.MusicSets = [_set]
	save_area(a)
	_select_meta(a)


## A new instrument with the selected one's settings and zones (same samples).
func duplicate_variant() -> void:
	if not library_mode or _instrument == null:
		push_warning("N64 Sounds: select a library instrument to duplicate.")
		return
	var v = _lib_tools().DuplicateVariant(bank, _instrument, "")
	_mark_dirty()
	_select_meta(v)


## The open (saved) bank into the library plus a bank set named after it.
func convert_bank() -> void:
	if library_mode or bank == null or bank_path == "":
		push_warning("N64 Sounds: open a saved sound bank to convert.")
		return
	if dirty:
		_save()
	var t = _lib_tools()
	var err: String = t.ConvertBank(bank, bank.Name if bank.Name != "" else bank_path.get_file().get_basename())
	if err != "":
		push_error("N64 Sounds: converting %s failed: %s" % [bank_path, err])
		return
	print("[N64 Sounds] %s" % t.Summary)
	EditorInterface.get_resource_filesystem().scan()
	open_library()
	_select_meta(load(t.LastSetPath))


## Selects the tree item showing `r` (and opens its editor).
func _select_meta(r) -> void:
	if r == null:
		return
	_selected = r if "Adpcm" in r else null
	_instrument = r if "Zones" in r else null
	_set = r if "Entries" in r else null
	_area = r if "MusicSets" in r else null
	_song_shown = false
	_refresh_tree()
	_show_editor()


func _refresh_library_tree(root: TreeItem) -> void:
	var users := {}  # instrument -> set names
	for st in _sets:
		for e in st.Entries:
			var ins = e.get("instrument")
			if ins:
				if not users.has(ins):
					users[ins] = []
				users[ins].append(st.Name)
	var counts := {}  # sample -> instruments playing it
	for ins in bank.Instruments:
		var seen := {}
		for z in ins.Zones:
			var smp = z.get("sample")
			if smp and not seen.has(smp):
				seen[smp] = true
				counts[smp] = counts.get(smp, 0) + 1
	var insts := _tree.create_item(root)
	insts.set_text(0, "Instruments (%d)" % bank.Instruments.size())
	insts.set_selectable(0, false)
	for ins in bank.Instruments:
		var it := _tree.create_item(insts)
		var sets: Array = users.get(ins, [])
		it.set_text(0, "%s%s  (%.1f KB)%s" % ["[kit] " if ins.IsDrumKit else "", ins.Name, instrument_bytes(ins) / 1024.0,
			"  in " + ", ".join(sets) if not sets.is_empty() else ""])
		it.set_metadata(0, ins)
		var tips := PackedStringArray()
		if ins.has_meta(&"cd64_export"):
			tips.append("From the CD64 export \"%s\" (re-importing it replaces this)" % ins.get_meta(&"cd64_export"))
		if ins.has_meta(&"variant_of"):
			tips.append("Variant of %s" % ins.get_meta(&"variant_of"))
		tips.append("Bank sets: %s" % (", ".join(sets) if not sets.is_empty() else "none"))
		it.set_tooltip_text(0, "\n".join(tips))
		it.collapsed = ins != _instrument and not (_ctx_instrument == ins and _selected != null)
		if ins == _instrument:
			it.select(0)
		var seen := {}
		for z in ins.Zones:
			var smp = z.get("sample")
			if smp == null or seen.has(smp):
				continue
			seen[smp] = true
			var si := _tree.create_item(it)
			var n: int = counts.get(smp, 1)
			si.set_text(0, "%s   %.1f KB%s" % [smp.Name, smp.StoredBytes() / 1024.0, "  (shared by %d)" % n if n > 1 else ""])
			si.set_metadata(0, smp)
			if smp == _selected and _ctx_instrument == ins:
				si.select(0)
	var samples := _tree.create_item(root)
	samples.set_text(0, "Samples (%d)" % bank.Samples.size())
	samples.set_selectable(0, false)
	samples.collapsed = not (_selected != null and _ctx_instrument == null)
	for smp in bank.Samples:
		var si := _tree.create_item(samples)
		var n: int = counts.get(smp, 0)
		si.set_text(0, "%s   %s  %.1f KB  %s" % [smp.Name, _note_name(smp.RootKey), smp.StoredBytes() / 1024.0,
			"unused" if n == 0 else "%d instrument%s" % [n, "" if n == 1 else "s"]])
		si.set_metadata(0, smp)
		if smp == _selected and _ctx_instrument == null:
			si.select(0)
	var budget := budget_bytes()
	var sets_item := _tree.create_item(root)
	sets_item.set_text(0, "Bank sets (%d)" % _sets.size())
	sets_item.set_selectable(0, false)
	for st in _sets:
		var it := _tree.create_item(sets_item)
		var used: int = st.StoredBytes()
		it.set_text(0, "%s  [%s]  %.1f / %d KB%s" % [st.Name, "SFX" if int(st.Kind) == 1 else "Music", used / 1024.0, budget / 1024,
			"  OVER BUDGET" if used > budget else ""])
		if used > budget:
			it.set_custom_color(0, Color(1, 0.4, 0.35))
		it.set_metadata(0, st)
		it.set_tooltip_text(0, "%d instruments, %d samples (each once)" % [st.Entries.size(), st.DistinctSamples().size()])
		if st == _set:
			it.select(0)
	var areas_item := _tree.create_item(root)
	areas_item.set_text(0, "Areas (%d)" % _areas.size())
	areas_item.set_selectable(0, false)
	for a in _areas:
		var it := _tree.create_item(areas_item)
		var worst: int = a.WorstCaseBytes()
		it.set_text(0, "%s  %.1f / %d KB%s" % [a.Name, worst / 1024.0, budget / 1024, "  OVER BUDGET" if worst > budget else ""])
		if worst > budget:
			it.set_custom_color(0, Color(1, 0.4, 0.35))
		it.set_metadata(0, a)
		it.set_tooltip_text(0, AreaEditor.report(a, budget))
		if a == _area:
			it.select(0)


## The selected sample's settings and loop as processed (what a cancelled change returns to).
func _take_snapshot() -> void:
	if _selected:
		_snapshot = _selected.Settings.duplicate(true)
		_snapshot_loop = Vector2i(_selected.LoopStart, _selected.LoopEnd)


## Re-processing a sample other instruments play too: change all of them, fork a copy for
## the instrument the sample was opened under, or cancel (settings go back).
func _ask_shared() -> void:
	if _shared_dialog == null:
		_shared_dialog = ConfirmationDialog.new()
		_shared_dialog.ok_button_text = "Change all"
		_shared_dialog.confirmed.connect(func():
			_shared_ok[_selected] = true
			_reprocess_selected())
		_fork_button = _shared_dialog.add_button("Fork", true, "fork")
		_shared_dialog.custom_action.connect(func(_a):
			_shared_dialog.hide()
			_fork_selected())
		_shared_dialog.canceled.connect(_revert_selected)
		EditorInterface.get_base_control().add_child(_shared_dialog)
	var users: Array = bank.UsersOf(_selected)
	var ctx_ok: bool = _ctx_instrument != null and users.has(_ctx_instrument)
	_fork_button.visible = ctx_ok
	_fork_button.text = "Fork for %s" % _ctx_instrument.Name if ctx_ok else "Fork"
	_shared_dialog.dialog_text = "%s is played by %d instruments: %s.\nRe-processing it changes what all of them play.%s" % [
		_selected.Name, users.size(), ", ".join(users.map(func(i): return i.Name)),
		"\nFork: %s gets its own copy with the new settings (more sample RAM where both are loaded)." % _ctx_instrument.Name if ctx_ok
		else "\nTo change it for one instrument only, open the sample under that instrument and fork it."]
	_shared_dialog.popup_centered()


func _revert_selected() -> void:
	if _selected == null:
		return
	_selected.Settings = _snapshot.duplicate(true)
	_selected.LoopStart = _snapshot_loop.x
	_selected.LoopEnd = _snapshot_loop.y
	_load_settings()
	_update_info()
	_wave.queue_redraw()


func _fork_selected() -> void:
	if _selected == null or _ctx_instrument == null:
		return
	var pending: Dictionary = _selected.Settings.duplicate(true)
	_revert_selected()
	var orig = _selected
	var fork = _lib_tools().Fork(bank, orig, _ctx_instrument)
	fork.Settings = pending
	if _procs.has(orig):
		_procs[fork] = _procs[orig]
	_selected = fork
	_snap_for = fork
	_mark_dirty()
	_refresh_tree()
	_show_editor()
	_reprocess_selected()


# --- Library export ---------------------------------------------------------------------------------

## Asks which instruments (all, the selected one, the selected set's), then a folder.
func _dialog_export_library() -> void:
	if not library_mode or bank.Instruments.is_empty():
		push_warning("N64 Sounds: the library has no instruments to export.")
		return
	if _lib_export_ask == null:
		_lib_export_ask = ConfirmationDialog.new()
		_lib_export_ask.ok_button_text = "All instruments"
		_lib_export_ask.confirmed.connect(func(): _export_library_pick(PackedStringArray(), "%s library" % _project_name()))
		_lib_export_sel = _lib_export_ask.add_button("Selection", true, "sel")
		_lib_export_ask.custom_action.connect(func(_a):
			_lib_export_ask.hide()
			if _set:
				_export_library_pick(PackedStringArray(_set.Entries.filter(func(e): return e.get("instrument")).map(func(e): return e.instrument.Name)), _set.Name)
			elif _instrument:
				_export_library_pick(PackedStringArray([_instrument.Name]), _instrument.Name))
		EditorInterface.get_base_control().add_child(_lib_export_ask)
	var sel := ""
	if _set:
		sel = "the bank set %s's %d instruments" % [_set.Name, _set.Entries.size()]
	elif _instrument:
		sel = _instrument.Name
	_lib_export_sel.visible = sel != ""
	_lib_export_sel.text = "Only %s" % sel if sel != "" else "Selection"
	_lib_export_ask.dialog_text = "Export for CD64 (an export folder the CD64 plugin opens like a disc: SFZ, recordings, ADPCM, each sample's settings):\nall %d library instruments%s?" % [
		bank.Instruments.size(), ", or only %s" % sel if sel != "" else ""]
	_lib_export_ask.popup_centered()


func _export_library_pick(names: PackedStringArray, export_name: String) -> void:
	_lib_export_names = names
	_lib_export_name = export_name
	if dirty:
		_save_library()
	if _lib_export_dialog == null:
		_lib_export_dialog = EditorFileDialog.new()
		_lib_export_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
		_lib_export_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
		_lib_export_dialog.title = "Export library for CD64 (choose an empty folder)"
		_lib_export_dialog.dir_selected.connect(func(d): export_library(d, _lib_export_names, _lib_export_name))
		EditorInterface.get_base_control().add_child(_lib_export_dialog)
	_lib_export_dialog.popup_file_dialog()


## Writes library instruments `names` (empty = all) as a CD64 export into `folder`.
func export_library(folder: String, names: PackedStringArray, export_name: String) -> String:
	var t = _lib_tools()
	var err: String = t.ExportCd64(bank, names, folder, export_name)
	if err != "":
		push_error("N64 Sounds: library export failed: %s" % err)
	else:
		print("[N64 Sounds] %s" % t.Summary)
	return err


static func _project_name() -> String:
	var n := str(ProjectSettings.get_setting("application/config/name", "game"))
	return n if n != "" else "game"


# --- Dialogs / widgets ---------------------------------------------------------------------------

func _dialog_open() -> void:
	if _open_dialog == null:
		_open_dialog = _make_dialog(EditorFileDialog.FILE_MODE_OPEN_FILE, EditorFileDialog.ACCESS_RESOURCES, "Open sound bank", "*.res,*.tres", open_bank)
	_open_dialog.current_dir = BANK_DIR
	_open_dialog.popup_file_dialog()


func _dialog_save() -> void:
	if _save_dialog == null:
		_save_dialog = _make_dialog(EditorFileDialog.FILE_MODE_SAVE_FILE, EditorFileDialog.ACCESS_RESOURCES, "Save sound bank", "*.res", func(p):
			bank_path = p
			_save())
	DirAccess.make_dir_recursive_absolute(BANK_DIR)
	_save_dialog.current_dir = BANK_DIR
	_save_dialog.current_file = "%s.res" % (bank.Name if bank else "bank")
	_save_dialog.popup_file_dialog()


func _dialog_import() -> void:
	if _import_dialog == null:
		_import_dialog = _make_dialog(EditorFileDialog.FILE_MODE_OPEN_FILES, EditorFileDialog.ACCESS_FILESYSTEM, "Import recordings (WAV)", "*.wav", import_files, true)
	_import_dialog.popup_file_dialog()


func _dialog_import_cd64() -> void:
	if _cd64_dialog == null:
		_cd64_dialog = _make_dialog(EditorFileDialog.FILE_MODE_OPEN_ANY, EditorFileDialog.ACCESS_FILESYSTEM,
			"Import CD64 bank (export folder or .n64bank.json)", "*.n64bank.json", _cd64_chosen)
		_cd64_dialog.dir_selected.connect(_cd64_chosen)
	_cd64_dialog.popup_file_dialog()


## Asks where the export goes: into the instrument library (the default: samples shared
## with what the library has, a bank set for the export), into its own legacy bank
## (res://audio/banks/<name>.res), or into the open legacy bank (next to what it has: a song
## bank plus a set of effects, say). Re-importing overwrites what came from the export
## (re-processed samples too): the text says so.
func _cd64_chosen(path: String) -> void:
	var imp = _new_cd64_importer()
	var own: String = imp.BankPathFor(path) if imp else ""
	if own == "":
		push_error("N64 Sounds: no CD64 sidecar (.n64bank.json) in %s." % path)
		return
	var into_open := bank != null and not library_mode and bank_path != "" and bank_path != own
	if _cd64_confirm == null:
		_cd64_confirm = ConfirmationDialog.new()
		_cd64_confirm.ok_button_text = "Into library"
		_cd64_confirm.confirmed.connect(func(): import_cd64(_cd64_path, "library"))
		_cd64_own_button = _cd64_confirm.add_button("Own bank", true, "own")
		_cd64_open_button = _cd64_confirm.add_button("Into open bank", true, "open")
		_cd64_confirm.custom_action.connect(func(action):
			_cd64_confirm.hide()
			import_cd64(_cd64_path, _cd64_target if action == "open" else ""))
		EditorInterface.get_base_control().add_child(_cd64_confirm)
	_cd64_path = path
	_cd64_target = bank_path
	var export_name: String = imp.ExportName(path)
	var lines := PackedStringArray(["Import the CD64 export \"%s\":" % export_name,
		"- Into library: the instrument library (%s), samples shared with what it has, a bank set \"%s\" for the export (song exports keep their channels and programs)." % [library_root(), export_name],
		"- Own bank: the legacy bank %s%s." % [own, " (imported before: updated)" if ResourceLoader.exists(own) else ""]])
	if into_open:
		lines.append("- Into open bank: %s, next to what it has." % bank_path)
	lines.append("What an earlier import of \"%s\" brought is replaced (edits to it are lost); other exports' and your own samples and instruments are kept." % export_name)
	_cd64_confirm.dialog_text = "\n".join(lines)
	_cd64_open_button.visible = into_open
	_cd64_confirm.popup_centered()


func _make_dialog(mode: int, access: int, title: String, filter: String, cb: Callable, multi := false) -> EditorFileDialog:
	var d := EditorFileDialog.new()
	d.file_mode = mode
	d.access = access
	d.title = title
	d.add_filter(filter)
	if multi:
		d.files_selected.connect(cb)
	else:
		d.file_selected.connect(cb)
	EditorInterface.get_base_control().add_child(d)
	return d


static func _note_name(midi: int) -> String:
	const NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
	return "%s%d" % [NAMES[posmod(midi, 12)], midi / 12 - 1]


func _spin(lo: float, hi: float, step: float, suffix: String) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.suffix = suffix
	return s


func _btn(parent: Control, text: String, fn: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(fn)
	parent.add_child(b)
	return b
