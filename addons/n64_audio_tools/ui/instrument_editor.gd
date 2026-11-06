@tool
extends VBoxContainer
## Instrument editor of the N64 Sounds workspace:
##  - settings: name, General MIDI program (drum kits: bank 128), volume, pan, envelope
##    (drawn), vibrato;
##  - zone map: keys left to right, velocity bottom to top; each zone a box labelled with
##    its sample, its root key marked. Drag edges to resize, the middle to move, double-click
##    empty space to add a zone with the chosen sample; Delete removes the selected zone;
##  - zone settings: sample, key / velocity range, root key, tuning, volume, pan;
##  - "Spread by root key": each zone covers the keys nearest its root (multi-sampled
##    instruments in one click). Drum kits: zones are single keys, named per General MIDI.

const KEY_LO := 0
const KEY_HI := 127
const GM := ["Acoustic Grand Piano", "Bright Acoustic Piano", "Electric Grand Piano", "Honky-tonk Piano", "Electric Piano 1", "Electric Piano 2", "Harpsichord", "Clavinet",
	"Celesta", "Glockenspiel", "Music Box", "Vibraphone", "Marimba", "Xylophone", "Tubular Bells", "Dulcimer",
	"Drawbar Organ", "Percussive Organ", "Rock Organ", "Church Organ", "Reed Organ", "Accordion", "Harmonica", "Tango Accordion",
	"Acoustic Guitar (nylon)", "Acoustic Guitar (steel)", "Electric Guitar (jazz)", "Electric Guitar (clean)", "Electric Guitar (muted)", "Overdriven Guitar", "Distortion Guitar", "Guitar Harmonics",
	"Acoustic Bass", "Electric Bass (finger)", "Electric Bass (pick)", "Fretless Bass", "Slap Bass 1", "Slap Bass 2", "Synth Bass 1", "Synth Bass 2",
	"Violin", "Viola", "Cello", "Contrabass", "Tremolo Strings", "Pizzicato Strings", "Orchestral Harp", "Timpani",
	"String Ensemble 1", "String Ensemble 2", "Synth Strings 1", "Synth Strings 2", "Choir Aahs", "Voice Oohs", "Synth Voice", "Orchestra Hit",
	"Trumpet", "Trombone", "Tuba", "Muted Trumpet", "French Horn", "Brass Section", "Synth Brass 1", "Synth Brass 2",
	"Soprano Sax", "Alto Sax", "Tenor Sax", "Baritone Sax", "Oboe", "English Horn", "Bassoon", "Clarinet",
	"Piccolo", "Flute", "Recorder", "Pan Flute", "Blown Bottle", "Shakuhachi", "Whistle", "Ocarina",
	"Lead 1 (square)", "Lead 2 (sawtooth)", "Lead 3 (calliope)", "Lead 4 (chiff)", "Lead 5 (charang)", "Lead 6 (voice)", "Lead 7 (fifths)", "Lead 8 (bass + lead)",
	"Pad 1 (new age)", "Pad 2 (warm)", "Pad 3 (polysynth)", "Pad 4 (choir)", "Pad 5 (bowed)", "Pad 6 (metallic)", "Pad 7 (halo)", "Pad 8 (sweep)",
	"FX 1 (rain)", "FX 2 (soundtrack)", "FX 3 (crystal)", "FX 4 (atmosphere)", "FX 5 (brightness)", "FX 6 (goblins)", "FX 7 (echoes)", "FX 8 (sci-fi)",
	"Sitar", "Banjo", "Shamisen", "Koto", "Kalimba", "Bagpipe", "Fiddle", "Shanai",
	"Tinkle Bell", "Agogo", "Steel Drums", "Woodblock", "Taiko Drum", "Melodic Tom", "Synth Drum", "Reverse Cymbal",
	"Guitar Fret Noise", "Breath Noise", "Seashore", "Bird Tweet", "Telephone Ring", "Helicopter", "Applause", "Gunshot"]
const GM_DRUMS := {35: "Acoustic Bass Drum", 36: "Bass Drum", 37: "Side Stick", 38: "Snare", 39: "Hand Clap", 40: "Electric Snare",
	41: "Low Floor Tom", 42: "Closed Hi-hat", 43: "High Floor Tom", 44: "Pedal Hi-hat", 45: "Low Tom", 46: "Open Hi-hat",
	47: "Low-Mid Tom", 48: "Hi-Mid Tom", 49: "Crash 1", 50: "High Tom", 51: "Ride 1", 52: "Chinese Cymbal", 53: "Ride Bell",
	54: "Tambourine", 55: "Splash", 56: "Cowbell", 57: "Crash 2", 58: "Vibraslap", 59: "Ride 2", 60: "Hi Bongo", 61: "Low Bongo",
	62: "Mute Hi Conga", 63: "Open Hi Conga", 64: "Low Conga", 65: "High Timbale", 66: "Low Timbale", 67: "High Agogo",
	68: "Low Agogo", 69: "Cabasa", 70: "Maracas", 71: "Short Whistle", 72: "Long Whistle", 73: "Short Guiro", 74: "Long Guiro",
	75: "Claves", 76: "Hi Wood Block", 77: "Low Wood Block", 78: "Mute Cuica", 79: "Open Cuica", 80: "Mute Triangle", 81: "Open Triangle"}

var workspace: Control  # sound_workspace.gd
var instrument: Resource  # N64Instrument
var sel_zone := -1

var _name: LineEdit
var _program: OptionButton
var _bank: SpinBox
var _drum: CheckBox
var _volume: HSlider
var _pan: HSlider
var _env: Array[SpinBox] = []
var _env_view: Control
var _vib: Array[SpinBox] = []
var _map: Control
var _zone_grid: GridContainer
var _zone_sample: OptionButton
var _zone_fields := {}
var _updating := false
var _drag := ""
var _drag_from := Vector2.ZERO
var _drag_zone := {}


func _init() -> void:
	var s := EditorInterface.get_editor_scale()
	var top := HFlowContainer.new()
	add_child(top)
	_name = LineEdit.new()
	_name.custom_minimum_size.x = 180 * s
	_name.text_changed.connect(func(t): if instrument and not _updating: instrument.Name = t; _changed(true))
	top.add_child(_name)
	_program = OptionButton.new()
	_program.custom_minimum_size.x = 230 * s
	_program.item_selected.connect(func(i): if instrument and not _updating: instrument.Program = i; _changed(true))
	top.add_child(_program)
	top.add_child(_label("Bank"))
	_bank = _spin(0, 128, 1)
	_bank.value_changed.connect(func(v): if instrument and not _updating: instrument.Bank = int(v); _changed())
	top.add_child(_bank)
	_drum = CheckBox.new()
	_drum.text = "Drum kit"
	_drum.toggled.connect(_on_drum)
	top.add_child(_drum)
	top.add_child(_label("Volume"))
	_volume = _slider(0, 1, 0.01)
	_volume.value_changed.connect(func(v): if instrument and not _updating: instrument.Volume = v; _changed())
	top.add_child(_volume)
	top.add_child(_label("Pan"))
	_pan = _slider(-1, 1, 0.05)
	_pan.value_changed.connect(func(v): if instrument and not _updating: instrument.Pan = v; _changed())
	top.add_child(_pan)

	var body := HSplitContainer.new()
	body.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(body)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = SIZE_EXPAND_FILL
	body.add_child(left)
	var tools := HFlowContainer.new()
	left.add_child(tools)
	tools.add_child(_label("Add zone with"))
	_zone_sample = OptionButton.new()
	_zone_sample.custom_minimum_size.x = 160 * s
	tools.add_child(_zone_sample)
	_btn(tools, "Add zone", func(): _add_zone(-1))
	_btn(tools, "Delete zone", _delete_zone)
	_btn(tools, "Spread by root key", _spread)
	_map = Control.new()
	_map.size_flags_vertical = SIZE_EXPAND_FILL
	_map.custom_minimum_size = Vector2(200, 170 * s)
	_map.clip_contents = true
	_map.focus_mode = Control.FOCUS_ALL
	_map.draw.connect(_draw_map)
	_map.gui_input.connect(_map_input)
	left.add_child(_map)
	var hint := _label("Keys → / velocity ↑. Drag edges to resize, middle to move; double-click to add; Delete removes.")
	hint.modulate = Color(1, 1, 1, 0.5)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = 100
	left.add_child(hint)

	var right := ScrollContainer.new()
	right.custom_minimum_size.x = 300 * s
	right.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(right)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = SIZE_EXPAND_FILL
	right.add_child(col)
	col.add_child(_header("Envelope"))
	_env_view = Control.new()
	_env_view.custom_minimum_size.y = 70 * s
	_env_view.draw.connect(_draw_env)
	col.add_child(_env_view)
	var eg := GridContainer.new()
	eg.columns = 2
	col.add_child(eg)
	for spec in [["Attack", 0, 10, 0.001, " s"], ["Decay", 0, 20, 0.01, " s"], ["Sustain", 0, 1, 0.01, ""], ["Release", 0, 20, 0.01, " s"]]:
		eg.add_child(_label(spec[0]))
		var sp := _spin(spec[1], spec[2], spec[3], spec[4])
		sp.value_changed.connect(func(_v): _env_changed())
		sp.size_flags_horizontal = SIZE_EXPAND_FILL
		eg.add_child(sp)
		_env.append(sp)
	col.add_child(_header("Vibrato"))
	var vg := GridContainer.new()
	vg.columns = 2
	col.add_child(vg)
	for spec in [["Depth", 0, 200, 1, " cents"], ["Rate", 0.1, 20, 0.1, " Hz"], ["Delay", 0, 5, 0.01, " s"]]:
		vg.add_child(_label(spec[0]))
		var sp := _spin(spec[1], spec[2], spec[3], spec[4])
		sp.value_changed.connect(func(_v): _vib_changed())
		sp.size_flags_horizontal = SIZE_EXPAND_FILL
		vg.add_child(sp)
		_vib.append(sp)
	col.add_child(_header("Selected zone"))
	_zone_grid = GridContainer.new()
	_zone_grid.columns = 2
	col.add_child(_zone_grid)
	_zone_grid.add_child(_label("Sample"))
	var zs := OptionButton.new()
	zs.size_flags_horizontal = SIZE_EXPAND_FILL
	zs.item_selected.connect(func(i): _zone_set("sample", zs.get_item_metadata(i)))
	_zone_grid.add_child(zs)
	_zone_fields["sample"] = zs
	for spec in [["key_lo", "Key low", 0, 127, 1, ""], ["key_hi", "Key high", 0, 127, 1, ""], ["vel_lo", "Velocity low", 0, 127, 1, ""],
			["vel_hi", "Velocity high", 0, 127, 1, ""], ["root_key", "Root key", -1, 127, 1, ""], ["tune_cents", "Tune", -1200, 1200, 1, " c"],
			["volume", "Volume", 0, 1, 0.01, ""], ["pan", "Pan", -1, 1, 0.05, ""]]:
		_zone_grid.add_child(_label(spec[1]))
		var sp := _spin(spec[2], spec[3], spec[4], spec[5])
		sp.size_flags_horizontal = SIZE_EXPAND_FILL
		var key: String = spec[0]
		sp.value_changed.connect(func(v): _zone_set(key, int(v) if key in ["key_lo", "key_hi", "vel_lo", "vel_hi", "root_key"] else v))
		if key == "root_key":
			sp.tooltip_text = "-1 = the sample's own root key"
		_zone_grid.add_child(sp)
		_zone_fields[key] = sp


func edit(ins: Resource) -> void:
	instrument = ins
	sel_zone = -1
	refresh()


func refresh() -> void:
	if instrument == null:
		return
	_updating = true
	_name.text = instrument.Name
	_program.clear()
	if instrument.IsDrumKit:
		for i in 128:
			_program.add_item("%03d  %s" % [i, "Standard Kit" if i == 0 else "Kit %d" % i])
	else:
		for i in 128:
			_program.add_item("%03d  %s" % [i, GM[i]])
	_program.select(instrument.Program)
	_bank.value = instrument.Bank
	_drum.button_pressed = instrument.IsDrumKit
	_volume.value = instrument.Volume
	_pan.value = instrument.Pan
	var e: Vector4 = instrument.Envelope
	for i in 4:
		_env[i].value = e[i]
	var v: Vector3 = instrument.Vibrato
	for i in 3:
		_vib[i].value = v[i]
	_fill_samples(_zone_sample)
	_fill_samples(_zone_fields["sample"])
	_updating = false
	_refresh_zone()
	_map.queue_redraw()
	_env_view.queue_redraw()


func _fill_samples(ob: OptionButton) -> void:
	var keep = ob.get_item_metadata(ob.selected) if ob.selected >= 0 else null
	ob.clear()
	for s in workspace.bank.Samples:
		ob.add_item("%s  (%s)" % [s.Name, _note(s.RootKey)])
		ob.set_item_metadata(ob.item_count - 1, s)
		if s == keep:
			ob.select(ob.item_count - 1)
	if ob.selected < 0 and ob.item_count > 0:
		ob.select(0)


func _refresh_zone() -> void:
	var z = _zone()
	for c in _zone_fields.values():
		if c is Range:
			c.editable = z != null
		else:
			c.disabled = z == null
	if z == null:
		return
	_updating = true
	var ob: OptionButton = _zone_fields["sample"]
	for i in ob.item_count:
		if ob.get_item_metadata(i) == z.get("sample"):
			ob.select(i)
	for k in _zone_fields:
		if k != "sample":
			_zone_fields[k].value = z.get(k, _default(k))
	_updating = false


func _zone():
	return instrument.Zones[sel_zone] if instrument and sel_zone >= 0 and sel_zone < instrument.Zones.size() else null


static func _default(k: String) -> float:
	return {key_lo = 0, key_hi = 127, vel_lo = 0, vel_hi = 127, root_key = -1, tune_cents = 0, volume = 1, pan = 0}.get(k, 0)


func _zone_set(key: String, value) -> void:
	var z = _zone()
	if _updating or z == null:
		return
	z[key] = value
	_changed()


func _changed(names := false) -> void:
	workspace.mark_dirty()
	if names:
		workspace.refresh_tree_keep()
	_map.queue_redraw()


func _env_changed() -> void:
	if _updating or instrument == null:
		return
	instrument.Envelope = Vector4(_env[0].value, _env[1].value, _env[2].value, _env[3].value)
	_env_view.queue_redraw()
	_changed()


func _vib_changed() -> void:
	if _updating or instrument == null:
		return
	instrument.Vibrato = Vector3(_vib[0].value, _vib[1].value, _vib[2].value)
	_changed()


func _on_drum(on: bool) -> void:
	if _updating or instrument == null:
		return
	instrument.IsDrumKit = on
	instrument.Bank = 128 if on else 0
	refresh()
	_changed(true)


# --- Zones -------------------------------------------------------------------------------------

## New zone with the chosen sample: drum kits get the next free key (or `key`); melodic
## instruments the whole keyboard (or around `key`).
func _add_zone(key: int) -> void:
	if instrument == null or _zone_sample.selected < 0:
		return
	var smp = _zone_sample.get_item_metadata(_zone_sample.selected)
	var z := {sample = smp, key_lo = 0, key_hi = 127, vel_lo = 0, vel_hi = 127, root_key = -1, tune_cents = 0.0, volume = 1.0, pan = 0.0}
	if instrument.IsDrumKit:
		var k := key
		if k < 0:
			k = 36
			while _drum_key_used(k) and k < 127:
				k += 1
		z.key_lo = k
		z.key_hi = k
	elif key >= 0:
		z.key_lo = maxi(key - 6, 0)
		z.key_hi = mini(key + 6, 127)
	instrument.Zones.append(z)
	sel_zone = instrument.Zones.size() - 1
	_refresh_zone()
	_changed(true)


func _drum_key_used(k: int) -> bool:
	for z in instrument.Zones:
		if z.get("key_lo", 0) <= k and z.get("key_hi", 127) >= k:
			return true
	return false


func _delete_zone() -> void:
	if _zone() == null:
		return
	instrument.Zones.remove_at(sel_zone)
	sel_zone = -1
	_refresh_zone()
	_changed(true)


## Melodic instruments: zones sorted by root key, each covering the keys up to halfway to
## its neighbours (the lowest down to 0, the highest up to 127).
func _spread() -> void:
	if instrument == null or instrument.IsDrumKit or instrument.Zones.is_empty():
		return
	var zs := []
	for z in instrument.Zones:
		zs.append([_root_of(z), z])
	zs.sort_custom(func(a, b): return a[0] < b[0])
	for i in zs.size():
		var z: Dictionary = zs[i][1]
		z.key_lo = 0 if i == 0 else int(floor((zs[i - 1][0] + zs[i][0]) * 0.5)) + 1
		z.key_hi = 127 if i == zs.size() - 1 else int(floor((zs[i][0] + zs[i + 1][0]) * 0.5))
	_refresh_zone()
	_changed()


func _root_of(z: Dictionary) -> int:
	var r: int = z.get("root_key", -1)
	if r >= 0:
		return r
	var s = z.get("sample")
	return s.RootKey if s else 60


# --- Zone map -------------------------------------------------------------------------------------

func _kx(key: float) -> float:
	return key / 128.0 * _map.size.x


func _vy(vel: float) -> float:
	return (1.0 - vel / 128.0) * (_map.size.y - 22.0)


func _zone_rect(z: Dictionary) -> Rect2:
	var x0 := _kx(z.get("key_lo", 0))
	var x1 := _kx(z.get("key_hi", 127) + 1)
	var y0 := _vy(z.get("vel_hi", 127) + 1)
	var y1 := _vy(z.get("vel_lo", 0))
	return Rect2(x0, y0, x1 - x0, y1 - y0)


func _draw_map() -> void:
	var m := _map
	var font := m.get_theme_default_font()
	m.draw_rect(Rect2(Vector2.ZERO, m.size), Color(0.09, 0.1, 0.12))
	if instrument == null:
		return
	var kb_h := 22.0
	# Octave lines + labels, and a key strip along the bottom.
	for k in range(0, 128):
		var x := _kx(k)
		var black := posmod(k, 12) in [1, 3, 6, 8, 10]
		m.draw_rect(Rect2(x, m.size.y - kb_h, _kx(k + 1) - x, kb_h), Color(0.15, 0.15, 0.15) if black else Color(0.85, 0.85, 0.85))
		if posmod(k, 12) == 0:
			m.draw_line(Vector2(x, 0), Vector2(x, m.size.y - kb_h), Color(1, 1, 1, 0.08))
			m.draw_string(font, Vector2(x + 2, m.size.y - 4), "C%d" % (k / 12 - 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0, 0, 0, 0.7))
	for i in instrument.Zones.size():
		var z: Dictionary = instrument.Zones[i]
		var r := _zone_rect(z)
		var s = z.get("sample")
		var col := Color.from_hsv(fposmod(hash(s.Name if s else "") / 1000.0, 1.0), 0.5, 0.85) if s else Color(0.6, 0.6, 0.6)
		m.draw_rect(r, Color(col, 0.35))
		m.draw_rect(r, Color(1.0, 0.85, 0.2) if i == sel_zone else Color(col, 0.9), false, 2.0 if i == sel_zone else 1.0)
		var root := _root_of(z)
		if root >= z.get("key_lo", 0) and root <= z.get("key_hi", 127) and not instrument.IsDrumKit:
			var rx := _kx(root + 0.5)
			m.draw_line(Vector2(rx, r.position.y), Vector2(rx, r.end.y), Color(0.4, 1.0, 0.5), 2.0)
		var label: String = s.Name if s else "(no sample)"
		if instrument.IsDrumKit:
			label = "%s: %s" % [GM_DRUMS.get(int(z.get("key_lo", 0)), _note(z.get("key_lo", 0))), label]
		if r.size.x > 24:
			m.draw_string(font, r.position + Vector2(3, 13), label, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 4, 11, Color(1, 1, 1, 0.9))


func _zone_at(p: Vector2) -> int:
	for i in range(instrument.Zones.size() - 1, -1, -1):
		if _zone_rect(instrument.Zones[i]).grow(3).has_point(p):
			return i
	return -1


func _map_input(event: InputEvent) -> void:
	if instrument == null:
		return
	var mb := event as InputEventMouseButton
	if mb and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			_map.grab_focus()
			if mb.double_click and _zone_at(mb.position) < 0:
				_add_zone(clampi(int(mb.position.x / _map.size.x * 128.0), 0, 127))
				return
			sel_zone = _zone_at(mb.position)
			_drag = ""
			if sel_zone >= 0:
				var r := _zone_rect(instrument.Zones[sel_zone])
				_drag = "move"
				if absf(mb.position.x - r.position.x) < 6:
					_drag = "left"
				elif absf(mb.position.x - r.end.x) < 6:
					_drag = "right"
				elif absf(mb.position.y - r.position.y) < 5:
					_drag = "top"
				elif absf(mb.position.y - r.end.y) < 5:
					_drag = "bottom"
				_drag_from = mb.position
				_drag_zone = instrument.Zones[sel_zone].duplicate()
			_refresh_zone()
			_map.queue_redraw()
		else:
			if _drag != "":
				_changed()
			_drag = ""
		_map.accept_event()
	var mm := event as InputEventMouseMotion
	if mm and _drag != "" and _zone() != null:
		var z: Dictionary = _zone()
		var dk := roundi((mm.position.x - _drag_from.x) / _map.size.x * 128.0)
		var dv := -roundi((mm.position.y - _drag_from.y) / maxf(_map.size.y - 22.0, 1.0) * 128.0)
		var o := _drag_zone
		match _drag:
			"left":
				z.key_lo = clampi(o.key_lo + dk, 0, z.key_hi)
			"right":
				z.key_hi = clampi(o.key_hi + dk, z.key_lo, 127)
			"top":
				z.vel_hi = clampi(o.vel_hi + dv, z.vel_lo, 127)
			"bottom":
				z.vel_lo = clampi(o.vel_lo + dv, 0, z.vel_hi)
			"move":
				var span: int = o.key_hi - o.key_lo
				z.key_lo = clampi(o.key_lo + dk, 0, 127 - span)
				z.key_hi = z.key_lo + span
		_refresh_zone()
		_map.queue_redraw()
	var key := event as InputEventKey
	if key and key.pressed and key.keycode in [KEY_DELETE, KEY_BACKSPACE]:
		_delete_zone()
		_map.accept_event()


func _draw_env() -> void:
	var v := _env_view
	v.draw_rect(Rect2(Vector2.ZERO, v.size), Color(0.09, 0.1, 0.12))
	if instrument == null:
		return
	var e: Vector4 = instrument.Envelope
	var hold := 0.4
	var total := maxf(e.x + e.y + hold + e.w, 0.01)
	var sx := v.size.x / total
	var h := v.size.y - 6
	var pts := PackedVector2Array([Vector2(0, v.size.y - 3), Vector2(e.x * sx, 3),
		Vector2((e.x + e.y) * sx, 3 + h * (1.0 - e.z)), Vector2((e.x + e.y + hold) * sx, 3 + h * (1.0 - e.z)),
		Vector2(total * sx, v.size.y - 3)])
	v.draw_polyline(pts, Color(0.95, 0.75, 0.35), 2.0)
	v.draw_string(v.get_theme_default_font(), Vector2(4, 12), "A  D  S  R", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 1, 1, 0.4))


# --- Widgets ------------------------------------------------------------------------------------

static func _note(midi: int) -> String:
	const NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
	return "%s%d" % [NAMES[posmod(midi, 12)], midi / 12 - 1]


func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l


func _header(t: String) -> Label:
	var l := _label(t)
	l.add_theme_color_override(&"font_color", Color(0.7, 0.85, 1.0))
	return l


func _spin(lo: float, hi: float, step: float, suffix := "") -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.suffix = suffix
	return s


func _slider(lo: float, hi: float, step: float) -> HSlider:
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.custom_minimum_size.x = 90
	return s


func _btn(parent: Control, text: String, fn: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(fn)
	parent.add_child(b)
	return b
