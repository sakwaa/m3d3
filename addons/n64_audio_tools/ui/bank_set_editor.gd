@tool
extends VBoxContainer
## Bank set editor (N64 Sounds > Library > a bank set): the library instruments one song /
## area loads into sample RAM (N64BankSet). Add / remove instruments, each one's program,
## bank and (CD64 song sets) channel in this set; the set's RAM (distinct samples, shared
## ones once) against the budget, and program clashes. Saves the set on every change.
## Programs of added instruments: their own if free in the set, else the lowest free one
## (N64BankSet.Add); drum kits stay kits (channel 10, matched by program).
## Sound-effect sets: each effect has a Play button (instead of the channel), played by name
## through an N64SfxPlayer as the game plays it, with the pitch / volume of the audition bar.

var workspace: Control  # sound_workspace.gd
var set: Resource  # N64BankSet

var _name: LineEdit
var _kind: OptionButton
var _ram: Label
var _add: OptionButton
var _grid: GridContainer
var _status: Label
var _audition: HFlowContainer
var _pitch: HSlider
var _volume: HSlider
var _pitch_label: Label
var _sfx_player: Node  # N64SfxPlayer, made on the first audition
var _updating := false


func _init() -> void:
	size_flags_vertical = SIZE_EXPAND_FILL
	add_theme_constant_override(&"separation", 6)
	var top := HFlowContainer.new()
	add_child(top)
	top.add_child(_label("Bank set"))
	_name = LineEdit.new()
	_name.custom_minimum_size.x = 180
	_name.text_submitted.connect(func(t): _rename(t))
	_name.focus_exited.connect(func(): _rename(_name.text))
	top.add_child(_name)
	_kind = OptionButton.new()
	_kind.add_item("Music (songs)")
	_kind.add_item("Sound effects")
	_kind.tooltip_text = "Music sets are played by songs (by program). Sound-effect sets are looked up by instrument name and load next to the area's music set."
	_kind.item_selected.connect(func(i): if set and not _updating: set.Kind = i; _changed())
	top.add_child(_kind)
	_ram = Label.new()
	_ram.mouse_filter = Control.MOUSE_FILTER_PASS
	top.add_child(_ram)

	var add := HFlowContainer.new()
	add_child(add)
	_add = OptionButton.new()
	_add.custom_minimum_size.x = 220
	_add.fit_to_longest_item = false
	add.add_child(_add)
	_btn(add, "Add to set", _add_selected)
	var hint := _label("Instruments are shared with the library: edit them there. Samples several instruments of the set play count once.")
	hint.modulate = Color(1, 1, 1, 0.55)
	add.add_child(hint)

	_audition = HFlowContainer.new()
	_audition.visible = false
	add_child(_audition)
	_audition.add_child(_label("Audition: pitch"))
	_pitch = HSlider.new()
	_pitch.min_value = -24
	_pitch.max_value = 24
	_pitch.step = 0.5
	_pitch.custom_minimum_size.x = 140
	_pitch.tooltip_text = "Semitones above the effect's natural key (N64SfxPlayer.Play pitchSemitones). Bends effects that are playing."
	_pitch.value_changed.connect(_pitch_changed)
	_audition.add_child(_pitch)
	_pitch_label = _label("+0 st")
	_pitch_label.custom_minimum_size.x = 50
	_audition.add_child(_pitch_label)
	_audition.add_child(_label("volume"))
	_volume = HSlider.new()
	_volume.max_value = 1
	_volume.step = 0.01
	_volume.value = 1
	_volume.custom_minimum_size.x = 100
	_volume.value_changed.connect(func(v): _sfx_set_all("SetVolume", v))
	_audition.add_child(_volume)
	_btn(_audition, "Stop", func(): if _sfx_player: _sfx_player.StopAll(0.1))
	var ahint := _label("Looping effects play until Stop. Effects play on their own voices, in parallel with the music.")
	ahint.modulate = Color(1, 1, 1, 0.55)
	_audition.add_child(ahint)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_grid = GridContainer.new()
	_grid.columns = 7
	_grid.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(_grid)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.modulate = Color(1, 0.75, 0.45)
	add_child(_status)


func edit(s: Resource) -> void:
	if _sfx_player and s != set:
		_sfx_player.StopAll(0.05)
	set = s
	refresh()


func refresh() -> void:
	if set == null:
		return
	_updating = true
	_name.text = set.Name
	_kind.select(int(set.Kind))
	_audition.visible = is_sfx()
	var budget: int = workspace.budget_bytes() if workspace else 512 * 1024
	var used: int = set.StoredBytes()
	_ram.text = "  %d instruments, %d samples: %.1f / %d KB%s" % [set.Entries.size(), set.DistinctSamples().size(), used / 1024.0, budget / 1024,
		"  OVER BUDGET by %.1f KB" % ((used - budget) / 1024.0) if used > budget else ""]
	_ram.add_theme_color_override(&"font_color", Color(1, 0.4, 0.35) if used > budget else (Color(1, 0.85, 0.4) if used > budget * 0.8 else Color(1, 1, 1)))
	_ram.tooltip_text = "Sample RAM of the set: each distinct sample once (Project Settings > n64/audio/bank_budget_kb)."
	_add.clear()
	var lib = workspace.bank if workspace and workspace.library_mode else null
	if lib:
		for ins in lib.Instruments:
			if not set.Has(ins):
				_add.add_item("%s%s" % ["[kit] " if ins.IsDrumKit else "", ins.Name])
				_add.set_item_metadata(_add.item_count - 1, ins)
	if _add.item_count == 0:
		_add.add_item("(every library instrument is in the set)")
		_add.disabled = true
	else:
		_add.disabled = false
	_rebuild_grid()
	var clashes: PackedStringArray = set.Clashes()
	_status.text = "Program clashes (the first listed plays): " + ", ".join(clashes) if not clashes.is_empty() else ""
	_updating = false


func _rebuild_grid() -> void:
	for c in _grid.get_children():
		c.queue_free()
	for h in ["Instrument", "Program", "Bank", "Audition" if is_sfx() else "Channel", "Samples", "Unique to it", ""]:
		var l := _label(h)
		l.modulate = Color(1, 1, 1, 0.55)
		_grid.add_child(l)
	for i in set.Entries.size():
		var e: Dictionary = set.Entries[i]
		var ins = e.get("instrument")
		var n := _label(("%s%s" % ["[kit] " if ins.IsDrumKit else "", ins.Name]) if ins else "(missing instrument)")
		n.size_flags_horizontal = SIZE_EXPAND_FILL
		n.clip_text = true
		n.custom_minimum_size.x = 140
		if ins and ins.has_meta(&"variant_of"):
			n.tooltip_text = "Variant of %s" % ins.get_meta(&"variant_of")
		_grid.add_child(n)
		var prog := _spin(0, 127)
		prog.value = int(e.get("program", 0))
		prog.tooltip_text = "Kit program (channel 10 picks the kit by program)" if ins and ins.IsDrumKit else "MIDI program in this set"
		prog.value_changed.connect(func(v): _entry(i, "program", int(v)))
		_grid.add_child(prog)
		var bank := _spin(0, 128)
		bank.value = int(e.get("bank", 0))
		bank.tooltip_text = "MIDI bank (CC0). Drum kits ignore it."
		bank.value_changed.connect(func(v): _entry(i, "bank", int(v)))
		_grid.add_child(bank)
		if is_sfx():
			var play := _btn(_grid, "Play", func(): play_effect(ins.Name if ins else ""))
			play.disabled = ins == null
			play.tooltip_text = "Plays the effect by name, as N64SfxPlayer.Play(\"%s\") does in the game" % (ins.Name if ins else "")
		else:
			var ch := _spin(0, 16)
			ch.value = int(e.get("channel", 0))
			ch.tooltip_text = "CD64 song slot: the MIDI channel this instrument was previewed on (0 = none). The song editor lists slots by channel."
			ch.value_changed.connect(func(v): _entry(i, "channel", int(v)))
			_grid.add_child(ch)
		var own := 0
		var all := 0
		if ins:
			var others := {}
			for j in set.Entries.size():
				var o = set.Entries[j].get("instrument")
				if j != i and o:
					for z in o.Zones:
						if z.get("sample"):
							others[z.sample] = true
			var seen := {}
			for z in ins.Zones:
				var s = z.get("sample")
				if s and not seen.has(s):
					seen[s] = true
					all += s.StoredBytes()
					if not others.has(s):
						own += s.StoredBytes()
		_grid.add_child(_label("%.1f KB" % (all / 1024.0)))
		var u := _label("%.1f KB" % (own / 1024.0))
		u.tooltip_text = "What removing it from the set frees (samples no other instrument of the set plays)"
		_grid.add_child(u)
		var del := _btn(_grid, "Remove", func(): set.Entries.remove_at(i); _changed())
		del.tooltip_text = "Remove from the set (the instrument stays in the library)"


func is_sfx() -> bool:
	return set != null and int(set.Kind) == 1


## Plays effect `effect_name` of the set (audition bar's pitch / volume); returns its handle.
func play_effect(effect_name: String) -> int:
	if set == null or effect_name == "":
		return 0
	if _sfx_player == null:
		_sfx_player = load("res://game/audio/N64SfxPlayer.cs").new()
		add_child(_sfx_player)
	for s in _sfx_player.LoadedSets():
		if s != set:
			_sfx_player.Unload(s)
	_sfx_player.Load(set)
	return _sfx_player.Play(effect_name, _pitch.value, _volume.value, 0.0, -1, -1)


func _pitch_changed(v: float) -> void:
	_pitch_label.text = "%+.1f st" % v
	_sfx_set_all("SetPitch", v)


## Bends the effects playing now (`method`: SetPitch / SetVolume).
func _sfx_set_all(method: String, v: float) -> void:
	if _sfx_player == null:
		return
	for h in _handles():
		_sfx_player.call(method, h, v)


func _handles() -> Array:
	return _sfx_player.Handles() if _sfx_player else []


func _entry(i: int, key: String, value: int) -> void:
	if _updating or set == null:
		return
	set.Entries[i][key] = value
	_changed()


func _add_selected() -> void:
	if set == null or _add.disabled or _add.selected < 0:
		return
	var ins = _add.get_item_metadata(_add.selected)
	if ins:
		set.Add(ins)
		_changed()


func _rename(t: String) -> void:
	if _updating or set == null or t == set.Name or t.strip_edges() == "":
		return
	set.Name = t.strip_edges()
	_changed()


func _changed() -> void:
	set.emit_changed()
	if workspace:
		workspace.save_set(set)
	refresh()


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _spin(lo: float, hi: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 1
	return s


func _btn(parent: Control, text: String, fn: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(fn)
	parent.add_child(b)
	return b
